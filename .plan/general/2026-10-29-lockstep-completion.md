# 2026-10-29 — lockstep 잔여 이관과 복구 검증

- Date: 2026-10-29
- GitHub Issue: https://github.com/Apptive-Game-Team/ArcaneCastersClient/issues/378
- Status: Completed — 구현·로컬 통합·대상 플랫폼 검증 완료, 운영 적용 전

## Goal
기존 lockstep 브랜치에서 전체 이관의 잔여 구현과 검증을 완료한다. 원본 simulation 915개와 server model 127개의 보장을 클라이언트/릴레이/로비의 실제 책임에 대응하고, 실행 결과와 미검증을 분리한다.

## Non-goals
운영 배포, 유료 외부 모델 호출, 기존 다른 브랜치 변경은 범위에 없다. 폰트 atlas 캐시는 보존한다.

## Context / Constraints
root/client/game-rust/lobby/database의 기존 lockstep checkout을 사용한다. 기존 V120은 수정하지 않고 양쪽 장기 트랙에서 migration 번호 중복을 확인한다. 완료된 결과의 DB 조회와 미완료 세션 복구를 구분한다. 상태 hash에 입력만 넣거나 위치만 넣어 전체 상태라고 부르지 않는다.

## Approach (Checklist)
- [x] **Step 0: Recon** — 기존 기록과 소스, 상태를 확인한다.
- [x] **Step 1: Implementation** — (A) 결정론 상태 checkpoint 계약과 replica 비교, 불일치의 확정 중단 및 저장 차단을 연결한다. RNG/ID/시간/예약 작업/덱/상태효과/물리 지속 상태를 포함하는 검증 가능한 정규화 state capture를 설계한다. (B) 서버 초기 상태·확정 입력의 내구 저장 및 서버 재시작 후 동일 초기 상태부터 복구, 모델 요청의 중복 실행 방지·종단 상태 기록을 연결한다. (C) 결과 transaction에 종료 알림 outbox를 함께 저장하고 재시도 worker 및 lobby 수신 멱등성을 검증한다. (D) 원본 잔여 19개와 model 127개를 실제 소유 계층의 검사에 매핑해 의미를 보존한다. 단순 제외/placeholder/이름만 같은 검사를 완료로 세지 않는다.
- [x] **Step 2: Tests** — 원본 대응 전체 실행, checkpoint 변조·상이한 replica·중복/재접속, DB 재시작 복구·응답 유실·결과 재전송/outbox 재시도 검사. Windows .NET/Unity Editor/WebGL의 동일 입력 replay와 최종 실제 GameScene 경기, 로비 매칭 계약을 검증한다.
- [x] **Step 3: Rollout / Rollback** — feature flag 기본값을 유지하고 필요한 migration·verifier 실행 설정과 롤백 경계를 기록한다.

## Validation
- **Commands to run:** C# probe/verifier Release, Unity EditMode 및 독립 WebGL probe/실제 장면, cargo fmt/clippy/test, lobby Gradle tests, migration 정적 검사, strict inventory, git diff --check, graphify update .
- **Expected output:** 미이관/미검증 0, 각 tick 상태 checkpoint 동일, desync 시 보상 저장 0, 재시작 후 확정 입력 중복/누락 0, 결과/통계/보상 1회, 종료 알림 재시도 후 lobby 효과 1회. 플랫폼에서 제외된 thread 전용 검사는 별도 플랫폼 실행으로 보장한다. 실제 외부 서비스 또는 실제 UI를 실행하지 못하면 완료라고 보고하지 않는다.

## Risks & Rollback
- **Risks:** BEPU 내부 캐시와 callback graph의 결정론 직렬화, 모델 IO의 crash 시 불확정 완료, DB 쓰기 부하, Unity 프로세스 lock과 플랫폼 빌드 시간.
- **Rollback steps:** lockstep 생성 flag를 끄고 현재 진행/저장 결과의 읽기 호환을 보존한다. 데이터 손실을 유발하는 migration rollback은 하지 않는다.

## Open Questions
없음. 상태 소유 경계와 불확정 모델 요청의 serverRestart 확정 정책을 구현하고 검사했다.

