"""서버 모델 테스트 원본 목록과 클라이언트 이관의 검증 기준선을 분리한다."""
import csv
import hashlib
import json
import re
import subprocess
from collections import Counter
from pathlib import Path

root = Path(__file__).resolve().parents[1]
repository = root / "game-rust"
generated = root / "client/Tools/LockstepProbe/.generated"


def git(*arguments):
    return subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True, capture_output=True,
    ).stdout


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else ""


revision = git("rev-parse", "HEAD").decode().strip()
paths = git("ls-tree", "-r", "--name-only", revision, "--",
            "crates/server/src/bot/llm").decode().splitlines()
mapping = {}
inventory = generated / "claude-model-candidate-inventory.csv"
if inventory.is_file():
    with inventory.open(encoding="utf-8-sig", newline="") as stream:
        for row in csv.DictReader(stream):
            if row["original_test"].startswith("("):
                continue
            key = row["original_path"] + "::" + row["original_test"]
            if key in mapping:
                raise RuntimeError("Duplicate model inventory entry: " + key)
            mapping[key] = row

# 이 로그는 과거 snapshot의 통과 증거다. 현재 runtime의 통과로 바꾸어 표시하지 않는다.
baseline = generated / "unity-model-bundled-parity.log"
passed = set()
if baseline.is_file():
    content = baseline.read_text(encoding="utf-8-sig")
    if "PASS model-original tests=38" in content and "PASS ticks=10000" in content:
        passed = set(re.findall(r"^MODEL PASS (.+)$", content, re.MULTILINE))

pattern = re.compile(
    r"^\s*#\[(?:tokio::)?test(?:\([^\]]*\))?\]\s*"
    r"(?:#\[[^\]]*\]\s*)*(?:async\s+)?fn\s+(\w+)", re.MULTILINE,
)
rows, seen = [], set()
target = root / "client/Tools/LockstepProbe/PortedTests/ModelCandidateChecks.cs"
snapshot = generated / "UnityProbe/Assets/PortedTests/ModelCandidateChecks.cs"
provenance = root / ".plan/general/2026-10-28-lockstep-model-baseline.json"
baseline_target_hash = ""
if passed:
    if not provenance.exists():
        if not snapshot.is_file() or snapshot.stat().st_mtime > baseline.stat().st_mtime:
            raise RuntimeError("The snapshot is newer than the baseline; its provenance cannot be inferred")
        provenance.write_text(json.dumps({
            "log": baseline.relative_to(root).as_posix(),
            "log_sha256": digest(baseline),
            "target": target.relative_to(root).as_posix(),
            "target_sha256": digest(snapshot),
        }, indent=2) + "\n", encoding="utf-8")
    evidence = json.loads(provenance.read_text(encoding="utf-8"))
    if evidence["log_sha256"] != digest(baseline):
        raise RuntimeError("The recorded baseline log changed")
    baseline_target_hash = evidence["target_sha256"]
for path in paths:
    if not path.endswith(".rs"):
        continue
    original = git("show", revision + ":" + path)
    content = original.decode("utf-8-sig")
    source = "game-rust/" + path
    matches = list(pattern.finditer(content))
    attributes = re.findall(r"^\s*#\[(?:tokio::)?test(?:\([^\]]*\))?\]", content, re.MULTILINE)
    if len(matches) != len(attributes):
        raise RuntimeError("An original test attribute was not resolved: " + source)
    for match in matches:
        key = source + "::" + match.group(1)
        if key in seen:
            raise RuntimeError("Duplicate original model test: " + key)
        seen.add(key)
        mapped = mapping.get(key, {})
        status = "unmapped"
        if mapped:
            status = "not-client-ported"
            if mapped["status"] == "ported":
                status = "ported-baseline-pass" if key in passed else "ported-unverified"
        rows.append({
            "id": key, "source": source,
            "line": content.count("\n", 0, match.start()) + 1,
            "source_revision": revision,
            "source_sha256": hashlib.sha256(original).hexdigest(),
            "target": target.relative_to(root).as_posix() if mapped.get("status") == "ported" else "",
            "target_method": mapped.get("csharp_check", ""),
            "baseline_log": baseline.relative_to(root).as_posix() if key in passed else "",
            "baseline_target_sha256": baseline_target_hash if key in passed else "",
            "current_target_sha256": digest(target) if mapped.get("status") == "ported" else "",
            "status": status,
        })

if passed - seen:
    raise RuntimeError("Baseline contains tests absent from the original revision")
destination = root / ".plan/general/2026-10-28-lockstep-model-tests.csv"
with destination.open("w", encoding="utf-8", newline="") as stream:
    writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
print("Model original inventory:", len(rows), dict(sorted(Counter(row["status"] for row in rows).items())))
print("Baseline evidence only; current runtime completion is not asserted.")
