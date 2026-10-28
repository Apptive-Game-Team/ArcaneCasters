"""원본 테스트와 C# 대응 테스트를 연결한다. 미이관 테스트를 통과로 집계하지 않는다."""
import argparse
import csv
import hashlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--strict", action="store_true", help="미이관 또는 미검증 테스트가 있으면 실패")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
sim = root / "game-rust/crates/sim"
client = root / "client"
ported = client / "Tools/LockstepProbe/PortedTests"
log = client / "Tools/LockstepProbe/.generated/latest-parity.log"
sources = list((sim / "src").rglob("*.rs")) + list((sim / "tests").rglob("*.rs"))
targets = {}
for file in sorted(ported.glob("*.cs")):
    text = file.read_text(encoding="utf-8-sig")
    constants = dict(re.findall(r'const string (\w+)\s*=\s*"([^"]+)"', text))
    for reference, method in re.findall(r'\[PortedTest\(([^)]+)\)\]\s*public static void (\w+)\(', text):
        source = constants.get(reference, reference.strip('"'))
        key = source + "::" + method
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
current_inputs = runtime_inputs + list(ported.glob("*.cs"))
current_inputs += list((client / "Tools/LockstepProbe/Fixtures").glob("*.sql"))
current_inputs += [client / "Tools/LockstepProbe" / name for name in ("CoreTests.cs", "Program.cs", "LockstepProbe.csproj")]
fresh = log.exists() and log.stat().st_mtime >= max(file.stat().st_mtime for file in current_inputs)
passed = set()
if fresh:
    text = log.read_text(encoding="utf-8-sig")
    if "PASS ported tests=" in text and "PASS ticks=10000" in text:
        passed = set(re.findall(r"^PARITY PASS (.+)$", text, re.MULTILINE))
        passed = {item.rstrip("\r") for item in passed}

unity_log = client / "Tools/LockstepProbe/.generated/latest-unity-parity-results.xml"
unity_inputs = list((client / "Assets/Scripts").rglob("*.cs")) + list((client / "Assets/Tests").rglob("*.cs")) + runtime_inputs
if unity_log.exists() and unity_log.stat().st_mtime >= max(file.stat().st_mtime for file in unity_inputs):
    results = ET.parse(unity_log).getroot()
    for case in results.iter("test-case"):
        if case.get("result") == "Passed":
            for prop in case.findall("./properties/property"):
                key = prop.get("value")
                if prop.get("name") == "OriginalSimulationTest" and key in unity_targets:
                    passed.add(key)

rows = []
known = set()
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
        status = "passed" if target and key in passed else "ported-unverified" if target else "not-ported"
        rows.append({"id": key, "source": "game-rust/crates/sim/" + relative,
                     "line": text.count("\n", 0, match.start()) + 1,
                     "source_sha256": hashlib.sha256(file.read_bytes()).hexdigest(),
                     "target": target.relative_to(root).as_posix() if target else "",
                     "target_sha256": hashlib.sha256(target.read_bytes()).hexdigest() if target else "",
                     "status": status})
unknown = targets.keys() - known
if unknown:
    raise RuntimeError("Port has no source test: " + ", ".join(sorted(unknown)))
destination = root / ".plan/general/2026-10-26-lockstep-tests.csv"
with destination.open("w", encoding="utf-8", newline="") as output:
    writer = csv.DictWriter(output, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
verified = sum(row["status"] == "passed" for row in rows)
print(f"Original test functions: {len(rows)}; mapped: {len(targets)}; verified: {verified}; remaining: {len(rows) - verified}")
if args.strict and verified != len(rows):
    raise SystemExit(1)
