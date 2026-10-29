"""원본 보장을 C#/Unity와 실제 서버 대체 검사에 연결하고 미검증을 통과로 세지 않는다."""
import argparse
import csv
import hashlib
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--strict", action="store_true", help="미이관 또는 미검증 테스트가 있으면 실패")
parser.add_argument("--run-rust", nargs=3, action="append", metavar=("PACKAGE", "TARGET", "FILTER"), default=[],
                    help="PACKAGE의 lib 또는 integration TARGET에서 FILTER(all은 전체)를 실행해 현재 소스 증거 기록")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
sim = root / "game-rust/crates/sim"
client = root / "client"
ported = client / "Tools/LockstepProbe/PortedTests"
generated = client / "Tools/LockstepProbe/.generated"
log = generated / "latest-parity.log"
sources = list((sim / "src").rglob("*.rs")) + list((sim / "tests").rglob("*.rs"))

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def rust_inputs(package, target):
    source_root = root / ("game-rust/crates/sim" if package == "ac-sim" else "game-rust/crates")
    paths = list(source_root.rglob("*.rs"))
    paths += list((root / "game-rust").glob("Cargo.*")) + list((root / "game-rust/crates").rglob("Cargo.toml"))
    if target != "lib":
        paths += list((root / "database/migration").glob("*.sql"))
        paths += list((client / "LocalPackages/com.arcanecasters.lockstep/Runtime").rglob("*.cs"))
        paths += list((client / "Tools/LockstepVerifier").glob("*.cs"))
    return {path.relative_to(root).as_posix(): sha(path) for path in sorted(set(paths))}

