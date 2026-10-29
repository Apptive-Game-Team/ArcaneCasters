"""모델 원본 보장을 실제 소유 계층의 실행 증거와 현재 소스 hash에 결속한다."""
import argparse
import csv
import hashlib
import json
import re
import subprocess
from collections import Counter
from pathlib import Path

root = Path(__file__).resolve().parents[1]
repository = root / "game-rust"
probe = root / "client/Tools/LockstepProbe"
generated = probe / ".generated"
parser = argparse.ArgumentParser()
parser.add_argument("--strict", action="store_true")
parser.add_argument("--run-server", action="store_true", help="서버 원본 model 테스트를 실행하고 현재 소스 증거를 기록")
parser.add_argument("--run-client", action="store_true", help="현재 C# probe를 빌드·실행하고 소스 증거를 기록")
args = parser.parse_args()

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def inventory_inputs(kind):
    if kind == "server":
        paths = list((repository / "crates").rglob("*.rs"))
        paths += list(repository.glob("Cargo.*")) + list((repository / "crates").rglob("Cargo.toml"))
    else:
        paths = list((root / "client/LocalPackages/com.arcanecasters.lockstep/Runtime").rglob("*.cs"))
        paths += list((probe / "PortedTests").glob("*.cs")) + list((probe / "Fixtures").glob("*.sql"))
        paths += [probe / name for name in ("Program.cs", "CoreTests.cs", "NetworkBattleProbe.cs", "LockstepProbe.csproj")]
    return {path.relative_to(root).as_posix(): sha(path) for path in sorted(set(paths))}

run_failures = []