## Review revisions
FAST/MEDIUM의 필수 수정 수용. 원본 목표는 유지한다.
1. checkpoint는 tick N을 모두 실행한 직후 상태다. 새 생성 경기의 SessionStart에 stateHashVersion=1을 고정하고, 모든 인간 참가자가 매 tick hash를 제출하기 전 다음 tick 공개/완료 저장을 막는다. 봇은 인간 replica에 포함하며 관전자는 투표하지 않는다. 같은 tick/hash 재전송은 멱등, 다른 hash는 영속 desync 종료다. 한 명 경기 역시 headless 최종 replay의 checkpoint 대조를 통과해야 저장한다. checkpoint 누락은 input timeout과 같이 중단한다. 기존 stateHashVersion 없는 replay는 읽기 호환만 유지한다.
2. 상태 writer는 시스템별 소유 경계를 둔다. 객체/컴포넌트의 private rule state, RNG/ID/시계/예약 실행 내용, 덱/봇/PVE, 물리 body와 접촉 지속 상태를 포함한다. presentation/외부 IO/구독자의 실제 UI target은 제외하고 게임 논리 callback과 예약 상태는 제외하지 않는다. 복구에는 checkpoint를 역직렬화하지 않고 최초 상태/확정 기록만 사용한다. 신규 상태/누락은 state field inventory와 mutation 검사로 검출하고 IL2CPP 보존도 확인한다. 구현 검토에서 이 조건을 만족하지 못하면 전체 상태 완료라고 기록하지 않는다.
3. 세션 생성/입력 확정은 DB commit 전에 응답·frame을 공개하지 않는다. 생성 attempt도 영속 멱등이다. DB 실패는 입력/모델 이벤트를 유실시키지 않으며 재시도한다. 같은 configured server identity 소유 세션만 복구하고 다중 instance 동시 소유는 DB lease로 차단한다. 서버 downtime 동안 게임 tick은 진행하지 않되 원래 30분 보존 기간은 유지한다.
4. 모델 IO admission은 외부 호출 전에 내구화한다. 재시작 시 이미 확정된 이벤트를 재생하고 accepted-but-no-terminal은 provider를 다시 호출하지 않고 serverRestart failure 이벤트로 확정한다. 외부 provider exactly-once는 주장하지 않는다. generation/sequence를 재사용하지 않는다.
5. outbox는 결과와 같은 transaction에 session ID 키로 저장한다. lease/재시도/ack로 at-least-once 전달하며 lobby 수신 효과는 session ID로 멱등이다. 전송 뒤 ack 전 crash와 sender/receiver 재시작을 검사한다. 일반 메시지 버스를 도입하지 않는다.
6. model 대응은 client-ported/server-retained-and-run/integration-replacement로 구분하고 source ID·대응 검사·실제 실행 증거를 붙인다. simulation19도 원본 보장별로 대응하며 이름/단일 IsRunning 검사로 부풀리지 않는다. 실제 UI 목표는 로비 진입→매칭→양쪽 GameScene→카드 입력→결과다. mock provider는 승인 범위이며 유료 서비스는 완료 조건이 아니다.
Rejected feedback: 없음.

## 완료 증거 (2026-10-29)
- `tools/lockstep-test-coverage.py --strict`: 원본915, 매핑915, 현재 소스 실행 검증915, 잔여0. C# 단독893개와 Unity DTO·서버 유지/대체 계약을 원본 ID별로 결속한다. 중복 대응을 원본 수에 더하지 않는다.
- `tools/lockstep-model-test-inventory.py --run-server --run-client --strict`: 서버 원본127/127 및 클라이언트 대응38개 실행 통과. 실제 IO는 서버에 유지한다.
- `tools/lockstep-source-inventory.py --check`: 원본668개 모두 소유·대응 위치를 기록. 테스트 없는483개는 architecture mapping이며 별도 통과 수로 세지 않는다.
- .NET·Unity Editor·WebGL IL2CPP 브라우저 실행에서 기본40tick·복합29tick·물리300tick checkpoint trace가 동일하다. 기존10,000tick 물리 회귀도 유지한다. WebGL의 desktop thread 전용4개는 제외하고 .NET/Editor에서 실행했다.
- Unity 일반 EditMode45개 중43pass/0fail/2skip. 두 skip은 로컬 fixture 설정이 필요한 실제 장면·로비 검사이며 별도 설정 실행으로 검증했다. 원본 Rust doctest 예제2개는 그대로 ignored이며 기존 실행 가능한 계약 검사로 대응한다. [계약 증거](2026-10-29-lockstep-doctest-contracts.json)를 별도 기록하고 literal pass로 세지 않는다.
- 로컬 실제 Spring lobby·Redis·전체 Flyway catalog·Rust game·.NET verifier에서 Unity↔.NET 경기와 Unity↔Unity 경기 각각54frames 완료. 양쪽 실제 로비 매칭 버튼→GameScene→CardUI 시전→ResultScene 흐름을 통과했다. 두 번째 경기의 승리/패배 화면, 카드시전1회, 결과·통계1회, outbox1회ack, 양쪽 Online 및 로비 active 해제를 DB/Redis/API에서 확인했다. 운영 DB는 사용하지 않았다.
- DB commit 응답 유실·새 입력 도착·중복 재전송, 서버 교체, 최초placement 보존, lease takeover/만료renew 거부, 모델 admission 복구 및 재호출 방지, checkpoint 미합의 complete202, desync/abort 보상0, 저장 실패 종료 공개 차단, outbox 재시도를 실행했다. mock 모델 v2는 HTTP→WebSocket→C# replay→결과저장까지 통과했다.
- Rust workspace tests, 최종 fmt/clippy, lobby tests, V121 정적 migration 검사를 통과했다. `graphify update .`는 명령 미설치로 실행할 수 없었다. graph.json도 없어 그래프 검증을 완료로 세지 않는다.
- Unity 실행 전의 폰트 atlas와 ProjectSettings를 원본 그대로 복원했다. 로컬 fixture의 token·build·복제 프로젝트는 Git 산출물에 포함하지 않는다.
- [구현 정책·적용 순서·롤백](../../docs/lockstep-completion.md). 운영 배포, 유료 모델, 다른 CPU 아키텍처·대규모 부하는 이번 완료의 검증 범위에 포함하지 않는다.
