"""현재 소스 소유 위치와 원본 테스트 증거를 별도로 기록한다."""
from __future__ import annotations
import argparse
import csv
import hashlib
import io
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / '.plan/general'
BASELINE = PLAN / '2026-10-26-lockstep-coverage.csv'
OWNERS = PLAN / '2026-10-29-lockstep-source-owners.json'
OUTPUT = PLAN / '2026-10-29-lockstep-source-coverage'
SIM = 'game-rust/crates/sim/src/'
CLIENT = 'client/LocalPackages/com.arcanecasters.lockstep/Runtime/Simulation/'
TEST_INPUTS = [PLAN / '2026-10-26-lockstep-tests.csv', PLAN / '2026-10-28-lockstep-model-tests.csv']
OWNERS_ALLOWED = {'client', 'server-retained', 'shared-contract', 'structural', 'testfixture'}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_csv(path):
    with path.open(encoding='utf-8-sig', newline='') as stream:
        return list(csv.DictReader(stream))


def file_ref(relative):
    path = ROOT / relative
    if not path.is_file():
        raise ValueError('Missing target/input: ' + relative)
    if path.resolve().is_relative_to(ROOT.resolve()) is False:
        raise ValueError('Target outside workspace: ' + relative)
    return {'path': relative, 'sha256': sha(path)}