def run(kind):
    if kind == "server":
        commands = [["cargo", "test", "-j1", "-p", "ac-game-server", "--lib", "bot::llm::", "--", "--nocapture"]]
    else:
        # Editor/probe의 동시 빌드와 obj/bin을 공유하지 않고 현재 소스를 반드시 다시 컴파일한다.
        commands = [["dotnet", "build", "LockstepProbe.csproj", "-c", "Release", "-t:Rebuild",
                     "-p:BaseIntermediateOutputPath=" + str(generated / "inventory-obj") + "/",
                     "-p:OutputPath=" + str(generated / "inventory-bin") + "/"],
                    ["dotnet", str(generated / "inventory-bin/LockstepProbe.dll")]]
    before = inventory_inputs(kind)
    output, exit_code = bytearray(), 0
    for command in commands:
        completed = subprocess.run(command, cwd=repository if kind == "server" else probe, capture_output=True)
        output.extend(completed.stdout + completed.stderr)
        exit_code = completed.returncode
        if exit_code:
            break
    log = generated / ("completion-model-" + kind + ".log")
    log.write_bytes(output)
    after = inventory_inputs(kind)
    evidence = {"commands": commands, "exit_code": exit_code, "inputs": before,
                "unchanged_during_run": before == after, "log_sha256": sha(log)}
    log.with_suffix(".evidence.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    if kind == "client":
        latest = generated / "latest-parity.log"
        latest.write_bytes(log.read_bytes())
        latest.with_suffix(".evidence.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    if exit_code != 0 or before != after:
        run_failures.append(kind)
    print(kind + " exit=" + str(exit_code) + " source-stable=" + str(before == after))

def proof(kind):
    log = generated / ("completion-model-" + kind + ".log")
    evidence = log.with_suffix(".evidence.json")
    if not log.is_file() or not evidence.is_file():
        return "", False, ""
    record = json.loads(evidence.read_text(encoding="utf-8"))
    valid = record.get("exit_code") == 0 and record.get("unchanged_during_run") is True
    valid = valid and record.get("log_sha256") == sha(log) and record.get("inputs") == inventory_inputs(kind)
    return log.read_text(encoding="utf-8-sig", errors="replace"), valid, log.relative_to(root).as_posix()

generated.mkdir(parents=True, exist_ok=True)
if args.run_server:
    run("server")
if args.run_client:
    run("client")

server_log, server_valid, server_path = proof("server")
client_log, client_valid, client_path = proof("client")
server_passed = set(re.findall(r"^test\s+(bot::llm::\S+)\s+\.\.\.\s+ok\s*$", server_log, re.MULTILINE)) if server_valid else set()
client_passed = set(item.rstrip("\r") for item in re.findall(r"^MODEL PASS (.+)$", client_log, re.MULTILINE)) if client_valid and "PASS model-original tests=" in client_log and "PASS ticks=10000" in client_log else set()

def git(*arguments):
    return subprocess.run(["git", "-C", str(repository), *arguments], check=True, capture_output=True).stdout

revision = git("rev-parse", "HEAD").decode().strip()
paths = git("ls-tree", "-r", "--name-only", revision, "--", "crates/server/src/bot/llm").decode().splitlines()
target = probe / "PortedTests/ModelCandidateChecks.cs"
target_text = target.read_text(encoding="utf-8-sig")
prefix = re.search(r'const string Source\s*=\s*"([^"]+)"', target_text).group(1)
mapping = {}
for suffix, method in re.findall(r'\(Source\s*\+\s*"([^"]+)"\s*,\s*(\w+)\)', target_text):
    key = prefix + suffix
    if key in mapping:
        raise RuntimeError("Duplicate C# model mapping: " + key)
    mapping[key] = method
pattern = re.compile(r"^\s*#\[(?:tokio::)?test(?:\([^\]]*\))?\]\s*(?:#\[[^\]]*\]\s*)*(?:async\s+)?fn\s+(\w+)", re.MULTILINE)
rows, seen = [], set()
for path in paths:
    if not path.endswith(".rs"):
        continue
    original = git("show", revision + ":" + path)
    content = original.decode("utf-8-sig")
    current = repository / path
    current_tests = {match.group(1) for match in pattern.finditer(current.read_text(encoding="utf-8-sig"))}
    matches = list(pattern.finditer(content))
    if len(matches) != len(re.findall(r"^\s*#\[(?:tokio::)?test(?:\([^\]]*\))?\]", content, re.MULTILINE)):
        raise RuntimeError("Unresolved original model test attribute: " + path)
    for match in matches:
        name = match.group(1)
        source = "game-rust/" + path
        key = source + "::" + name
        if key in seen or name not in current_tests:
            raise RuntimeError("Duplicate or removed original model test: " + key)
        seen.add(key)
        rust_test = "bot::llm::" + Path(path).stem + "::tests::" + name
        rust_pass = rust_test in server_passed
        client_required = key in mapping
        client_pass = key in client_passed
        owner = "client-ported-and-server-retained" if client_required else "server-retained"
        status = "passed" if rust_pass and (client_pass or not client_required) else "unverified"
        rows.append({"id": key, "source": source, "line": content.count("\n", 0, match.start()) + 1,
                     "source_revision": revision, "source_sha256": hashlib.sha256(original).hexdigest(),
                     "current_source_sha256": sha(current), "owner": owner,
                     "target": target.relative_to(root).as_posix() if client_required else source,
                     "target_method": mapping.get(key, rust_test), "current_target_sha256": sha(target) if client_required else sha(current),
                     "server_test": rust_test, "server_log": server_path if rust_pass else "",
                     "client_log": client_path if client_pass else "", "status": status,
                     "responsibility": "후보·설명·turn 계산은 C#에서 검증하고 원본 서버 계약도 유지" if client_required else "provider IO·설정·key·executor·health·응답 파싱은 서버 책임으로 유지"})
if mapping.keys() - seen:
    raise RuntimeError("C# model mapping has no original: " + str(sorted(mapping.keys() - seen)))
destination = root / ".plan/general/2026-10-28-lockstep-model-tests.csv"
with destination.open("w", encoding="utf-8", newline="") as stream:
    writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
counts = dict(sorted(Counter(row["status"] for row in rows).items()))
print("Model original inventory:", len(rows), counts, "client-mapped=" + str(len(mapping)))
print("Current source evidence: server=" + str(server_valid) + " client=" + str(client_valid))
if run_failures or (args.strict and any(row["status"] != "passed" for row in rows)):
    raise SystemExit(1)
