# 2026-11-16 — Rust 밸런스 실험과 Unity 직접 플레이 연결 추가

- Date: 2026-11-16
- GitHub Issue: Apptive-Game-Team/ArcaneCastersClient#463
- Status: Implemented

## Goal
미리보기·튜토리얼 기반 Rust 실행기에서 후보 5개를 비교하고 같은 전투를 Unity에서 직접 플레이한다.

## Non-goals
운영 데이터 변경, 배포, 덱 전체 승률·재미의 자동 평가는 포함하지 않는다.

## Context / Constraints
기존 미커밋 작업과 분리한 worktree를 사용했다. Rust 구현은 game-rust에만 추가했으며 archived Java는 수정하지 않았다. client는 Editor playground의 prefab UI와 native renderer를 재사용한다. 전투는 loopback에서 실행하고 계정·전적·보상·진행도와 연결하지 않는다.

## Approach (Checklist)
- [x] **Step 0: Recon** preview, tutorial, Editor playground와 모듈 지침을 확인했다. FAST/MEDIUM 검토를 반영하고 HEAVY REVIEW: PASS를 받았다.
- [x] **Step 1: Implementation** 단일 step/cast 실행기, 파일 기반 snapshot/scenario/patch, CLI batch, live HTTP, Unity 직접 시전·일시정지·배속·기록 저장·재생을 추가했다.
- [x] **Step 2: Tests** 후보 5개 × 조건 18개 × seed 3개 = 270쌍, 540개 전투를 비교했다. 수정안을 운영에 적용하지 않았다. 나무 골렘 회복 변경은 최초 대상 밖의 과생장 조합 9쌍에서도 영향을 보였다.
- [x] **Step 3: Rollout / Rollback** submodule의 공개된 feature commit을 연결한 draft PR만 열었다. dev 병합·배포는 하지 않는다. 기능 제거 또는 pointer 복원으로 원복할 수 있다.

## Validation
- **Commands to run:** cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test; ac-balance batch; BalanceLabValidation.Validate; BuildScript.BuildWebGL; BuildScript.BuildDevWebGL.
- **Expected output:** Rust 신규 테스트 5개 포함 1,400개 통과(기존 두 실패 제외). Unity 실제 직접 시전·pause·수정안 전환·저장·재생 통과. 일반·개발 WebGL 빌드 성공 및 Editor asset 배제 guard 통과.
- 전체 cargo test의 닫힌 포트 오류 분류·Windows 시간 정밀도 테스트 두 실패는 수정 전 f0be9c1에서도 재현했다. 상세 결과와 한계는 game-rust/docs/balance-lab-results-2026-11-16.md에 기록했다.
- graphify update .는 실행 파일이 없어 수행하지 못했다.

## Risks & Rollback
- **Risks:** 기준 데이터는 2026-11-04 snapshot이다. 무료 fixture와 실제 시전 비용을 구분한다. 고정 예약 시전의 실패는 사람의 적응 행동을 대표하지 않는다. 누적 피해·회복은 미측정이며 HP 적분을 대신 해석하지 않는다.
- **Rollback steps:** game-rust/client pointer 복원 또는 두 모듈의 기능 commit revert.

## Open Questions
- 없음. 후속 채택 여부는 실제 플레이로 결정한다.

## Pull requests
- Rust: https://github.com/Apptive-Game-Team/ArcaneCastersGameRust/pull/45
- Unity: https://github.com/Apptive-Game-Team/ArcaneCastersClient/pull/464