def render():
    baseline = read_csv(BASELINE)
    if len(baseline) != 668 or len({r['Source'] for r in baseline}) != 668:
        raise ValueError('The preserved baseline must contain 668 unique source rows.')
    declared = json.loads(OWNERS.read_text(encoding='utf-8'))
    rules = declared['sources']
    sources = {p.relative_to(ROOT / SIM).as_posix() for p in (ROOT / SIM).rglob('*.rs')}
    expected = {r['Source'] for r in baseline}
    if sources != expected:
        raise ValueError('Source set changed; review inventory explicitly: ' + repr(sorted(sources ^ expected)))
    if set(rules) != expected:
        raise ValueError('Owner rules must cover every preserved source exactly once.')
    tests = []
    for path in TEST_INPUTS:
        for test in read_csv(path):
            tests.append((path.name, test))
    rows = []
    for old in sorted(baseline, key=lambda r: r['Source']):
        relative = old['Source']
        source = SIM + relative
        rule = rules[relative]
        if rule['owner'] not in OWNERS_ALLOWED or not rule['reason'] or not rule['targets']:
            raise ValueError('Incomplete reviewed ownership: ' + relative)
        contents = (ROOT / source).read_text(encoding='utf-8-sig')
        if rule['owner'] == 'structural':
            # module/reexport 파일에 새 행동이 생기면 기존 구조 분류로 통과시키지 않는다.
            code = re.sub(r'/\*.*?\*/|//[^\n]*', '', contents, flags=re.S)
            if re.search(r'\b(fn|struct|enum|trait|impl|const|static|type)\s+[A-Za-z_]', code):
                raise ValueError('Structural source now contains declarations: ' + relative)
        matched = []
        for inventory, test in tests:
            if test['source'] != source:
                continue
            target = test.get('target', '')
            target_ref = file_ref(target) if target and (ROOT / target).is_file() else None
            matched.append({
                'inventory': inventory, 'id': test['id'], 'source_line': int(test['line']),
                'status_in_test_inventory': test['status'], 'owner_in_test_inventory': test.get('owner', ''),
                'source_sha256_in_test_inventory': test.get('current_source_sha256') or test.get('source_sha256', ''),
                'source_hash_matches_current': (test.get('current_source_sha256') or test.get('source_sha256', '')) == sha(ROOT / source),
                'target': target_ref,
                'target_sha256_in_test_inventory': test.get('current_target_sha256') or test.get('target_sha256', ''),
                'target_hash_matches_current': target_ref is not None and target_ref['sha256'] == (test.get('current_target_sha256') or test.get('target_sha256', '')),
                'external_evidence': test.get('external_evidence', ''),
                'server_log': test.get('server_log', ''), 'client_log': test.get('client_log', ''),
                'replacement_reason': test.get('replacement_reason') or test.get('responsibility', ''),
            })
        rows.append({
            'source': file_ref(source), 'baseline_source_sha256': old['SourceSha256'],
            'source_changed_since_baseline': sha(ROOT / source) != old['SourceSha256'],
            'owner': rule['owner'], 'mapping_basis': rule['mapping_basis'], 'reason': rule['reason'],
            'targets': [file_ref(p) for p in sorted(set(rule['targets']))],
            'architectural_mapping_only': True,
            'original_test_mapping': 'mapped' if matched else 'no-original-tests-in-inventories',
            'original_tests': sorted(matched, key=lambda t: (t['inventory'], t['id'])),
        })
    evidence = []
    for path in sorted((ROOT / 'client/Tools/LockstepProbe/.generated').glob('completion-*.evidence.json')):
        evidence.append(file_ref(path.relative_to(ROOT).as_posix()))
    report = {
        'schema_version': 1,
        'scope': 'preserved 668 ac-sim src files; architecture mapping, not semantic equivalence or acceptance verdict',
        'acceptance': 'Separate source-bound original 915 / model 127 test evidence plus platform and UI gates are required. No source row is marked complete by this inventory.',
        'inputs': [file_ref(p.relative_to(ROOT).as_posix()) for p in [BASELINE, OWNERS, *TEST_INPUTS]],
        'owner_counts': dict(sorted(Counter(r['owner'] for r in rows).items())),
        'rows_with_original_tests': sum(bool(r['original_tests']) for r in rows),
        'rows_without_original_tests': sum(not r['original_tests'] for r in rows),
        'test_inventory_counts': {p.name: len(read_csv(p)) for p in TEST_INPUTS},
        'tests_outside_source_scope': [{'inventory': inventory, 'id': t['id'], 'source': t['source']} for inventory, t in tests if not t['source'].startswith(SIM) or t['source'][len(SIM):] not in expected],
        'evidence_file_references_only': evidence,
        'sources': rows,
    }
    json_text = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    stream = io.StringIO(newline='')
    writer = csv.DictWriter(stream, fieldnames=['source', 'source_sha256', 'baseline_source_sha256', 'owner', 'mapping_basis', 'reason', 'targets_with_current_sha256_json', 'original_test_mapping', 'original_test_count', 'original_test_status_counts_json', 'original_test_ids_json', 'architectural_mapping_only'], lineterminator='\n')
    writer.writeheader()
    for row in rows:
        writer.writerow({
            'source': row['source']['path'], 'source_sha256': row['source']['sha256'],
            'baseline_source_sha256': row['baseline_source_sha256'], 'owner': row['owner'],
            'mapping_basis': row['mapping_basis'], 'reason': row['reason'],
            'targets_with_current_sha256_json': json.dumps(row['targets'], ensure_ascii=False, separators=(',', ':')),
            'original_test_mapping': row['original_test_mapping'], 'original_test_count': len(row['original_tests']),
            'original_test_status_counts_json': json.dumps(dict(sorted(Counter(t['status_in_test_inventory'] for t in row['original_tests']).items())), separators=(',', ':')),
            'original_test_ids_json': json.dumps([t['id'] for t in row['original_tests']], separators=(',', ':')),
            'architectural_mapping_only': 'true',
        })
    return {OUTPUT.with_suffix('.json'): json_text, OUTPUT.with_suffix('.csv'): stream.getvalue()}, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='저장된 결과와 현재 입력의 결정적 출력을 비교한다.')
    args = parser.parse_args()
    outputs, report = render()
    for path, text in outputs.items():
        encoded = text.encode('utf-8')
        if args.check:
            if not path.exists() or path.read_bytes() != encoded:
                raise SystemExit('Stale inventory: ' + str(path.relative_to(ROOT)))
        else:
            path.write_bytes(encoded)
    print(json.dumps({'source_count': len(report['sources']), 'owners': report['owner_counts'], 'with_original_tests': report['rows_with_original_tests'], 'without_original_tests': report['rows_without_original_tests'], 'check': args.check}, ensure_ascii=False))


if __name__ == '__main__':
    main()