run_failed = False
for package, target, test_filter in args.run_rust:
    if not re.fullmatch(r"[A-Za-z0-9_-]+", package) or not re.fullmatch(r"[A-Za-z0-9_-]+", target):
        raise RuntimeError("Invalid Rust test package or target")
    command = ["cargo", "test", "-j1", "-p", package]
    command += ["--lib"] if target == "lib" else ["--test", target]
    if test_filter != "all":
        command.append(test_filter)
    command += ["--", "--include-ignored", "--nocapture"]
    before = rust_inputs(package, target)
    result = subprocess.run(command, cwd=root / "game-rust", capture_output=True)
    filename = re.sub(r"[^A-Za-z0-9_.-]", "_", package + "-" + target + "-" + test_filter)
    generated.mkdir(parents=True, exist_ok=True)
    output = generated / ("completion-rust-" + filename + ".log")
    output.write_bytes(result.stdout + result.stderr)
    evidence = {"command": command, "exit_code": result.returncode, "inputs": before,
                "unchanged_during_run": before == rust_inputs(package, target), "log_sha256": sha(output),
                "log": output.relative_to(root).as_posix()}
    output.with_suffix(".evidence.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    run_failed |= result.returncode != 0 or not evidence["unchanged_during_run"]
    print("Rust evidence:", filename, "exit=" + str(result.returncode), "source-stable=" + str(evidence["unchanged_during_run"]))

# 대체 검사는 원본 ID별로 실제 test name, 담당 소스, 검증 이유를 명시한다.
# C# 대응이 있는 ID에도 추가 서버 보장을 요구할 수 있다.
replacement_path = root / ".plan/general/2026-10-29-lockstep-test-replacements.json"
replacements = json.loads(replacement_path.read_text(encoding="utf-8-sig")) if replacement_path.exists() else {}
external_passed = {}

for evidence_file in generated.glob("completion-rust-*.evidence.json"):
    record = json.loads(evidence_file.read_text(encoding="utf-8-sig"))
    output = root / record["log"]
    command = record["command"]
    target = "lib" if "--lib" in command else command[command.index("--test") + 1]
    package = command[command.index("-p") + 1]
    valid = record.get("exit_code") == 0 and record.get("unchanged_during_run") is True
    valid = valid and record.get("inputs") == rust_inputs(package, target) and output.is_file() and record.get("log_sha256") == sha(output)
    if valid:
        content = output.read_text(encoding="utf-8-sig", errors="replace")
        for name in re.findall(r"^test\s+(\S+)\s+\.\.\.\s+ok\s*$", content, re.MULTILINE):
            # integration 파일마다 같은 함수명을 쓸 수 있어 target까지 결속한다.

            external_passed[(package, target, name)] = record["log"]

targets = {}
for file in sorted(ported.glob("*.cs")):
    text = file.read_text(encoding="utf-8-sig")
    constants = dict(re.findall(r'const string (\w+)\s*=\s*"([^"]+)"', text))
    for reference, method in re.findall(r'\[PortedTest\(([^)]+)\)\]\s*public static void (\w+)\(', text):
        key = constants.get(reference, reference.strip('"')) + "::" + method
        if key in targets:
            raise RuntimeError("Duplicate port: " + key)
        targets[key] = file
unity_targets = {}
for file in sorted((client / "Assets/Tests").rglob("*.cs")):
    for key in re.findall(r'\[Property\("OriginalSimulationTest",\s*"([^"]+)"\)\]', file.read_text(encoding="utf-8-sig")):
        if key in targets:
            raise RuntimeError("Duplicate port: " + key)
        targets[key] = file
        unity_targets[key] = file
runtime_inputs = list((client / "LocalPackages/com.arcanecasters.lockstep/Runtime").rglob("*.cs"))
current_inputs = runtime_inputs + list(ported.glob("*.cs")) + list((client / "Tools/LockstepProbe/Fixtures").glob("*.sql"))
current_inputs += [client / "Tools/LockstepProbe" / name for name in ("CoreTests.cs", "Program.cs", "LockstepProbe.csproj")]
fresh = False
native_proof = log.with_suffix(".evidence.json")
if log.exists() and native_proof.exists():
    record = json.loads(native_proof.read_text(encoding="utf-8-sig"))
    captured = record.get("inputs", {})
    fresh = record.get("exit_code") == 0 and record.get("unchanged_during_run") is True and record.get("log_sha256") == sha(log)
    fresh = fresh and all(captured.get(path.relative_to(root).as_posix()) == sha(path) for path in current_inputs)
passed = set()
if fresh:
    text = log.read_text(encoding="utf-8-sig")
    if "PASS ported tests=" in text and "PASS ticks=10000" in text:
        passed = {item.rstrip("\r") for item in re.findall(r"^PARITY PASS (.+)$", text, re.MULTILINE)}
unity_log = generated / "latest-unity-parity-results.xml"
unity_inputs = list((client / "Assets/Scripts").rglob("*.cs")) + list((client / "Assets/Tests").rglob("*.cs")) + runtime_inputs
if unity_log.exists() and unity_log.stat().st_mtime >= max(file.stat().st_mtime for file in unity_inputs):
    results = ET.parse(unity_log).getroot()
    for case in results.iter("test-case"):
        if case.get("result") == "Passed":
            for prop in case.findall("./properties/property"):
                key = prop.get("value")
                if prop.get("name") == "OriginalSimulationTest" and key in unity_targets:
                    passed.add(key)

rows, known = [], set()
for file in sorted(sources):
    relative = file.relative_to(sim).as_posix()
    source = relative.removeprefix("src/")
    text = file.read_text(encoding="utf-8-sig")
    for match in re.finditer(r"#\[test\](?:(?!\bfn\b).)*\bfn\s+(\w+)\s*\(", text, re.DOTALL):
        key = source + "::" + match.group(1)
        if key in known:
            raise RuntimeError("Ambiguous source test: " + key)
        known.add(key)
        target = targets.get(key)
        replacement = replacements.get(key)
        evidence = []
        externally_verified = bool(replacement)
        external_targets = []
        if replacement:
            if not replacement.get("reason") or not replacement.get("checks"):
                raise RuntimeError("Incomplete replacement explanation: " + key)
            for check in replacement["checks"]:
                test = (check["package"], check["target"], check["test"])
                check_source = root / check["source"]
                if not check_source.is_file():
                    raise RuntimeError("Missing replacement source: " + str(check_source))
                proof = external_passed.get(test)
                externally_verified &= proof is not None
                if proof:
                    evidence.append(proof)
                external_targets.append(check["source"])
        verified = (target is None or key in passed) and (replacement is None or externally_verified) and (target is not None or replacement is not None)
        mapped = target is not None or replacement is not None
        status = "passed" if verified else "ported-unverified" if mapped else "not-ported"
        target_path = target.relative_to(root).as_posix() if target else "|".join(sorted(set(external_targets)))
        target_hash = sha(target) if target else "|".join(sha(root / path) for path in sorted(set(external_targets)))
        rows.append({"id": key, "source": "game-rust/crates/sim/" + relative,
                     "line": text.count("\n", 0, match.start()) + 1, "source_sha256": sha(file),
                     "target": target_path, "target_sha256": target_hash, "status": status,
                     "owner": "client-ported-and-server-replacement" if target and replacement else "client-ported" if target else "server-retained-and-integration-replacement" if replacement else "unmapped",
                     "replacement_reason": replacement.get("reason", "") if replacement else "",
                     "external_evidence": "|".join(sorted(set(evidence)))})
unknown = (targets.keys() | replacements.keys()) - known
if unknown:
    raise RuntimeError("Port has no source test: " + ", ".join(sorted(unknown)))
destination = root / ".plan/general/2026-10-26-lockstep-tests.csv"
with destination.open("w", encoding="utf-8", newline="") as output:
    writer = csv.DictWriter(output, fieldnames=list(rows[0]), lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
verified = sum(row["status"] == "passed" for row in rows)
mapped = sum(row["status"] != "not-ported" for row in rows)
print(f"Original test functions: {len(rows)}; mapped: {mapped}; verified: {verified}; remaining: {len(rows) - verified}")
if run_failed or (args.strict and verified != len(rows)):
    raise SystemExit(1)
