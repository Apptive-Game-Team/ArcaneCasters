# 2026-10-26 — 클라이언트 고정 소수점 lockstep 전투 이관

- Date: 2026-10-26
- GitHub Issue: https://github.com/Apptive-Game-Team/ArcaneCastersClient/issues/378
- Status: Completed — 2026-10-29 잔여 구현·전체 원본 대응·실제 양쪽 Unity 로비 경기 검증 완료, 운영 적용 전
- Worktree: `C:/Users/jys09/.codex/worktrees/lockstep/ArcaneCasters`
- Branch: 루트/client/game-rust/lobby/database 모두 `lockstep`
- 분기 SHA: root `2c7681edff525d2579304a5dfb4da3f5b3b4e690`, client `bcba32316ffd3e5e0dfe1bfdf73fb9de4dc00279`, game-rust `cea4754e3965a37cb040d8041ef2b9007971bbae`, lobby `f10c515a9c639d9ec339f02cae7f86318d7091b4`

## Goal

서버에서 수행하던 전투, 마법, 봇, PVE 계산을 클라이언트에서 동일한 입력으로 재현한다. 전투 수치와 물리는 고정 소수점을 사용하고, 모든 참여자의 확정 입력이 모인 tick만 실행한다. 루트와 변경 대상 모듈은 각각 `lockstep` 브랜치를 사용한다.

## Non-goals

계정 인증, 영속 저장과 보상 지급 권한은 클라이언트에 주지 않는다. 렌더링 보간과 UI의 float는 전투 상태에 역으로 입력하지 않는 한 유지한다. 다른 장기 브랜치와 병합하거나 운영 서버를 전환하지 않는다.

## Context / Constraints

- 현재 체크아웃에서 분기했다. 기존 미커밋 변경은 보존하고 작업 커밋에 섞지 않는다.
- `client`는 Unity이며 서버 frame/sync DTO를 시각화한다.
- `game-rust/crates/sim/src`에는 668개 파일이 있다. 물리와 전투에서 f32/f64를 사용하므로 일부 수치만 바꾸는 것으로 결정론을 보장할 수 없다.
- 사용자는 결정론 지원 오픈소스 물리엔진 사용도 허용했다.
- 후보는 `sam-vdp/bepuphysics1int`, 커밋 `9237daa68c3014fd7c2e93c6a99326ba5248d60b`다. 소스, 라이선스, Unity API 호환성을 확인한 뒤 채택한다. 이 엔진은 멀티스레딩을 끄고 float 입력을 배제해야 한다.
- 게임 규칙의 기준은 현재 브랜치의 서버 코드와 데이터다. 기존 Java 동작과 수치 오차까지 일치시키는 포팅 규칙은 이번 고정 소수점 전환 목표로 대체하되 게임 규칙 변경은 기록한다.

## Approach (Checklist)

- [x] **Step 0: Recon** — 모듈 지침, 기존 물리 코드, SDK 의존성, 작업 상태 확인. 루트/client/game-rust/lobby 브랜치 생성.
- [x] **Step 1: Implementation** — 엔진 소스를 고정 버전으로 도입하고 Unity 독립 시뮬레이션 assembly에서 충돌·고정 tick을 실행한다. 입력은 tick/player/sequence 순서로 적용하며 누락 tick은 대기한다. seed, 규칙 버전, 콘텐츠 해시를 시작 시 합의한다.
- [x] 전투 기능 목록을 서버 파일과 일대일로 추적한다. 카드/마법/상태효과/이동/충돌/표적/봇/PVE/종료 조건을 순차 이관하며 매 단계 기존 frame DTO로 렌더링을 검증한다.
- [x] game-rust는 인증된 입력 중계, tick 확정, 재전송과 입력 기록을 담당한다. lobby는 시뮬레이션 버전과 콘텐츠를 합의한 매치를 생성한다. 서버 결과 검증 없이 클라이언트가 보상을 확정할 수 없게 한다.
- [x] **Step 2: Tests** — 고정 소수점 경계, 입력 재정렬/중복/누락/잘못된 플레이어, 동일 seed 재생, 충돌, 장기 재생 상태 해시, 재접속과 종료를 검사한다.
- [x] **Step 3: Rollout / Rollback** — 명시적 lockstep 매치 모드로 연결한다. 이관되지 않은 기능을 지원한다고 광고하지 않는다. 전투 규칙/플랫폼 검증을 마친 뒤 전환한다.

## Validation

- **Commands to run:** Unity EditMode tests, Windows/IL2CPP/WebGL replay, 관련 서버 테스트, `git diff --check`, 루트 `graphify update .`.
- **Expected output:** 동일 초기 상태와 입력 로그에 대해 각 tick의 정규화 상태 해시가 일치한다. float 변환은 입력 양자화 또는 렌더링 경계에만 있다. 실제 GameScene에서 두 플레이어의 한 경기가 종료되고 결과가 한 번만 저장된다.
- 재생 상태에는 RNG, 생성 ID, 시간, 예약 이벤트, 카드, 상태효과와 엔진 내부 지속 상태까지 포함한다. 위치만 같은 것은 충분하지 않다.
- 재접속은 입력 로그와 동일 초기 상태의 재생부터 구현한다. 엔진 캐시를 빠뜨리는 임의의 중간 스냅샷 복원은 허용하지 않는다.

## Risks & Rollback

- **Risks:** 엔진의 WebGL/IL2CPP 호환성, 고정 소수점 범위와 성능, 기존 물리 규칙 차이, 숨겨진 무작위 순서, 느린 참여자의 tick 정체, 결과 위조. 각각 빌드/재생/규칙 비교/입력 시간 제한/검증 경로로 확인한다.
- **Rollback steps:** lockstep 매치 생성만 비활성화한다. 기존 게임 서버 경로 제거는 완전 이관 검증 이후에 수행한다.

## Open Questions

- 엔진 Unity·WebGL 빌드 검증 결과와 실제 동시 유닛 수의 성능 측정이 필요하다.
- 모든 전투 기능의 이관 목록과 프로토콜 세부 값은 소스 확인 후 확정한다.

## Review revisions

Fast/medium 검토의 필수 지적을 반영했다. 전체 이관 전에 다음 선행 검증을 수행한다. 이 검증만 완료한 상태를 기능 이관 완료라고 보고하지 않는다.

1. 엔진 검증은 `client/Tools/LockstepProbe`에서 격리해 수행한다. 동일 프로세스의 복수 world, 서로 다른 프로세스의 10,000 tick 충돌 재생을 비교한다. 이어 Unity Editor/IL2CPP/WebGL 빌드와 플랫폼 간 재생, sphere/box/trigger/raycast 및 기존 규모 성능을 검증해야 채택한다. 검증 전에는 GameScene 실행 경로를 바꾸지 않는다.
2. 전체 이관의 첫 게임 통합 단계는 입력→인증 중계→확정 tick→이동/충돌/공격→화면→종료까지 연결하는 최소 경기다. 이후 기능별 원본 경로/구현 경로/fixture/상태 목록으로 전투 기능 전체를 추적한다. 서버 파일 구조를 그대로 복제할 필요는 없다.
3. 결과 검증은 Unity와 무관한 동일 C# 시뮬레이션의 headless 재생으로 수행한다. Rust에서 전투 규칙을 재구현하지 않는다. Rust는 서명된 초기 상태와 서버가 확정한 입력 로그를 검증 프로세스에 전달하고, 콘텐츠/시뮬레이션 버전과 최종 결과가 일치할 때만 기존 결과 저장 경로를 호출한다.
4. 초기 상태는 서버가 생성한다. 플레이어/슬롯, 덱 순서, 모든 수치, 맵/시나리오, seed/RNG 상태, 최초 객체 ID, 콘텐츠/프로토콜/시뮬레이션 버전을 담는다. 현재 wire contract는 서버가 직렬화한 JSON 원문을 `initialStateJson` 문자열로 보내고 그 UTF-8 바이트를 SHA-256 해시한다. 클라이언트가 JSON을 재직렬화해서 해시하지 않는다. 콘텐츠 스키마와 lobby 생성은 아직 미구현이다. 클라이언트 캐시의 현재값을 초기 상태에 섞지 않는다.
5. 각 플레이어는 tick당 하나의 완결 batch(입력 없음은 빈 배열)를 제출한다. batch의 명령은 sequence 순서다. 같은 tick/player의 동일 batch 재전송은 멱등이고 다른 payload는 거부한다. 서버가 모든 슬롯의 batch를 모아 player 순서로 확정하고 클라이언트는 연속 확정 tick만 실행한다. 제한 시간/연결 종료의 중단 또는 패배도 서버가 하나의 결과로 확정한다. 클라이언트가 누락 입력을 채우지 않는다.
6. 재접속은 초기 상태와 확정 입력 전체를 재생한다. 복원할 수 없는 물리 캐시를 생략한 중간 스냅샷은 도입하지 않는다. DTO는 렌더링 경계에만 둔다.

Rejected feedback: 없음. 전체 이관은 위 선행 검증을 통과한 뒤 진행한다.

Heavy review: PASS (격리된 엔진 probe 구현 범위). 전체 이관 승인을 의미하지 않는다.

2026-10-26 진행: Windows .NET 8의 별도 프로세스 및 Unity 2022.3.34f1 Editor에서 32개 sphere, 10,000 tick 재생 해시가 일치했다. `client/Tools/LockstepProbe/README.md`에 소스/패치/명령/검증 한계를 기록했다. worktree 요청에 따라 이번 생성 파일만 옮기고 원래 체크아웃의 브랜치와 기존 수정은 복원·보존했다. Graphify는 설치되어 있지 않아 update를 실행하지 못했다.

WebGL 추가 검증: 새 worktree에서 IL2CPP WebGL 빌드가 종료 코드 0으로 완료됐고 브라우저 콘솔에서도 같은 `BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D` 해시를 확인했다. 실제 GameScene·서버 프로토콜·전투 규칙은 아직 변경하지 않았다.

## 이어서 구현한 내용

- `game-rust/crates/server/src/lockstep.rs`: 서비스 권한으로 세션 생성, JWT 참여자만 초기 상태/이력 조회 및 입력 제출. 한 tick에 두 슬롯의 완결 batch가 필요하며, 같은 입력은 재전송 가능하고 다른 입력은 거부한다. 20 Hz, 입력당 명령 16개, tick 12,000개, 세션 로그 2 MiB, 초기 상태 128 KiB, 세션 64개, 무진행 30초, 생성 후 보관 30분으로 제한했다.
- 세션 mutex 아래서 이력을 먼저 기록한 뒤 broadcast한다. 최대 128 frame씩 이력을 재생한다. wildcard 구독과 재인증 CONNECT를 막아 다른 참가자의 입력을 볼 수 없게 했다. 결과/보상 경로에는 연결하지 않았다.
- `LockstepConnection`: 초기 상태 해시/버전 검증, 확정 tick 순차 전달, 누락 이력 조회, 미확정 batch 재전송, 재연결. GameScene에 설치하거나 기존 매칭에서 시작하는 코드는 아직 없다.
- 실제 BEPU 고정 소수점 소스를 `LocalPackages/com.arcanecasters.lockstep`에 고정했다. 단일 스레드 `PhysicsWorld`는 ID 순서의 충돌 이벤트와 동거리 raycast 선택을 제공한다.
- 덱/마나/fever, Java shuffle, 능력치, 속성 상성, 피해 처리 순서, 소환 위치, 사거리, tick 시계와 예약 이벤트를 독립 C# 코어로 옮겼다. 전체 유닛/마법의 호출 경로를 이관했다는 뜻은 아니다. 사망 후 필드·공중 낙하·PVE·봇·경로 탐색·컨텐츠 초기화는 미완료다.
- `tools/lockstep-coverage.ps1`이 원본 소스 해시와 부분 이관 경로를 CSV로 기록한다. 각 원본에 대한 경기 fixture 검증 전에는 완료로 표시하지 않는다.

검증: Rust clippy 전체 targets 및 fmt 통과. 실제 WebSocket 참여자 2명/비참여자 차단/130 tick/이력 2페이지 테스트 통과. 전체 Rust 테스트에서 `instant_format::matches_java_instant_to_string`(Windows 시간 정밀도)과 `llm_http_client::a_closed_port_is_an_io_failure`(Timeout/Io 분류) 두 건이 실패했으며 해당 소스는 수정하지 않았다. 나머지 대상은 통과했다. Native 전송 실제 소스를 로컬 WebSocket에 연결해 UTF-8 분할/분할 STOMP/100개 동시 전송/옛 소켓 콜백/ERROR 처리를 검증했다. WebGL JS 콜백도 별도 검사했다. 이는 Unity 경기 두 개의 네트워크 대전 검증을 대신하지 않는다.

최신 검증: 전체 client 스크립트 컴파일 종료 코드 0. 추가한 CoreTests와 10,000 tick 재생은 .NET/Editor/WebGL에서 모두 통과했다. WebGL incremental 실행에서 `_unity_self` 오류가 발생해 GUI probe를 제거하고 data caching을 끈 clean development 빌드로 다시 확인했다. 브라우저 콘솔에 `PASS core`와 같은 `BF7A...7D` 재생 해시가 출력됐으며 `FAIL`은 없었다. 이는 엔진 내부 캐시 상태를 포함하는 전투 전체 해시 검증은 아니다.

다음 구현 경계: (1) 서버 콘텐츠를 담은 초기 상태 스키마, (2) 객체/컴포넌트 수명과 이동/공격 상태 머신, (3) 고유 마법·상태효과·봇·PVE, (4) lobby 및 GameScene 실행 연결, (5) 동일 C# headless 결과 재생과 영속 결과 저장. 이 항목이 남아 있으므로 실제 매칭을 lockstep으로 전환하지 않았다. 현재 변경은 worktree의 미커밋 파일로 보관한다.

## 기존 테스트 전체 이관 요구 반영

사용자가 기존 테스트 전체 이관과 기존 동작 동일성을 추가 요구했다. 최종 완료 조건은 전체 전투 이관, lobby/GameScene 연결, 실제 대전 종료와 결과 검증, 원본 테스트 전체 대응 및 통과다. 작은 테스트 묶음의 통과는 이 조건을 대체하지 않는다.

- `tools/lockstep-test-coverage.py`는 `ac-sim/src`와 `ac-sim/tests`의 원본 테스트 함수, 원본/대응 코드 해시, 실행 결과를 CSV에 기록한다. `--strict`는 미이관 또는 미검증 항목이 하나라도 있으면 실패한다. 원본 소스에서 915개 테스트 함수를 찾았다.
- `Tools/LockstepProbe/PortedTests`는 원본 파일과 함수명을 유지한다. 현재 economy 19개, 객체/컴포넌트/이벤트 11개, `tests/mob.rs` 전체 17개를 이관했다. .NET에서 47개 통과했고 기존 코어·10,000 tick 물리 재생도 통과했다. 나머지 868개는 완료로 표시하지 않는다.
- 원본 마나 테스트 이관으로 1.8 마나를 5번 충전할 때 8로 절삭되는 차이를 발견했다. 원본의 1e-6 경계를 고정 소수점으로 유지해 9가 되도록 수정했다. 기존의 20/60 FPS 테스트 조건을 삭제하지 않았다.
- `PlayerData`, `ManaCharger`, `CardDeck`를 원본 책임대로 분리하고 기존 `PlayerEconomy`도 같은 구현을 사용하게 했다. `SimObject`/`SimComponent`의 시작·지연 추가/삭제·반복 상태 이벤트·Dying 상태, `ElementSet`의 원소 출처별 합성, `FlowPublisher`의 구독 취소를 이관했다.
- `MobComponent`는 직접 피해/일반 피격, 면역/방어막/속성 반응, 최대 HP 변경, 지연 피해, hit 이벤트, 사망 통지를 담당한다. `DeathField`는 원래 소유자와 native 원소로 장판을 고르며, `AerialDeathFall`은 사망을 착지까지 미룬다. hover/낙하 피해 규칙은 `ZPhysics`에 있다. 실제 모든 prefab 및 전투 루프와 연결한 상태는 아니다.
- 다음은 상태효과/피해 수신기와 타깃·이동/공격 상태 머신을 원본 테스트와 함께 연결한다. 소환 prefab을 임시 generic 유닛으로 대체해 전체 이관으로 간주하지 않는다.

### 상태 효과 이관 진행

- 화상/젖음 상쇄, DOT, 둔화/속박, 기절/감전의 hover 잠금·중력 복원, 광란 소유권 변경, 고무 공격 속도, 방울 피해 차단, 질량에 따른 넉백을 추가했다. 원본의 지연 제거와 갱신 시 Start 재호출을 유지했다.
- 일반/건물 효과 수신기의 설정값 적용, 원소 면역, 동일 key 갱신/연장/무시를 이관했다. 설정값은 `SimulationContext.GameParameters`에서 읽는다. 전체 콘텐츠 초기 상태 로딩은 아직 연결하지 않았다.
- 넉백의 0.1초 테스트에서 고정 소수점 절삭 잔량이 만료를 한 틱 늦추는 차이를 찾았다. 1e-6보다 작은 마지막 이동 잔량을 합쳐 원본 테스트의 5회 이동/6회 만료를 유지했다.
- 원본 테스트 17개를 추가해 .NET 64/915개가 통과했다. 851개가 남았다. Rust 컴파일 목록은 일반 테스트 915개와 doctest 2개이며, 현재 인벤토리는 일반 테스트 함수만 다룬다. doctest의 계약도 최종 이관 검증 대상이다.
- `RigidBody`는 한 틱의 요청 속도 누적만 담당한다. 실제 `PhysicsWorld`와 전체 전투 시스템 연결은 아직 남았다. 원본 전체 테스트와 실제 대전 완료 전에는 작업을 완료로 표시하지 않는다.
- 같은 64개 원본 테스트와 10,000 tick 재생이 Unity Editor에서도 통과했다. 새 파일 import 도중 임시 컴파일 오류 뒤 자동 재컴파일이 성공했고 최종 실행과 프로세스 종료 코드 0을 확인했다. 이번 상태 효과 추가분의 WebGL 검증은 아직 하지 않았다.

### 경로 탐색과 이동·공격 상태 머신

- `Terrain`에 강·다리 셀과 노출된 물 경계, 물까지의 거리를 옮겼다. `NavigationGrid`/`FlowFieldNavigation`은 장애물·물 여유 공간, 프레임별 변경 감지, 목적지별 캐시, 경로 직선화와 갇힌 경우 원본 직선 fallback을 유지한다. 동률 우선순위 큐의 sift 순서는 원본 Java 구현과 같다. 비용 연산은 고정 소수점이다.
- `BehaviorMob`에 Idle/Move/Attack/Stun/DirectiveMove 상태, 주기적 재탐색, 타깃 마스크 변경, 소유권 변경, 고도 무시 공격, 이동 지시 우선순위와 공격 간격 carry-over를 연결했다. 지상은 context의 flow field, 공중은 직선 경로를 쓴다. `AttackMob`/`MeleeAttackMob`의 피격 및 공격 상태 전환, `RallyMoveDirective`의 집결 범위 교전 규칙도 옮겼다.
- 원본 flow field 통합 테스트 21개, BehaviorMob 15개, detector 7개, terrain 10개, rally 5개를 추가했다. .NET 기준 총 122/915개 통과, 793개 미완료다. 물리 재생 해시는 유지됐다. 실제 전체 prefab 등록, PhysicsWorld와 전투 시스템 연결, PVE/봇/네트워크 대전 완료는 여전히 미완료다.
- 다음에는 원본 충돌/시스템 단계와 클라이언트 고정 소수점 물리 어댑터를 맞추고, 고유 유닛·마법 prefab과 전투 초기 콘텐츠 로딩을 연결한다. 유닛별 고유 동작을 generic 대체로 축소하지 않는다.
- Unity Editor도 최종 재컴파일 후 원본 테스트 122개와 같은 10,000 tick 해시를 통과했고 종료 코드 0을 확인했다. `git diff --check`는 root/client에서 통과했다. Graphify 실행 파일은 계속 없어 갱신할 수 없었다.

### 충돌 질의와 객체 시스템

- `SimCollider`, `CircleCollider`, `EdgeCollider`, `CollisionChecker`를 추가했다. 원형끼리는 엄격한 거리 비교, 경계는 반지름 이하 비교, 벽의 높이 무시·피격체 높이 반영, 지연 등록 RigidBody 조회를 원본대로 유지했다. 이는 전투 질의 코드이며 BEPU 물리 응답 어댑터 연결을 완료했다는 의미는 아니다.
- 기존 경로·행동 테스트의 임시 원형 인터페이스 구현을 실제 `CircleCollider`로 교체했다. 경계 캐시/고도와 RigidBody 지연 등록 관련 원본 테스트 7개가 추가 통과했다.
- `GameObjectStateInitialSystem`, `ComponentUpdateSystem`, `GameObjectAddRemoveSystem`을 추가했다. 한 객체의 예외가 다음 객체 갱신을 막지 않으며 객체별 최초 오류만 알리는 원본 동작을 유지했다. 해당 원본 테스트 1개도 통과했다.
- 최신 .NET 검증은 130/915개 통과, 785개 미완료다. Unity Editor는 객체 시스템 추가 직전 129개와 물리 해시 검증을 통과했다. 전체 물리 시스템, prefab 콘텐츠와 실제 대전 연결은 계속 미완료다.

### BEPU 전투 어댑터와 돌진 속도 추적

- `BattlePhysicsSystem`이 실제 BEPU 몸체와 원형·경계 충돌체를 연결한다. 물은 지상 피격체만 막고, 비행·투사체·사망 중 객체는 통과한다. `TerrainPrefabs`에 실제 Wall/RiverWater 경계를 등록했다. 강 관련 원본 테스트 14개, 벽 관련 2개, 충돌 콜백 2개를 추가했다.
- 선택적 전투 재질에 warm-start/침투 보정 제외, 충격량 상한, 회전 제외와 같은 높이 접촉의 수평 법선 규칙을 추가했다. 밀집 유닛 12개를 300프레임 진행하는 원본 강 테스트도 통과한다. `Patch-Engine.ps1`에 같은 수정을 기록했다. 새 upstream 다운로드부터 패치까지의 재현 실행은 아직 하지 않았다.
- `MovementSpeedTracker`에 실제 수평 이동 거리의 0.15초 표본과 돌진 1~4단계 효과를 이관했다. 원본 테스트 2개와 별도 표본 시점·정지·효과 정리 검증을 통과했다.
- .NET과 Unity Editor에서 원본 테스트 150/915개와 기존 10,000 tick 해시 검증이 통과했다. 일반 테스트 765개와 doctest 2개의 이관 검증이 남았다. 새 코드의 WebGL 검증은 아직 하지 않았다.
- 물리 콜백 시점은 원본의 충격량 계산 뒤 호출과 아직 다르다. 고유 유닛·마법/PVE/봇, 전체 prefab 및 초기 콘텐츠, lobby·GameScene 연결, 동일 시뮬레이션의 결과 재검증과 실제 대전 종료까지 계속 구현해야 한다. 전체 동등성을 완료로 표시하지 않는다.

### 공포 유닛의 목표 탐색과 상태 전환

- `PriorityEnemyDetector`와 `TargetCategory`를 추가했다. 분류 우선순위 뒤 중심 거리를 비교하고 동률은 객체 순서를 유지한다. 체력·속도 기반 유닛/건물 분류, 플레이어 우선 판별, 범위·높이 마스크·적대 관계 필터를 이관했다.
- `CowardMob`의 전용 Idle/Move/Attack/Panic 상태와 `NonAttackingCowardMob`, `PanicStatusEffect`를 추가했다. 위협은 유닛, 목표는 건물 다음 플레이어로 분리하며 공포 종료 후 10초 대기와 목표 재탐색을 유지한다. 같은 위치에서 도주 방향을 뽑는 난수는 Java nextDouble의 두 상태 전이를 유지한 Q32.32 분수와 고정 소수점 삼각함수를 사용한다.
- 원본의 NonAttackingCoward 범위 테스트와 공포 도주 벽 테스트를 추가해 .NET 152/915개가 통과했다. 벽 테스트의 LightningSummonEffectReceiver는 효과 수신을 호출하지 않으므로 동일한 빈 충돌 콜백을 가진 CommonEffectReceiver를 사용했다. LightningSummon 고유 과충전 효과는 아직 이관하지 않았다. 별도 통합 검증은 위협 감지, 2배 도주 속도, 목표 재획득, 공포 효과 제거와 공격 간격을 확인한다.
- 일반 테스트 763개와 doctest 2개, StormStag 고유 돌진과 나머지 전체 전투/매치 연결 작업은 계속 남아 있다.
- Unity Editor에서도 152개와 같은 10,000 tick 해시가 통과했고 프로세스 종료 코드 0을 확인했다. 새 파일 import 후 자동 재컴파일이 완료된 최종 결과다.

### 번개 소환수의 과충전 효과

- `EffectApplication`에 효과를 일으킨 객체를 담고 `LightningSummonEffectReceiver`에서 아군·중립·출처 없는 Shock만 과충전으로 바꾼다. 적 Shock은 기존 면역 규칙을 거친다. 공포 도주 벽 테스트의 임시 수신기도 실제 번개 수신기로 교체했다.
- `OverchargeStatusEffect`는 속도에 독립적인 1.5배 배율을 적용한다. 재적용은 동일 컴포넌트의 지속 시간을 늘리며 제거 예약 상태면 다시 활성화한다. 매초 사거리 2 안의 가장 가까운 적에게 ElectricShot 이벤트와 0.2초 지연 피해를 보낸다. `BattleEvent`에 지속 시간과 폭을 추가했다. 초기 콘텐츠 로더가 채울 피해 키는 `electric_shot.damage`다.
- 원본 효과 테스트 6개와 수신기 테스트 7개를 추가했다. 0.2 속도 보정의 수치 검사는 Q32.32 표현 오차가 연산을 거친 상한(10~16 raw 단위)을 명시했다. 의미상 동작과 정수 피해·지연·지속 시간은 원본 기대값을 검증한다.
- .NET과 Unity Editor에서 원본 테스트 165/915개 및 기존 10,000 tick 해시가 통과했다. 일반 테스트 750개와 doctest 2개의 이관 검증이 남았다. 이벤트의 실제 GameScene 렌더링과 전체 네트워크 대전 종료는 아직 연결하지 않았다.

### StormStag 돌진과 충돌 콜백 순서

- `StormStagMob`에 목표 탐색·가속 돌진·공포 상태를 이관했다. 유닛/건물/플레이어 목표 우선순위, 공포 위협 분류, 속도 단계별 피해와 Java 반올림, 충돌 뒤 중복 피해 차단, 공포 중 벽에 닿으면 재돌진하는 동작을 유지한다. 3단계 이상 공격의 ElectricShot 연출은 충돌한 객체가 아닌 기존 돌진 목표를 향한다.
- 원본 StormStag 테스트 7개와 실제 왼쪽 벽 충돌 후 재돌진 테스트를 추가했다. 이로써 벽 통합 테스트 4개 모두 이관했다.
- `PhysicsWorld.Step`의 위치 갱신 직전 콜백을 통해 `BattlePhysicsSystem` 순서를 BEPU 충격량 계산 → 전투 충돌 콜백 → 위치 적분으로 맞췄다. 콜백은 계산된 속도를 읽고 같은 틱에 속도를 더할 수 있다. 콜백에서 파괴된 객체는 위치 갱신 대상에서 제외한다. 두 경우를 별도 통합 검증으로 확인했다. 원본의 정확한 두 패스 접촉 해결 순서와 전체 물리 수치 동등성은 계속 검증해야 한다.
- .NET에서 원본 테스트 173/915개, 추가 통합 검증 및 기존 10,000 tick 해시가 통과했다. 일반 테스트 742개와 doctest 2개, 나머지 전투 콘텐츠와 실제 매치 연결은 계속 남아 있다.
- Unity Editor에서도 원본 테스트 173개와 같은 재생 해시가 통과했고 종료 코드 0을 확인했다.

### 이동 투사체와 객체 수명

- `Shot`의 지정 방향 이동, 최초 적 충돌 시 반경 1 피해, 아군 제외와 파괴를 이관했다. 범위 질의는 원본처럼 각 객체의 첫 충돌체를 검사한다. `PushShot`은 같은 적에게 피해를 한 번만 주며 `TimedMassPush`의 방향·속도·남은 시간을 같은 출처별로 갱신한다. 밀림 속도는 질량 제곱근의 역수이며 마지막 부분 틱을 반영한다.
- `ProjectileRangeAttackMob`과 효과 전달형을 추가했다. 이들의 투사체는 표시용이며 피해는 즉시 적용하는 원본 동작을 유지한다. 실제 이동 Shot과 합쳐서 지연 피해로 바꾸지 않았다. 표시 이벤트를 GameScene에 연결하는 작업은 남았다.
- `TimedSelfDestroyer`의 시간 회복·한 틱 정지·TTL 게이지와 `DistanceSelfDestroyer`의 발사 원점 기준 거리 제한을 이관했다. 밀림 4개, PushShot 1개, 시간 수명 10개, 거리 수명 3개의 원본 테스트가 추가됐다.
- .NET에서 원본 테스트 191/915개와 기존 10,000 tick 해시가 통과했다. 실제 컴포넌트 갱신과 물리 충돌을 통해 Shot이 범위 피해를 한 번만 적용하고 아군·원거리 객체를 제외하는 추가 통합 검증도 통과했다. 일반 테스트 724개와 doctest 2개, 고유 마법·유닛/PVE/봇 및 전체 매치 연결은 계속 남아 있다.
- Unity Editor에서도 191개와 추가 통합 검증, 같은 재생 해시를 통과했고 종료 코드 0을 확인했다.

### 관통·연쇄·바위 투사체

- `WindBladeShot`의 대상별 한 번 피해와 관통마다 2/3 정수 감쇠를 이관했다. `ChainShot`은 주변 객체 순서의 다음 대상을 선택하고, 0.12초 대기 후 이동하며, 최소 피해를 유지하면서 절반 감쇠하고 최대 5번 적중한다. 원본이 숨긴 direction 때문에 상속된 Direction이 null인 동작도 유지했다.
- `BoulderStrikeShot`의 최초 피해와 `BoulderStrikeKnockback`의 질량별 밀림·행동 정지·벽/바위 잔해/적 유닛 충돌 피해를 추가했다. `BattleEvent`는 참조 ID뿐 아니라 고정 좌표 투사체 연출도 표현한다.
- 원본 바람/연쇄 테스트 4개가 추가되어 .NET 195/915개가 통과했다. 원본 연쇄 테스트의 고정 질의 결과 대신 동일한 후보 순서를 가진 실제 원형 충돌체를 구성했다. 별도 통합 검증은 바위 투사체의 한 번 피해 → 피격체 밀림 → 실제 벽 충돌의 추가 피해 → 충돌 효과 제거를 확인한다. 기존 10,000 tick 해시도 유지됐다.
- 일반 테스트 720개와 doctest 2개, 나머지 고유 마법·유닛/PVE/봇, 초기 콘텐츠 및 실제 매치 연결은 계속 남아 있다.
- Unity Editor에서도 195개, 추가 통합 검증과 같은 재생 해시가 통과했고 종료 코드 0을 확인했다.

### 정신 지배와 덩굴 순차 생성

- `MindControlShot`의 적 소환수 소유권 반전, Idle 전환과 투사체 파괴를 이관했다. 중립·비 Mob·명시적 정신 지배 면역은 제외한다. 기존 Frenzy 면역과 별도 인터페이스를 사용하며 실제 면역 대상 유닛을 이관할 때 각각 적용해야 한다.
- `VineToss`/`VineLine`은 간격만큼 앞에 첫 덩굴을 생성한다. `SequentialLineSpawner`는 마지막 생성 객체로 이동하면서 최초 시전 프레임 기준 일정을 유지한다. `VineHitTracker`와 `OnStartAttacker`는 줄 전체의 같은 적 중복 피해를 막는다. 생성 중 tracker는 전역 thread-local 대신 세션 context에 보관하고 중첩·예외 후 이전 값으로 복원한다.
- 원본 테스트 8개를 추가해 .NET 203/915개가 통과했다. 첫 덩굴 만료 뒤 9개 생성 완료, 생성 일정, 첫 위치, 영벡터 시전, 면역·소유권, tracker 중복·중첩 복원을 검증했다. 별도 통합 검증으로 여러 시작 공격의 피해 공유와 예외 후 context 복원도 확인했다. 기존 10,000 tick 해시가 유지됐다.
- 일반 테스트 712개와 doctest 2개가 남았다. Vine prefab의 EffectProvider와 씨앗 정령 진화, 나머지 고유 전투 콘텐츠와 전체 매치 연결은 아직 이관하지 않았다.
- Unity Editor에서도 203개, 추가 통합 검증 및 같은 재생 해시가 통과했고 종료 코드 0을 확인했다.

### 덩굴 prefab의 효과 전달과 씨앗 정령 진화

- `EffectProvider`는 효과의 출처를 전달하고, `KnockbackEffectProvider`는 Shot 방향 또는 폭발 중심 방향과 반지름 대비 근접도를 전달한다. `SeedSpiritEvolver`/`OnStartSeedSpiritEvolver`는 범위 안의 아군 SeedSpirit을 같은 소유권·위치의 지정 prefab으로 교체한다. 중립 출처는 양쪽을 진화시킨다. `SeedSpiritVineSummoner`는 아군 씨앗 정령 아래에 Vine을 생성한다.
- `VinePrefabs.Register`에 원본 Vine 구성을 옮겼다: trigger 원형, Nature 원소, Snared 효과 전달, 시간 수명, VineSpirit 진화, 공유 적중 기록을 받는 시작 공격. 매개변수는 `vine.radius`, `vine.duration`, `vine.damage`로 초기 콘텐츠에 연결할 예정이다. 진화한 VineSpirit 자체의 고유 유닛 동작은 아직 별도 이관 대상이다.
- 원본 진화 테스트 2개와 덩굴 소환 테스트 3개를 추가해 .NET 208/915개가 통과했다. 별도 통합 검증은 실제 Vine prefab의 아군 진화, 적에게 피해 4 적용, 실제 물리 접촉의 Snared 적용을 확인했다. 기존 10,000 tick 해시가 유지됐다.
- 일반 테스트 707개와 doctest 2개, 나머지 전투 콘텐츠·초기 콘텐츠·lobby/GameScene·실제 매치 종료 검증은 계속 남아 있다.
- Unity Editor에서도 208개와 추가 통합 검증, 같은 재생 해시가 통과했고 종료 코드 0을 확인했다.

### 자연 유닛과 소환기 구성

- `LeafSlime`, `SeedSpirit`, `VineSpirit`, `SeedNest` prefab을 고정 소수점 컴포넌트에 연결했다. 씨앗 정령은 이동 경로에 중립 LeafField를 남기고, 덩굴 정령은 NatureShot 연출과 Snared를 주는 원거리 공격을 한다. LeafField의 속박·회복 및 불에 닿으면 중립 FireField로 바뀌는 동작을 이관했다.
- `Spawner`의 소환 주기 잔여 시간·반 단위 동시 소환 배치·파괴 가능 여부와 HP gauge를 옮겼다. `LimitedSequenceSpawner`는 첫 update 즉시 소환 옵션, 횟수 제한, prefab 순환과 원본 X/Y 배치를 유지한다. `CraterSpawner`는 긴 프레임에서 누락 주기를 모두 생성한다. `RandomAreaSpawner`는 원본의 0..PI 각도 범위와 난수 소비 순서, 높이 10의 낙하 위치를 고정 소수점으로 계산한다.
- 원본 Slime/field 테스트 4개와 소환기 테스트 9개를 추가해 .NET 221/915개가 통과했다. 별도 검증은 실제 SeedNest → SeedSpirit → VineSpirit 진화·이동·공격·Snared, LeafField의 FireField 전환, 동일 seed 무작위 영역 소환의 좌표·난수 상태 재현을 확인한다. 자연 유닛 검증은 초기화·update·충돌 예외도 수집해 실패로 처리한다.
- 기존 10,000 tick 해시는 `BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D`로 유지됐다. 일반 테스트 694개와 doctest 2개, 나머지 콘텐츠·PVE·봇·초기 콘텐츠·lobby/GameScene·실제 매치 종료 검증은 남아 있다. Spawner의 PVE health 인터페이스는 PVE 계층 이관 때 연결해야 한다.
- Unity Editor에서도 221개와 추가 연계 검증, 같은 10,000 tick 해시가 통과했고 종료 코드 0을 확인했다. root/client의 `git diff --check`가 통과했다. Graphify 실행 파일은 계속 없어 AST 갱신은 실행하지 못했다.

### 생명 나무 회복과 PVE 컴포넌트 연결

- `Totem`, `SelfAttacker`, `SelfHealer`와 실제 LifeTree prefab을 이관했다. Totem은 원본처럼 targetMask를 사용하지 않고 범위 안의 활성 아군 Mob에게 직접 피해/회복을 적용하며 자신도 대상에 포함한다. SelfAttacker/Healer는 간격을 초과한 뒤 발동하며 시작 시 찾은 Mob의 `OnDamaged` 경로를 사용한다. SelfHealer가 SelfAttacker 타입으로 조회되지 않는 동작도 유지했다.
- `IPveHealthMob`을 Mob 계층에 연결해 HP/최대 HP 재설정, 소환기 구분을 제공한다. `PveObjectiveTarget`은 null·파괴된 객체·개별 목표 종료 상태를 판정한다. `PveShieldComponent`는 매 피해 시점에 보호막 출처 함수를 다시 조회하고 양수 피해만 차단하며 Bubble 표시를 동기화한다.
- `PveScenarioComponents`는 TimedSelfDestroyer/RandomAreaSpawner 수명 제거, 기존 Spawner 제거, 파괴 불가능한 소환기 추가, 보호막 추가를 실제 컴포넌트로 수행한다. PVE 시나리오 설치·스크립트 실행 계층은 아직 이관 전이다.
- `tests/mob_simple.rs`의 원본 테스트 3개를 추가해 .NET 224/915개가 통과했다. 별도 검증은 LifeTree의 자기/공중 아군 회복·범위 제외·면역, PVE 체력 재설정과 종료 판정, 보호막의 직접/지연 피해 차단·회복 허용, 수명 제거 및 소환기 교체를 확인했다. 기존 10,000 tick 해시도 유지됐다.
- 남은 일반 테스트는 691개와 doctest 2개다. 나머지 전투 콘텐츠·PVE 엔진·봇·초기 콘텐츠·lobby/GameScene 연결·실제 매치 종료 검증까지 목표 범위를 유지한다.
- Unity Editor에서도 224개와 추가 연계 검증, 같은 10,000 tick 해시가 통과했고 종료 코드 0을 확인했다. root/client의 `git diff --check`가 통과했다.

### 수리 오라와 RepairTotem

- `RepairAura`와 실제 RepairTotem prefab을 이관했다. 같은 소유자의 Building에 한해 첫 수명 컴포넌트를 다음 갱신 한 번 동안 정지한다. 자신·적·유닛·플레이어·분류 없는 마법 효과·다른 RepairAura 보유 객체는 제외하며 중립 소유자는 질의 전에 반환한다. 수명을 되돌리거나 HP를 회복하지 않는다.
- 원본 테스트 11개를 추가해 .NET 235/915개가 통과했다. 원본의 FixedPhysics 후보를 실제 겹치는 원형 충돌체로 구성했고, 내부 frozen 필드 검사는 다음 수명 갱신 결과로 검증했다. 중립 테스트의 mock 질의 횟수는 사용하지 않으며 코드의 조기 반환과 수명이 멈추지 않는 결과를 확인한다.
- 별도 검증은 실제 prefab에서 BuildingEffectReceiver와 RepairAura 초기화, 수리 토템 자신의 수명 감소, 대상의 범위 이탈 후 수명 감소 재개, 재진입 및 오라 미적용 다음 tick의 수명 감소를 확인한다. 기존 10,000 tick 재생 해시가 유지됐다. 남은 일반 테스트 680개와 doctest 2개, 나머지 콘텐츠·PVE·봇·매치 연결은 계속 진행 대상이다.
- Unity Editor에서도 235개와 추가 연계 검증, 같은 10,000 tick 해시가 통과했고 종료 코드 0을 확인했다. root/client의 `git diff --check`가 통과했다.

### 바람 토템 범위 밀기

- `WindPushComponent`와 실제 WindTotem prefab을 이관했다. 첫 update부터 적용하고 0.5초마다 갱신한다. 지면에서 시작하는 직육면체를 진영 앞쪽에 배치하며, 같은 출처의 TimedMassPush를 갱신해 중복 컴포넌트를 만들지 않는다. 밀기 지속 시간은 0.5초 + 해당 tick 길이로 유지한다.
- `OverlapBoxAll`은 원본 SimplePhysics처럼 객체 중심 좌표를 경계 포함으로 비교하고 충돌체 반지름을 더하지 않는다. 바람 컴포넌트에서 자신·파괴된 객체·아군·Mob 없는 대상을 제외한다. 중립 출처는 동작하지 않는다.
- 원본 테스트 2개를 추가해 .NET 237/915개가 통과했다. mock 질의 기록 대신 실제 box 좌표와 실제 후보를 검사한다. 추가 검증에서 양 진영 방향, 높은 토템의 지면 기준 범위, 공중·옆 범위 밖 제외, 질량 4의 절반 속도, 주기 중간에 진입한 대상의 다음 갱신까지 대기, 실제 prefab의 정수 절삭 수명을 확인했다.
- 기존 10,000 tick 해시가 유지됐다. 남은 일반 테스트 678개와 doctest 2개, 나머지 콘텐츠·PVE·봇·매치 연결은 계속 진행 대상이다.
- Unity Editor의 새 테스트 파일 import 과정에서 일시적인 타입 미발견 로그가 있었고, 재컴파일 뒤 237개와 추가 연계 검증, 같은 10,000 tick 해시가 통과했다. 최종 종료 코드 0을 확인했다. root/client의 `git diff --check`가 통과했다.

### 번개 구름과 전기 장판

- `LightningCloud`와 실제 prefab, `ElectricField` prefab을 연결했다. 구름 아래 높이 0..10의 column을 즉시 공격하고 정해진 횟수를 채운 뒤 0.3초 동안 마지막 연출을 유지한다. 긴 프레임에는 남은 주기를 따라잡는다. 아군 LightningSummonEffectReceiver에는 과충전을, 다른 진영의 모든 IDamageable에는 피해를 주며 매 공격마다 중립 전기 장판을 생성한다. 중립 구름은 중립 대상도 공격한다.
- 1.9초 + 0.1초의 Q32.32 절삭 잔량으로 공격이 한 tick 밀리는 것을 막기 위해 주기 비교에 1 LSB 허용치를 사용했다. 원본 cloud 테스트 6개와 전기 장판 분류 테스트 1개를 추가해 .NET 244/915개가 통과했다. mock 후보/box 기록은 실제 column 내부 좌표와 BoxCenter/BoxSize 검사로 대체했다. 원본 아군의 Initializing 상태는 실제 생성된 대상의 초기 Idle 상태가 그대로 유지되는지로 검증한다.
- 추가 검증은 실제 prefab의 즉시 공격, 중립 대 중립 피해, 범위 밖 제외, 긴 프레임의 남은 공격 완료와 마지막 연출 대기를 확인한다. 기존 10,000 tick 해시가 유지됐다. 남은 일반 테스트 671개와 doctest 2개, 나머지 콘텐츠·PVE·봇·매치 연결은 계속 진행 대상이다.
- Unity Editor에서도 244개와 추가 연계 검증, 같은 10,000 tick 해시가 통과했고 종료 코드 0을 확인했다. root/client의 `git diff --check`가 통과했다.

### ShockTrap 감지와 지연 기절

- `ShockTrapDetector`와 실제 ShockTrap prefab을 이관했다. 첫 적 감지 tick에는 카운트다운만 시작하고, 대기 시간이 지난 시점에 범위 안의 공격 가능한 IDamageable을 다시 조회해 기절시킨다. 대상이 떠나도 shock 이벤트를 한 번 내보내고 함정을 파괴한다. HP 없는 장판은 발동시키지 않으며 수명 컴포넌트는 없다.
- CommonEffectReceiver를 가진 대상은 TrapStunReceive를 RefreshDuration으로 적용한다. receiver가 없으면 대기 중인 같은 키의 StunStatusEffect를 갱신하거나 새로 추가한다. 파괴 시 준비 효과를 제거한다.
- 원본 테스트 10개를 추가해 .NET 254/915개가 통과했다. mock 범위 후보는 실제 원형 충돌체와 대상 이동으로 대체했다. 추가 검증은 실제 prefab의 수명 없음·BuildingEffectReceiver, 두 함정의 대기 중 기절 중복 방지와 기절 만료를 확인했다. 기존 10,000 tick 재생 해시가 유지됐다.
- 남은 일반 테스트 661개와 doctest 2개, 나머지 콘텐츠·PVE·봇·실제 매치 연결까지 계속 진행한다.
- Unity Editor에서도 254개와 추가 연계 검증, 같은 10,000 tick 해시가 통과했고 종료 코드 0을 확인했다. root/client의 `git diff --check`가 통과했다.

### 기본·물·과부하 폭발과 원소 prefab

- 기본 `Explode`는 생성 시 피해 원소를 보관하고 지연 시간 경계를 넘긴 다음 update에 자신을 제외한 범위 내 모든 IDamageable에 피해를 주며 파괴된다. 아군도 대상이다. `WaterExplode` 컴포넌트는 피해 처리 뒤 질량 제곱근 역수 비율의 수직 충격을 적용한다.
- `ShockOverloadExplosion`은 적에게 1차 피해와 Shock 표시를 주고 1초 뒤 살아 있는 표시 대상의 현재 위치에서 반경·피해 절반의 2차 폭발을 만든다. 반올림 피해는 최소 1이며 여러 표시 대상의 폭발은 각각 적용된다. 표시된 대상이 파괴됐다면 표시만 제거한다.
- 6개 원소 폭발 및 ShockOverload prefab을 연결했다. 원본 WaterExplode prefab은 기본 Explode를 사용한다. WindExplode는 KnockbackEffectProvider를 추가하며 나머지 원소의 Burn/Wet/Snared/Shock 제공자 구성을 유지한다.
- 원본 테스트 7개를 추가해 .NET 261/915개가 통과했다. 과부하 이동 테스트의 mock 후보 주입은 1차 폭발 뒤 실제 대상을 이동시키는 방식으로 대체했다. 별도 검증은 실제 6개 prefab의 원소·충돌체·아군 피해·일회성 폭발과 Wind 넉백 제공자를 확인했다. 기존 10,000 tick 재생 해시가 유지됐다.
- 남은 일반 테스트 654개와 doctest 2개, 나머지 콘텐츠·PVE·봇·실제 매치 연결은 계속 진행 대상이다.
- Unity Editor에서도 261개와 추가 검증, 같은 10,000 tick 해시가 통과했고 종료 코드 0을 확인했다. 원본 대응표 스캐너가 복수 상수 선언을 인식하지 못해 테스트 경로 상수 선언을 분리했고 .NET 재실행 및 261개 대응표 생성을 확인했다. root/client의 `git diff --check`가 통과했다.

### Drop과 Leafair

- `Drop`은 HP 1의 Mob으로 초당 높이 5만큼 내려오며, 지면 아래 또는 적 IDamageable 접촉 시 사라진다. 별도 착지 폭발은 생성하지 않는다. DropMarker로 원소 사망 장판을 제외한다. `Leafair`는 충돌 콜백 대신 update의 범위 질의 순서에서 처음 처리 가능한 대상을 선택해 소모된다. 아군 Mob 회복과 수명 복구, 적 피해·Snared를 연결했다.
- Fire/Nature/Rock/WindDrop, Fire+Rock 원소의 MeteorDrop, `leaf_drop` 매개변수를 쓰는 Leafair prefab을 추가했다. 원본 테스트 6개를 추가해 .NET 267/915개가 통과했다. 범위 mock은 실제 원형 충돌체로 대체했다.
- 추가 검증은 실제 Leafair prefab의 HP 회복·수명 복구·적 속박과 MeteorDrop 피격 시 사망 장판 미생성을 확인했다. 기존 10,000 tick 해시가 유지됐다. 남은 일반 테스트 648개와 doctest 2개, 나머지 콘텐츠·PVE·봇·실제 매치 연결은 계속 진행 대상이다.
- Unity Editor에서도 267개와 추가 검증, 같은 10,000 tick 해시가 통과했고 종료 코드 0을 확인했다. root/client의 `git diff --check`가 통과했다.

### 마나 우물과 플레이어별 충전기 연결

- SimulationContext에 진영별 PlayerData 연결점을 추가하고 `ManaWellMob`이 생성 시 충전 비율 +0.8, 파괴 시 -0.8을 적용하도록 이관했다. 원본처럼 해당 진영의 player data가 없으면 실패한다. Frenzy/정신 지배 면역, HP gauge, Lightning+Nature 원소와 정수 절삭 수명의 실제 ManaWell prefab을 연결했다.
- 원본 생명주기 테스트 1개를 추가해 .NET 268/915개가 통과했다. 별도 검증은 두 우물의 충전량 누적, 반대 진영 격리, 개별 파괴 및 수명 만료 뒤 비율 복원, player data 없는 중립의 실패를 확인했다. 기존 10,000 tick 재생 해시가 유지됐다.
- 초기 매치 콘텐츠에서 Players를 구성하는 연결은 아직 남아 있다. 남은 일반 테스트 647개와 doctest 2개, 나머지 콘텐츠·PVE·봇·실제 매치 연결을 계속 진행한다.
- Unity Editor에서도 268개와 추가 검증, 같은 10,000 tick 해시가 통과했고 종료 코드 0을 확인했다. root/client의 `git diff --check`가 통과했다.

### 플레이어 체력과 로컬 승패 상태

- `PlayerHealthComponent`는 생성 때 원래 진영 PlayerData HP를 설정하고 ApplyDamage 후 HP를 동기화한다. Mob의 피해·회복·지연 피해와 HP 상한을 사용하며 PlayerHealth/FrenzyImmune/MindControlImmune 표식을 제공한다. 사망 시 객체를 파괴하지 않고 현재 진영을 패자로 기록한다.
- `BattleResult`는 ResultChecker의 순수 상태 부분을 옮겼다. 첫 패자 유지, 종료 여부, 양 진영 승패 및 무승부를 제공한다. 결과 프레임 전송·MMR·실제 세션 종료는 아직 연결하지 않았다. PlayerStatusSetter와 실제 Player prefab도 입력 처리 계층 이관 뒤 연결해야 한다.
- 추가 검증은 양 진영 HP 초기화와 분리, 피해·회복 상한·지연 피해 동기화, 플레이어 사망 장판 제외, 객체 유지, 동시 사망 순서와 무승부 상태를 확인했다. 원본 결과 테스트는 전송까지 검증하므로 아직 이관 수에 포함하지 않았다. .NET 원본 268/915개와 추가 검증, 기존 10,000 tick 해시가 통과했다.
- Unity Editor에서도 같은 검증과 재생 해시가 통과했고 종료 코드 0을 확인했다. root/client의 `git diff --check`가 통과했다. 나머지 콘텐츠·PVE·봇·매치 종료 연결과 원본 테스트 647개 및 doctest 2개는 계속 진행 대상이다.

### 마법 입력 처리와 Player prefab

- `MagicInputHandler`의 사람/봇 카드 사용, 카드 없는 봇 마법 실행, 종료 후 거절을 이관했다. 손패 조회 전에 마법을 조회하지 않고, 해석할 수 없는 카드는 무료로 덱에 반환한다. 정상 카드는 위치 보정·배치 검사 후 마나/카드를 차감하고 실행·덱 반환·결과 이벤트·사용 기록 hook 순서로 처리한다.
- 고정 소수점 BoundMagic 실행 연결점과 IMagicLookup을 추가했다. 실제 콘텐츠 parser/전체 마법 registry는 아직 없다. 소환 매개변수 key와 공중 여부로 기존 CastPlacement 및 실제 Terrain/객체에 연결했다. 카드 없는 봇 마법은 원본처럼 배치 검사를 하지 않는다.
- PlayerStatusSetter가 입력 결과를 구독해 성공 시 Attack, 잘못된 마법 시 Hindered를 적용하고 파괴 시 구독을 해제한다. 실제 Player prefab의 HP·충돌체·효과 수신·입력 구독 구성을 연결했다. Context에 UserIds/CardDecks/InputHandler/MagicUsed 연결점을 추가했다.
- 원본 입력 테스트 11개와 PlayerStatusSetter/Player prefab 테스트 각 1개를 추가해 .NET 281/915개가 통과했다. 추가 검증은 실제 Leafair 생성, Player Attack, 구독 해제, 결과 결정 후 마나/객체 생성 금지를 확인했다. 기존 10,000 tick 재생 해시가 유지됐다.
- 남은 일반 테스트 634개와 doctest 2개, 초기 콘텐츠 parser·마법 registry·PVE·봇·lobby/GameScene·매치 종료 연결은 계속 진행 대상이다.
- Unity Editor에서도 281개와 추가 검증, 같은 10,000 tick 해시가 통과했고 종료 코드 0을 확인했다. root/client의 `git diff --check`가 통과했다.

### 마법 카탈로그와 실행 구현 바인딩

- DatabaseMagicParser와 MagicRegistry를 이관했다. 데이터의 ID/이름/속성을 실행 구현에 연결하고, 미등록 이름 제외, 사람의 소유권 검사, 봇의 ID/이름 조회, 행 없는 봇 마법, lazy load와 캐시 무효화를 보존했다. 카탈로그는 매치 초기 스냅샷에 연결할 인터페이스이며 DB 접근을 클라이언트에 노출하지 않는다.
- 같은 이름의 행이 여러 개면 Rust HashMap 순회 대신 가장 작은 ID를 고른다. ID별 목록과 구현 이름 목록도 정렬한다. 전체 마법 구현을 등록하는 Standard registry와 초기 콘텐츠 loader는 아직 연결하지 않았다.
- 원본 parser 테스트 4개를 추가했다. .NET과 Unity Editor에서 285/915개와 추가 검증이 통과했다. Unity 종료 코드 0, 기존 10,000 tick 재생 해시 유지, root/client diff 검사 통과를 확인했다.
- 남은 일반 테스트 630개와 doctest 2개, 모든 마법 구현·PVE·봇·lobby/GameScene·매치 종료 연결은 계속 진행 대상이다. 이 검증은 core 범위이며 실제 매치 완료를 의미하지 않는다.

### 낙하 마법 등록과 광란 토템·유성우

- DropMagics에 원본 10개 bean 이름을 등록했다. 일반 낙하는 Y=10, lightning_drop은 Y=0, chicken_commando는 spawn_height를 사용한다. 입력 Y를 더하지 않고 덮어쓴다. rallying_totem/chicken_commando의 실행 등록은 추가했지만 실제 prefab 이관은 아직 남았다.
- FrenzyTotem의 낙하, 지면 아래 도달/적 충돌 발동, 활성 객체 범위 검사, 아군·적 모두의 EffectReceiver에 duration 전달, 한 번만 발동을 이관했다. 실제 prefab의 trigger collider와 파라미터를 연결했다.
- MeteorShower prefab은 Fire/Rock 원소와 기존 RandomAreaSpawner를 사용한다. duration/radius의 원본 정수 절삭과 interval을 유지한다. 실제 MeteorDrop 생성, 소유 진영, 높이, 반경, 수명 만료를 추가 검증했다.
- 원본 테스트 5개를 추가해 .NET과 Unity Editor에서 290/915개가 통과했다. 별도 prefab 검증과 기존 10,000 tick 해시가 통과했고 Unity 종료 코드 0을 확인했다. 남은 일반 테스트 625개와 doctest 2개, 나머지 콘텐츠·PVE·봇·lobby/GameScene·실제 매치 종료 연결을 계속 진행한다.

### 집결 토템과 이동 지시 연결

- RallyingTotem의 낙하와 지면 보정, 착지 다음 tick부터 수명 계산, 아군 IStunnableBehavior 모집, 범위 안 아군 Inspired 버프, TTL 갱신을 이관했다. 기존 RallyMoveDirective를 재사용하고 현재/대기 component를 모두 검사해 중복 등록을 막는다. 원본처럼 모집 단계에서 별도 IsActive 필터를 추가하지 않는다.
- 실제 prefab의 Fire 원소와 trigger collider, 몸체 radius와 별개인 effect_radius를 연결했다. 원본 토템 테스트 6개와 prefab 테스트 2개를 옮겼다. 물리 mock 대신 실제 collider query를 사용한다. 기존 이동 지시 테스트는 중복 집계하지 않는다.
- 추가 검증으로 DirectiveMoveState 진입, 대기/활성 지시 중복 방지, 토템 파괴 후 지시 제거와 일반 상태 복귀, 중립 모집 제외를 확인했다. 지시 재조회 주기는 기존 이동 상태 그대로 유지한다.
- .NET과 Unity Editor에서 298/915개와 추가 검증, 기존 10,000 tick 해시가 통과했다. Unity 종료 코드 0을 확인했다. 남은 일반 테스트 617개와 doctest 2개, 나머지 콘텐츠·PVE·봇·lobby/GameScene·실제 매치 완료는 계속 진행 대상이다.

### ChickenCommando 낙하 유닛

- ChickenCommandoMob은 Y>0.05 동안 부모 melee update 전체를 건너뛰며 착지 후 기존 MeleeAttackMob으로 동작한다. 실제 prefab의 RigidBody/ZPhysics/ground target mask/Wind 원소/CommonEffectReceiver와 데이터 매개변수를 연결했다. 원본 f32::MAX 낙하 피해 threshold는 Fix64.MaxValue로 옮겼다.
- 추가 통합 검증은 등록된 chicken_commando 마법의 spawn_height 덮어쓰기, 0.05 경계 양쪽, 공중 목표 탐색/공격 중지, BattlePhysicsSystem을 통한 낙하와 무피해 착지, 착지 후 적 공격을 확인한다. 해당 컴포넌트와 prefab에는 독립 원본 테스트가 없어 이 검증을 원본 테스트 수에 더하지 않았다.
- .NET과 Unity Editor에서 원본 298/915개 및 추가 검증, 기존 10,000 tick 재생 해시가 통과했다. Unity 종료 코드 0과 root/client diff 검사 통과를 확인했다. 일반 원본 테스트 617개와 doctest 2개, 나머지 마법·유닛·PVE·봇·초기 콘텐츠·lobby/GameScene·매치 종료 연결은 계속 진행 대상이다.

### 건물 소환 마법 25종 등록

- BuildMagics에 원본 build/twocard 25종의 bean→prefab 실행을 연결했다. cannon/tower/dragon_tower만 지면으로 보정하며 나머지는 입력 높이를 유지한다. 공통 생성기는 원본 AbstractSummonMagic의 소유 진영 변환 hook도 제공한다.
- MagicImplementation과 BoundMagic에 SummonedPrefab을 보존한다. 배치 radius는 마법 이름이 아니라 prefab bean에서 유래한 key를 사용한다. 예를 들어 cannon은 ground_cannon, fire_slime_nest는 fire_summon이다. 전체 Standard registry와 나머지 건물 prefab 전투 동작은 아직 구현 대상이다.
- 원본 테스트 5개를 옮겨 25개 이름/소환 대상/소유 진영/높이 규칙을 확인했다. 별도 검증은 DatabaseMagicParser에서 seed_nest를 해석하고 실제 MagicInputHandler를 통해 카드와 마나를 소비하며, 플레이어와 겹친 위치를 반경 합의 0.6배 이상으로 보정한 뒤 실제 SeedNest prefab을 생성하는 경로를 확인했다.
- .NET과 Unity Editor에서 303/915개와 추가 검증, 기존 10,000 tick 해시가 통과했다. Unity 종료 코드 0과 root/client diff 검사 통과를 확인했다. 남은 일반 테스트 612개와 doctest 2개, 모든 전투 콘텐츠·PVE·봇·lobby/GameScene·매치 종료 연결은 계속 진행 대상이다.

### 회복 토템과 Item 추적

- HealingTotem prefab을 원본 RigidBody/trigger circle/Totem/Item/Nature+Water/정수 duration/CommonEffectReceiver 구성으로 연결했다. Item은 첫 circle 반경으로 조회하며 자신·적을 제외한 첫 아군 또는 중립 객체를 선택하고 다음 update부터 위치를 따른다. 원본처럼 대상 파괴 시에도 참조를 유지하며 추가 활성/유닛 필터를 넣지 않는다.
- 추가 검증으로 등록된 healing_totem 마법의 실제 생성, 아군 회복과 적·원거리 제외, 최초 획득 시 위치 유지, 이동 및 파괴된 대상 추적, 중립 획득, collider 없는 Item, 정수 수명 만료를 확인했다. 독립 원본 테스트가 없는 두 파일이므로 원본 이관 수에는 추가하지 않았다.
- .NET과 Unity Editor에서 원본 303/915개와 추가 검증, 기존 10,000 tick 재생 해시가 통과했다. Unity 종료 코드 0과 root/client diff 검사 통과를 확인했다. 남은 일반 테스트 612개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·lobby/GameScene·실제 매치 완료는 계속 진행 대상이다.

### BubbleGenerator와 주기 행동 부모

- TimedBehaviorMob의 interval Stat, 누적 타이머, 성공 때만 carry-over 적용을 이관했다. BubbleGeneratorMob은 활성 아군 중 EffectReceiver/IDamageable이 있고 기존 BubbleReceive가 없는 가장 가까운 대상을 선택한다. 동거리에서는 객체 순서를 유지한다. 대상 선정은 몸체 가장자리 기준 range와 실제 3D 거리 우선순위를 사용한다.
- WaterShot projection 이벤트의 거리/projectile_speed duration과 즉시 Bubble 적용, Attack 상태, 실제 prefab의 RigidBody/solid circle/수명/Water/BuildingEffectReceiver를 연결했다. 대기 중인 Bubble 효과는 원본처럼 제외 조건에 포함하지 않는다.
- 추가 검증으로 실제 등록 마법 생성, 대상 없는 동안 재시도 타이머 유지, 적·비활성·수신기 없는 객체·피해 불가·원거리 제외, 동거리 순서, 기존 보호막 건너뛰기, 발사 주기, 즉시 피해 차단, 대기 효과의 원본 동작을 확인했다. 독립 원본 테스트가 없는 파일들이므로 원본 이관 수에는 더하지 않았다.
- .NET과 Unity Editor에서 원본 303/915개와 추가 검증 및 기존 10,000 tick 해시가 통과했다. Unity 종료 코드 0, root/client diff 검사 통과를 확인했다. 일반 테스트 612개와 doctest 2개, 나머지 콘텐츠·PVE·봇·매치 연결 및 종료 검증은 계속 진행 대상이다.

### GrassGenerator 장판 슬롯과 수명 유지

- GrassSpread의 고정 동심원 슬롯을 이관했다. 반경/개수/간격 하한, 1.75 ring 간격과 홀수 ring 각도 offset, 안쪽부터 순차 생성, 파괴된 슬롯 재사용, 지연 tick의 while catch-up, Burn 공급자와 겹친 후보 건너뛰기를 유지한다. 난수는 사용하지 않으며 각도 계산은 고정 소수점 sin/cos를 사용한다.
- 생성 시 장판 TimedSelfDestroyer를 캐시하고 다음 update부터 매 tick Freeze한다. 생성기 파괴 이후는 freeze를 중단해 장판 고유 수명으로 만료된다. 실제 GrassGenerator prefab의 effect_radius, 몸체 radius, HP, 수명, BuildingEffectReceiver와 기존 SeedSpiritVineSummoner를 연결했다.
- 원본 GrassSpread 테스트 9개와 prefab 테스트 1개를 옮겼다. 원본 위치 전용 physics mock은 실제 collider 조회로 교체했다. 극좌표 검증은 사분면/대각선의 독립 기대 위치에 고정 소수점 오차 허용치를 적용한다.
- .NET과 Unity Editor에서 원본 313/915개와 추가 검증, 기존 10,000 tick 해시가 통과했다. Unity 종료 코드 0과 root/client diff 검사 통과를 확인했다. 남은 일반 테스트 602개와 doctest 2개, 전체 전투 콘텐츠·PVE·봇·lobby/GameScene·매치 완료 검증은 계속 진행 대상이다.

### Tower·Turret 지연 공격과 RockTurret prefab

- HP 없는 Tower component와 HP를 가진 TimedBehaviorMob 기반 Turret을 이관했다. 둘 다 range 조건으로 가장 가까운 적을 고르고 RockShot projection을 보낸다. Tower는 대상 주위 1 범위의 공격 가능한 객체에 지연 피해를 예약하고 Turret은 한 대상에게만 예약한다. 대상이 없으면 타이머를 유지한다.
- RockTurret prefab의 ground target mask, 명시적 0.2초 지연, HP·몸체·수명·Rock·CommonEffectReceiver와 광란/정신 지배 면역을 연결했다. GroundTower prefab은 RockDeathRemnant 의존성을 이관한 뒤 연결해야 하므로 아직 등록하지 않았다.
- 원본 RockTurret 수명 테스트 1개를 옮겼다. 추가 검증은 실제 마법 소환부터 지상/공중 선택, 단일/범위 피해 차이, 아군·원거리 제외, 발사 타이머, 이벤트와 지연값, 실제 DummyMob의 지연 후 HP 감소를 확인했다.
- .NET과 Unity Editor에서 원본 314/915개와 추가 검증, 기존 10,000 tick 해시가 통과했다. Unity 종료 코드 0 및 root/client diff 검사 통과를 확인했다. 남은 일반 테스트 601개와 doctest 2개, 나머지 콘텐츠·PVE·봇·lobby/GameScene·실제 매치 종료 검증은 계속 진행 대상이다.

### 바위 잔해와 GroundTower 연결

- RockDeathRemnant가 전투 사망 callback에서 한 번만 소유 진영/사망 위치의 잔해를 생성하도록 이관했다. Small/Medium의 잔해·재소환·폭발 후 잔해 매핑도 추가했다. 작은 잔해는 mini_rock.radius, 중간 잔해는 medium_rock_remnant.radius를 쓰며 둘 다 Rock 원소, 비전투 solid collider, 20초 수명을 가진다.
- 기존 StaticObstacle 표식에 원본 ICollidable 구현을 추가해 실제 물리 충돌에도 참여시켰다. GroundTower prefab의 공중 대상 Tower, DummyMob HP, 수명, RockDeathRemnant, CommonEffectReceiver를 연결했다.
- 원본 사망/크기 테스트 6개, 작은 잔해 prefab 5개, 중간 잔해 prefab 1개를 이관했다. 추가 검증은 실제 tower 마법의 지면 생성, 피해 사망→실제 잔해, 수명 만료→잔해 없음, 정적 잔해와 동적 객체의 충돌을 확인했다. 충돌 기대값은 기존 impulse 상한 1에 따른 속도 감소이며 완전 정지/침투 보정을 새로 추가하지 않았다.
- .NET과 Unity Editor에서 원본 326/915개와 추가 검증, 기존 10,000 tick 해시가 통과했다. Unity 종료 코드 0 및 root/client diff 검사 통과를 확인했다. 남은 일반 테스트 589개와 doctest 2개, 전체 전투 콘텐츠·PVE·봇·네트워크 매치 연결 및 종료 검증은 계속 진행 대상이다.

### MiniRock·RockGolem prefab과 넉백 공격

- MiniRock의 RigidBody/ZPhysics/solid circle/Slime/Rock/CommonEffectReceiver를 연결했다. 수명이나 사망 잔해는 없다. RockGolem은 같은 몸체 구성과 RockGolemMob, Small RockDeathRemnant를 사용한다. 현재 원본의 Small 지정 그대로이며 Medium으로 추정 변경하지 않았다.
- RockGolemMob은 현재 원소의 근접 피해 후 지상 방향으로 0.25 넉백을 적용한다. 원본 AttackInfo가 공격자 ID를 설정하지 않는 점과 영벡터 정규화도 유지했다.
- 원본 MiniRock prefab 테스트 3개와 골렘 공격 테스트 1개를 옮겼다. 추가 검증에서 실제 MiniRock 피해 사망은 잔해를 만들지 않고 실제 RockGolem 피해 사망은 소유 진영의 작은 RockRemnant 하나를 생성함을 확인했다.
- .NET과 Unity Editor에서 원본 330/915개와 추가 검증, 기존 10,000 tick 해시가 통과했다. Unity 종료 코드 0 및 root/client diff 검사 통과를 확인했다. 남은 일반 테스트 585개와 doctest 2개, 나머지 마법·유닛·PVE·봇·lobby/GameScene·실제 매치 종료 검증을 계속 진행한다.

### TitanRemnant·TitanFist 연결

- TitanRemnantMob은 TimedBehaviorMob 주기로 지상/공중 적을 탐색하고 범위 안의 가장 가까운 대상의 지면 위치에 소유 진영 TitanFist를 생성한다. 건물 prefab은 HP/몸체/수명/Rock/BuildingEffectReceiver와 Medium RockDeathRemnant를 연결했다.
- TitanFist는 trigger circle, Rock, 기존 OnStartAttacker, 표시 수명으로 구성한다. 생성 시 즉시 범위 피해가 발생하며 추가 넉백은 없다. 원본 초기화 대기 component 검증은 Spawn의 Start 완료 후 실제 component 검증으로 대응했다.
- 원본 테스트 3개를 옮겼고 실제 마법 소환부터 지면 주먹 생성, 즉시 적 피해·아군/원거리 제외, 주먹 만료 후 중복 피해 없음, 건물 전투 사망 후 중간 잔해 생성을 추가 검증했다.
- .NET과 Unity Editor에서 원본 333/915개와 추가 검증, 기존 10,000 tick 해시가 통과했다. Unity 종료 코드 0과 root/client diff 검사 통과를 확인했다. 남은 일반 테스트 582개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·실제 네트워크 매치 완료는 계속 진행 대상이다.

### GroundCannon·FireworkTower 연결

- Cannon은 지상 적 한 명을 선택하고 RockShot 표시 이벤트를 보낸 뒤 0.5초 지연 피해를 예약한다. GroundCannon의 고정 60초 수명, CommonEffectReceiver, Small RockDeathRemnant를 연결했다. 실제 cannon 마법의 지면 생성, 대상 없는 주기의 재시도, 공중/아군 제외, 단일 대상 지연 피해와 전투 사망 잔해를 추가 검증했다.
- FireworkLauncher는 진영 방향의 고정 위치로 발사하고 비행 시간이 지난 뒤 FireworkShell을 생성한다. 기존 비행을 먼저 진행해 새 포탄이 같은 tick에 착탄하지 않도록 했으며 발사 주기가 여러 번 지난 경우도 원본처럼 처리한다. FireworkTower의 몸체/HP/수명/BuildingEffectReceiver와 FireworkShell의 Fire 범위 피해/표시 수명을 연결했다.
- 원본 발사기 테스트 6개와 포탄 prefab 테스트 3개를 옮겼다. 실제 마법 소환→발사→착탄 피해, 건물 파괴 후 비행 중 포탄 취소도 추가 검증했다. 원본의 tower.attack_range는 표시용이며 피해 반경은 shell.radius를 사용한다.
- .NET과 Unity Editor에서 원본 342/915개, 추가 검증, 기존 10,000 tick 해시가 통과했다. Unity 종료 코드 0을 확인했다. 남은 일반 테스트 573개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·lobby/GameScene 연결과 실제 네트워크 매치 완료는 계속 진행 대상이다. Graphify graph는 이 worktree에 없다.

### Crater 불씨와 DragonTower 발사 연결

- Crater prefab을 기존 CraterSpawner에 연결하고 CraterEmber의 무작위 착지 위치, 높이 3의 포물선, 지면 착지 후 중립 FireField 생성, 첫 적 Mob 충돌 피해를 이관했다. 원본처럼 이미 해결된 불씨는 다시 피해나 장판을 만들지 않는다. 각도는 nextDouble의 두 난수 전이, 거리는 nextFloat의 한 전이를 사용하며 24비트 분수를 고정 소수점으로 변환한다. 최대 거리가 1 이하인 잘못된 설정의 예외도 원본과 맞췄다.
- DragonTower의 FlameLauncher와 DragonFlame prefab을 연결했다. 대상 탐색 없이 진영 전방으로 발사하고 IIntervalAttacker의 공격 속도 변경, DistanceSelfDestroyer의 사거리 소멸, Burn 효과와 Shot 피해를 사용한다.
- DragonFlame 원본 테스트로 Shot의 축 방향 정규화에서 역수 양자화 오차를 확인했다. 길이의 역수를 곱하는 대신 각 성분을 길이로 직접 나눠 축 방향 속도와 거리 경계를 정확하게 유지했다. 기존 투사체 테스트도 통과했다.
- Crater 원본 테스트 4개와 FlameLauncher/DragonFlame 원본 테스트 9개를 추가했다. 실제 마법 생성부터 불씨 착지 장판, 아군/비전투 제외와 첫 Mob 단일 피해, DragonTower 지면 생성과 실제 비행 거리 소멸을 추가 검증했다.
- .NET과 Unity Editor에서 원본 355/915개와 추가 검증을 통과했다. Unity 종료 코드 0, 기존 10,000 tick 해시 일치와 root/client diff 검사를 확인했다. 남은 일반 테스트 560개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·lobby/GameScene 연결·실제 네트워크 대전 종료 검증은 계속 진행 대상이다.

### ElectricTower 연쇄 공격 연결

- LightningTowerMob과 ElectricTower prefab을 연결했다. 첫 대상은 지상/공중의 가장 가까운 적이며, 이후에는 직전 대상 주변에서 아직 타격하지 않은 가장 가까운 적을 chain_count만큼 찾는다. 동거리일 때 조회 순서의 첫 대상을 유지한다.
- ElectricShot의 source는 직전 연쇄 대상이지만 모든 Hit의 attacker ID는 건물 ID다. 첫 피해/연쇄 피해를 구분하고 각 대상의 모든 IDamageable에 0.2초 지연 피해를 예약한다. 이미 타격한 객체, 아군, 범위 밖 객체를 제외한다.
- 추가 Core 검증은 실제 electric_tower 마법 생성, 대상 없는 주기 후 재시도, 두 단계 연쇄와 동거리 순서, 중복/아군 제외, 다중 피해 수신기, 공중 대상과 실제 지연 피해, 전투 사망 후 기존 ElectricField 생성 및 만료를 확인한다. ElectricField는 이미 이관된 구현을 재사용했다.
- .NET과 Unity Editor에서 원본 355/915개 및 추가 검증이 통과했다. 이 두 원본 파일에는 독립 테스트 함수가 없어 원본 이관 수는 그대로다. Unity 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 남은 일반 테스트 560개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·lobby/GameScene 연결 및 실제 대전 종료 검증은 계속 진행 대상이다.

### 불·바위·바람 둥지와 슬라임 연결

- FireSummon/RockSummon/WindSummon 및 각 FireSlime/RockSlime/WindSlime prefab을 연결했다. 둥지는 trigger circle, 원소, Spawner만 갖고 Spawner 기본 2초 주기를 사용한다. 각 슬라임은 RigidBody/ZPhysics/solid circle/Slime/CommonEffectReceiver를 연결하며, FireSlime에만 1 거리마다 FireField를 남기는 PathSpawner가 있다.
- 실제 둥지 마법→2초 후 소유 진영 슬라임 생성→근접 피해, 불 슬라임 이동 경로의 중립 장판, 둥지 HP 소진 시 파괴와 추가 장판 없음까지 검증했다. 설정 attack_interval을 임의로 둥지 소환 주기에 적용하지 않았다.
- .NET과 Unity Editor에서 기존 원본 355/915개와 추가 Core 검증이 통과했다. Unity 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 전기 둥지/슬라임은 ElectricDeathEnergy 이관 후 연결할 대상이다. 남은 일반 테스트 560개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·lobby/GameScene 연결·실제 대전 종료 검증은 계속 진행 대상이다.

### ElectricDeathEnergy와 전기 둥지 연결

- ElectricDeathEnergy는 전투 사망 때 한 번만 실행된다. 반경 내 활성 아군 중 본래 Lightning 원소, Mob/IDamageable/ElectricDeathEnergy를 모두 가진 가장 가까운 대상에 electric_field.duration만큼 과충전을 적용한다. 이미 대기 중인 과충전도 연장한다. 장판 생성은 기존 DeathField가 담당한다.
- ElectricAbsorb를 사망 위치→흡수 대상 ID로 표현할 수 있도록 BattleEvent 생성자를 추가했다. ElectricSummon과 ElectricSlime prefab을 연결하고 전기 슬라임에 LightningSummonEffectReceiver와 ElectricDeathEnergy를 구성했다.
- 원본 테스트 4개를 이관했다. 실제 전기 둥지 마법→슬라임 두 마리 생성→한 마리 전투 사망→전기 장판과 다른 슬라임의 과충전→속도 배율 적용을 추가 검증했다.
- .NET과 Unity Editor에서 원본 359/915개와 추가 Core 검증이 통과했다. Unity 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 남은 일반 테스트 556개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·lobby/GameScene 연결·실제 대전 종료 검증은 계속 진행 대상이다.

### Towerback 공중 우선 추격과 공격 연결

- TowerbackMob과 prefab을 연결했다. 공중 사거리의 1.5배인 수평 가장자리 거리 안의 공중 적을 지상 적보다 우선하고, 지상 공격 상태에서도 탐지 주기를 지나면 공중 대상으로 전환한다. 추격 범위를 벗어나면 Idle로 돌아간다.
- 지상 공격은 sub_damage의 즉시 단일 피해, 공중 공격은 damage의 반경 1 지연 범위 피해와 RockShot이다. prefab은 sub_speed/sub_attack_range와 공중 attack_range를 구분하고 RigidBody/ZPhysics/CommonEffectReceiver를 갖는다.
- 원본 상태 전이 테스트 6개를 이관했다. 원본 AERIAL_MOB_INIT_HEIGHT=3을 사용해 검사했다. 실제 마법 소환, 지상 피해, 공중 주변 범위 피해, 원거리 제외와 prefab 구성도 추가 검증했다.
- .NET과 Unity Editor에서 원본 365/915개와 추가 검증이 통과했다. 최종 Unity 로그 unity-parity-365-height.log의 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 남은 일반 테스트 550개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·lobby/GameScene 연결·실제 대전 종료 검증은 계속 진행 대상이다.

### 유닛 소환 마법 30종 등록

- SpawnMagics에 원본 30개 bean을 등록했다. AbstractSpawnMagic 기반 28종은 quantity 기본 1, 단일 소환의 난수 미소비, 다중 소환의 X/Z 각 nextFloat 전이, 지상 높이 0/공중 높이 3을 적용한다. BoundMagic에 IsSpawnMagic과 SummonedQuantity를 연결했다.
- EarthCall은 표시 객체를 만들고 범위 내 활성 작은/중간 잔해를 시전자 소유 MiniRock/RockGolem으로 변환한다. TornadoStrike는 지정 위치에 생성하는 폭발 마법이며 둘 모두 ObjectSummoning/IsSpawnMagic으로 표시하지 않는다.
- 원본 테스트 5개를 이관했다. 실제 MiniRock prefab의 무리 소환, 소유 진영, 원본 난수 소비 순서와 위치, 수량 0의 무생성/난수 미소비를 추가 검증했다. 미이관 유닛 prefab과 EarthCall/TornadoStrike 표시 prefab, 보스의 실제 cast 연결은 별도 남은 작업이다. spawn_boss_magic.rs의 is_spawn/등록 테스트만 이관했으므로 파일 전체 이관으로 매핑하지 않았다.
- .NET과 Unity Editor에서 원본 370/915개와 추가 검증이 통과했다. Unity 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 남은 일반 테스트 545개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·lobby/GameScene 연결·실제 대전 종료 검증은 계속 진행 대상이다.

### EarthCall 실제 변환과 TornadoStrike 연결

- EarthCall prefab의 Rock 원소와 고정 1초 표시 수명을 연결했다. 실제 작은/중간 잔해 prefab을 시전자 소유의 실제 MiniRock/RockGolem으로 변환하고 범위 밖 잔해를 유지하는 흐름을 검증했다.
- Tornado는 기본 경기장 중앙 방향 이동, 피해 대상 중복 포획 방지, 진입 당시 3차원 거리의 궤도 반경(최소 0.1), 시계 방향 회전과 초당 8의 상승(높이 5까지), 기본 피해+포획 수*2의 Wind 피해를 적용한다. 이미 높이 5보다 높은 대상은 원본처럼 내리지 않는다. 원본에 없는 피해 대상 정리나 추가 Shot 인터페이스는 넣지 않았다.
- TornadoStrike의 trigger collider/Nature+Wind/Tornado/수명을 연결했다. 원본 테스트 2개와 실제 마법 prefab, 다중 피해 증가, 높이 경계 및 만료 검증을 추가했다.
- .NET과 Unity Editor에서 원본 372/915개와 추가 검증이 통과했다. Unity 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 남은 일반 테스트 543개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·lobby/GameScene 연결·실제 대전 종료 검증은 계속 진행 대상이다.

### CraterCarrier 설치·철수와 독립 포탄 연결

- CraterCarrier는 CraterEmber가 아니라 별도 CraterShell을 사용한다. 설치가 끝나면 즉시 첫 발을 쏘고 일반 공격 주기로 이어가며, 목표 상실/범위 이탈/소유 변경 시 철수 시간을 거친다. 기절 중 일반 이동 지시와 철수 중 반복 이동 지시가 단계를 건너뛰거나 타이머를 재시작하지 않도록 원본 state wrapper를 이관했다.
- CraterShell은 발사 시 목표 지면 위치와 공격자/피해/원소를 복사하고 독립적으로 포물선 비행한다. 착탄 시 활성 지상 적의 모든 피해 수신기에 한 번 피해를 주고, 0.6초 표시 전용 CraterExplosion을 생성한다. 발사자 사망 후에도 착탄한다.
- 원본 Carrier 테스트 6개와 Shell 테스트 2개를 이관했다. 고정 소수점 누적 경계 차이: Q32.32 0.1*12가 1.2 미만이므로 설치 테스트는 13번째 tick에 발사하고 14번째에 Deployed 복원을 확인한다(원본 float 검증은 13번째). 이 차이를 숨기지 않고 테스트에 기록했으며 전체 시간 경계의 원본 일치 검증은 완료되지 않았다.
- 실제 crater_carrier 마법→설치→포탄 생성→발사자 파괴→적 피해→표시 객체 소멸을 추가 검증했다. .NET과 Unity Editor에서 원본 380/915개와 추가 검증이 통과했다. Unity 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 남은 일반 테스트 535개와 doctest 2개, 나머지 전투 콘텐츠·PVE·봇·lobby/GameScene 연결·실제 대전 종료 검증은 계속 진행 대상이다.

### CraterCarrier 단계 시간 경계 보정

- 앞 절의 설치 1 tick 지연을 수정했다. 설치/철수 PhaseTimer는 양수 delta를 Q32.32로 변환할 때 잘리는 raw 1 미만의 누적 상한을 추적하고, 남은 간격이 그 상한보다 작을 때만 경계 도달로 처리한다. 임의의 ms epsilon을 적용하지 않는다. 0초 update는 보정 상한을 늘리지 않는다.
- 원본 설치 테스트의 대기 시간을 14 tick으로 늘렸던 변경을 제거하고 원본의 13 tick 검증을 복원했다. 10Hz/20Hz 설치 직전·정확한 경계, 철수 9 tick, 오차 상한 밖의 미도달, 0초 반복의 무진행을 추가 검증했다. 다른 전투 타이머 전체에 동일 보정을 적용하거나 원본 float 경계가 모두 일치한다고 주장하지 않는다.
- .NET과 Unity Editor에서 원본 380/915개와 추가 검증이 통과했다. 최종 Unity 로그 unity-parity-380-boundary.log의 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 남은 일반 테스트 535개와 doctest 2개 및 전체 전투·PVE·봇·실제 네트워크 대전 연결은 계속 진행 대상이다.

### AquaArcher·RockMage와 BeanShooter 이관

- AquaArcher/WaterShot과 RockMage/RockShot의 실제 소환, 즉시 피해, 공중 대상 탐지를 연결했다. MultiEnemyDetector는 원본대로 Destroyed만 제외하고 3차원 거리의 안정 정렬로 대상을 고른다. RockMage는 두 번째 적이 없으면 첫 적을 두 번 공격한다. 동거리 선택, 아군/범위 밖 제외와 Initializing 대상 포함을 검증했다. Unity 로그 unity-parity-ranged-units.log에서 원본 380개와 추가 검증이 통과했다.
- BeanShooter와 Bean prefab을 연결했다. Bean은 지상 방향으로 비행하며 활성 지상 적의 모든 피해 수신기에 한 번 피해를 주고 소멸한다. 아군/공중 대상/비활성 대상은 통과하고, 빗나가면 공격 사거리의 1.5배에서 소멸한다. 발사자 파괴 후에도 비행하며 공격자는 Bean 자신이다.
- Bean 원본 테스트 4개와 BeanShooter 원본 테스트 2개를 이관했다. 실제 마법 소환, 오른쪽 진영 발사 방향, 즉시 피해 없음, 발사자 사망 후 명중, 복수 수신기, 중복 명중 방지, 비행 거리 경계를 추가 검증했다.
- .NET과 Unity Editor에서 원본 386/915개와 추가 검증이 통과했다. Unity 로그 unity-parity-bean.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 293/668개이며 모두 core-only 상태다. 남은 일반 테스트 529개와 doctest 2개, 나머지 전투·PVE·봇·lobby/GameScene 연결·실제 대전 종료 검증은 계속 진행 대상이다.

### FireSpirit 분사와 주변 Burn 이관

- SprayingAttacker는 공격 방향의 두 구에서 첫 Mob을 모아 중복을 제거하고, 모든 대상에 피해를 준 뒤 첫 EffectReceiver에 출처를 포함한 효과를 전달한다. 원본대로 진영/활성 상태 필터를 추가하지 않아 아군과 자신도 범위에 포함된다. 피해 대상이 없어도 위치 기반 분사 표시를 먼저 생성하며 실행 시점 AttackRange를 읽는다.
- AreaEffectProvider의 주기/잔여 시간 이월과 반경 내 첫 효과 수신기 전달을 이관했다. FireSpirit의 RigidBody/ZPhysics/solid collider, Ground 탐지, Fire+Wind, CommonEffectReceiver, 1초 주기 주변 Burn을 실제 소환 마법과 연결했다.
- 해당 원본 파일에는 독립 테스트가 없어 원본 테스트 수를 늘리지 않았다. 실제 소환, 겹친 범위의 단일 피해, 첫 Mob/수신기 선택, 피해→효과 순서, 아군/자신 포함, 범위 밖 제외, 효과 출처, 주기 잔여 시간, 동적 사거리와 빈 분사의 표시를 추가 검증했다.
- .NET 및 Unity Editor에서 원본 386/915개와 추가 검증이 통과했다. unity-parity-fire-spirit.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 296/668개이며 모두 core-only다. 남은 원본 테스트 529개와 doctest 2개, 나머지 전투·PVE·봇·네트워크 실제 대전 연결은 계속 진행 대상이다.

### BubbleSpirit·ThunderSpirit 비행 소환 연결

- BubbleSpiritMob는 공중 대상을 탐지하고 거리/투사체 속도로 BubbleShot 표시 시간을 계산한다. 발사 순간 목표 반경 1 안의 공격 가능한 공중 객체를 확정해 첫 피해 수신기에 지연 피해를 예약한다. 대상이 뒤에 이동해도 이미 예약한 피해를 취소하지 않는다.
- BubbleSpirit의 Water+Wind, ThunderSpirit의 Lightning+Wind 및 ElectricDeathEnergy, 각 원본의 즉시/대기 컴포넌트 추가 순서와 높이 3 호버를 연결했다. ThunderSpirit은 지상 대상을 탐지하며 ElectricShot 표시는 0.5초지만 피해는 원본대로 즉시 적용한다.
- 두 실제 소환 마법, 초기 높이와 호버 복귀, 대상 mask, 공중 높이 경계, 아군/먼 대상 제외, 첫 피해 수신기만 적용, BubbleSpirit 지연 및 이동 후 피해, ThunderSpirit 즉시 피해를 검증했다. 해당 원본 파일에는 독립 테스트가 없어 원본 테스트 수는 그대로다.
- .NET과 Unity Editor에서 원본 386/915개와 추가 검증이 통과했다. unity-parity-flying-spirits.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 299/668개이며 모두 core-only다. 원본 테스트 529개와 doctest 2개 및 전체 전투·PVE·봇·실제 네트워크 대전 연결은 계속 진행 대상이다.

### WindSpirit 자폭과 호버 해제 이관

- SelfDestructMob의 0초 공격 간격, 자기 반경+0.3의 공격 진입 범위, 별도 폭발 반경, 첫 원형 충돌체 요구와 선택적 고도 임계값을 이관했다. 공격 상태에서 호버를 잠그고 고도 진행률로 수평 위치만 보간한다. 원본 Vector3.lerp처럼 진행률을 0~1로 제한하며 동일 높이는 진행률 1로 처리한다. 상태 종료/대상 파괴/객체 파괴 시 호버 잠금을 해제한다.
- 폭발은 활성 적의 첫 Mob에 한 번만 피해를 준다. 충돌·거리 임계값·고도 임계값·사망이 같은 폭발을 사용하고, 공중 사망은 추락을 기다리지 않는다. 실제 wind_spirit 마법의 높이 3, 공중 탐지, Wind 원소와 CommonEffectReceiver를 연결했다.
- 원본 테스트 3개와 실제 소환·공격 취소·높이가 다른 대상 접근·보간 범위 제한·호버 복구·중복 폭발 방지·공중 사망 즉시 폭발 검증을 추가했다.
- .NET과 Unity Editor에서 원본 389/915개와 추가 검증이 통과했다. unity-parity-self-destruct.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 301/668개이며 모두 core-only다. 원본 테스트 526개와 doctest 2개, 남은 전투·PVE·봇 및 실제 네트워크 대전 연결은 계속 진행 대상이다.

### BombSprite 투하·착지 폭발 이관

- BombSpriteMob는 지상 대상을 수평 거리로 탐지하고 활성 목표에 부모 소유/위치의 BombSpriteBomb을 투하한다. 폭탄은 목표의 지면 위치를 저장하고 3차원 거리/속도(최소 0.1초)로 직선 낙하한다. 피해와 원소·공격자 ID는 폭탄 자체에서 읽으며 착지 시점 활성 적의 모든 피해 수신기를 처리한다. 원본처럼 폭발에는 공중/지상 mask 필터가 없다.
- BombSprite의 높이 3 호버와 Wind/CommonEffectReceiver, 충돌체 없는 폭탄, 피해 없는 0.6초 BombSpriteExplosion을 실제 소환 경로에 연결했다. 폭발 표시를 먼저 생성하고 피해 처리 후 폭탄을 파괴한다.
- 원본 폭탄 테스트 1개와 실제 소환→투하→투하자 파괴→착지 흐름, 공중 적 피해, 아군/비활성/범위 밖 제외, 여러 수신기 및 폭탄 공격자 ID, 중복 폭발 방지, 표시 소멸, 미조준/최소 시간 처리를 검증했다. 낙하 중간 위치는 Q32.32 1/3 나눗셈 때문에 raw 1 차이를 관찰해 raw 2 이내로 비교하며, 착지 위치와 피해는 정확히 비교한다.
- .NET과 Unity Editor에서 원본 390/915개와 추가 검증이 통과했다. unity-parity-bomb-sprite.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 306/668개이며 모두 core-only다. 원본 테스트 525개와 doctest 2개 및 나머지 전투·PVE·봇·실제 네트워크 대전 연결은 계속 진행 대상이다.

### ThunderBird 급강하와 상승 상태 이관

- ThunderBirdMob는 지상 목표를 수평 거리로 탐지하고, 높이 3 미만에서는 FloatingState로 상승을 기다린다. 공격 상태는 호버를 잠그고 원본처럼 충돌 거리 검사 후 보간 이동하며, 접촉 시 기본 피해*(출발 높이-현재 높이)/2.5를 정수로 잘라 첫 Mob에 적용한 뒤 상승 상태로 돌아간다.
- 목표 파괴 시 이동/피해 없이 상승 상태로 전환하며, 상태 종료 때 호버를 복구한다. 실제 thunder_bird_swarm의 수량별 소환, 높이 3, Lightning 단일 원소, ElectricDeathEnergy와 LightningSummonEffectReceiver를 연결했다.
- 원본 목표 파괴 테스트 1개와 실제 2개체 소환, 중간 급강하 위치, 피해량 10/8, 첫 Mob만 피해, 공격 후 생존과 호버 복귀, 저고도 공격 대기, 높이 3 도달 후 Idle 복귀, 비-Mob 거부를 추가 검증했다.
- .NET과 Unity Editor에서 원본 391/915개와 추가 검증이 통과했다. unity-parity-thunder-bird.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 308/668개이며 모두 core-only다. 원본 테스트 524개와 doctest 2개, CloudDragon/ChainLightning을 포함한 나머지 전투·PVE·봇·실제 네트워크 대전 연결은 계속 진행 대상이다.

### CloudDragon 보조 공격과 ChainLightning prefab 연결

- CloudDragonMob의 일반 WaterShot과 별도 ChainLightning 쿨다운을 이관했다. 부모 update 후 타이머를 cooldown+delta까지 누적하고 유효한 현재 목표가 있을 때 발사하며, 사거리 검사를 추가하지 않는다. 목표가 없는 동안에도 준비 상태를 유지한다.
- 원본 14.9초+0.1초 쿨다운 검증을 지연시키지 않도록 각 양수 delta 변환의 raw 1 미만 오차 누적 상한 안에서만 경계를 보정한다. 발사 후 상한은 초기화하며 0초 update는 늘리지 않는다. 오차 상한 밖의 미도달과 0초 반복을 별도 검증했다.
- ChainLightning은 기존 ChainShot에 trigger collider/Lightning/Shock EffectProvider를 연결했다. 속도는 원본의 int 파라미터 읽기를 보존한다. CloudDragon은 높이 3 호버, Water+Wind+Lightning, CommonEffectReceiver와 1초 주기 Wet 범위를 연결했다.
- 원본 쿨다운 테스트 1개와 실제 소환·목표 없는 대기 후 발사·투사체 이동·18→9 연쇄 피해·연쇄 대기 중 충돌 무시·일반 WaterShot 피해를 검증했다. 독립 chain_lightning 마법의 AbstractShotMagic 경로는 아직 미이관 상태이며 이 항목은 CloudDragon 발사를 검증한다.
- .NET과 Unity Editor에서 원본 392/915개와 추가 검증이 통과했다. unity-parity-cloud-dragon.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 311/668개이며 모두 core-only다. 원본 테스트 523개와 doctest 2개 및 나머지 전투·PVE·봇·실제 네트워크 대전 연결은 계속 진행 대상이다.

### 투사체 마법 공통 발사와 기본 prefab 연결

- AbstractShotMagic의 원점 없음→무발사, 원점 있음→소유/위치로 prefab 생성 후 ShotTarget 조준을 이관했다. BoundMagic의 원점을 생략한 overload는 해당 진영의 활성 Player 위치를 찾는다. 명시적 null 원점과 생략 호출을 구분한다. 기본 발사 마법 8종을 등록했다.
- FireShot/WaterShot/ElectricShot의 원소, trigger, Burn/Wet/Shock, Shot을 연결했다. ElectricShot의 AllyOverchargeProvider와 원본 테스트 4개도 이관했다. 일반 충돌에서 우호적인 LightningSummonEffectReceiver만 과충전하며 적 충돌 전용 callback은 아무것도 하지 않는다.
- 원본 공통 발사 테스트 2개와 기본 3종의 직접 발사·이동·충돌 피해, 비활성 Player 제외, 오른쪽 진영 방향, 별도 공중 원점, 명시적 null, 중립 소유 override, Shot 누락 예외, 독립 ChainLightning 직접 발사를 검증했다. BoulderStrike/RockRolling/TideCall/WindBlade는 bean 등록까지이며 실제 prefab 연결은 아직 남아 있다.
- 직접 ChainLightning 발사에서 역수 선양자화로 축 방향 이동이 짧아지는 것을 확인해 ChainShot.SetTarget도 성분별 나눗셈으로 수정했다. 기존 ChainShot 원본 테스트와 10,000 tick 해시는 유지된다.
- .NET과 Unity Editor에서 원본 398/915개와 추가 검증이 통과했다. unity-parity-shot-magics.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 324/668개이며 모두 core-only다. 원본 테스트 517개와 doctest 2개 및 나머지 전투·PVE·봇·실제 네트워크 대전 연결은 계속 진행 대상이다.

### 특수 투사체 4종과 물 장판 연결

- BoulderStrike/RockRolling/TideCall/WindBlade의 실제 prefab을 연결했다. BoulderStrike는 Rock+Wind, 지연 추가 Shot과 고정 0.65초 밀치기를 사용한다. TideCall은 Wet/PushShot/0.5 이동 거리 PathSpawner/수명을 연결하고 중립 WaterField를 남긴다. WaterField는 Shock 수신 시 중립 ElectricField를 생성하고 파괴된다.
- RollingRock은 수평 조준·지면 이동, 반경을 고려한 경기장 경계 반사, 모서리 동시 반사 1회 소비, 적 접촉 반사와 0.05 분리 이동을 이관했다. 벽/적 충돌이 같은 반사 횟수 2회를 공유하고 세 번째는 파괴된다. 적 충돌은 피해를 먼저 주므로 세 번째 적도 피해를 받는다. 같은 적의 연속 접촉은 잠그고 분리/대상 파괴/제거 후 update에서 풀린다.
- 원본 RollingRock 테스트 4개와 4종 실제 발사, WindBlade 피해 9→6과 중복 관통 방지, BoulderStrike 밀치기 생성, RollingRock 접촉 잠금/분리 후 재타격, TideCall 장판 생성·전환·단일 피해·만료를 검증했다.
- .NET과 Unity Editor에서 원본 402/915개와 추가 검증이 통과했다. unity-parity-special-shot-prefabs.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 331/668개이며 모두 core-only다. 원본 테스트 513개와 doctest 2개 및 나머지 전투·PVE·봇·실제 네트워크 대전 연결은 계속 진행 대상이다.

### VineToss·VineFan·WillOWisp 마법 연결

- VineToss는 원점/목표로 정규화한 방향을 기존 VineLine에 전달하며 원점 없음/영벡터는 생성을 생략한다. VineFan은 고정 소수점 삼각함수로 -30/0/+30도 회전 후 각 VineToss를 호출한다. IVineFan과 BoundMagic의 위임 및 IsVineFan 메타데이터를 추가했다. VineWitch 전체 구현/보스 파서 연결이 완료됐다는 뜻은 아니다.
- WillOWisp 마법과 trigger/None 원소/MindControlShot prefab을 연결했다. 일반 발사처럼 명시적 null 원점은 무발사하며 MindControlShot을 직접 요구한다.
- 원본 VineFan 테스트 3개와 실제 Vine prefab의 순차 생성 및 같은 줄의 단일 피해, tracker 복구, 바인딩된 IVineFan 호출, null 원점, 실제 WillOWisp 이동/명중/진영 변경/피해 없음 검증을 추가했다. spawn 후 추가되는 SequentialLineSpawner는 다음 component flush에서 활성화되는 기존 생명주기를 테스트에 반영했다.
- .NET과 Unity Editor에서 원본 405/915개와 추가 검증이 통과했다. unity-parity-vine-magics.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 335/668개이며 모두 core-only다. 원본 테스트 510개와 doctest 2개 및 나머지 전투·PVE·봇·실제 네트워크 대전 연결은 계속 진행 대상이다.

### SpiritBomb 흡수·빔과 ray 질의 이관

- RayQueries는 첫 원형 충돌체를 3차원 구로 취급하고 표면까지의 ray 진입 거리로 안정 정렬한다. 원본처럼 trigger/객체 상태 필터를 추가하지 않고, 시작점이 구 내부인 경우와 음수/사거리 초과 거리를 제외한다. 원본 ray 테스트 4개와 접선·동거리 순서·첫 collider 제한·정확한 사거리 경계를 검증했다. SimplePhysics 전체 이관 완료가 아닌 raycast_all 부분 매핑이다.
- SpiritBombMagic은 활성 Player를 별도로 찾고 전달된 원점을 무시한다. 활성 아군의 첫 Mob에서 최대 체력 절반 초과분만 흡수하고 Player는 제외한다. 흡수당 ElectricAbsorb를 표시하고 합계의 7/10을 Java 반올림해 채널을 추가한다. 7/10은 곱셈 후 나눗셈으로 계산해 흡수 5의 3.5 반올림이 Q32.32 상수 양자화로 3이 되지 않도록 했다.
- 채널은 높이 포함 조준 방향을 유지하고 매 tick 현재 플레이어 위치에서 사거리 끝까지 raycast한다. 4회 피해에 정수 나머지를 앞 tick부터 배분하고, 첫 적 처치 시 속성 배율을 반영한 초과 체력 비율만큼 다음 적에게 넘긴다. Mob 없음/피해 없음/생존은 해당 tick을 종료한다. 피해와 별개인 빔 폭·표면 종점·reference→position 표시 이벤트를 연결했다.
- 원본 채널/마법 테스트 11개와 실제 흡수→채널, 영방향 무흡수, 원점 무시, 큰 delta의 여러 tick 처리, 20Hz의 8/28/48/68 tick 적용을 검증했다. 시간 경계는 양수 delta 변환마다 raw 1 미만의 누적 상한 내에서 보정한다. 원본 float의 모든 누적 오차 패턴이 동일하다는 의미는 아니다.
- .NET과 Unity Editor에서 원본 420/915개와 추가 검증이 통과했다. 최종 unity-parity-spirit-bomb-timing.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사를 확인했다. 소스 매핑은 338/668개이며 모두 core-only다. 원본 테스트 495개와 doctest 2개 및 나머지 전투·PVE·봇·실제 네트워크 대전 연결은 계속 진행 대상이다.

### TidalWarhead 추적·폭발 이관

- 활성 Player 위치에서 발사하고 공중 적을 우선 선택하며 없을 때 지상 적을 선택한다. 클릭 위치와의 3차원 거리 및 동거리 생성 순서를 유지하고 전달된 cast origin은 원본처럼 무시한다.
- 두 발사체는 같은 trigger/Water/추적 component를 사용한다. 활성 대상의 위치를 매 tick 갱신하고 사라진 대상은 마지막 위치까지 추적한다. 도착 또는 damageable과의 enemy 충돌에서 한 번 폭발하며 지상 지정은 반올림한 절반 피해, 공중 지정은 전체 피해를 준다. 폭발 범위에서는 고도 마스크를 추가하지 않는다.
- 원본 5개 테스트와 실제 마법 바인딩→prefab→이동→폭발, 이동 대상 추적, 대상 파괴 후 마지막 위치, 홀수 피해 반올림, 아군 제외, 반복 충돌 무효화를 검증했다. 원본 공중 피해 테스트의 FixedPhysics는 거리 질의를 무조건 반환하므로 C# 테스트는 실제 구 질의 안에 발사체를 배치했다.
- .NET과 Unity Editor에서 원본 425/915개와 추가 검증이 통과했다. unity-parity-tidal-warhead.log 종료 코드 0, 10,000 tick 해시 일치를 확인했다. 소스 매핑 343/668개는 모두 core-only다. 남은 원본 테스트 490개와 doctest 2개, 나머지 전투·PVE·봇 및 실제 네트워크 대전 연결을 계속 진행한다.

### RockBlast·VineWorld 연결

- RockBlast는 범위 안 활성 잔해를 snapshot으로 모아 진영에 관계없이 소비한다. 폭발은 시전자 진영으로 만들며 중형 잔해만 기존 진영의 작은 잔해를 남긴다. 실제 RockRemnant/MediumRockRemnant/RockExplode prefab으로 원본 테스트를 이관했다.
- VineWorld는 별도 hit tracker로 GiantVine을 생성하고 지연 추가한 성장 component가 0.75초 뒤 반경 2.25의 덩굴 10개, 반경 4의 덩굴 16개를 생성한다. 두 고리의 작은 덩굴은 tracker를 공유한다. 큰 덩굴 피격 수의 2배와 작은 덩굴 피격 수를 합쳐 SeedSpirit을 소환한다. 원본의 씨앗 나선은 X/Y 평면이고 덩굴 고리는 X/Z 평면인 차이를 그대로 유지했다.
- 실제 GiantVine/Vine/SeedSpirit으로 즉시 피해, 같은 고리 사이 중복 피해 방지, 별도 tracker 복구, 3개 소환, 각 고리 반경, 성장 component 제거와 재실행 방지를 검증했다. 양수 delta 양자화 누적 상한을 적용해 20Hz에서는 15번째 update에 성장한다. 이는 모든 원본 float 누적 패턴의 동일성을 입증한 것은 아니다.
- .NET 및 Unity Editor에서 원본 427/915개와 추가 검증이 통과했다. unity-parity-remnant-vine.log 종료 코드 0, 10,000 tick 기존 해시 일치, root/client diff 검사를 확인했다. 소스 부분 매핑 347/668개는 모두 core-only다. 원본 테스트 488개와 doctest 2개, 나머지 전투·PVE·봇·네트워크 실제 대전 연결은 미완료다.
- 다음 폭발 마법 연결에서 OvergrowthExplosion과 RazorGale 구현이 남아 있음을 확인했다. WaterExplosion의 원본 EffectProvider는 Wet이 아니라 Burn이며, RazorGale은 자기 자신만 제외하고 아군/파괴 상태 필터를 추가하지 않는 원본 동작을 보존해야 한다.

### 폭발 계열 등록·Overgrowth·RazorGale 연결

- AreaMagics로 폭발 계열 10개 bean을 등록하고 기존 RockBlast/VineWorld도 같은 등록 경로에 연결했다. AbstractExplosion 계열 8개만 IsExplosionMagic을 가지며 바인딩 후에도 유지된다. WindExplosion은 중립 진영, 나머지는 시전자 진영으로 클릭 위치에 생성하고 cast origin은 무시한다.
- Overgrowth는 0.5초 누적 후 다음 update에 적 damageable 전부에 피해를 주고 첫 effect receiver에 Snared를 전달한다. 같은 진영/중립/Destroyed는 제외한다. 아군 SeedSpirit 진화를 먼저 시도하고 진화 수가 0이면 최소 1개의 SeedSpirit을 간격 0.5의 가운데 정렬 행으로 소환한다. 중립 시전은 적 피해를 생략한다.
- RazorGale은 interval 누적과 carry-over 뒤 자신만 제외하고 모든 damageable에 피해를 준다. 원본처럼 아군과 중립 객체를 제외하지 않는다. Overgrowth/RazorGale/MagmaExplosion/WaterExplosion/SandStorm prefab을 연결했다. WaterExplosion은 원본의 Burn 공급자 및 수직 충격을 그대로 쓴다.
- 원본 4개 테스트와 8개 실제 마법 생성/소유자/원점 무시/메타데이터, Overgrowth 속박·진화·최소 소환·중립 무피해·재실행 방지, RazorGale 아군 피해·범위·잔여 시간, SandStorm 속성·만료, WaterExplosion 지연 피해·상승을 검증했다. .NET/Unity Editor 원본 431/915개와 추가 검증 통과, unity-parity-area-magics.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다.
- 소스 부분 매핑은 363/668개이고 모두 core-only다. 원본 테스트 484개와 doctest 2개, 나머지 전투·PVE·봇·실제 네트워크 대전 연결은 미완료다. 이번 테스트의 SeedSpirit/TreeGolem 등록은 진화 및 소환 호출 확인용이며 해당 유닛의 전체 전투 실행을 증명하지 않는다.

### 표준 마법 등록과 PVE 보스 시전 연결

- MagicRegistry.Standard/StandardMagics.RegisterAll로 build/drop/explode/shoot/spawn 88개 bean을 묶었다. 발사 계열 13개의 정확한 등록 이름을 원본 테스트로 검증했다. 이는 모든 대상 prefab 또는 실제 세션 bootstrap이 완료됐다는 뜻은 아니다.
- IBossMagic과 BoundMagic.Cast를 추가해 PveBossMob의 시전을 기존 HandleBotMagicInput에 연결했다. 보스는 입력 마법 순서대로 성공하는 첫 마법을 사용하고 성공한 ID에만 2초 cooldown을 설정한다. 소환은 자기 위치, 나머지는 대상 위치를 쓰며 항상 보스 위치를 origin으로 전달한다. cooldown은 update마다 감소하고 원본의 0.0001초 준비 허용값을 유지한다.
- 보스는 Frenzy 면역 및 PVE 목표 종료 판정을 제공하고 가상 CastMagic을 통해 하위 보스 패턴을 구현할 수 있다. 하위 보스 패턴과 prefab 등록은 아직 연결하지 않았다.
- 원본 20Hz/60Hz의 2초 cooldown 테스트 2개와 shoot 등록 테스트 1개를 추가했다. 표준 registry→DatabaseMagicParser→BoundMagic→MagicInputHandler→FireShot 실제 생성/이동, 마나 소비/부족 후 즉시 재시도, 소환 위치, 동일 ID cooldown 공유, null 대상/마법, 실패한 마법 재시도, 면역/종료 판정을 검증했다. ZapMouse 소환 대상은 호출 검증용 빈 prefab이며 해당 유닛의 전체 전투 실행을 입증하지 않는다.
- .NET/Unity Editor 원본 434/915개와 추가 검증 통과, unity-parity-pve-boss.log 종료 코드 0, 기존 10,000 tick 해시 일치를 확인했다. 소스 부분 매핑은 365/668개이고 모두 core-only다. 원본 테스트 481개와 doctest 2개, 나머지 전투·PVE·봇 및 실제 네트워크 대전 연결은 미완료다.


### VineWitch 분노 패턴 이관

- VineWitchMob은 체력이 양수인 상태로 정수 최대 체력의 절반 이하가 되면 한 번만 분노 패턴을 시작한다. 다음 update에서 첫 fan을 시전하고 0.45초 간격으로 총 4회 실행한다. 남은 횟수가 있는 동안 일반 시전은 성공으로 응답해 일반 마법을 중지하며 fan이 없으면 패턴을 해제하고 기본 시전으로 돌아간다.
- 대상이 없거나 파괴되면 detector로 다시 선택하고 첫 원형 collider 반경을 저장한다. 수평·수직 body 가장자리 사거리 안에서만 타이머가 흐른다. 실제 VineFanMagic의 세 Vine 시작점 생성까지 검증했다. PveVineWitch prefab과 보스 parser service는 아직 미연결이다.
- 원본 mob_simple 테스트 1개와 사거리 밖 긴 대기 후 즉시 1회 시전, 큰 delta의 잔여 연속 시전, 회복 후 재발동 금지, 치명 피해 미발동, 홀수 최대 체력과 지연 피해, fan 부재, 대상 재탐색·고도 경계를 검증했다. 양수 delta 양자화 누적 상한으로 경계를 보정해 20Hz에서는 발동 후 1/9/18/27번째 update에 시전한다. 모든 원본 float 누적 오차 패턴의 동일성을 증명한 것은 아니다.
- Rust impl_mob_traits의 objective_target과 GaugeComponent를 대조해 PveBossMob에 빠져 있던 IsObjectiveTarget=true 및 HP 게이지를 보완했다. 하위 VineWitch에도 상속된다.
- .NET/Unity Editor 원본 435/915개와 추가 검증 통과, unity-parity-vine-witch.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 소스 부분 매핑 366/668개는 모두 core-only다. 원본 테스트 480개와 doctest 2개, 남은 전투·PVE·봇·실제 네트워크 대전 연결은 미완료다.

### PVE 보스 prefab 4종과 마법 parser 연결

- SimplePveBossInitializer 및 PveWaterSlimeNest/PveNatureSlimeNest/PveVineColony/PveVineWitch를 연결했다. Rigidbody/ZPhysics/trigger collider/CommonEffectReceiver/보스/Spawner 순서로 구성한다. 보스가 첫 Mob이며 Spawner는 비파괴·숨김 HP 게이지를 사용한다. 생성 시 JavaRandom.NextBound로 한 종류를 선택하고 이후 같은 소환 구성을 유지한다.
- SimulationContext.BossMagicParser와 DatabaseBossMagicParser를 연결했다. 등록된 bean 이름으로 조회하고 null 마법은 제외하며 vine_fan은 IsVineFan인 경우에만 반환한다. parser가 없는 보스는 빈 마법 목록을 가진다. 일반 보스는 속도 0, 공격 간격 2.5, 사거리 7, Ground 타깃이며 Witch는 공격 간격 8을 사용한다.
- GaugeExtractor를 추가해 음수 max 게이지를 제외하고 같은 category의 기존 항목을 교체한다. Spawner가 보스 HP를 덮지 않는 원본 테스트를 포함했다.
- 원본 prefab/parser 테스트 8개와 5개 seed별 난수 소비·선택 유지, 2개 소환 간격/소유자/배치, Spawner 피해 무시, Witch의 기본 전투 설정을 검증했다. SimulationContext 생성자 인자는 RNG seed가 아닌 최초 객체 ID이므로 난수 검증 fixture는 Random을 명시적으로 지정했다.
- .NET/Unity Editor 원본 443/915개와 추가 검증 통과, unity-parity-simple-boss-prefabs.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 소스 부분 매핑은 372/668개이고 모두 core-only다. 원본 테스트 472개와 doctest 2개, 남은 전투·PVE·봇 및 실제 네트워크 대전 연결은 미완료다. 이번 소환 선택 테스트의 LeafSlime/WaterSlime/VineSpirit은 빈 prefab으로 생성 종류를 확인했으며 전투 실행을 입증하지 않는다.

### DimensionToad와 PVE 올챙이 이관

- PveGateKeeperMob은 속도 0·공격 없음·PVE 목표·HP 게이지를 제공하고 사망 장판을 남기지 않는다. PveDimensionToad는 Fire+Lightning/trigger/CommonEffectReceiver/keeper/무제한 즉시 시작 LimitedSequenceSpawner를 순서대로 연결했다. PveFireTadpole/PveLightningTadpole은 Ground 근접 공격과 20초 수명 등 각 파라미터를 사용하며 번개 올챙이는 ElectricDeathEnergy와 LightningSummonEffectReceiver를 가진다.
- 원본 테스트 5개로 정지 상태, 첫 tick 즉시 소환 후 10초 교대 소환, 체력 override, 사망 목표 종료·장판 없음, 올챙이 수명 만료를 확인했다. 실제 생성된 올챙이의 근접 피해 12/10, 속성·충돌체·진영, Shock 과충전도 검증했다.
- 순차 소환기의 기존 fixed-point 누적은 세 번째 소환을 한 프레임 늦췄다. LimitedSequenceSpawner에 양수 delta의 raw 양자화 누적 상한을 반영하고 소환 후 초기화했다. 원본 소환기 테스트들과 DimensionToad의 20Hz 소환 테스트가 함께 통과한다. 모든 원본 float 오차 패턴의 동일성을 입증한 것은 아니다.
- .NET/Unity Editor 원본 448/915개와 추가 검증 통과, unity-parity-dimension-toad.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 소스 부분 매핑 376/668개는 모두 core-only다. 원본 테스트 467개와 doctest 2개, 남은 전투·PVE·봇·실제 네트워크 대전 연결은 미완료다.

### PVE CorruptedSpirit 2종 연결

- PveCorruptedVineSpirit은 전용 파라미터를 사용하는 Ground 근접 공격 Mob이며 Nature/CommonEffectReceiver/지상 ZPhysics/solid collider를 가진다. PveCorruptedWindSpirit은 전용 파라미터와 Any 타깃, 고도 3 hover, 고도 1 자폭 임계치의 SelfDestructMob을 연결했다. 두 prefab에는 수명 component가 없다.
- 원본 prefab 테스트 2개와 실제 근접 피해, WindSpirit의 지상·공중 대상 허용, dive 진입, 고도 1의 단일 폭발, 지상·공중 피해 및 아군 제외, 반복 충돌 무효화를 검증했다. PVP 파라미터를 등록하지 않은 fixture에서 초기화돼 전용 설정 사용도 확인했다.
- .NET/Unity Editor 원본 450/915개와 추가 검증 통과, unity-parity-corrupted-spirits.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과를 확인했다. 소스 부분 매핑 378/668개는 모두 core-only다. 원본 테스트 465개와 doctest 2개, 남은 전투·PVE·봇·실제 네트워크 대전 연결은 미완료다.

### EvilEnt와 PVE EvilEnt 이관

- EvilEntMob의 일반 주먹, 충전 3회 상한·재충전, 잡기·끌기·불주먹 상태를 fixed-point로 옮겼다. Rigidbody 없는 대상, 고정 질량, 무거운 대상은 잡지 않으며 잡기 중 대상 소멸·Rigidbody 제거 시 불주먹을 취소한다. 불주먹은 별도 피해와 Burn을 적용한다.
- EvilEnt/PveEvilEnt prefab을 각 전용 파라미터로 구성했다. PVE는 정지한 목표 보스이며 사망 장판이 없고, 잡기 시퀀스 밖에서 가까운 대상으로 다시 조준한다.
- 일반 EvilEnt 원본 14개와 prefab 원본 1개, PVE 동작 원본 9개를 이관했다. PVE의 전장 너머 일반 타격, 긴 거리 끌기, 가까운 유닛으로 대상 변경 및 유닛 소멸 후 플레이어 복귀, HP override·종료 판정을 검증했다. PVE card_evil_ent_is_unchanged와 prefab 원본 테스트들은 아직 남아 있다.
- .NET/Unity Editor 원본 474/915개와 core 검증이 통과했다. unity-parity-pve-evil-ent.log 종료 코드 0, 기존 10,000 tick 해시 일치. 소스 부분 매핑 382/668개는 core-only이며 원본 테스트 441개와 doctest 2개, 남은 전투·PVE·봇 및 실제 네트워크 대전 연결은 미완료다.

### SeaSerpent 광선과 EvilEnt 잔여 동작 테스트

- SeaSerpentMob을 이관했다. 지상 XZ 선분과 대상 원형 반경을 사용해 지상·공중 적에게 0.35초 지연 피해를 주며 아군·비활성 객체는 제외한다. 광선 길이는 공격 사거리와 자신의 solid 반경 합이고, 시각 효과는 입 높이 1.6에서 주 대상의 높이까지 이어진다. 겹친 위치의 대상에는 발사하지 않는다.
- SeaSerpent prefab은 전용 파라미터, Any 타깃, Water 속성, CommonEffectReceiver, 지상 물리와 1단위 이동마다 중립 WaterField를 남기는 PathSpawner를 연결했다. 실제 prefab에서 지연 피해·장판·퇴화 선분 거리를 추가 검증했다.
- PVE EvilEnt 원본의 카드 변경 없음 테스트와 prefab 동작 4개를 추가했다. 일반 카드는 PVE objective가 아니며 사망 장판을 남기는 것을 확인했다. registers_under_its_own_names의 서버 bean/DB 이름 메타데이터 계약은 아직 미이관이다.
- .NET/Unity Editor 원본 480/915개와 core 검증 통과, unity-parity-sea-serpent.log 종료 코드 0 및 10,000 tick 해시 일치. 테스트 매핑 도구의 파일 단위 상수 해석에 맞게 두 EvilEnt suite를 별도 파일로 나눈 후 .NET과 매핑을 다시 검증했다. 부분 소스 매핑 384/668개는 core-only이며 원본 435개와 doctest 2개, 나머지 전투/PVE/봇·실제 매칭 연결은 미완료다.

### SummonerMob·MagmaSpirit·MagmaFist 이관

- SummonerMob은 대상이 수평 도달 범위 안이면 대상 위치에, 밖이면 자신의 solid 반경+공격 사거리 끝에 같은 진영의 prefab을 생성한다. 범위 밖에서는 소환자의 Y를 유지하는 원본 규칙도 반영했다. 원본 5개 테스트로 작은/큰 대상의 가장자리와 소환 위치를 확인했다.
- MagmaSpirit의 Ground SummonerMob, Fire+Rock, Medium RockDeathRemnant, CommonEffectReceiver 및 1초 Burn 범위를 연결했다. MagmaFist는 trigger collider/Fire+Rock/Burn/수명/OnStartAttacker를 구성한다. 실제 prefab 소환으로 대상 가장자리에 도달해 피해 20을 주고 수명이 끝나는 경로를 검증했다.
- 직전 SeaSerpent 구현에서 BehaviorMob의 verticalRangeIgnored=true가 빠진 것을 원본 생성자 대조로 발견해 수정했다. 고도 20의 대상에 대해 WithinAttackRange와 AttackState 실제 발사를 검증하는 회귀 검증을 추가했다.
- .NET/Unity Editor 원본 485/915개 및 core 검증 통과. unity-parity-summoner.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 387/668개는 core-only이며 원본 테스트 430개와 doctest 2개, 남은 전투/PVE/봇 및 실제 매칭 연결은 미완료다.

### WaterSlime 원거리 공격과 prefab 이관

- WaterSlimeRangeAttackMob을 기존 ProjectileRangeAttackMob에 연결했다. WaterShot 시각 효과 0.5초, 즉시 피해, 개체별 공격 간격을 유지한다. WaterSlime prefab은 전용 체력/속도/피해/간격을 사용하고 공격 사거리만 원본처럼 aqua_archer.attack_range에서 읽는다. Ground 타깃, 지상 물리, Water, CommonEffectReceiver와 1단위 이동 장판을 구성했다.
- 원본 테스트 4개로 발사 간격, 두 개체의 독립 발사와 동일 피해, 치명타 반복 호출의 사망 장판 1회 생성, 직접 Destroy의 장판 미생성을 검증했다. 실제 prefab의 파라미터 연결·solid collider·물리와 중립 WaterField 생성도 확인했다.
- .NET/Unity Editor 원본 489/915개 및 core 검증 통과. unity-parity-water-slime.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 389/668개는 core-only이며 원본 테스트 426개와 doctest 2개, 남은 전투/PVE/봇 및 실제 매칭 연결은 미완료다.

### PVE BrickGolem 공격·prefab 이관

- PveBrickGolemMob은 BehaviorMob 상태를 잠그고 속도 0에서 내려찍기와 휩쓸기 타이머를 독립 갱신한다. 내려찍기는 지상 대상의 예고 순간 위치를 고정하고 1초 뒤 해당 구역의 적 Mob에 피해를 준다. 휩쓸기는 가장 가까운 지상 적 방향의 120도 범위에 피해와 0.75 강도 Knockback을 적용한다. 원본대로 타깃 선정은 Ground이며 피해 질의 자체에는 별도 Ground 필터를 추가하지 않았다.
- PveBrickGolem prefab에 Rock/trigger/물리/CommonEffectReceiver/보스를 연결했다. PVE objective, HP gauge, 체력 override, 사망 장판 없음과 기본 Spawner 없음 규칙을 유지한다.
- 원본 8개 테스트로 예고 위치 고정·지연·범위·아군 제외, 휩쓸기 방향/넉백/뒤쪽 제외/대상 대기, 상태 잠금, 공중 단독 대상 미선정, 사망 목표 종료를 검증했다. 실제 prefab의 공격 피해 30, 체력 override 및 장판 없는 사망도 검증했다.
- .NET/Unity Editor 원본 497/915개 및 core 검증 통과. unity-parity-brick-golem.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 391/668개는 core-only이며 원본 테스트 418개와 doctest 2개, 남은 전투/PVE/봇 및 실제 매칭 연결은 미완료다.

### WallGolem prefab 이관

- RockUnitPrefabs에 WallGolem을 등록하고 wall_golem 전용 파라미터로 Ground RockGolemMob/solid collider/물리/CommonEffectReceiver를 구성했다. 기존 RockGolem의 Small remnant는 유지하고 WallGolem만 Medium RockDeathRemnant를 사용한다.
- 원본 prefab 테스트 3개와 추가 전투 검증으로 HP 5000·속도 0.1·질량 200·공격 간격 1.5·피해 5, 실제 MediumRockRemnant 생성과 소유자/위치/장애물/수명, 반복 피해 시 중복 잔해 없음까지 확인했다.
- .NET/Unity Editor 원본 500/915개 및 core 검증 통과. unity-parity-wall-golem.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 392/668개는 core-only이며 원본 테스트 415개와 doctest 2개, 남은 전투/PVE/봇 및 실제 매칭 연결은 미완료다.
- 다음 후보 VineColony를 확인했다. 카드 VineColony와 SummonMob은 아직 없으며 PveVineColony와 다르다. 원본 SummonMob은 TimedBehaviorMob 기반 Ground 최근접·CombatRange 필터로 대상 위치에 Vine을 생성하고 Start에서 detector를 준비한다. prefab의 attack_interval/attack_range는 int 변환, 속도 0, duration 수명 규칙을 유지해야 한다.

### 카드 VineColony와 SummonMob 이관

- SummonMob을 TimedBehaviorMob 기반으로 옮겼다. Start에서 Ground 최근접 detector를 준비하며 자신의/대상의 solid 반경을 반영한 사거리 안의 적 위치에 소유 진영 prefab을 생성한다. 대상이 없으면 타이머를 유지한다.
- VineColony는 속도 0·Nature·solid collider·RigidBody·CommonEffectReceiver·duration 수명을 연결했다. 원본처럼 attack_interval/attack_range를 int로 변환해 SummonMob에 전달한다.
- 원본 prefab 테스트 2개와 실제 Vine 소환을 검증했다. 공중/아군/범위 밖 대상만 있을 때 대기하고, 지상 적이 들어오면 즉시 소환해 피해 6을 주며 이후 1초마다 반복한다. 수명 만료와 Building 분류도 확인했다.
- .NET/Unity Editor 원본 502/915개 및 core 검증 통과. unity-parity-vine-colony.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 394/668개는 core-only이며 원본 테스트 413개와 doctest 2개, 남은 전투/PVE/봇 및 실제 매칭 연결은 미완료다.

### DragonTower·FireworkTower 원본 prefab 테스트 이관

- 기존 구현에 원본 테스트 6개를 연결했다. DragonTower의 Fire/solid 반경 0.8/HP 120/FlameLauncher/수명 20/CommonEffectReceiver와 타깃 탐색 Tower 부재를 확인했다. FireworkTower의 반경 1.2/HP 500/수명 60/물리 및 BuildingEffectReceiver 단일 구성을 확인했다.
- FireworkTower attack_interval 4와 attack_offset 3을 실제 launcher에서 실행해 발사 tick에 포탄 객체가 없고 0.5초 뒤 (8,0,5)에 FireworkShell이 생성되는 것을 확인했다. 해당 검증에서는 등록된 실제 FireworkShell 초기화도 실행했다.
- .NET/Unity Editor 원본 508/915개 및 core 검증 통과. unity-parity-build-towers.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑은 394/668개 core-only이며 원본 테스트 407개와 doctest 2개, 나머지 이관 및 실제 매칭 연결은 미완료다.

### ShockTrap·LifeTree prefab 원본 테스트 이관

- ShockTrap 원본 2개로 Lightning/물리/DummyMob/BuildingEffectReceiver/Detector 구성, 수명 component 부재, body radius 2.5를 확인했다. LifeTree 원본 1개로 cast range 6과 effect_radius 1.5를 구분하고 가까운 아군만 HP 10→13으로 회복하는 것을 검증했다.
- .NET/Unity Editor 원본 511/915개 및 core 검증 통과. unity-parity-build-effects.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑은 394/668개 core-only이며 원본 테스트 404개와 doctest 2개, 나머지 이관 및 실제 매칭 연결은 미완료다.

### RepairTotem·WindTotem 테스트와 DummyMob 게이지 보완

- RepairTotem의 원본 HP gauge/반경/수명/RepairAura/BuildingEffectReceiver/Nature 구성 테스트를 이관하면서 DummyMob의 IGaugeComponent 누락을 발견했다. Hp/MaxHp/Hp category를 반환하도록 추가했다.
- WindTotem 원본 수명 테스트도 이관해 100*1.5/4의 정수 절삭 결과 37초와 Wind 속성을 검증했다.
- .NET/Unity Editor 원본 513/915개 및 core 검증 통과. unity-parity-totem-gauge.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 원본 테스트 402개와 doctest 2개, 나머지 전투/PVE/봇 이관 및 실제 매칭 연결은 미완료다.

### StormStag prefab·영구 과충전 연결

- StormStagPrefabs를 추가해 전용 파라미터, 물리/solid collider/MovementSpeedTracker/StormStagMob/CommonEffectReceiver/Lightning/영구 Overcharge를 연결했다. Fixed64에 infinity가 없으므로 OverchargeStatusEffect.IsPermanent로 시간 차감과 재적용 시 Extend를 건너뛰어 만료와 overflow를 막는다. 기존 유한 과충전 경로는 유지한다.
- StormStag 원본 영구 과충전 테스트와 추가 시간 경과·재적용 검증, ElectricField 원본 설정 테스트를 이관했다. ElectricField fixture 값은 parameters.tsv의 radius 0.5/duration 3이며 지상 배치·속성·수명도 확인했다.
- .NET/Unity Editor 원본 515/915개 및 core 검증 통과. unity-parity-lightning-prefabs.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 395/668개 core-only, 원본 테스트 400개와 doctest 2개 및 전체 이관·실제 매칭 연결은 미완료다.

### SeedNest 원본 테스트와 실제 소환 검증

- SeedNest 원본 구성 테스트 1개를 이관하고 실제 SeedSpirit prefab을 3초 간격의 Spawner에서 생성해 종류·진영·체력을 확인했다. Nest의 20초 수명 만료와 LeafSlime/SeedSpirit의 서로 다른 HP 40/20·반경 0.5/0.25 및 Nature/PathSpawner/receiver도 추가 검증했다.
- leaf_slime_and_seed_spirit_read_their_own_parameters 원본은 두 initializer가 모두 LeafSlime prefab_type을 광고하는 메타데이터까지 검사한다. 현재 등록 함수 구조에는 그 메타데이터 계약이 없으므로 해당 원본 테스트는 미이관으로 남겼다. 위 추가 검증을 해당 테스트 전체 통과로 집계하지 않는다.
- .NET/Unity Editor 원본 516/915개 및 core 검증 통과. unity-parity-seed-nest.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 원본 테스트 399개와 doctest 2개, 나머지 이관 및 실제 매칭 연결은 미완료다.

### EmberSpirit 실제 prefab 해석 보존

- 원본 prefab_type.rs에서 EmberSpirit의 bean 이름이 fire_slime_prefab인 것을 확인했다. ember_spirit 전용 initializer는 별도로 등록되지만 실제 EmberSpirit 생성 경로에서 선택되지 않는다. 이 예외를 유지해 ElementalNests에서 EmberSpirit을 fire_slime 파라미터로 초기화하도록 연결했다. 생성된 객체의 Prefab 식별자는 EmberSpirit으로 유지한다.
- fire_slime과 ember_spirit에 서로 다른 값을 넣어 실제 생성된 HP/속도/반경/공격 피해가 fire_slime을 사용하는지, 이동 시 중립 FireField를 남기는지 검증했다. 사용되지 않는 initializer의 메타데이터 테스트는 아직 미이관으로 유지한다.
- .NET/Unity Editor 기존 원본 516/915개 및 추가 core 검증 통과. unity-parity-ember-spirit.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 원본 테스트 399개와 doctest 2개, 나머지 이관 및 실제 매칭 연결은 미완료다.

### Prefab 이름 계약과 PVE BrickGolem prefab 테스트

- PrefabCatalog에 원본 prefab_type.rs의 136개 이름/bean 매핑과 game_object_key.rs의 DB 키 매핑을 옮겼다. 문자열은 ordinal로 해석하고 Names는 복사본을 반환한다. 같은 bean을 가리키는 유일한 중복은 EmberSpirit/FireSlime이다.
- SimulationContext.InitializePrefab은 직접 등록이 없으면 canonical 이름의 등록을 조회한다. EmberSpirit 별도 등록을 제거하고 이 계약을 통해 FireSlime 초기화로 연결했다. 기존 EmberSpirit 전용 core 검증이 여전히 통과한다. 전체 prefab 초기화 등록이 완료됐다는 뜻은 아니다.
- 원본 이름 테스트와 PveEvilEnt 이름 테스트, PveBrickGolem 전용 HP4000·정지·Rock·collidable·기본 Spawner 없음·objective 및 이름 계약 테스트를 추가했다.
- .NET/Unity Editor 원본 519/915개 및 core 검증 통과. unity-parity-prefab-catalog.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 397/668개 core-only이며 원본 테스트 396개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### Rune 전투 컴포넌트와 6종 prefab 이관

- Rune과 Fire/Water/Nature/Rock/Lightning/WindRune 등록을 추가했다. 각 속성과 rune.radius trigger collider를 연결한다. 적 충돌 callback은 rune.attack_range/damage를 읽어 범위 안 첫 MobComponent에 피해를 준 뒤 객체를 파괴한다. 원본처럼 폭발 피해에 진영 필터나 추가 콜백 중복 방지 조건을 임의로 추가하지 않았다.
- 원본 2개로 폭발 피해·비 Mob 대상 제외·파괴, 6종 등록과 속성/반경/trigger/bean 계약을 검증했다. 실제 네트워크 대전의 룬 사용 경로 검증은 아직 남아 있다.
- .NET/Unity Editor 원본 521/915개 및 core 검증 통과. unity-parity-runes.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 405/668개 core-only이며 원본 테스트 394개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### IdleAura·AttackAura 상태 효과 이관

- IdleAuraStatusEffect은 영구 대기 오라를 표시하고 객체 상태를 구독한다. Attack에서 같은 속성의 활성/대기 AttackAura가 없으면 0.3초 효과를 추가한 뒤 만료하며 Hindered에서도 만료한다. 취소·만료·파괴 시 구독을 해제한다. AttackAura는 속성별 시각 효과와 기존 duration 만료를 사용한다.
- 원본 테스트 2개와 6속성별 시간 무제한 대기·중복 공격 오라 방지·0.3초 만료·방해 후 미발생 검증을 추가했다. 카드 선택 visualizer와 실제 입력에서의 효과 생성 연결은 아직 남아 있다.
- .NET/Unity Editor 원본 523/915개 및 core 검증 통과. unity-parity-auras.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 부분 소스 매핑 407/668개 core-only, 원본 테스트 392개와 doctest 2개 및 전체 이관·실제 매칭 연결은 미완료다.

### CardSelectedStatusEffect 이관

- 선택 개수 추적, 마지막 선택 해제 시 만료, Attack/Hindered 상태 구독에 따른 만료, 중복 만료 방지 및 구독 해제를 옮겼다. 시간 갱신으로는 만료되지 않는다.
- 원본 테스트 3개를 이관했다. 실제 선택 입력의 CardSelectVisualizer는 아직 미이관이며 효과 생성 연결도 남아 있다. 다음 단계에서 원본의 active/pending 효과 검색과 같은 frame의 만료 marker 재생성을 보존해야 한다.
- .NET/Unity Editor 원본 526/915개 및 core 검증 통과. unity-parity-card-selected.log 종료 코드 0과 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 408/668개 core-only이며 원본 테스트 389개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### CardSelectVisualizer와 시전 처리 연결

- CardSelectVisualizer를 이관했다. 원본처럼 active/pending 오라와 선택 marker를 함께 조회하며, 같은 frame에서 만료된 marker를 다시 선택하면 새 marker를 만든다. Player 조회는 활성 객체만 허용한다.
- SimulationContext.SelectCard/UnselectCard 진입점을 추가했다. 원본 테스트 7개와 실제 MagicInputHandler/PlayerStatusSetter를 통한 성공·거절 시 선택 효과 해제, 파괴된 Player 거절, visualizer 미설정 시 no-op을 검증했다. 네트워크 입력 및 GameScene 연결은 아직 남아 있다.
- .NET/Unity Editor 원본 533/915개 및 core 검증 통과. unity-parity-card-input.log 종료 코드 0과 기존 10,000 tick 해시 일치. 소스 부분 매핑 409/668개 core-only, 원본 테스트 382개와 doctest 2개 및 전체 이관·실제 매칭 연결은 미완료다.

### GameActionQueue와 SimulationContext 실행 기반 이관

- GameActionQueue/GameActionSender/GameActionSystem을 추가했다. 256개 제한, FIFO, drain 시작 시 개수만 처리, 액션 실패 격리, 여러 producer의 제출을 보존한다. SimulationContext의 SubmitAction/DrainActions/ActionSender와 연결했다. lockstep 입력 수신과 실제 프레임 루프 연결은 아직 남아 있다.
- SimulationContext에 tick rate 검증과 고정 소수점 nominal delta, 타입별 서비스 조회·이벤트 소비, 활성 Player/사용자 조회를 추가했다. 기존 BattleEvent 소비 API도 유지한다. CardSelectVisualizer는 공통 Player 조회를 사용한다. 실제 네트워크 tick rate와 BattleClock 연결은 별도 미완료다.
- 원본 큐/시스템 테스트 6개와 context 테스트 6개를 옮겼다. 8개 producer의 총 160개 제출, drain 중 추가 이월, 실패 후 실행, 큐 재사용, 다른 스레드에서 제출 후 소비, 타입별 이벤트 분리·일회 소비 등을 검증했다.
- .NET/Unity Editor 원본 545/915개 및 core 검증 통과. unity-parity-context.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 부분 소스 매핑 412/668개 core-only이며 남은 원본 테스트 370개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### BattleFrameLoop 실행 순서와 종료 유예 이관

- 원본 WordOnlineLoop.update의 액션 → frame 시작 → fever → bot → PVE hook → 시간 초과/결과 판정 → 상태 초기화 → component → physics → flush → sync snapshot → frame 끝 순서를 BattleFrameLoop에 옮겼다. 실제 GameActionSystem/객체/물리/flush 구현을 기본값으로 사용하며 frame 출력·bot·fever는 연결 지점을 제공한다.
- 첫 종료 frame부터 tick rate만큼 유예한 뒤 종료 callback을 한 번 호출하고 stop 요청을 표시한다. 유예 중 객체 갱신은 계속한다. 시간 초과 HP 판정은 최초 한 번만 하고, PVE HasTimeLimit=false에서는 timeout 함수를 읽지 않는다. frame 1 및 반초마다 snapshot 생성 callback을 호출한다.
- BattleFrameChecks로 20/60Hz 단계 순서, 결과 1회, timeout 1회, 첫 loser 유지, snapshot cadence, 실제 component 갱신 중 발생한 사망의 다음 frame 판정을 검증했다. 실제 결과 DTO/MMR 저장·snapshot 구현 및 봇 초기화는 미연결이므로 WordOnlineLoop 원본 테스트를 통과로 계상하지 않았다.
- .NET/Unity Editor 기존 원본 545/915개 및 추가 core 검증 통과. unity-parity-battle-loop.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 413/668개 core-only이며 원본 테스트 370개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### 봇 참가자 lifecycle와 fever 시스템 이관

- IBotControl/BotLifecycle에 연습전의 음수 ID 봇 생성, 상대 사용자 novice progress 전달, 단절된 사람의 봇 활성화 중복 방지, 재접속한 사람의 봇 해제 및 원래 봇 참가자 유지 규칙을 옮겼다. 진행도는 Fix64로 전달한다. 실제 BotAgent 판단과 네트워크 연결 상태 확정 입력은 미연결이다.
- FeverTimeSystem은 clock 조건이 참인 첫 frame에 양쪽 덱 Fever와 ManaCharger +1 modifier를 적용한다. 이후 clock 재조회·중복 modifier 적용을 하지 않는다. BattleFrameSystems.Fever에 연결 가능한 구현이며 실제 세션 bootstrap의 clock 연결은 남아 있다.
- 원본 lifecycle 테스트 2개와 큐에서의 활성화, 미등록 사용자/no control 무시, 양쪽 덱 0.5초 드로우·0.25초당 마나 2 충전 및 fever 중복 방지를 검증했다.
- .NET/Unity Editor 원본 547/915개 및 core 검증 통과. unity-parity-bot-lifecycle.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 414/668개 core-only이며 원본 테스트 368개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### 봇 관측값·이동 추정·시전 deadline 이관

- BotVisibleObject/BotEye는 프레임의 객체 위치·HP·mob/targetable·손패·마나·상대 HP를 복사하며 live 객체 참조를 보관하지 않는다. 미확인 HP=10, mob HP 최솟값=1, dying/inactive 표적 제외 규칙을 보존한다.
- MotionTracker는 연속 관측의 위치 차이로 속도를 구한다. 간격이 0 이하 또는 2초 초과이거나 속도가 8 초과이면 제외한다. 원본 NaN 관측 시각은 Fix64? null로 나타내며 baseline을 갱신하지 않는다.
- BotTier/CastDeadline의 Hospitality 60,000ms 무시전 상한과 시전 후 갱신을 옮겼다. 다른 tier에는 deadline이 없다. FrameMillisClock은 FrameNumber*1000/TickRate로 시각을 산출한다. 실제 봇 판단/실행기는 아직 미연결이며 난수 판단 로직도 남아 있다.
- 원본 BotEye 6개·MotionTracker 4개·CastDeadline 5개와 실제 mob HP/상태 복사, 20/60Hz deadline 경계 검증을 추가했다.
- .NET/Unity Editor 원본 562/915개 및 core 검증 통과. unity-parity-bot-observation.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 419/668개 core-only이며 원본 테스트 353개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### BotSkill·BotPersona 설정 이관

- 12개 BotCapability의 선언 순서와 tier별 누적 능력·점수 noise amplitude를 옮겼다. With/Without은 원본을 바꾸지 않는 복사본을 반환한다. Hospitality는 능력 없음/noise 0, Intro부터 Elite까지 원본의 값과 능력 목록을 유지한다.
- BotPersona 기본값, 20FPS 기준 reaction interval, thinking time 최솟값, counter aggression [-1,1] 및 음수 보존, brain type DB 문자열 해석, 모델명 trim을 옮겼다. 모델 호출 기능은 추가하지 않았으며 실제 봇 판단기 연결은 남아 있다.
- 원본 skill 테스트 6개와 persona 테스트 2개 및 반응 시간·음수 aggression 경계 검증을 추가했다. 난수로 점수를 계산하는 BotBrain은 아직 미이관이다.
- .NET/Unity Editor 원본 570/915개 및 core 검증 통과. unity-parity-bot-skill.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 422/668개 core-only이며 원본 테스트 345개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### BotMagic·BotSpellStats·UnitCatalogue 이관

- 봇용 immutable 마법 정보와 소환 prefab/quantity/airborne, magic kind 및 explosion 여부를 추가했다. BotSpellStats는 실제 마법 이름으로 비용·거리·반경·피해를 읽고 unknown cost=9999, damage=8, radius=0.5 fallback을 보존한다. 실제 DatabaseMagicParser에서 이 정보로 변환하는 연결은 남아 있다.
- UnitCatalogue는 sqrt(HP*DPS)와 평균 power/cost로 효율과 위협을 계산한다. 소환 수량 최소 1, 누락 interval=1, 효율 [0.5,2], 위협 [0.25,3], Player 위협=0, 정보 없는 유닛 평균 취급을 보존한다. prefab 이름을 snake_case로 바꾸는 원본 tag helper도 구현했다. catalogue 열거 실패 시 그때까지의 합계를 유지하고 예외를 기록한다.
- 원본 UnitCatalogue 5개·BotSpellStats 4개·이름 변환 1개 및 상하한·swarm 수량·미등록 비용 검증을 추가했다.
- .NET/Unity Editor 원본 580/915개 및 core 검증 통과. unity-parity-unit-catalogue.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 425/668개 core-only이며 원본 테스트 335개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### BoardValue와 실제 마법 parser의 봇 정보 연결

- BoardValue에 소환 비용/수량의 정수 나눗셈, 같은 prefab의 최저 비용 선택, 남은 HP 비율과 floor(x+0.5) 반올림, Player·다른 진영·비표적 제외, unknown cost=0 및 unknown HP=전체 가치 규칙을 옮겼다.
- ParsedBotMagicCatalog는 DatabaseMagicParser와 실제 BoundMagic에서 속성·kind·explosion·class name·소환 prefab/quantity/airborne을 복사한다. 비어 있지 않은 결과만 cache하고 명시적 invalidation 후 재생성한다. 서버의 bot_magic_catalog.rs 구현을 대조했으며 실제 BotBrain 연결은 남아 있다.
- core 검증은 실제 StandardMagics/parser의 EmberSpirit swarm 5개/20마나, Overgrowth의 combo+explosion, VineToss, airborne, 누락 bean, HP별 가치·표적 필터·unknown fallback·같은 prefab 최저 비용, cache snapshot 보존·무효화·빈 catalog 재시도를 확인한다. BoardValue 원본에는 단독 test 함수가 없고 서버 adapter 테스트는 기존 sim 915개 목록 밖이므로 원본 통과 수를 늘리지 않았다.
- .NET/Unity Editor 원본 580/915개 및 추가 core 검증 통과. unity-parity-board-value.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 426/668개 core-only이며 원본 테스트 335개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### HospitalityDirector의 허용량·aggression 이관

- novice progress를 [0.5,1]로 제한하고 상대 board mana의 해당 비율에서 자기 board mana를 차감하는 허용량을 옮겼다. 유닛 수 lead<=0이면 -1, lead>=2 또는 pressure>=0.6이면 -0.2, 나머지는 -0.6인 aggression을 보존한다.
- Q32.32 비율 양자화로 100*0.7의 정수 절삭이 69가 되는 것을 막기 위해 곱에 대한 raw 오차 범위 내 정수 경계만 보정한다. 9*0.7=6, 10*0.7=7, 100*0.699=69 및 음수 허용량을 별도로 확인했다.
- 원본 테스트 12개와 추가 수치 경계 검증을 이관했다. BoardValue/CastDeadline을 실제 BotBrain의 후보 선택에서 사용하는 연결은 아직 남아 있다.
- .NET/Unity Editor 원본 592/915개 및 core 검증 통과. unity-parity-hospitality.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 427/668개 core-only이며 원본 테스트 323개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### ThreatAssessment·EnemyThreat 이관

- snapshot의 적을 활성/targetable 기준으로 수집하고 방어 위치까지 3D 거리로 안정 정렬한다. Player core HP는 세션 값을 쓰고 strength/pressure는 0으로 처리한다.
- 9 거리 horizon, 3 pressure saturation, 2.5 Z lane gap, 같은 pressing lane의 아군 방어력 0.8 차감 규칙과 전투력 가중 압박을 옮겼다. 전체 가중 lane과 가장 무거운 단일 lane을 구분한다. 동률은 안정 정렬/엄격한 greater 비교로 첫 lane을 유지한다.
- 예측 이동은 알려진 속도*시간으로 threat만 옮기고 거리 재계산/재정렬하며 기존 관측값과 defenders는 유지한다. 가중 lane은 기준점에서의 offset을 누적해 단일 Z의 원본 exact assertion을 보존한다.
- 원본 테스트 15개를 이관했다. 실제 객체의 mob HP·dying/destroyed filtering, 압박 범위/포화, core, 가중 라인, 아군 cover, 예측 이동 불변성을 검증했다. 실제 BotBrain 후보 선택 연결은 남아 있다.
- .NET/Unity Editor 원본 607/915개 및 core 검증 통과. unity-parity-threat.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 429/668개 core-only이며 원본 테스트 308개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### PlacementPlanner 이관

- 적이 있을 때 nearest threat까지 거리의 0.6(원거리 0.35), 전장이 비었을 때 cast range의 0.9(원거리 0.6)를 사용하는 소환 위치 계산을 옮겼다. strongest-lane 옵션은 해당 lane의 첫 non-core threat를 기준으로 하고 없으면 전체 nearest로 돌아간다.
- 좌우 전진 방향, map bounds 후 cast range clamp, 빈 전장에서만 nextDouble 대응 NextFraction 1회로 Z ±1.5 편차를 주는 순서를 보존한다. Master.None은 거절한다.
- 원본 테스트 6개와 난수 소비·같은 seed 재현·잘못된 side 거절을 검증했다. 실제 BotBrain의 소환 후보 선택과 시전 연결은 남아 있다.
- .NET/Unity Editor 원본 613/915개 및 core 검증 통과. unity-parity-placement-planner.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 430/668개 core-only이며 원본 테스트 302개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### BlastTargetSelector 이관

- 시전 가능한 적 위치마다 폭발 후보를 평가하며 각 대상의 남은 HP로 피해를 제한하고 Player core 피해 가중치 2를 적용한다. 평가 순서는 expected damage, covered count, 짧은 거리이며 완전 동률은 첫 후보를 유지한다. core는 lethal count에서 제외한다.
- 원본 테스트 5개와 동률·거리 우선순위·원래 관측은 범위 밖이지만 예측 관측은 범위 안인 상황·core 처치 집계 제외를 검증했다. ThreatAssessment.LedBy와 연결해 예측 조준 위치를 계산할 수 있으며 실제 BotBrain 후보 선택은 미연결이다.
- .NET/Unity Editor 원본 618/915개 및 core 검증 통과. unity-parity-blast-target.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 431/668개 core-only이며 원본 테스트 297개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### 봇 우선 행동 규칙 연결

- ThinkContext/ScoredPlay와 capability gate를 추가했다. 후보마다 noise를 한 번 적용하며 amplitude=0이어도 난수 소비를 유지하고, 동률은 먼저 나온 후보를 보존한다. 무료 양수 가치 시전의 무한대 점수는 Fix64.MaxValue로 표현하며 noise 곱셈 overflow를 피한다.
- LethalRule은 non-summon·affordable·range·stated damage 조건을 만족하는 가장 싼 finisher를 noise 없이 비교한다. SeedSpiritComboRule은 활성 아군 SeedSpirit의 VineToss/Overgrowth를, MobClusterComboRule은 반경 2.5의 적 mob 3개 이상 군집을 두 번 중심 계산한 뒤 선택한다. 실행 순서는 lethal→seed→cluster다.
- core 검증에서 우선순위, tier gate, 실제 후보의 마나/사거리/피해 누락, 군집 중심, 정확한 난수 소비, 무료 시전, 동률 보존을 확인했다. 이 파일들의 원본 단독 test는 없고 BotBrain 테스트가 전체 pipeline을 검증하므로 원본 통과 수를 늘리지 않았다. 전체 BotBrain 가치 평가·실제 시전 연결은 남아 있다.
- .NET/Unity Editor 기존 원본 618/915개 및 추가 core 검증 통과. unity-parity-priority-rules.log 종료 코드 0, 기존 10,000 tick 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 437/668개 core-only이며 원본 테스트 297개와 doctest 2개, 전체 이관 및 실제 매칭 연결은 미완료다.

### GamePlanner 및 태그 상성 평가 이관

- CardRoles의 44개 분류, SummonRelevance의 대공/방어/지원 조건, DeckProfile의 중복 포함 전체 덱 집계, GamePlanner의 마나 비축과 출발 중인 아군 집결 위치 합류를 이관했다. 50마나 이상 Fighter 3장 조건, max mana-10 상한, 먼저 나온 동률 후보 유지, 알 수 없는 소환 역할의 최초 경고를 보존한다.
- GamePlanner core 검증과 기존 618개 테스트는 .NET/Unity 모두 통과했다(unity-parity-game-planner.log, 종료 코드 0). 원본 독립 테스트가 없는 파일이므로 통과 수는 늘리지 않았다.
- ITagCatalog/MagicMetadataService/BotCounterEvaluator를 추가했다. 공격/방어 방향으로 태그 상성 합계를 계산하며 조회 실패는 중립 점수로 처리한다. 마법 태그 캐시와 명시적 무효화를 옮겼고 캐시에 저장하는 태그는 정렬된 읽기 전용 복사본이다. 실제 태그 데이터 로더와 BotBrain 연결은 남아 있다.
- 상성 평가 원본 5개 및 metadata 원본 2개 테스트를 이관했다. .NET/Unity Editor 원본 625/915개 및 core 검증 통과, unity-parity-bot-counter.log 종료 코드 0. 10,000 tick 기존 해시 일치, root/client diff 검사 통과. 소스 부분 매핑 444/668개이며 원본 테스트 290개와 doctest 2개, 전체 전투 및 lobby/GameScene 실제 연결은 미완료다.

### BotBrain 전체 판단 흐름 연결

- BotBrain/InputDecision을 추가하고 관측 시점의 motion 갱신, 손패 중복 제거, unit catalogue/pressure/lead 계산, 접대 보드 예산, 우선 규칙, wave plan, 후보 가치 평가, 마나 비축, overdue cycle을 연결했다. 손패 포화는 원본 PlayerData의 6장 상수를 사용한다.
- 일반 봇은 aggression 부호에 따라 공격/방어 상성을 읽고, 접대 봇은 보드 상태로 aggression을 다시 정한다. 소환의 비용이 allowance 이상이면 overdue여도 거절한다. 후보마다 시전 위치와 noise 계산 순서를 유지했다. seed는 명시적으로 주입하며 wall clock/entropy를 쓰지 않는다.
- 원본 BotBrain의 상성·접대·swarm 가격·마나 대기·overdue cycle·빈 손패 테스트 14개를 이관했다. .NET/Unity 639/915개 및 core 검증 통과, unity-parity-bot-brain.log 종료 코드 0, 10,000 tick 해시 일치. root/client lockstep 브랜치 확인 및 diff 검사 통과.
- 아직 BotBrain의 나머지 콤보/noise/고급 capability/game-plan 테스트는 이관하지 않았다. 설명 문자열의 Java double scientific 형식은 현 decimal 표시와 차이가 있어 보완해야 하며 zero-cost/negative infinity 점수 경계도 추가 검증이 필요하다. 실제 BotAgent/전투 루프 시전·lobby/GameScene 연결은 남아 있다. 소스 부분 매핑 445/668, 원본 테스트 276개 및 doctest 2개가 남아 있고 전체 목표는 미완료다.

### BotBrain 고급 판단과 콤보 검증

- 원본 capability 테스트 7개와 game-plan 테스트 8개를 이관했다. 소환 효율·막타 우선순위/명시 피해 요구·평온할 때 비축/최대 마나 제한/overdue·이동 예측, 대공/밀어내기 역할·손패 6장 포화·wave 비축/합류·전체 덱 구성 조건을 실제 BotBrain을 통해 검증한다.
- 콤보 우선순위/군집 중심/후보당 noise 1회/같은 seed 재현의 원본 테스트 4개를 이관했다. noise 횟수는 두 NextFraction 호출 후의 JavaRandom 전체 상태와 비교하며 결정 재현은 magic ID·target·rule·reason 전부 비교한다.
- lethal rule ID 테스트의 잘못된 예상 문자열을 원본 lethal_rule.rs의 finish.lethal로 바로잡았다. runtime 동작 변경은 없다. BotBrain의 Java double 설명 문자열 테스트는 미이관이며 표시 형식 보완이 남는다.
- .NET/Unity Editor 658/915개와 core 검증 통과, unity-parity-bot-capabilities.log 종료 코드 0. 기존 10,000 tick 해시 일치와 root/client diff 검사 통과. 소스 부분 매핑 445/668개, 원본 테스트 257개 및 doctest 2개가 남아 있다. 다음 연결 대상은 BotAgent의 지연 결정/시전 및 emote/decision-source 의존성이며 lobby/GameScene 실제 매칭은 아직 미완료다.

### 봇 결정에서 다음 프레임 시전까지 연결

- IBotDecisionSource/RuleDecisionSource, BotInputRequest, BotAction, BotInputHandlerService와 실제 MagicInputHandler adapter를 추가했다. botUseMagic을 session action queue에 넣고 drain 시점에 handler service를 조회한다. 누락된 handler는 알림 후 무시하고 가득 찬 queue는 false를 반환한다.
- 원본 queues_the_cast_for_the_next_frame 테스트를 이관했다. 추가 core 검증은 handler 누락과 queue overflow를 확인한다.
- 실제 BattleFrameLoop에서 BotBrain→RuleDecisionSource→BotAction→MagicInputHandler를 검증했다. 첫 frame에서 마나50/손패 유지, 다음 frame에서 마나30/손패 소비/덱 반환/마법 실행 1회, 결과 종료 후 큐에 있던 시전은 거절된다. 테스트용 QueuedBotSystem은 즉시 판단만 담당하며 production BotAgent의 생각 시간·반응 주기·emote를 구현한 것은 아니다.
- .NET/Unity Editor 659/915개 및 core 검증 통과, unity-parity-bot-action.log 종료 코드 0. 10,000 tick 기존 해시 일치 및 root/client diff 검사 통과. 소스 부분 매핑 448/668, 원본 테스트 256개 및 doctest 2개가 남아 있다. BotAgent/BotEmoteDirector·전투 bootstrap·lobby/GameScene 실제 연결은 계속 미완료다.

### BotAgent의 지연 시전과 반응 주기

- BotAgent의 decision-source, pending/last decision, CastDeadline, IntervalTimer 반응 주기, 10초 주기 BotThought 알림을 이관했다. ready pending dispatch가 새 판단과 주기 알림보다 먼저이며 생각 시간 0은 같은 tick에 queue에 들어간다. 큐가 가득 차도 원본과 같이 결정/기한/알림은 갱신한다.
- 요청 번호는 원본 process-global NEXT_ID 대신 세션이 주입하는 공급자를 쓴다. 서로 다른 경기의 실행 순서에 따른 번호 변동을 없애기 위한 결정론 변경이다. clock도 주입하며 운영 연결에서는 FrameMillisClock을 사용한다.
- 원본 BotAgent 시간 관련 테스트 4개를 이관했다. 20/60Hz의 8초 동안 20회 반응·첫 반응 0.4초, 249/250ms 준비 경계, 즉시 시전, idle thought를 검증했다. core에서 실제 FrameMillisClock으로 20/60Hz 모두 250ms마다 큐가 한 번 처리되고 세션 요청 번호가 0→1로 증가함을 확인했다.
- .NET/Unity Editor 663/915개 및 core 검증 통과, unity-parity-bot-agent.log 종료 코드 0. 10,000 tick 기존 해시 일치와 root/client diff 검사 통과. 소스 부분 매핑 449/668, 원본 테스트 252개 및 doctest 2개가 남아 있다. BotAgent emote 경로·executor 공유 검증·BotAgentSystem 연결은 아직 미완료이며, 전체 전투 bootstrap/lobby/GameScene 연결도 남아 있다.

### BotEmoteDirector 및 BotAgent 이모트 연결

- Warm/Smug/Timid/Stoic의 상황별·답장별 가중치, 확률, 인사 지연 3~8초, 답장 지연 0.8~2.5초, 상황 간격 20~30초, 답장 간격 8초, 공통 cooldown 3초를 이관했다. 경기 총합6/상황4/답장2/개별상황2회 제한과 답장 우선순위를 유지한다. seed와 clock은 외부 입력이며 확률/jitter는 고정 소수점으로 계산한다. 70% 체력 비교는 정수 교차 곱으로 수행한다.
- 원본 director 테스트 16개를 이관했다. 원본과 같은 200경기·300초·100ms 간격/seed로 성향별 분포·횟수·간격·답장 burst·지연 변화 및 owned/explicit RNG 경로를 검증했다.
- BotAgent에 director·공통 cooldown callback·EmoteSent를 연결하고 OnOpponentEmote와 UpdateEmote를 추가했다. cooldown이 거절하면 director가 선택한 이모트는 원본처럼 버린다. 이 경로의 원본 BotAgent 테스트 2개를 이관했다. director를 사용하는 생성은 cooldown callback을 필수로 요구한다.
- .NET/Unity Editor 원본 681/915개 및 core 검증 통과, unity-parity-bot-emote.log 종료 코드 0. 기존 10,000 tick 해시 일치 및 root/client diff 검사 통과. 소스 부분 매핑 450/668, 원본 테스트 234개와 doctest 2개가 남아 있다. BotAgentSystem/실제 세션 초기화·lobby/GameScene 연결은 미완료다.

### BotAgentSystem을 전투 루프에 연결

- BotAgentSlots/IBotAgentSource, IBotThinkExecutor/SynchronousBotThinkExecutor, BotAgentSystem을 추가했다. 기본 실행은 좌측→우측 동기 실행이며 시뮬레이션 frame/tickRate 시각으로 frozen BotEye를 만든다. 각 side의 processing flag를 finally에서 풀고 두 판단 이후 양쪽 emote를 갱신한다. 별도 executor 주입은 원본 비동기 동작 검증에 사용한다.
- 슬롯은 IBotControl을 구현하고 생성 factory를 주입받아 BotLifecycle의 생성/제거에 연결할 수 있다. 실제 persona/content 기반 factory와 세션 bootstrap 연결은 아직 남아 있다.
- 원본 system 테스트 3개를 이관했다. parked executor에 중복 제출되지 않으며 다른 thread에서 job을 완료하면 다시 제출되는 것, thought sink 예외 후 flag 해제, 실제 brain의 시전 queue를 검증한다. core에서 양쪽 순서 및 side 제거 후 갱신도 확인한다.
- 기존 MagicInputParityTests.CheckBrainQueuedCast의 테스트용 QueuedBotSystem을 삭제하고 실제 BotAgentSystem/BotAgent/FrameMillisClock으로 대체했다. BattleFrameLoop에서 다음 프레임의 마나/손패/덱 반환 및 종료 후 예약 시전 거절을 계속 검증한다.
- .NET/Unity Editor 684/915개와 core 검증 통과, unity-parity-bot-system.log 종료 코드 0. 기존 10,000 tick 해시 일치 및 root/client diff 검사 통과. 소스 부분 매핑 451/668, 원본 테스트 231개와 doctest 2개가 남아 있다. 실제 세션/lobby/GameScene 연결과 전체 이관은 미완료다.

### SessionBotControl 생성 경로

- 원본 server bot_control.rs를 바탕으로 SessionBotControl을 추가했다. 확정된 persona provider/전체 덱/seed/catalog/counter를 받고 BotBrain→RuleDecisionSource→BotAgent→BotEmoteDirector를 생성한다. 전체 덱과 persona는 복사하며 원본의 opponent novice progress를 전달한다. generation을 side별로 저장해 재생성 seed가 다른 세션 실행 순서에 의존하지 않는다. 요청 번호도 세션에 속한다.
- 모델 봇은 decision factory가 없으면 생성 실패로 드러낸다. 규칙 봇으로 조용히 치환하지 않는다. 실제 모델 추론/동기화 전달 경로는 여전히 미구현이며 factory 인터페이스만 연결했다.
- BotLifecycle 연습전 초기화/접속 끊김 대체/재접속 해제를 실제 SessionBotControl로 검증했다. 덱 외부 변경 격리, persona 복사, wave 판단, 동일 seed+재생성 순서의 결정 재현, 모델 provider 누락과 주입을 core 테스트로 확인했다.
- MagicInput의 BattleFrameLoop 통합 검증도 SessionBotControl로 생성한 실제 BotAgent를 사용한다. .NET/Unity 684/915개 및 추가 core 검증 통과, unity-parity-session-bot.log 종료 코드 0, 10,000 tick 기존 해시 일치 및 root/client diff 검사 통과. server 경로를 참고한 신규 core 검증이므로 sim 원본 테스트 수는 늘리지 않았다. 전체 세션 bootstrap/content 로딩·lobby/GameScene 연결은 미완료다.

### 세션 공통 이모트 입력과 cooldown

- SessionObject의 side별 atomic 3초 cooldown을 EmoteCooldown으로 이관했다. wall clock 대신 FrameMillisClock을 사용하며 deadline을 노출해 세션 상태에 포함할 수 있다. SessionEmotes는 정확한 대소문자 이름 해석, 참가자 side 검증, 공통 cooldown 소비, 표시 event, opposing bot 알림 큐를 담당한다.
- opposing bot 알림은 입력 시 존재 여부를 확인하고 drain 시 context의 SessionBotControl을 다시 읽는다. BotAgent에는 같은 Cooldown.TryConsume을 주입하고 EmoteSent를 PublishBot에 연결하는 계약이다. 이 wiring을 포함한 전체 세션 bootstrap은 아직 남아 있다.
- 원본 emote_cooldown_drops_the_second_emote 1개와 core 20/60Hz의 3초 전/정확 경계, 좌우 독립 상태, 사람/봇 공유 소비, invalid side/name/user의 cooldown 미소비를 검증했다.
- .NET/Unity Editor 685/915개 및 core 검증 통과, unity-parity-session-emote.log 종료 코드 0. 기존 10,000 tick 해시 일치와 root/client diff 검사 통과. 소스 부분 매핑 453/668, 원본 테스트 230개와 doctest 2개가 남아 있다. 실제 lobby/GameScene 연결과 전체 전투 이관은 미완료다.

### 세션 정의와 덱 seed 초기화

- SessionDefinition에 확정된 session ID/참가자/전체 덱/명시 seed/type/map/scenario를 담았다. 덱은 읽기 전용 복사본이며 CreateLeftDeck/CreateRightDeck은 각각 독립된 가변 deck을 만든다. InitializeIdentityAndDecks는 context의 UserIds/CardDecks를 설정하고 중복 초기화를 거절한다. 이는 전체 전투 bootstrap 중 identity/deck 단계이며 player/terrain/physics/network 초기화는 아직 포함하지 않는다.
- DeckSeedDeriver의 unsigned shift와 wrapping multiply를 옮겼다. 원본 OpenJDK 기준 seed 두 값과 일치한다. SessionType 네 종류와 GameMap 다섯 종류를 선언했다. map terrain 메서드/직렬화는 별도 연결이 남아 있다.
- 원본 seed derivation 1개, session identity/deck 2개 테스트를 이관했다. core에서 입력 deck 복사, 좌우별 다른 순서, 동일 정의로 만든 두 context의 재현/격리, metadata 및 중복 초기화 거절을 검증했다.
- .NET/Unity Editor 688/915개와 core 검증 통과, unity-parity-session-definition.log 종료 코드 0. 10,000 tick 기존 해시 일치 및 root/client diff 검사 통과. 부분 소스 매핑 455/668, 원본 테스트 227개와 doctest 2개가 남아 있다. 실제 세션 bootstrap/lobby/GameScene 연결은 미완료다.

### 플레이어와 지형 필드 초기화

- BattleFieldInitializer로 원본 GameLoop.initialize_loop의 플레이어→벽→terrain 설정→water cells→bridge cells 순서를 옮겼다. 세션 Map을 그대로 사용하고 createRightPlayer=false를 지원한다. 입력 handler/플레이어 데이터/HP 파라미터 선행 조건과 반복 초기화 거절을 추가했다. 전체 prefab registry 구성은 호출자 책임이며 전체 bootstrap은 아직 남아 있다.
- RiverBridge initializer를 TerrainPrefabs에 추가했다. 원본과 같이 None element만 가지며 collider/component/HP 없이 표시용 cell 객체로 남는다.
- 원본 GameLoop map/초기 객체 테스트 5개를 이관했다. 실제 PlayerHealth/PlayerStatusSetter/Wall/WaterBarrier/Bridge를 생성하며 River의 물8/다리12 중심 좌표, PVE map 선택 보존, 양쪽 player 순서를 검증한다. core에서는 우측 player 생략, HP250, 객체 생존, bridge 비충돌/비mob 및 중복 초기화 거절을 확인한다.
- .NET/Unity Editor 693/915개와 core 검증 통과, unity-parity-battle-field.log 종료 코드 0. 기존 10,000 tick 해시 일치와 root/client diff 검사 통과. 부분 소스 매핑 457/668, 원본 테스트 222개와 doctest 2개가 남아 있다. 실제 세션 bootstrap/lobby/GameScene 연결 및 전체 이관은 미완료다.

### BattleSessionRuntime 서비스 연결과 종료 통합 검증

- BattleSessionRuntime이 identity/decks/session RNG, MagicInputHandler/CardSelectVisualizer, BotInputHandler service, SessionEmotes/SessionBotControl/BotLifecycle, BotAgentSystem/FeverTimeSystem/BattleFrameLoop, 필드 생성을 연결한다. Practice에서만 음수 참가자의 봇을 초기화하고 PVE에는 기본 시간제한을 적용하지 않는다. 확정 frame은 1부터 연속으로 받아야 하며 종료 후 advance를 거절한다.
- 전체 콘텐츠/prefab registry/플레이어 데이터는 여전히 호출자가 준비해야 한다. 이 클래스가 DB 로딩이나 실제 GameScene 연결을 완료한 것은 아니다. HasPrefab과 필드 prefab 사전검사를 추가해 미등록 필드 객체가 조용히 destroyed 상태로 생성되는 문제를 막는다.
- 추가 core 통합 검증은 테스트용 strike 마법으로 실제 BotBrain/Agent/System/InputHandler/PlayerHealth를 통과해 2회 시전, 마나50→40, 적HP20→0, 우측 패배, 1초 종료 유예 후 정지와 결과 callback 1회를 확인한다. 같은 seed/입력으로 실행한 두 런타임의 매 frame 마나/HP/큐/종료 trace가 일치하며 frame 건너뛰기와 종료 후 advance도 거절한다. 실제 전체 콘텐츠·네트워크 대전 증거는 아직 아니다.
- .NET/Unity Editor 기존 원본 693/915개 및 추가 core 검증 통과, unity-parity-battle-session.log 종료 코드 0. 기존 10,000 tick 해시 일치와 root/client diff 검사 통과. 원본 테스트 222개 및 doctest 2개, 전체 콘텐츠 초기화·PVE·lobby/GameScene/실제 네트워크 대전 검증이 남아 있다.

### Prefab 통합 등록 경로와 누락 확인

- StandardPrefabs.Register에 현재 이관된 prefab 등록 함수 57개를 연결했다. 중첩 상태 클래스가 아닌 실제 소유 클래스의 정적 함수를 호출한다. 기존 BattleSessionChecks가 Player/Terrain 개별 등록 대신 이 통합 경로를 사용하도록 바꿨다. 중복 등록 예외 없이 전체 서비스 연결/종료 통합 검증을 통과한다.
- CoreTests가 PrefabCatalog 전체 136개 이름을 실제 context.HasPrefab으로 대조해 누락을 로그로 출력한다. 현재 10개가 미등록이다: VineToss, StormRider, TreeGolem, ZapMouse, FireLordSpirit, FireChildSpirit, DimensionToad, FireTadpole, LightningTadpole, ArcaneInfantry. PveDimensionToad/PveFireTadpole/PveLightningTadpole는 일반 버전의 대체가 아니므로 그대로 분리한다. 통합 등록 전체 완료로 간주하지 않는다.
- VineToss의 원본 initializer/component를 확인했다. 기존 VineMagics.Toss는 VineLine을 직접 생성하지만 prefab VineToss는 Shot(speed0,damage0)을 가지고 SetTarget 시 VineLine 생성 후 자신을 파괴하는 별도 경로다. 다음 이관에서 이 경로도 보존해야 한다.
- .NET/Unity Editor 원본 693/915개 및 통합 core 검증 통과, unity-parity-standard-prefabs.log 종료 코드 0. 기존 10,000 tick 해시 일치 및 root/client diff 검사 통과. 신규 원본 테스트는 없으며 222개/doctest2와 일반 unit 10개 등록, 전체 콘텐츠·PVE·lobby/GameScene 네트워크 연결이 남아 있다.

### VineToss prefab 등록 검증
- 기존 VineToss 동작과 원본 테스트는 이관되어 있었으나 StandardPrefabs 등록에서 빠져 있어 등록을 연결했다. Nature 속성 및 즉시 추가하는 ShotTarget을 원본 initializer와 맞췄다.
- 목표 방향 계산은 VineMagics.Normalize와 공유해 축 방향의 역수 선양자화 오차를 제거했다. 실제 prefab 생성 후 속성, 충돌체 부재, 최초 덩굴 위치 및 소유자를 검증했다.
- .NET 및 Unity 2022.3.34f1에서 원본 테스트 693개와 core 검증 통과. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일. Unity 로그 unity-parity-vine-registration.log, 종료 0.
- 원본 915개 중 222개와 doctest 2개는 남아 있다. 부분 소스 대응 458/668, 미등록 prefab 9개. lobby/GameScene 연결 및 실제 네트워크 대전 완료 검증도 계속 필요하다.

### 일반 우선순위 유닛 연결
- StormRider, ZapMouse, TreeGolem prefab을 원본 initializer 순서 및 즉시/지연 컴포넌트 추가 방식에 맞춰 등록했다.
- PlayerPrioMob은 플레이어 우선 탐색 후 동일 filter를 적용한 가장 가까운 적으로 대체한다. BuildingPrioMob은 건물, 플레이어 순서이며 일반 유닛을 표적으로 삼지 않는다.
- TreeGolem의 SelfHealer 및 중립 LeafField PathSpawner를 연결했다. 실제 prefab 생성, 물리 body 연결, 속성, 우선순위/filter, 공격 피해, 회복, 장판 생성을 core 검증에 추가했다.
- .NET 및 Unity 2022.3.34f1 모두 원본 테스트 693개와 core 검증 통과. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일. unity-parity-priority-units.log 종료 0.
- 미등록 prefab은 FireLordSpirit, FireChildSpirit, DimensionToad, FireTadpole, LightningTadpole, ArcaneInfantry 6개. 원본 테스트 222개와 doctest 2개, 콘텐츠 로딩/PVE/실제 네트워크 대전 완료 검증은 여전히 남아 있다.

### FireLordSpirit 및 FireChildSpirit 연결
- KeepDistanceMob를 원본처럼 1초 초과마다 표적을 갱신하고 수평 충돌체 가장자리 거리가 선호 거리+0.25보다 클 때만 접근하도록 옮겼다. 근거리 후퇴는 원본에 없어 추가하지 않았다. 체력 gauge 및 사망 처리 포함.
- FireLordSpirit는 공중 높이 3, Fire+Wind, 5초마다 FireChildSpirit 최대 5마리 생성. 자식은 Fire 속성, Any 표적, FireShot 이벤트 0.4초의 원거리 공격으로 구성했다.
- 20/60Hz 각각 30초 생성 횟수와 시점, 이동/정지 경계, 소유권 변경 표적 제외, 자식 위치/속성/피해/이벤트를 core에서 검증했다. 위치 기대값은 Q32.32 한두 raw 단위 반올림 차이를 허용하는 1e-9 오차로 검증한다.
- .NET 및 Unity 2022.3.34f1 모두 이관 원본 테스트 693개와 core 검증 통과. unity-parity-fire-lord.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 미등록 prefab: DimensionToad, FireTadpole, LightningTadpole, ArcaneInfantry. 원본 테스트 222개 및 doctest 2개, PVE와 콘텐츠 로딩, lobby/GameScene 네트워크 대전 완료 검증은 계속 필요하다.

### 일반 두꺼비와 보병 prefab 연결
- DimensionToad를 NonAttackingCowardMob(선호 거리 4) 및 즉시 시작/무제한 교대 LimitedSequenceSpawner로 연결했다. PVE의 정지 objective/trigger 구성과 분리했다.
- FireTadpole 및 LightningTadpole은 일반 파라미터를 읽되 원본과 같은 melee/lifetime/속성/효과 receiver 구성으로 연결했다. ArcaneInfantry는 설정된 attack_range를 쓰는 Ground AttackMob로 연결했다.
- StandardPrefabs의 모든 PrefabCatalog 이름 등록 여부를 core 실패 조건으로 승격했다. 등록 누락은 이제 0개이며, 전체 콘텐츠 초기화 및 동작 완료를 의미하지 않는다.
- 20/60Hz에서 일반 두꺼비의 즉시/교대/5마리 초과 소환, 비공격, 올챙이 피해와 수명, 보병 사거리를 검증했다.
- .NET 및 Unity 2022.3.34f1 모두 원본 테스트 693개와 core 검증 통과. unity-parity-general-toad.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일. 부분 소스 대응 471/668.
- 원본 테스트 222개 및 doctest 2개, 콘텐츠 로딩/PVE/실제 lobby-GameScene lockstep 대전 완료 검증은 남아 있다.

### PVE 설치 객체와 런타임 상태 이관
- PveInstallObject, PveRuntimeState, PveScenarioInstaller를 추가했다. 설치 ID는 아직 월드에 flush되지 않은 객체도 직접 참조하고, 재설치 시 새 객체로 교체한다. 초기 batch install은 새 Runtime을 만들며 기존 Runtime 참조는 유지한다.
- 초기화 전 max HP override는 대기 후 한 번만 적용한다. objective health를 우선하고 Spawner를 제외한다. 선택적 PveScenarioComponents를 통해 시나리오 구조물의 lifetime을 제거한다.
- 원본 max_hp_override_waits_for_the_boss_mob_to_appear를 이관했다. 추가 core 검증으로 pending 객체 조회, 보스/Spawner/일반 mob 공존 시 HP 선택, lifetime 제거, 파괴 후 조회, 재설치 및 Runtime 교체를 확인했다.
- .NET 및 Unity 2022.3.34f1에서 원본 테스트 694개와 core 검증 통과. unity-parity-pve-installer.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일. 부분 소스 대응 473/668.
- 원본 테스트 221개 및 doctest 2개가 남아 있다. PVE script/event/rule engine, 콘텐츠 로딩, 실제 lobby-GameScene lockstep 대전 완료 검증은 아직 미완료다.

### PVE 승패 판정 이관
- PveScenarioRules/PveWinCondition 및 PveResultChecker를 추가했다. 기존 BattleResult를 주입할 수 있어 플레이어 사망 상태를 공유한다. 아직 PVE loop 연결 전이다.
- 목표를 매번 installer ID로 조회하고, 미설치 목표는 남은 목표로 센다. terminal 객체는 ID로 기억하며 재설치된 새 ID는 다시 남은 목표가 된다. 목표가 없거나 Runtime이 없으면 목표 파괴 승리는 성립하지 않는다.
- Survive는 프레임 임계 도달 또는 모든 목표 파괴로 성공하며, 같은 프레임 플레이어 사망이 먼저 적용되면 실패한다. 원본의 unchecked i32 임계 곱셈과 최초 loser 보존을 유지했다.
- pve_engine.rs의 결과 판정 원본 테스트 9개를 이관했다. 추가 core에서 60Hz 경계/공유 결과/재설치 목표 카운트/규칙 초기화를 검증했다.
- .NET 및 Unity 2022.3.34f1 모두 원본 테스트 703개 및 core 통과. unity-parity-pve-result.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일. 부분 소스 대응 476/668.
- 원본 테스트 212개와 doctest 2개, PVE script/objective/loop 연결, 콘텐츠 로딩 및 실제 lobby-GameScene 네트워크 대전 완료 검증이 남아 있다.

### PVE 목표 상태 출력 이관
- PveObjectiveSystem과 불변 PveObjectiveState를 추가했다. PveResultChecker의 목표 수/생존 프레임 임계를 사용하며, 남은 초는 올림 계산한다.
- 최초 Update는 양쪽 사용자에게 출력하고 이후 remainingSeconds 또는 objectivesRemaining이 바뀔 때만 출력한다. SendCurrentTo는 한 사용자에게 현재 상태를 출력하되 lastSent를 변경하지 않는다.
- pve_engine.rs 원본 테스트 6개를 이관해 최초 출력, 중복 억제, 개별 동기화, 최초 전체 출력 보존, 목표 파괴 변경, 생존 카운트다운을 확인했다. Action sink는 아직 실제 네트워크/UI adapter에 연결하지 않았고 wire 직렬화도 별도 작업이다.
- .NET 및 Unity 2022.3.34f1 모두 원본 테스트 709개 및 core 통과. unity-parity-pve-objective.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일. 부분 소스 대응 477/668.
- 원본 테스트 206개와 doctest 2개, PVE script/loop 연결, 콘텐츠 로딩 및 실제 lobby-GameScene 네트워크 대전 완료 검증은 남아 있다.

### PVE 채널 상태 저장 이관
- PveStateStore/PveChannelState를 추가했다. 채널별 최신 값과 경기 공통 증가 seq를 저장하고, 같은 값은 seq 증가 없이 무시한다. snapshot은 seq 오름차순으로 반환한다.
- 원본 one_seq_counts_changes_across_channels_and_skips_unchanged_values를 이관했다. core에서 최초 null 저장/중복 억제, 기존 snapshot 및 반환 배열의 독립성, 경기별 seq 격리를 확인했다.
- .NET 및 Unity 2022.3.34f1 모두 원본 테스트 710개와 core 통과. unity-parity-pve-state.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일. 부분 소스 대응 478/668.
- 아직 script의 SetBgm 액션 및 재동기화 전송에 연결하지 않았다. wire DTO 직렬화도 별도 작업이다. 원본 테스트 205개와 doctest 2개, PVE script/loop와 실제 네트워크 대전 통합은 남아 있다.

### PVE 액션 실행부 이관
- PveActionRunner로 SpawnWave, InstallObject, SetSpawner, SetBgm, PullPlayerUnits의 실행 경로를 추가했다. 아직 이벤트 모델/트리거/once-only 실행 루프와 연결하지 않아 원본 이벤트 테스트 이관 수는 늘리지 않았다.
- SpawnWave는 최소 1개, 중앙 정렬 0.5 간격으로 RightPlayer 생성. InstallObject는 설치 ID 및 HP override 사용. SetSpawner는 기존 제거 후 count>0일 때만 추가하고 기본 주기 2초.
- SetBgm은 sink가 있을 때만 상태 저장 및 양쪽 전달, 중복 억제, null 기본값과 현재 상태 재전송을 지원한다.
- PulledToPoint는 1.5초 동안 XZ 선형 이동 후 파괴하며 Y는 유지한다. PullPlayerUnits는 살아 있는 LeftPlayer Unit의 Mob 컴포넌트를 제거한 뒤 끌어오고, 유효 목적지가 없으면 파괴한다.
- core에서 실제 컴포넌트 교체, HP override, 웨이브 위치, 끌어오기/파괴, BGM 상태 출력/재전송을 확인했다. .NET 및 Unity 2022.3.34f1 원본 테스트 710개 및 core 통과. unity-parity-pve-actions.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 부분 소스 대응 479/668, 원본 테스트 205개와 doctest 2개 남음. 다음은 PveScriptSystem 이벤트 모델, 트리거, 대화 replay, shield attachment 및 액션별 예외 격리 연결이다. 실제 lobby-GameScene 네트워크 대전 완료도 미검증.

### PVE 이벤트 실행 루프 연결
- PveScenario/Event/Action/Shield 모델과 PveScriptSystem을 추가했다. 입력 목록은 복사한 읽기 전용 컬렉션이다. 네 가지 트리거, 실행 전 fired 등록, 액션별 예외 격리, 대화 실패 뒤 액션 계속 실행을 구현했다.
- HP 비율 반올림은 양수 HP에 대해 (hp*200+maxHp)/(maxHp*2)의 long 정수 계산으로 Math.round 의미를 유지한다. 프레임 트리거는 20Hz 기준 값을 실제 tick rate로 환산한다.
- 대화는 seq와 frame을 기록하고 최근 10초 이내, 요청 seq 초과 항목만 순서대로 재전송한다. 채널 상태는 나이와 관계없이 최신 snapshot을 재전송한다.
- shield는 설치된 대상에 한 번 추가하며 피해 시점마다 캡처한 Runtime에서 소스의 현재 객체를 조회한다. 객체 재설치와 아직 설치되지 않은 소스를 지원한다.
- pve_engine.rs 원본 트리거/대화 테스트 12개 이관. core에서 액션 실패 격리, 같은 프레임 설치/보호막 활성화, 소스 파괴 즉시 피해 허용, 중복 부착 방지, 10초 replay 경계 및 seq 필터 검증.
- .NET 및 Unity 2022.3.34f1 원본 테스트 722개 및 core 통과. unity-parity-pve-script.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일. 부분 소스 대응 485/668.
- 원본 테스트 193개와 doctest 2개 남음. 나머지 PVE 액션/shield/replay 테스트 이관, registry/rows/match/loop 연결, 콘텐츠 로딩과 실제 lobby-GameScene 네트워크 대전 통합은 계속 필요하다.

### PVE 보호막 원본 테스트 이관
- tests/pve_shield.rs의 원본 8개를 실제 PveScenarioInstaller/PveScriptSystem/PveShieldComponent 및 DummyMob 경로로 이관했다.
- 소스 미설치, 직접/ApplyDamage/DOT/지연 피해 차단, 회복 허용, 마지막 소스 파괴, 다중 소스, 소스 자체 피해 및 objective 상태, InstallObject 액션으로 같은 프레임 재설치, 보호막 없는 시나리오를 검증했다. 지연 피해는 원본의 예약 호출에 더해 실제 Mob.Update 처리까지 확인했다.
- .NET 및 Unity 2022.3.34f1 원본 테스트 730개 및 core 통과. unity-parity-pve-shields.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 부분 소스 대응 485/668. 원본 테스트 185개와 doctest 2개, PVE 액션/replay 나머지 원본 검증, registry/rows/match/loop, 콘텐츠 로딩 및 실제 lobby-GameScene 네트워크 대전 통합은 계속 필요하다.

### PVE 경기 구성과 확정 프레임 루프 연결
- PveScenarioRegistry/PveMatch/IPveSessionSink를 추가했다. 기본 scenario 1, 알려지지 않은 ID 오류, installer/runtime/result/script/objective 구성 및 목표→최근 대화→채널 상태 순서의 sync를 연결했다.
- 원본 registry 1개 및 pve_engine match 4개 테스트 이관. MMR/markOnline helper는 아직 미이관이다.
- BattleSessionRuntime.InitializePve가 첫 프레임 전에 한 번 scenario를 설정하고 BeforeResultCheck에서 script/objective 및 결과 판정을 실행한다. PVE 초기화 없이 프레임 진행하거나 중복 초기화하면 실패한다.
- core에서 실제 BattleSessionRuntime의 1초 생존 조건→1초 종료 유예→종료 콜백 한 번/StopRequested를 40확정프레임으로 검증했다. 봇 자동 생성 없음과 PVP 제한 시간 비활성도 확인했다. 이는 네트워크 경유 검증은 아니다.
- .NET 및 Unity 2022.3.34f1 원본 테스트 735개 및 core 통과. unity-parity-pve-match.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 부분 소스 대응 487/668. 원본 테스트 180개 및 doctest 2개 남음. 실제 콘텐츠 rows/source 로딩, PVE 종료 출력/서버 저장, 나머지 parity, lobby/GameScene 및 네트워크 대전 완료 검증은 미완료다.

### PVE 시나리오 행 변환
- PveScenarioRows와 installer/event/action/rules/shield 행 모델을 추가했다. 목록 입력 순서를 보존하고 Build에서 runtime의 읽기 전용 시나리오를 만든다. interval은 Fix64로 받는다.
- 초기 installer/objective가 없고 Survive가 아니면 null을 반환한다. PlayBgm→SetBgm 변환, null 허용 필드와 필수 필드, 정확한 enum 이름만 허용하는 검사 및 원본 오류 문구를 구현했다.
- pve_scenario_rows.rs 원본 10개 테스트를 이관했다. .NET 및 Unity 2022.3.34f1 모두 원본 테스트 745개 및 core 통과. unity-parity-pve-rows.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 부분 소스 대응 488/668. 원본 테스트 170개와 doctest 2개 남음. 이 변경은 순수 행 변환이며 실제 서버 콘텐츠 다운로드/JSON 고정 소수점 파싱 경로는 아직 없다. 나머지 parity 및 lobby-GameScene 네트워크 대전 통합도 계속 필요하다.

### PVE 대화 replay 및 BGM 원본 테스트
- pve_engine.rs의 seq/replay/state 원본 6개를 PveScriptSystem의 실제 이벤트 실행으로 이관했다.
- 유대사 이벤트만 seq 증가, 사용자별 순서/미수신 필터, 10초 초과 대화 제외와 prune 뒤 seq 유지, BGM 변경 시에만 양쪽 출력, 오래된 이벤트의 BGM snapshot 유지, 초기 빈 상태 동기화를 검증했다.
- .NET 및 Unity 2022.3.34f1 원본 테스트 751개 및 core 통과. unity-parity-pve-replay.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 부분 소스 대응 488/668, 원본 테스트 164개 및 doctest 2개 남음. 실제 콘텐츠/네트워크 전송 경로와 lobby-GameScene 대전 통합은 계속 미완료다.

### PVE 설치 및 소환기 액션 원본 테스트
- pve_engine.rs 원본 11개 이관: 웨이브 위치/소유권, InstallObject ID/HP, 소환기 교체/기본 주기/제거, 설치 ID 및 기본/override HP, batch 설치, 미설치/빈 ID 조회, lifetime 제거.
- 소환기 mock 기록 대신 실제 Spawner의 생성 개수와 시간(3초 5마리, 기본 2초 1마리)을 검증했다.
- .NET 및 Unity 2022.3.34f1 원본 테스트 762개 및 core 통과. unity-parity-pve-install-actions.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 부분 소스 대응 488/668, 원본 테스트 153개 및 doctest 2개 남음. 실제 콘텐츠/네트워크 전송과 lobby-GameScene 대전 통합은 아직 미완료다.

### PVE terminal 목표 및 보호막 부착 원본 검증
- pve_engine.rs 원본 6개 이관: Spawner보다 보스 HP 우선 override/trigger, 파괴되지 않은 terminal objective의 파괴 트리거, 보호막 단일 부착과 소스 추적, 늦게 설치한 대상 부착, 파괴된 대상 미부착, terminal 보스 소스 제외.
- 원본 TestBossMob처럼 객체를 파괴하지 않고 HP로 terminal을 표시하는 fixture를 사용해 단순 IsDestroyed 검사로 대체되지 않음을 검증했다.
- .NET 및 Unity 2022.3.34f1 원본 테스트 768개 및 core 통과. unity-parity-pve-terminal.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 부분 소스 대응 488/668, 원본 테스트 147개 및 doctest 2개 남음. 실제 콘텐츠 및 lobby-GameScene 네트워크 대전 통합은 여전히 미완료다.

### PVE 끌어오기 및 누락 초기화기 원본 검증
- pve_script_system.rs 원본 2개 이관: 왼쪽 이동 유닛만 목적지로 끌어온 뒤 제거, 건물/상대 유닛 유지, 목적지가 없으면 제자리 제거.
- pve_engine.rs 누락 초기화기 테스트 이관: 미등록 WaterSlime 초기화 실패 후 객체가 파괴 상태가 되고 이벤트가 한 번만 실행되는지 확인했다.
- .NET 및 Unity 2022.3.34f1 원본 테스트 771개 및 core 통과. unity-parity-pve-missing-prefab.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 부분 소스 대응 488/668, 원본 테스트 144개 및 doctest 2개 남음. 실제 콘텐츠 및 lobby-GameScene 네트워크 대전 통합은 미완료다.

### PVE 런타임 종료 결과 전달
- PveMatch의 원본 종료 helper 이관: PVE MMR 4개 값은 0, 온라인 복귀 대상은 음수가 아닌 사용자 ID를 순서대로 보존한다.
- BattleFrameLoop.GameEnded 이벤트에 PVE 종료를 연결했다. 결과 확정 콜백 후 오른쪽/왼쪽 결과 메시지를 순서대로 전달하고 루프가 종료된다. 기존 HandleGameEnd 콜백 설정으로 PVE 종료 연결이 덮어써지지 않는다.
- 실제 BattleSessionRuntime을 40프레임 실행하여 승리/0 MMR/콜백 순서/1회 전달/종료를 검증했다. 무승부와 패배 메시지도 확인했다. 접속 상태 및 보상 저장의 서버 연동은 아직 연결하지 않았다.
- .NET 및 Unity 2022.3.34f1 원본 테스트 772개 및 core 통과. unity-parity-pve-completion.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 부분 소스 대응 488/668, 원본 테스트 143개 및 doctest 2개 남음. 실제 콘텐츠 및 lobby-GameScene 네트워크 대전 통합은 미완료다.

### 확정 입력과 전투 런타임 실행 연결
- LockstepBattleDriver 추가. ConfirmedInputStream으로 순서/중복/충돌을 검증한 뒤 서버 tick 0을 전투 frame 1에 대응시킨다. 좌측/우측 배치와 배치 내부 순서를 보존하고 raw 고정 소수점 좌표를 MagicInputHandler에 전달한다.
- 실제 런타임 두 개에 다른 도착 순서로 확정 입력을 공급해 동일 승패/HP/마나/종료 프레임을 검증했다. 중복 입력 미실행, 충돌 거부, 동일 프레임 좌측의 종료 확정 뒤 우측 입력 거부와 마나 유지도 검증했다.
- 입력 큐 포화 또는 입력 실행 예외는 driver를 실패 상태로 고정한다. GameScene LockstepConnection과 콘텐츠 로딩 연결은 아직 미완료이며, 이 검증은 네트워크 없는 런타임 검증이다.
- .NET 및 Unity 2022.3.34f1 원본 테스트 772개 및 core 통과. unity-parity-confirmed-order.log 종료 0. 10,000프레임 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 동일.
- 원본 테스트 143개 및 doctest 2개 남음. 실제 lobby-GameScene 대전 및 결과 화면 연결은 계속 필요하다.

### LockstepConnection 런타임 연결 및 실제 패키지 컴파일
- ConfigureBattle factory, BattleInitialized/BattleCompleted 이벤트를 추가했다. 연결이 확정 프레임을 LockstepBattleSession/Driver에 전달하며, 전투 종료 시 입력 송신을 멈추고 정상 완료 이벤트를 발생시킨다.
- 재접속은 새 런타임에서 기록을 재생한다. 초기 상태 해시/참가자 순서 변경, 세션 ID/사용자/tick rate 불일치를 거부한다. .NET 및 Unity core에서 새 런타임 재생과 불일치 거부를 검증했다.
- 전체 클라이언트 컴파일에서 BotPriorityRules/PveResultChecker/SprayingAttacker/UnitCatalogue metadata의 33자리 GUID를 발견해 유효한 GUID로 교체했다. Prepare-UnityProbe에 metadata 누락/형식/중복 검사를 추가하고 hand-edited-assets 지침에 실제 패키지 컴파일 필요성을 기록했다.
- .NET 및 Unity probe 원본 772개/core/10,000프레임 해시 통과. unity-parity-battle-recovery.log 종료 0. 실제 client 프로젝트 Unity 컴파일도 unity-client-lockstep-connection-fixed.log 종료 0.
- 아직 ConfigureBattle을 호출하는 GameScene bootstrap, 콘텐츠 초기화 factory, 결과 화면 및 lobby 생성 경로가 필요하다. 실제 네트워크 대전 검증은 완료하지 않았다. 원본 143개 및 doctest 2개 남음.

### 고정 소수점 콘텐츠 스냅샷 로더
- BattleContentSnapshot/BattleContent 추가. 밸런스는 Q32.32 raw long으로 받고 기존 float DTO를 거치지 않는다. 마법 ID/이름/속성 및 양쪽 소유권을 복사해 IMagicCatalog와 DatabaseMagicParser/BossMagicParser에 연결한다.
- 파라미터와 마법 ID 중복, 알 수 없는 속성/소유 마법, 스키마 불일치를 거부한다. 로딩 후 DTO 변경 및 서로 다른 런타임 파라미터 변경이 전파되지 않으며, 소수점 최소 단위(raw +1)가 유지됨을 core에서 검증했다.
- .NET 및 Unity probe 원본 772개/core/10,000프레임 해시 통과. unity-parity-battle-content.log 종료 0. 실제 client Unity 컴파일 unity-client-battle-content.log 종료 0. Unity가 자동 생성한 Android icon 설정 변경은 되돌렸다.
- JSON 디코딩, 서버 초기 콘텐츠 생성, PlayerData/봇/PVE 구성의 전체 runtime factory와 GameScene/lobby 호출은 아직 연결하지 않았다. 원본 143개 및 doctest 2개 남음.

### 콘텐츠 기반 런타임 생성 및 매 프레임 경제 갱신 누락 수정
- 원본 WordOnlineLoopFactory의 PlayerData/ManaCharger 생성과 PveLoop의 우측 플레이어 미생성을 대조했다. BattleRuntimeFactory가 BattleContent로 파라미터/마법/보스 파서를 로딩하고 플레이어/prefab/봇/PVE 런타임을 구성한다. 세션-콘텐츠/PVE sink 사용자 불일치는 거부한다.
- 실제 BattleFrameLoop에 마나 충전/카드 드로우가 빠져 있음을 발견했다. 원본 FrameDataSystem의 입력 처리 다음, fever/bot 처리 이전 순서로 BattleEconomySystem을 연결했다. 매 프레임 양쪽 충전 후 드로우하고, 화면 어댑터용 마나/추가 카드 결과를 노출한다.
- 원본 charges_mana_and_draws_into_the_frame 이관. 초기 마나 0/빈 패, 1초 후 마나 4/카드 1장, 독립 런타임, PVE 우측 객체 미생성/종료를 core로 검증했다. 기존 완료 테스트는 실제 1초 종료 유예 중 충전과 드로우 결과(마나 44, 패 1장)를 검증하도록 수정했다.
- .NET 및 Unity probe 원본 773개/core/10,000프레임 해시 통과. unity-parity-runtime-factory.log 종료 0. 실제 client 컴파일도 unity-client-runtime-factory.log의 최종 Tundra build success 및 종료 0 확인. Unity 자동 Android icon 설정 변경은 되돌렸다.
- 남은 원본 142개 및 doctest 2개. 서버 JSON 초기화/콘텐츠 생성, 봇 metadata/persona snapshot 공급, lobby-GameScene 호출과 실제 네트워크 대전 검증은 여전히 미완료다.

### 봇 태그 및 상성 가중치 스냅샷
- BattleTagSnapshot/BattleTagCatalog 추가. 마법/객체 태그를 복사하고 ordinal 정렬·중복 제거한다. prefab→game_object 이름은 기존 UnitCatalogue.GameObjectName을 재사용한다.
- 원본 TagRepository SQL의 ANY 집합 의미를 보존해 입력 순서/중복과 무관하게 공격 태그→대상 태그 가중치를 합산한다. 가중치는 Q32.32 raw 값이며 합산 순서를 고정했다. 누락 태그는 빈 집합, 매치 중 cache invalidation은 고정 스냅샷을 유지한다.
- 실제 BotCounterEvaluator로 공격/방어 방향, 양수/음수 가중치, 최소 raw 단위, DTO 변경 독립성, 중복 태그를 core에서 검증했다. 기존 snake_case 원본 테스트를 중복 등록하지 않도록 유지했다.
- .NET 및 Unity probe 원본 773개/core/10,000프레임 해시 통과. unity-parity-tag-content.log 종료 0. 전체 client Unity 컴파일 unity-client-tag-content.log 종료 0. 자동 Android icon 설정은 되돌렸다.
- 원본 142개 및 doctest 2개 남음. 서버 JSON 초기 콘텐츠, persona/progress 스냅샷 공급, lobby-GameScene 실대전 연결은 아직 미완료다.

### 초기 스냅샷 JSON에서 런타임 생성
- BattleInitialState에 seed/세션 종류/맵/덱/콘텐츠/태그/참가자 persona·숙련도를 묶었다. 문자열 enum을 엄격히 검증하고 모든 실행 데이터는 복사해 런타임을 구성한다.
- LockstepConnection.ConfigureSnapshotBattle을 추가했다. 별도 factory가 없으면 Begin이 이 기본 경로를 사용해 검증된 initialStateJson을 JsonCodec으로 읽고 BattleRuntimeFactory에 전달한다. PVE scenario/sink 및 모델 결정 공급자는 명시적으로 주입해야 한다.
- core에서 DTO 수정 후 덱/persona 고정, 잘못된 enum/profile 거부, 시간 종료를 검증했다. 실제 Unity JsonCodec EditMode 테스트 2개 모두 통과: Int64 최대 seed 및 2^53+1 raw 정수 왕복, JSON 초기화부터 40프레임 종료. 종료 유예 중 fever로 마나가 최대 10에 도달하는 원본 동작도 반영했다.
- WebGL JSON reflection DTO 15개를 Assets/link.xml에 보존했다. XML 구문 검사 통과. IL2CPP 실행 검증은 이번 단계에서 하지 않았다.
- .NET/Unity probe 원본 773개 및 core/10,000프레임 해시 통과. unity-parity-initial-state.log 종료 0. 실제 client EditMode 결과 unity-initial-json-results-final.xml: passed=2 failed=0. 자동 Android icon 설정 변경은 되돌렸다.
- 원본 142개 및 doctest 2개 남음. 서버 초기 콘텐츠 생성, PVE JSON scenario, UI 프레임 표시, lobby/GameScene 실제 시작·종료 흐름과 네트워크 대전 완료 검증은 아직 남아 있다.

### PVE 시나리오 초기 JSON 연결
- BattlePveSnapshot 및 설치물/이벤트/액션/보호막/규칙 DTO 추가. 소환 간격은 nullable Q32.32 raw 정수로 전달하며 기존 PveScenarioRows의 검증과 변환을 재사용한다.
- BattleInitialState의 PVE 생성은 선택한 시나리오 ID와 내장 pve.scenarioId를 대조한 뒤 복사한 시나리오로 registry를 구성한다. 외부 registry에 의존하던 JSON 초기화 경로를 제거했다.
- LockstepConnection의 기본 PVE sink가 목표/대사/BGM 상태 이벤트를 노출한다. GameScene 화면 presenter 구독은 아직 연결하지 않았다. PVE JSON DTO 6개 linker 보존 추가.
- 실제 Unity JsonCodec EditMode 4개 모두 통과: 기존 정수/전투 종료 2개, PVE 간격 raw+1 왕복 및 불변 복사, PVE 대사/BGM 양쪽 각 1회 전달/우측 플레이어 없음/생존 승리/ID 불일치 거부. unity-pve-json-results.xml passed=4 failed=0.
- .NET 및 독립 Unity probe 원본 773개/core/10,000프레임 해시 통과. unity-parity-pve-snapshot.log 종료 0. 자동 Android icon 설정 변경은 되돌렸다.
- 원본 142개 및 doctest 2개 남음. 서버 초기 스냅샷 생성, PVE/봇 참가자 네트워크 규칙, UI 프레임 표시, lobby-GameScene 실제 시작·종료 대전 검증은 아직 미완료다.

### 객체 스냅샷과 기존 화면 DTO 매핑
- ObjectSnapshot은 객체 ID/prefab/위치/소유권/상태/효과/gizmo/gauge를 고정 소수점 불변 복사로 보관한다. SimObject에 원본 DrawCircle/DrawBox 저장 경로 추가.
- snapshot_mapper.rs 원본 3개 이관: 전체 필드, 효과/gizmo 복사 독립성, gauge category 덮어쓰기와 음수 max 제외. .NET 및 Unity probe 원본 776개/core/10,000프레임 해시 통과.
- GameScene.LockstepPresentationMapper가 기존 SnapshotObjectDto로 변환하며 float 변환은 이 화면 경계에서만 수행한다. 원본 wire 이름 HP/TTL 유지. FixedPhysics autoReferenced를 켜 predefined Assembly-CSharp 화면 어댑터가 공개 벡터 타입을 참조하도록 했다.
- UpdatedObjectDto의 snapshot 생성자가 master를 누락하던 부분 수정. 실제 Unity EditMode에서 위치/상태/효과/gizmo/HP·TTL/master 매핑을 검증했다. unity-presentation-contract-results.xml: passed=5 failed=0 (기존 JSON 4개 포함).
- 자동 Android icon 설정 변경은 되돌렸다. 원본 139개 및 doctest 2개 남음. 매 프레임 DTO 출력/화면 presenter 연결, 서버 스냅샷 생성 및 실제 네트워크 대전 검증은 아직 미완료다.

### 프레임 변경분·투사체 출력
- BattlePresentationOutput을 런타임의 최초 객체 생성 전에 연결했다. 원본처럼 BeginFrame에서 이전 변경분/이벤트를 인계하고 EndFrame에서 전달한다. 동기화 프레임은 컴포넌트·물리·객체 flush 이후 전체 객체와 현재 손패를 담는다.
- 객체 생성 시점의 값과 첫 변경 순서를 보존하며 같은 객체의 반복 변경은 마지막 상태로 합친다. 같은 프레임에서 사라진 gauge category는 원본 UpdatedObjectDto와 같이 마지막 값을 유지한다. 다음 프레임에는 이 병합 상태를 초기화한다.
- 기존 frame/sync DTO로 마나·카드·HP·타이머·객체·hit/shock·투사체를 변환한다. 투사체의 position/reference 양 끝점, duration, width를 보존하고 float 변환은 화면 경계에 둔다. LockstepConnection.PresentationReceived로 전달한다. 관전자 출력은 마나와 손패를 숨긴다.
- objects_info_dto_builder.rs 원본 6개를 추가 이관했다. .NET 및 독립 Unity probe 원본 782개/core/10,000프레임 해시 통과. unity-parity-frame-output-final.log 종료 0.
- 실제 client Unity EditMode 테스트 8개 통과: 기존 JSON/객체 계약, frame/sync JSON 왕복과 이벤트/투사체 타입, 프레임 경계와 관전자 정보, 같은 프레임 gauge 유지. unity-frame-output-final-results.xml passed=8 failed=0. 자동 Android icon 변경은 되돌렸고 root/client diff --check 통과.
- 원본 133개 및 doctest 2개 남음. GameScene 기존 화면 처리기 구독, 서버 초기 스냅샷 생성, 입력 응답/선택·감정표현 연결, lobby 세션 생성과 실제 네트워크 대전 종료 검증은 아직 미완료다.

### 입력 응답 ID와 GameScene 메시지 경로
- LockstepLocalInputs가 화면 요청 ID를 확정 tick/slot/index ID와 대응시킨다. 재전송에서는 같은 배치를 유지하고 뒤에 들어온 입력은 다음 배치로 넘긴다. 응답을 한 번 전달한 ID는 제거해 재접속 재생 시 중복 전달하지 않는다. 입력 범위/배치 16개/대기 중 ID 중복도 검증한다.
- LockstepBattleDriver와 로컬 요청 대응이 같은 SimulationRequestId 계산을 사용한다. LockstepConnection이 런타임 InputHandled를 받아 자기 요청의 응답만 원래 화면 ID의 MagicValidInfo로 전달한다. 전투 입력 wire 계약은 바꾸지 않았다.
- 기존 SUCCESS/FAIL_* 결과 코드와 PVE 목표/대사/BGM DTO 변환 추가. 기본 PVE sink는 자기 사용자 메시지만 PresentationReceived로 보낸다. GeneralHandler가 ServerMessage를 직접 처리하며 StompConnector.BindLockstepPresentation에서 구독/재바인딩/해제를 지원한다. 아직 실제 세션 시작 호출부에서 이 API를 호출하지 않는다.
- core 검증: 동일 배치 재전송, 복구 중 과거 tick 요청, 중복 응답 억제, 실패 응답 보존, 16개 한도, 초기화. 실제 LockstepBattleDriver에 연결해 중복 확정 프레임에서 피해 1회와 원래 요청 ID 응답 1회를 검증했다.
- .NET 및 독립 Unity probe 원본 782개/core/10,000프레임 해시 통과. unity-parity-local-input.log 종료 0. 실제 client Unity EditMode unity-input-presentation-results.xml passed=9 failed=0. 입력 결과 코드 6종과 PVE 메시지 JSON 왕복 포함.
- 원본 133개 및 doctest 2개 남음. lobby/서버 초기 스냅샷 생성, GameScene 세션 시작과 카드 입력 호출부, 선택/감정표현, 재접속 화면 복구, 결과 저장 및 실대전 종료 검증은 미완료다.

### 카드 선택·해제 확정 입력 (2026-10-27)
- GameScene 시작 경로 확인 중 기존 카드 선택/해제도 네트워크 입력임을 확인했다. 시작 호출부 전환 전에 CastCommand에 cast/selectCard/unselectCard kind를 추가해 aura 상태가 각 클라이언트에서 같은 순서로 변하도록 했다. kind 생략은 cast, 알 수 없는 값/null은 거부한다. 선택 명령의 좌표는 0만 허용한다.
- ConfirmedInputStream은 kind를 복사하고 fingerprint에 포함한다. LockstepBattleDriver는 확정된 선택/해제를 원본 CardSelectVisualizer로 실행하며 시전 응답을 만들지 않는다. LockstepLocalInputs/Connection에 선택 명령 큐 API를 추가했고 혼합 배치의 시전 응답 ID도 전체 명령 index를 따른다.
- Rust relay에 동일한 명령 enum/검증 추가. 단위 테스트 5개 및 실제 WebSocket 130 tick 중계·HTTP 이력 복구 테스트 통과: 순서 유지, kind 충돌 거부, 잘못된 좌표/종류 거부. rust-lockstep-selection.log 종료 0.
- .NET/독립 Unity probe 원본 782개/core/10,000프레임 해시 통과. unity-parity-selection-command.log 종료 0. 선택 효과 생성/해제, 선택 후 시전으로 효과 종료, 마나/응답 없음, 혼합 배치의 요청 ID, kind 복사와 충돌을 검증했다.
- 실제 Unity JSON/EditMode unity-selection-command-results.xml passed=10 failed=0. 기존 cast JSON 호환, raw 정수, 선택 종류 왕복/null 거부 포함. Rust 변경은 rustfmt 적용.
- 실제 GameScene 시작 호출부와 lobby는 이번 단계에서도 전환하지 않았다. 초기 프레임의 플레이어 준비 시점, 선택 UI와 큐 실패 처리, 감정표현/복구 화면, 서버 초기 콘텐츠/결과 검증 및 실대전 종료가 남아 있다. 원본 미이관 133개 및 doctest 2개도 남아 있다.

### GameScene 시작과 카드 입력 호출부 (2026-10-27)
- MatchedInfoDto에 lockstepSimulationVersion 및 JsonIgnore IsLockstep을 추가했다. 이 값이 있는 매치에서 StompConnector.Start가 LockstepConnection을 생성하고 화면 handler를 구독한 뒤 server/sessionId/user/token/version으로 Begin한다. 일반 STOMP 연결과 프레임 구독 루프는 시작하지 않는다. lobby가 이 필드를 보내는 경로는 아직 없다.
- CardInputSender의 시전/선택/해제는 StompConnector.TrySendCardUse/TrySendCardSelection을 사용한다. lockstep 시전의 XZ만 Q32.32 raw로 변환하며 NaN/Infinity/경계 밖 좌표를 거부한다. 원래 화면 request ID를 전달한다.
- LockstepLocalInputs.HasCapacity와 Connection.CanQueueCommands로 첫 확정 프레임 이전, 복구 중, 종료 후, 큐 부족 상태를 검사한다. CardUI 클릭과 CardInputSender 선택 교체/전체 해제에서 필요한 명령 수를 먼저 확인해 UI와 확정 입력의 선택이 갈라지지 않게 했다. 준비 전의 플레이어 검색 오류도 피한다.
- lockstep 시전은 3초 경과만으로 선택을 복구하지 않는다. 확정 응답 또는 연결 종료까지 기다려 재연결 중 같은 카드를 다시 시전하지 않게 한다. 전투 계산 종료는 무음 감시 종료만 알리며 MMR/보상 결과를 만들어내지 않는다.
- .NET 원본 782개/core/10,000프레임 해시 통과. 실제 Unity EditMode unity-scene-input-final-results.xml passed=12 failed=0. 매치 JSON/계산 속성 제외, 실제 StompConnector→LockstepConnection→로컬 배치의 좌표/요청 ID/선택 kind, 첫 프레임·복구·용량 제한을 검증했다. 컴파일 중 Global.Exception namespace 충돌은 System.Exception으로 수정했다.
- 자동 Android icon 변경은 되돌렸다. 실제 매칭 서버의 초기 스냅샷/세션 생성, 지원 버전 고정, 관전자·봇/PVE 참가자 규칙, 감정표현, 복구 화면 처리, 서버 결과 검증/저장, 완주 실대전 및 원본 테스트 133개/doctest 2개는 남아 있다.

### DB 콘텐츠 읽기와 raw JSON 생성 (2026-10-27)
- ac-data/game/lockstep_snapshot.rs 추가. REPEATABLE READ READ ONLY 트랜잭션에서 파라미터·마법 목록·양쪽 사용자 마법 소유권·마법/객체 태그·상성 규칙을 읽는다. 덱/프로필/PVE 시나리오는 아직 이 묶음에 포함하지 않았다.
- 기존 DB float8은 서버 입력 경계에서 한 번 Q32.32 raw 정수로 변환한다. 0 방향 절삭, 유한값/범위 검사, NULL 파라미터=0의 기존 repository 동작을 유지한다. 마법 ID와 태그는 정렬하며 상성은 같은 태그 쌍을 합산한 뒤 변환한다.
- ac-game-server/lockstep_content.rs가 BattleInitialState의 content/tags JSON을 만든다. 기존 DB 대문자 element를 클라이언트 이름으로 바꾸며 raw 정수는 JSON i64로 보존한다. 아직 세션 생성 endpoint/프로세스 wiring에서 호출하지 않는다.
- ac-data raw 변환 단위 테스트 2개, 서버 JSON 테스트 1개 통과. 2^53+1 정수 보존, 음수 raw 가중치, field 이름, 정렬 및 소유권 구분 확인.
- WSL Docker의 기존 postgres:16 이미지로 전용 임시 lockstep_snapshot_test DB를 만들었다. 실제 SQL 통합 테스트 1개를 --ignored로 명시 실행해 조회/NULL/정렬/태그/가중치/스냅샷 독립성/비정상값 거부를 검증했다. 동시에 30회 원자적 밸런스·마법 이름 갱신과 30회 snapshot 조회를 수행해 섞인 시점의 값이 나오지 않음을 확인했다. rust-snapshot-database-final.log 통과. 테스트 fixture 스키마이며 전체 Flyway 운영 스키마 검증은 아니다.
- 테스트 컨테이너는 종료·자동 삭제했다. root/game-rust diff --check 통과. client 변경 없음. 원본 782/915개 이관 상태는 그대로이며, 실제 매칭 및 대전 종료까지의 통합은 아직 미완료다.

### 선택 덱·참가자 프로필 스냅샷 (2026-10-27)
- 같은 DB 읽기 트랜잭션에서 참가자별 선택 덱과 novice progress를 읽고, 음수 ID의 봇 persona를 추가했다. 덱 count를 물리 카드 ID 목록으로 확장하고 기존 novice_progress의 float4→Java double 보정, 봇 숙련도 1.0, persona 누락 시 Default Bot 규칙을 재사용한다.
- load_with_decks는 lobby의 매칭 시 확정 덱을 받는다. 제공된 쪽은 현재 선택 덱을 읽지 않고 원본 순서·중복을 그대로 사용한다. 기존 DeckService와 같이 15장 및 마법 존재만 검사하며 소유권 판단은 별도 원본 계약을 유지한다.
- JSON에 leftDeck/rightDeck/profiles 추가. persona의 tier/temperament/brainType을 클라이언트의 정확한 enum 이름으로 명시 매핑한다. counterAggressionRaw·noviceProgressRaw는 i64이며, 추론 서비스 자격정보는 읽거나 전송하지 않는다.
- 임시 Postgres SQL 통합 테스트 통과: 선택 덱 중복, 0.15 숙련도 raw, 봇 숙련도/프로필/모델명 정규화/기본 persona, 확정 덱 우선/잘못된 장수·마법 거부. 동시 30회 덱·밸런스·마법 이름 변경과 snapshot 조회의 일관성도 검증했다. rust-profile-database-final.log 종료 0.
- 서버 JSON 테스트 rust-profile-wire.log 통과. 임시 ac-lockstep-profile-test 컨테이너는 종료·자동 삭제했다. root/game-rust diff --check 통과. client에는 변경이 없으며 원본 782/915개 상태는 그대로다.
- PVE 시나리오·세션 seed/map 결합, 실제 세션 생성 endpoint/프로세스 wiring 및 lobby 응답/복구 저장, 결과 검증·저장과 완주 실대전은 아직 미완료다.

### PVE DB 스냅샷과 초기 JSON (2026-10-27)
- pve_scenario_repository의 연결 기반 조회를 추가해 설치물·목표·규칙·이벤트·대사·행동·실드·stage map을 콘텐츠와 같은 REPEATABLE READ 트랜잭션에서 읽는다. 기존 pool 조회 API와 알 수 없는 시나리오 판정은 유지했다.
- lockstep_pve는 다섯 행동 종류를 클라이언트 BattlePveSnapshot 계약으로 변환한다. nullable 필드와 DB 순서를 보존하고 spawner interval은 Q32.32 raw로 바꾸며 비유한 값을 거부한다. content_fields에 scenarioId/pve를 포함했다.
- rust-pve-wire.log: 서버 JSON 테스트 2개 통과. rust-pve-database.log: 임시 PostgreSQL 통합 테스트 통과. PVE 배열 순서·기본 규칙·Survive·map 누락·없는 시나리오 거부와 동시 30회 콘텐츠/덱/PVE HP 변경의 읽기 일관성을 확인했다.
- 임시 ac-lockstep-pve-test 컨테이너 종료·자동 삭제. client 변경 없음, 원본 이관 782/915개 유지. 세션 seed/type/map 조립과 실제 생성 endpoint/lobby 연결은 다음 작업이며 아직 전체 네트워크 대전 완주는 검증하지 않았다.

### 초기 상태 메타데이터와 DB 기반 생성 API (2026-10-27)
- lockstep_content.initial_state는 schemaVersion/randomSeed/sessionType/map과 콘텐츠/PVE 스냅샷을 결합한다. GameMapSelector를 재사용해 강제 맵/PVE stage 맵/맵 누락 Grassland 규칙을 유지하고 클라이언트 enum 이름으로 변환한다. seed는 i64 전체 범위를 보존한다. PVE와 snapshot의 불일치 및 알 수 없는 stage 맵은 거부한다.
- /api/server/lockstep-battles 추가. WORDONLINE_SERVER 권한 아래 참가자·확정 덱·전투 유형을 받아 DB에서 스냅샷을 읽고 서버가 seed와 맵을 정한 뒤 기존 registry에 생성한다. main이 AppState.lockstep_database에 공유 pool을 연결한다. 호출자가 initialState를 주입하는 것은 deny_unknown_fields로 거부한다.
- 아직 봇/PVE 입력 슬롯이 연결되지 않았으므로 새 API는 양수 ID 두 명의 PVP/Practice만 받는다. 임시 제한이며 전체 목표의 완료 조건이 아니다. lobby 호출·attempt 중복 방지/영속 복구·지원 버전 고정 및 서버 상태/용량 연동도 추가로 필요하다.
- rust-initial-metadata.log 2개 통과. rust-battle-endpoint.log 단위 7개 및 실제 WebSocket 통합 1개 통과. rust-battle-api-guards.log 실제 HTTP API 권한/DB 미설정/참가자 검증/초기 상태 주입 거부 1개 통과. main 포함 서버 빌드 성공. root/game-rust diff --check 통과.
- 실제 DB 생성 API 성공→클라이언트 초기화와 lobby 연결/대전 완주는 아직 검증하지 않았다. client 변경 없음, 원본 테스트 이관 782/915개 그대로이며 남은 원본 133개/doctest 2개도 계속 필요하다.

### DB 생성 성공 경로와 lobby 복구 버전 (2026-10-27)
- DB fixture를 crates/data/tests/fixtures/lockstep_snapshot.sql로 추출해 data/server 테스트가 공유한다. 서버 테스트 support에 선택적 DB pool 주입을 추가했다.
- rust-battle-api-database.log: 임시 Postgres에서 실제 HTTP 생성 성공 테스트 통과. 초기 상태의 해시·맵·덱·소유권·raw 값을 확인하고 DB 수정 뒤 양 참가자의 재조회 결과가 최초 SessionStart와 같은지 검증했다. 제3자 조회도 거부된다. 임시 컨테이너는 종료했다.
- lobby issue #102 생성, assignee dev-yunseong/feature 확인. 사용자 요청대로 lockstep 브랜치 유지. SessionReadyResponse→MatchedInfoDto→SessionRecoveryInfo→복구 MatchedInfoDto에 lockstepSimulationVersion을 전달한다. 복구 websocket 주소도 보존하며 기존 JSON의 없는 필드는 null이다.
- MatchTicket 직렬화, 복구 신규/기존 JSON, 실제 LegacyGameMatchService 전달 테스트 추가. Windows JDK 없음으로 WSL JDK21에서 gradlew test 실행. compileKotlin/compileJava는 통과했으나 compileTestKotlin에서 기존 src/test/java/.../matching 디렉터리 읽기 실패. 해당 경로는 양 OS에서 존재·조회 확인. 종료 후 --no-watch-fs 재시도는 WSL 시작 자체가 Insufficient system resources로 실패했다. 새 lobby 테스트는 아직 실행 검증되지 않았으며 다음 작업에서 같은 변경으로 재검증해야 한다.
- lobby 실제 생성 호출 전환/attempt 멱등성/서버 liveness·결과 연동 및 봇/PVE 입력 슬롯 연결은 남아 있다. 원본 782/915개와 전체 대전 완주 미검증 상태는 유지된다.

### lockstep 생성 재시도 식별 (2026-10-27)
- CreateBattleRequest에 attemptId/sessionId를 필수로 추가하고 registry가 지정 sessionId로 생성한다. 식별자는 영숫자·하이픈·밑줄 1~128자로 검사한다.
- Session에 최초 생성 요청을 보존한다. 동일 attempt/session/참가자/덱/type/version 요청은 DB 재조회와 seed 재생성 없이 같은 SessionStart를 반환한다. 같은 attempt 또는 session에 다른 요청을 보내면 거부한다. async 생성 gate로 동시 조회/생성 경쟁을 막는다.
- rust-lockstep-idempotency.log 단위 7개 + 실제 HTTP/WebSocket 2개 통과. rust-battle-api-retry-database.log 실제 DB 통합 통과: 지정 ID, DB 변경 이후 동시 재시도 결과 일치, 참가자/덱/attempt/session 충돌 거부. 임시 ac-lockstep-retry-test 컨테이너 종료.
- 이는 프로세스 내 retention 기간의 멱등성이다. 프로세스 재시작/다른 호스트의 중복 배치와 영속 복구는 미완료다. lobby 실제 생성 호출 전환 및 서버 상태/liveness 연결도 남아 있다.
- lobby WSL 재가동 가능 확인 후 JDK21 gradlew test --no-watch-fs --max-workers=2 실행. 현재 tool session 75307은 살아 있으며 compileTestKotlin에서 KotlinCompilerClient.connectAndLease 대기 중이다. WSL Gradle daemon PID1081, client PID952; jcmd 스레드 덤프로 실제 연결 대기 확인. 재시작하지 말고 같은 handle을 확인할 것. 로그 client/Tools/LockstepProbe/.generated/lobby-lockstep-recovery-final.log. 아직 새 lobby 테스트 통과를 주장하지 않는다.

### lobby 실제 호출과 readiness/liveness 연결 (2026-10-27)
- 서버 /api/server/lockstep-matches는 기존 DB 생성/멱등 경로를 사용하면서 attemptId/sessionId/ready/serverUrl/webSocketUrl/instanceId/lockstepSimulationVersion을 반환한다. /api/server/lockstep-battles/{id}/active는 서버 권한 아래 종료·retention·입력 timeout을 검사한다.
- lobby LockstepProperties 추가: gameserver.lockstep.enabled 기본 false, simulation-version 기본 lockstep-v1. 활성화된 사람 2명 PVP/Practice는 새 생성 API를 호출하고 버전 일치를 검사한다. 복구 및 ticket liveness는 버전이 있으면 lockstep active API를 사용한다. 봇/PVE와 기본 활성화는 아직 전환 전이며 전체 목표는 유지된다.
- rust-lockstep-ready.log 병렬 빌드는 Windows paging file 부족으로 mmap 실패. -j 1로 재검증한 rust-lockstep-ready-unit.log 단위 7개 통과. rust-ready-api-database.log 실제 PostgreSQL/HTTP 테스트 통과: readiness ID/version/instance 및 active 권한·없는 세션. 임시 컨테이너 종료.
- lobby의 기존 tool session75307/PID952+1081이 KotlinCompilerClient RMI에서 이전 데몬에 연결 대기하는 것을 확인했다. 이 작업 소유 프로세스만 종료한 뒤 -Pkotlin.compiler.execution.strategy=in-process --no-daemon --no-watch-fs --max-workers=2로 실행해 컴파일 성공.
- lobby-lockstep-inprocess.log 전체261개: 3실패/21skip. 신규 LockstepRecoveryContractTest2, MatchTicketSerializationTest3, LegacyGameMatchServiceTest14는 XML로 모두 통과 확인. 실패는 DataControllerTest 조회 timeout1 + 기본인자 추가로 Mockito 2인자 matcher가 깨진 liveness/lostreport2. 기존 2인자 overload 유지와 legacy 호출 분기로 후자 수정.
- 전체 재검증 tool session44512 살아 있음, 로그 client/Tools/LockstepProbe/.generated/lobby-lockstep-overload-fix.log. 같은 handle을 계속 확인할 것. 새 overload 수정 이후 전체 성공은 아직 미확인이다.
- 생성 상태/용량 연동, 지원 버전 고정, 영속 복구·다중 호스트 중복 생성, 봇/PVE·관전자·감정표현, 결과 검증/저장 및 전체 대전 완주와 원본133개/doctest2개는 계속 남아 있다.

### 지원 simulation version 고정과 테스트 재검증 (2026-10-27)
- C# LockstepVersion.Supported 및 Rust SIMULATION_VERSION을 lockstep-v1로 고정했다. Connection.Begin과 SessionStart.Validate, 서버 raw/DB 생성 모두 미지원 버전을 거부한다. 서로 같은 미지원 버전을 보내도 통과하지 않는다.
- version-pin-parity.log .NET 원본782개/core/10000프레임 해시 통과. rust-version-unit.log 7개 및 rust-version-http.log HTTP/WebSocket2개 통과. 실제 Unity unity-version-pin-results.xml 12 passed/0 failed. Unity 자동 Android icon 변경만 복원했다.
- lobby-lockstep-overload-fix.log 전체261개 중 1실패/21skip. liveness/lostreport Mockito 실패는 해결(각5/10개 통과 XML 확인). 남은 DataControllerTest 첫 조회는 단독 재실행 lobby-data-timeout-check.log에서도 5초 blocking read timeout으로 실패하고 나머지3개는 통과했다.
- DataControllerTest에 테스트 클라이언트 대기시간15s만 지정해 응답 내용 검증까지 도달하는지 확인 중이다. 운영 timeout과 응답 검증식은 그대로다. 전체 테스트 tool session31382 살아 있음, 로그 client/Tools/LockstepProbe/.generated/lobby-lockstep-test-timeout.log. 같은 handle을 이어서 확인할 것. 성공 주장은 아직 하지 않는다.
- 전체 이관782/915 유지. bot/PVE·관전자·감정표현 네트워크 연결, 결과 검증/저장, 플랫폼 완주 및 원본133개/doctest2개는 아직 미완료다.

### 봇/PVE 입력 슬롯과 생성 연결 (2026-10-27)
- 서버 참가자 검증은 0/중복/사람이 없는 조합을 거부하고 사람+음수 bot/PVE 조합을 받는다. 음수 ID로 입력/구독할 수 없으며 advance가 그 슬롯에 빈 입력을 채운다. 사람 입력과 tick 시간이 모두 있어야 확정한다.
- DB 생성은 PVE 시나리오(기본1)를 읽고 우측 덱을 비운다. PVE는 양수 좌측/-1 우측만 허용한다. 비PVE 모델 봇은 확정 decision stream이 아직 없어 명시 거부하며 규칙 봇으로 대체하지 않는다.
- 클라이언트 SessionStart는 사람+봇을 검증한다. Connection.Begin의 UUID 제한이 실제 lobby의 bot-/pve-/숫자 세션 ID와 충돌함을 발견해 서버와 같은 영숫자/하이픈/밑줄 1~128자 검증으로 바꿨다.
- lobby의 활성화된 lockstep 경로는 사람이 있는 PVE/봇 연습전을 포함한다. PVE null uid2는 -1로 보낸다. 사람 없는 봇 대전/관전자 경로는 아직 기존 경로다.
- rust-bot-slots.log 단위8개, rust-pve-bot-api.log 실제 DB 생성(생존PVE/규칙봇/모델봇거부), rust-bot-websocket.log 실제 HTTP/WebSocket3개(사람1명만 접속한 봇전3tick 포함) 모두 통과. 임시 Postgres 종료. bot-session-id-parity.log 원본782/core/10000프레임 해시 통과.
- lobby-lockstep-test-timeout.log 전체261개 실패0/skip21 XML 확인. 이후 PVE/봇 라우팅 변경과 해당 테스트 확장으로 전체 재검증 시작: tool session69295 살아 있음, client/Tools/LockstepProbe/.generated/lobby-pve-bot-routing.log. 이 실행을 이어 확인할 것. 최근 Connection.Begin ID 변경 이후 실제 Unity EditMode 재검증도 필요하다.
- 모델봇 decision 전달, 봇끼리 대전/관전자, 결과 검증·저장/보상, 영속 복구, 초기 상태→실제 GameScene 완주, 원본133개/doctest2개 및 플랫폼 검증은 아직 미완료다.

### 독립 클라이언트 프로세스의 네트워크 전투 종료 (2026-10-27)
- Tools/LockstepProbe에 --network-battle 모드와 NetworkBattleProbe를 추가했다. HTTP 초기 상태를 검증해 실제 BattleInitialState/LockstepBattleSession을 생성하고 ClientWebSocket의 STOMP 확정 입력으로만 전투를 진행한다. 테스트 인증정보는 환경으로 전달한다. .NET 전용 분기로 Unity probe의 Program 복사를 유지한다.
- game-rust lockstep_client_network 통합 테스트는 임시 PostgreSQL fixture와 실제 HTTP/WS 서버를 열고 dotnet 클라이언트를 별도 프로세스 두 개로 실행한다. 각 프로세스가 독립적으로 초기 상태를 읽고 입력을 제출한다.
- network-client-cast-final.log 통과: 빈 손패 시간 종료는 양쪽40프레임/HP100:100/무승부. 실제 lightning_explosion 시전은 손패 확인 후1회 승인, 양쪽53프레임/HP100:0/RightPlayer 패배. 초기 hash와 결과 요약이 두 프로세스에서 같았다. 이는 해당 두 시나리오의 엔진/네트워크 검증이며 전체 상태 해시·모든 마법·GameScene 화면·결과 영속 저장 검증은 아니다.
- 최초 cast 검증은 첫 카드를 받기 전에 전송해 FailLackOfCard였고, probe가 실제 손패를 보고 시전하도록 수정했다. 전투 로직은 바꾸지 않았다. 임시 DB 컨테이너가 외부에서 없어져 한 번 PoolTimedOut; 새 컨테이너에서 재실행 성공. 최종 cleanup 시 해당 새 컨테이너도 이미 없음을 확인했다.
- lobby-pve-bot-routing.log 전체 테스트 BUILD SUCCESSFUL 확인. 원본이관782/915 유지.
- 실제 Unity ID/봇 참가자 변경 재검증 tool session75912 실행 중. 로그 client/Tools/LockstepProbe/.generated/unity-bot-session-id.log, 결과 unity-bot-session-id-results.xml. 같은 handle을 이어 확인하고 Unity 자동 Android icon 변경이 있으면 해당 변경만 확인 후 복원할 것.
- PVE/봇 네트워크 완주, 모델 decision stream, spectator/bot-only, 결과 검증/저장·보상 및 GameScene 실제 매치 종료 UI, 원본133개/doctest2개와 플랫폼 결정론 검증은 남아 있다.

### PVE와 Rule 봇의 실제 네트워크 전투 종료 검증 (2026-10-27)
- NetworkBattleProbe에 IPveSessionSink를 연결하고 목표 출력 수를 보고한다. DB→HTTP 초기 상태→STOMP 확정 입력→동일 C# runtime 경로로 PVE 생존 승리를 검증했다.
- lockstep_client_network 통합 테스트를 네 가지로 확장했다. network-pve-practice.log: PVP 무승부40프레임, 사람 마법 시전 승리53프레임, PVE 생존 승리40프레임/목표출력4회, Elite Rule 봇의 마법 시전 승리53프레임. 사람 2명 시나리오는 별도 클라이언트 프로세스들의 종료 보고가 동일하다. 봇/PVE는 사람 1명과 서버 자동 빈 입력을 사용한다.
- 봇 테스트는 실제 lobby 계약대로 Practice를 사용한다. PVP로 생성했던 초기 fixture는 봇 활성화 대상이 아니었다. Elite persona와 마법의 명시 피해량을 설정해 lethal 판단 경로를 검증했다. 전투 동작 자체는 이번 단계에서 변경하지 않았다.
- unity-bot-session-id-results.xml 12 passed/0 failed 확인. 자동 Android icon 변경만 복원했다. .NET probe 빌드 성공(기존 Fix64 unreachable 경고4개), 대상 Rust clippy -D warnings와 root/client/game-rust diff --check 통과.
- 분리 실행한 WSL Docker가 사라져 PoolTimedOut이 발생했다. foreground docker run 실행 세션을 유지한 후 전체 네트워크 테스트 통과. 이 방식으로 다음 로컬 DB 검증을 실행한다.
- 원본 이관782/915는 유지된다. 남은133개/doctest2개, GameScene 실제 UI 완주/재연결, 모델 봇 결정 스트림, 결과 검증·저장·보상, 관전자/bot-only, 영속 복구와 플랫폼 결정론 검증은 계속 남아 있다. headless 네트워크 통과를 전체 전환 완료로 간주하지 않는다.

### 소환 위치 원본 테스트 16개 이관 (2026-10-27)
- CastPlacementParityTests를 추가하고 ParityTests 실행 목록에 연결했다. 원본 cast_placement.rs의16개 입력/기대 결과를 대응시켰다: 반경 합의0.6 겹침, 공중/비소환 예외, 안쪽 링과 방향 순서, 맵 경계/사거리, 물 칸 가장자리/모서리, 다리, 빈자리 탐색.
- 비소환과 공중 마법의 검사 생략은 실제 MagicInputHandler, Player prefab, 카드 사용 경로로 검증한다. 단위 조건을 테스트용 분기로 재구현하지 않았다.
- placement-parity.log에서 원본798개/core/10000프레임 통과. latest-parity.log 및 원본 대응표 갱신:915개 중798개 verified,117개 remaining. doctest2개는 별도 남음.
- Prepare-UnityProbe 후 Unity2022.3.34f1 별도 probe 프로젝트 실행도798개 통과, 종료코드0. 로그 unity-placement-parity.log의 최신 실행에서 PASS ported tests=798과 PASS ticks=10000 확인. .NET/Unity traceSha256은 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D로 동일하다. 기존 로그 앞부분의 임시 import 오류와 구분한다.
- root/client diff --check 통과. graphify 실행 파일은 없어 AST 갱신은 실행할 수 없었다. 전체 목표는 유지하며 결과 저장/UI 완주와 남은 테스트·플랫폼 검증 등은 아직 완료되지 않았다.

### 바람·물 prefab 원본 테스트 14개 이관 (2026-10-27)
- WindPrefabParityTests7개와 WaterPrefabParityTests7개를 원본 implement/wind/mod.rs 및 implement/water/mod.rs에 대응시켰다. ParityTests 실행 목록에 두 suite를 연결했다.
- 바람: WindSpirit 공중 mask/수직 사거리, BombSprite HP와 물리 컴포넌트, 폭탄·폭발, WindBlade trigger/radius, WindSlime 지상 mask, WindSummon HP/trigger,7종 등록을 검증했다.
- 물: SeaSerpent Any mask/사거리/HP/물길/충돌체, WaterSlime의 aqua_archer.attack_range와 공격 주기/질량, 두 TidalWarhead의 공통 component와 독립 이름, 폭발 수명, WaterField 지면 배치·효과, WaterShot 효과,7종 등록을 검증했다.
- water-wind-prefab-parity.log 및 Unity 별도 probe unity-water-wind-prefab.log에서812개/core/10000프레임 통과. Unity 종료코드0, .NET과 Unity traceSha256은 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D로 동일하다.
- 대응표 갱신 결과915개 중812개 verified,103개 remaining. doctest2개 별도. root/client diff --check 통과. graphify 실행 파일은 여전히 없어 갱신 불가. 전체 목표는 아직 진행 중이다.

### 자연 prefab 및 사망 효과 allowlist 원본 테스트 8개 이관 (2026-10-27)
- NaturePrefabParityTests에 남은5개를 추가했다. GiantVine의 시작 피해/진화/효과/수명, LeafField의2종 효과와 지면 배치, LeafSlime/SeedSpirit 각 매개변수, VineToss,6종 등록을 확인한다. 기존 서로 다른 HP/radius와 SeedNest 생성/만료 검증도 유지했다.
- PrefabAllowlistParityTests3개 추가: 전기 에너지7종 포함/5종 제외, 바위 잔해3종 중간/4종 작은 크기 및13종 제외, misc36종 등록과 실제 생성 후 prefab 이름 확인. 원본 parameter enum의 DB 이름으로 모두1인 PrefabParameterFixture를 만들었다. 실제 Spawn은 Start까지 실행하므로 ManaWell용 player state도 제공한다.
- allowlist-all-parity.log의820개/core/10000프레임 통과. Unity 별도 probe unity-nature-allowlist.log에서도820개와10000프레임 통과, 종료코드0. traceSha256은 .NET/Unity 모두 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D이다.
- 원본 대응표915개 중820개 verified,95개 remaining으로 갱신했다. doctest2개 별도. root/client diff --check 통과. graphify는 설치되지 않아 갱신 불가.
- 원본 잔여 테스트는 DTO18개, game_loop12개, map selector7개, random7개 등이다. GameScene UI 완주와 결과 검증/저장·보상, 모델 봇, 영속 복구, 플랫폼 결정론 등 전체 목표는 계속 남아 있다.

### 전투 루프와 결과 전달 원본 테스트 8개 이관 (2026-10-27)
- BattleLoopParityTests에 word_online_loop5개와 game_loop 동기 주기1개를 이관했다. 최초 프레임/0.5초마다 snapshot, 사이 프레임 미생성, production systems 전체 프레임,20프레임 종료 유예/최초 패자 유지/단회 결과/봇 정지/마지막 출력, timeout clock1회 읽기를 검증한다.
- BattleFrameLoop.SyncIntervalFrames를 분리하되 IsSyncFrame의 잘못된 tickRate 거부 순서는 유지했다.
- BattleResult.Broadcast에 오른쪽→왼쪽 동일 결과/계산된 MMR 전달을 구현하고 실제 PVE 종료 경로에 연결했다. ResultCheckerParityTests2개로 최초 패자/승자ID/양쪽결과와 무승부를 검증한다. PVP loop 테스트는 결과 callback을 주입한다. PVP의 실제 저장/MMR 산정/네트워크 결과 제출 및 UI 연결이 완료된 것은 아니다.
- loop-result-final.log 및 Unity 별도 probe unity-loop-result.log에서828개/core/10000프레임 통과, Unity 종료코드0. 두 런타임 traceSha256은 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D이다.
- 대응표915개 중828개 verified,87개 remaining으로 갱신. doctest2개 별도. root/client diff --check 통과. graphify 명령은 없어 AST 갱신 불가. 전체 목표는 유지한다.

### Java 난수 수열 원본 테스트 5개 이관 (2026-10-27)
- JavaRandom에 NextInt/NextLong/NextBoolean을 추가했다. NextLong은 Java처럼 하위 signed int를 더하며 Next32의 unchecked 변환을 명시했다. 기존 NextBound/Shuffle/NextFraction/NextFloatFraction 호출 순서는 유지했다.
- RandomParityTests5개: 원본 OpenJDK21 시드별 정수/long/boolean, 일반·2의거듭제곱·rejection sampling bound, double/float 분수 수열. 실수의 IEEE 비트 기대값은 테스트에서 정수 연산으로 Q32.32에 내리고 raw 값과 비교한다. 원본 float 비트 자체와의 동일성을 주장하는 테스트가 아니다.
- random-parity.log 및 Unity 별도 probe unity-random-parity.log에서833개/core/10000프레임 통과. Unity 종료코드0. .NET/Unity traceSha256은 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D로 동일하다.
- 대응표915개 중833개 verified,82개 remaining으로 갱신했다. doctest2개 별도. 난수 원본 중 Gaussian/bounded default2개와 map selector7개는 아직 미이관이다. 서버의 초기 상태 map 선택은 현재 원본 GameMapSelector를 그대로 사용하고 snapshot으로 고정한다.
- root/client diff --check 통과. graphify 미설치로 갱신 불가. 전체 목표는 계속 진행 중이다.

### 범위 난수와 Gaussian 고정 소수점 이관 (2026-10-27)
- JavaRandom.NextRange/NextLongBound에 Java rejection sampling과 overflow 폭 분기를 이관했다. NextFractionRange/NextFloatRange/NextFloatBound는 기존 난수 소비 횟수를 유지하고 Q32.32로 범위를 계산한다. 표현 불가능한 범위 폭은 checked overflow로 거부한다.
- NextGaussian은 polar rejection과 두 번째 값 cache를 유지한다. 작은 square에서 나눗셈 중간값 overflow를 피하도록 Ln의 제곱근을 먼저 나눈다. 상태 검증용 HasGaussianSpare/GaussianSpare를 노출했다. 전체 상태 직렬화 구현은 여전히 별도 남아 있다.
- 원본 bounded_default_methods_match_java/next_gaussian_matches_java2개를 이관했다. 정수 기대값은 정확히 같고, 실수 기대값은 원본 IEEE 비트로부터 변환하여1e-6 허용 오차로 비교한다. 이 오차는 해당 테스트 시드의 검증 기준이며 모든 입력의 원본 비트 동등성 보장은 아니다.
- 추가10000회 혼합 int/long/Gaussian 호출에서 결과와 RNG/cache 상태를 canonical BinaryWriter 바이트로 해시했다. .NET random-trace-parity.log와 Unity unity-random-complete.log 모두10DE04CD7DE82D8240FAB434C14DBBA83B84AD248B56B1712F4034EE9A99A5B3 일치.
- .NET/Unity835개/core/물리10000프레임 통과, Unity 종료코드0. 물리 trace는 기존 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 유지. 대응표915개 중835개 verified,80개 remaining. doctest2개 별도.
- root/client diff --check 통과. graphify 미설치. 아직 전체 전투/GameScene/결과 저장/플랫폼 검증 등 전체 목표는 완료되지 않았다.

### 다중 수신자 프레임 출력과 원본 테스트 8개 이관 (2026-10-27)
- BattleSessionOutput을 추가했다. 양쪽 플레이어와 선택적 관전자 출력에 공통 이벤트를 한 번만 Drain하고 개별 배열로 복사한다. 구독자가 없으면 관전자 payload를 만들지 않고, 구독 변경을 BeginFrame에서 반영한다. 관전자의 Cards/Mana는 비우며 sync 때 각 플레이어는 자기 손패를 받는다.
- BattlePresentationOutput에 내부 BeginFrame(events)/SkipFrame/CurrentFrame을 추가했다. 기존 단일 viewer 경로는 유지하고 잘못된 context에서 이벤트 큐를 비우지 않도록 검증한다. 새 runtime .meta 추가.
- FrameOutputParityTests: frame_data_system5개와 sync_frame_data_system3개 이관. 이벤트가 세 수신자 모두에 전달되고 배열 수정이 다른 수신자에 전파되지 않으며 다음 틱에 중복되지 않는 검사 추가.
- NetworkBattleProbe에서 실제 runtime에 BattleSessionOutput을 주입했다. network-frame-output.log의 실제 DB/HTTP/STOMP 네 가지 전투(PVP 무승부40,사람시전승리53,PVE생존40,Rule봇승리53프레임)가 모두 통과했다. 각 확정 틱에 모든 로컬 수신자 출력 수가 일치하고 관전자 출력에 private hand/mana가 없는지 검사한다. 실제 관전자 네트워크 입장은 아직 구현되지 않았다. 임시 DB 컨테이너 정상 종료.
- frame-output-final.log 및 Unity 별도 probe unity-frame-output.log에서843개/core/10000물리프레임 통과, Unity 종료코드0. RNG10000회 trace 10DE04CD7DE82D8240FAB434C14DBBA83B84AD248B56B1712F4034EE9A99A5B3 및 물리 trace BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 유지.
- 대응표915개 중843개 verified,72개 remaining. doctest2개 별도. root/client diff --check 통과. graphify 미설치. GameScene 실제 관전/결과 UI, 검증·저장·보상 등 전체 목표는 아직 진행 중이다.

### Unity 메시지 계약 원본 테스트 10개 이관 (2026-10-27)
- LockstepWireParityTests에서 실제 LockstepPresentationMapper와 JsonCodec을 사용해 result, pve_objective, magic_valid, result_codes_spellings, objects_info, empty_objects_info, frame, broadcast_frame_has_no_cards_and_no_mana, box_gizmo_keeps_box_size, sync를 검증한다. JSON 속성 순서는 무시하며 구조·값과 역직렬화 후 재직렬화를 비교한다. 전체 JSON 문자열의 바이트 일치를 주장하지 않는다.
- Result mapper에 승패와 평면 MMR 필드를 연결했다. 실제 서버 결과 제출·저장 또는 ResultScene 연결이 완료된 것은 아니다.
- Circle gizmo의 boxSize를 null로 보존하고 nullable Vector3도 x/y/z만 출력하도록 Vector3JsonConverter를 확장했다. Box 렌더링은 누락 크기에 기존 영벡터 기본값을 유지한다. ShockEvent.targetId를 추가하고, 참조되지 않는 SnapshotObjectDto.hp/maxHp를 제거해 원본 계약에 없는 필드가 출력되지 않도록 했다.
- Unity 전체 WordOnline.Tests 실행에서 647개 중 646개 통과, sync의 불필요한 hp/maxHp 출력 1개 실패를 확인했다. 해당 필드 제거 후 lockstep·frame contract·vector converter 관련 31개가 모두 통과했다(unity-wire-complete-results.xml, 종료코드 0). 마지막 수정 이후 전체 647개를 재실행하지는 않았다.
- 대응표 도구는 C# Property("OriginalSimulationTest", ...)와 최신 NUnit XML을 읽는다. Unity 소스 변경 후 오래된 결과는 통과로 집계하지 않는다. 기존 .NET 원본 843개와 Unity 원본 10개를 합쳐 915개 중 853개 verified, 62개 remaining이다. doctest 2개는 별도다.
- 테스트 중 생성된 Android 아이콘 설정과 사운드 프로필의 공백 변경은 복구했다. root/client diff --check 통과. Graphify 명령이 없어 AST 갱신은 수행하지 못했다. 전체 전투 이관·결과 저장·GameScene 완주·플랫폼 결정론 검증은 계속 남아 있다.

### 강 건너기와 이동·이벤트 원본 테스트 5개 이관 (2026-10-27)
- 원본 river_crossing.rs의 두 시나리오를 PhysicsParityTests에 이관했다. 실제 BehaviorMob, navigation, BattlePhysicsSystem, Wall/RiverWater prefab과 충돌체를 사용한다. 단일 유닛은 400프레임 동안 물 충돌 없이 다리 중앙에서 한 번 건너 x>13에 도달한다. 12개 유닛은 500프레임 동안 물 안에 서지 않고 모두 x>10에 도달한다.
- RigidBody.ApplyVelocity의 deltaTime 적용과 속도 초기화, IIntervalAttacker 조회 후 동일 Stat 변경, 투사체 이벤트의 발생 순서 유지와 다음 프레임 중복 제거를 추가했다. 고정 소수점에 NaN은 없으므로 원본의 NaN 속도 입력은 재현하지 않는다. 이동값은 Q32.32 한 단위 오차 이내로 확인한다.
- river-projection-parity.log와 unity-river-projection.log에서 .NET/Unity 원본 848개, core, 물리 10000프레임, 혼합 난수 10000회가 통과했다. Unity 종료코드 0. 물리 trace BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 및 난수 trace 10DE04CD7DE82D8240FAB434C14DBBA83B84AD248B56B1712F4034EE9A99A5B3는 동일하다.
- 실제 Unity Assets 테스트에 포함되지 않는 Tools/PortedTests 변경은 Assets NUnit 결과를 무효화하지 않도록 대응표 도구의 입력 범위를 분리했다. Runtime 변경은 양쪽 결과 모두 무효화한다. 기존 Unity 메시지 원본 10개와 합쳐 915개 중 858개 verified, 57개 remaining이다. doctest 2개는 별도다.
- root/client diff --check 통과. 실제 GameScene 완주·결과 검증/저장/보상·모델 봇·관전자 연결·WebGL 결정론 등 전체 목표는 계속 진행 중이다.

### prefab 등록과 PVE 액션 실패 원본 테스트 9개 이관 (2026-10-27)
- 건물·낙하·폭발·불·번개·바위·PVE·subprefab의 원본 등록 테스트 8개를 추가했다. 등록 여부와 PrefabCatalog의 bean 이름, 실제 생성 후 prefab 이름/초기화를 확인한다. fixture에 PVE 보스의 별도 hp/mass/radius 키와 CraterEmber의 유효한 attack_range=2를 제공하며 실제 게임 매개변수는 변경하지 않았다.
- PveScenarioComponents.AddSpawner를 재정의할 수 있도록 바꿔 원본과 같은 스포너 추가 실패를 주입했다. 실패가 보고되고 다음 SpawnWave가 두 유닛을 생성하며, 이벤트가 재실행되지 않는 원본 테스트를 추가했다. PveScriptSystem의 기존 액션별 예외 격리 경로가 이를 처리한다.
- prefab-registration-parity.log와 unity-prefab-registration.log에서 원본 857개/core/물리 10000프레임/난수 10000회 통과. Unity 별도 probe 종료코드 0. 실제 클라이언트의 lockstep·frame contract·vector converter 31개도 통과했다(unity-prefab-client-results.xml, 종료코드 0).
- 물리 trace BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D, 난수 trace 10DE04CD7DE82D8240FAB434C14DBBA83B84AD248B56B1712F4034EE9A99A5B3 유지. Unity 메시지 원본 10개와 합쳐 915개 중 867개 verified, 48개 remaining이다. doctest 2개는 별도다.
- Unity의 Android 아이콘 자동 변경 복구 후 root/client diff --check 통과. 전체 목표는 아직 완료되지 않았다.

### PVE 재동기화 서비스와 GameScene 요청 연결 (2026-10-27)
- BattleSessionRuntime.InitializePve에서 PveSync 서비스를 등록한다. 기본 시나리오 설치/시간 제한 해제/서비스를 통한 목표 재전송과, 알 수 없는 시나리오 거부/첫 프레임 실행 금지를 검증하는 원본 pve_loop 테스트 2개를 추가했다.
- LockstepConnection.TrySendPveSync는 복구가 끝난 로컬 상태에서 목표·누락 대사·채널 상태를 다시 전달한다. 첫 프레임 전, 복구 중, 종료 후, 음수 이벤트 번호는 거부한다. StompConnector/PveSyncSender가 lockstep 요청을 해당 경로로 보내고, 입력 이력 복구 완료 시 화면에 표시한 마지막 대사 번호로 재동기화한다. 기존 서버 방식은 STOMP 경로를 유지한다.
- Unity 테스트에서 실제 Connection의 presentation 이벤트로 목표/대사/BGM이 전달되는지 확인했다. 이미 받은 대사는 다시 보내지 않으며 재전송 전후 전투 프레임/난수 상태는 동일하다. 실제 소켓 재연결을 통해 GameScene 전체 복구를 검증한 것은 아니다.
- pve-sync-parity.log와 unity-pve-sync.log에서 원본 859개/core/물리 10000프레임/난수 10000회 통과, Unity probe 종료코드 0. 실제 클라이언트 관련 32개도 모두 통과했다(unity-pve-sync-client-final-results.xml, 종료코드 0). 기존 물리·난수 trace 유지.
- Unity 메시지 원본 10개와 합쳐 915개 중 869개 verified, 46개 remaining이다. doctest 2개는 별도다. PVE 클리어의 실제 저장·온라인 상태 복귀·승패 전달을 함께 검사하는 원본 종료 테스트는 아직 남아 있다. Android 아이콘 자동 변경 복구 및 root/client diff --check 통과.

### 입력 이력 복구 중 화면 재생 억제와 현재 snapshot 전달 (2026-10-27)
- LockstepConnection은 복구 중 과거 프레임/PVE presentation을 전달하지 않는다. 복구가 끝나면 BattlePresentationOutput.RecoverySnapshot으로 현재 객체·손패·마나·HP를 구성해 한 번 전달하고 Recovered를 알린다. 이미 종료된 경기 이력을 복구할 때도 마지막 snapshot과 Recovered 뒤에 BattleCompleted가 발생한다.
- 복구 snapshot에는 투사체/피격 이벤트가 없고, JSON에 포함되지 않는 suppressSpawnPresentation으로 ObjectSyncer의 새 객체 소환 연출을 생략한다. 기존 객체는 현재 snapshot으로 조정하므로 과거 create를 반복 적용하지 않는다. 이미 화면에 남은 독립 투사체의 수명 종료를 강제로 앞당기지는 않는다.
- 미확인 로컬 카드 입력 응답은 복구 중에도 전달한다. TryAcknowledge가 해당 사용자와 요청을 확인하고 한 번만 처리하여 카드 대기 상태가 남지 않도록 한다.
- Unity 테스트에서 15프레임 이력을 숨긴 뒤 snapshot 1회/반복 완료 호출 무시/다음 실시간 프레임 전달, 40프레임 종료 이력의 snapshot→Recovered→BattleCompleted 순서, 입력 응답의 사용자 구분/단회 전달/요청 ID 해제를 확인했다. 관련 34개 모두 통과(unity-recovery-client-final-results.xml, 종료코드 0). 실제 소켓 단절 및 렌더링된 GameScene 전체 복구 검증은 아직 남아 있다.
- .NET recovery-presentation-parity.log 및 Unity unity-recovery-presentation.log에서 원본 859개/core/물리 10000프레임/난수 10000회 통과, 기존 trace 유지. Unity 메시지 원본 10개를 합친 대응표는 869/915 verified, 46개 및 doctest 2개 남음. Android 아이콘 자동 변경 복구 및 root/client diff --check 통과.

### 실제 STOMP 연결 단절과 입력 이력 재생 검증 (2026-10-27)
- NetworkBattleProbe에 35번째 확정 프레임 뒤 소켓 Abort, 새 WebSocket/STOMP 구독, HTTP 초기 상태/입력 이력 재조회, 새 runtime 생성과 재생을 추가했다. 출력 구독·PVE sink·시전 집계도 새 runtime에 맞춰 재구성한다.
- 재생 전후 프레임 번호, RNG 상태, 각 플레이어의 HP/마나/손패, 객체 ID/prefab/소유자/상태/좌표/효과/gauge를 비교한다. 내부 컴포넌트 상태 전체의 직렬화 해시를 검증하는 것은 아니다.
- 실제 일회용 Postgres와 Rust HTTP/STOMP 서버의 network-reconnect.log에서 네 모드 모두 통과했다. PVP 무승부는 40프레임, 사람 시전 승리는 53프레임에 종료했고 재연결한 오른쪽 클라이언트와 연결을 유지한 왼쪽 클라이언트의 결과가 동일하다. PVE와 Rule 봇은 사람 클라이언트가 재연결한 뒤 각각 40/53프레임에 완료됐다. 모든 재연결 대상의 reconnects=1을 확인한다.
- dotnet probe 빌드, 해당 Rust 통합 테스트, cargo clippy -j 1 -p ac-game-server --test lockstep_client_network -- -D warnings 통과. 일회용 ac-lockstep-reconnect-test 컨테이너 종료. root/client/game-rust diff --check 통과.
- 이는 .NET 네트워크 probe에서 실제 연결과 공통 시뮬레이션 복구를 검증한 결과다. Unity LockstepConnection의 실제 코루틴·렌더링된 GameScene·결과 저장/보상까지 검증한 것은 아니며 전체 목표는 진행 중이다.

### 독립 C# 결과 검증기와 상태 효과 DB 키 수정 (2026-10-27)
- `client/Tools/LockstepVerifier`는 Unity/probe 테스트 코드 없이 동일 Runtime 소스를 .NET 8로 빌드한다. 표준 입력의 서버 초기 상태와 확정 로그를 검증하고 처음부터 종료 유예 프레임까지 재생한다. 초기 해시/버전/참가자/연속 순서를 확인하며 미완료, 종료 이후 입력, 3 MiB/12000프레임 초과를 거부한다. 출력은 세션·버전·초기 해시·종료 프레임·패자·양측 HP다.
- `BattleSessionRuntime.Failure`가 액션/컴포넌트/충돌/봇/PVE 스크립트에서 격리된 최초 오류를 보존한다. 검증기는 해당 오류가 있으면 승패를 승인하지 않는다. 오류 격리 자체는 기존 동작을 유지한다.
- 이 검증에서 `CommonEffectReceiver`가 DB의 `game.*` 접두사 없이 파라미터를 읽는 이관 오류를 발견했다. 원본 Rust `status_float/status_int`의 GameObjectKey::Game 사용을 확인하고 공통 수신기와 테스트 fixture를 수정했다. 네트워크 fixture에는 감전 지속/갱신 시간을 추가했다. 키 누락 후 초기 해시를 다시 계산한 입력도 실행 오류로 거부하는 회귀 검사를 추가했다.
- `game-rust/lockstep_verifier`는 별도 프로세스를 최대 2개, 30초, 응답 8 KiB로 제한하고 반환된 세션/버전/해시/프레임 수를 서버 입력과 대조한다. 아직 실제 완료 HTTP 경로 및 저장/보상 호출에 연결하지 않았다.
- .NET `verifier-parity-final.log`, Unity `unity-verifier-parity.log`에서 원본 859개/core/물리 10000틱 통과, 기존 trace 유지. 실제 client의 `Lockstep` 필터 25개 통과(`unity-verifier-client-results.xml`, 종료코드 0), 이 중 원본 메시지 10개를 합쳐 869/915 verified, 원본 46개와 doctest 2개가 남는다. 필터 밖 테스트 전체가 통과했다는 뜻은 아니다.
- `network-verifier-final.log`에서 실제 DB/HTTP/STOMP 네 모드의 별도 프로세스 재생 결과가 플레이어 결과와 일치했다. 잘린 로그/추가 종료 프레임/순서 오류/버전 불일치/해시 불일치/실행 중 콘텐츠 누락을 거부했다. 서버 adapter 경로의 추가 통합 검증은 아래 결과에 기록한다.
- `network-verifier-adapter.log`에서 Rust `lockstep_verifier::verify` 경로를 추가로 호출한 네 모드 모두 통과했다(35.34초). `verifier-clippy.log`의 해당 통합 테스트 `-D warnings`도 통과했다. Unity Android 아이콘 자동 변경을 복구했고 root/client/game-rust diff --check 통과. 검증용 DB 컨테이너를 종료한다.

### 검증된 마법 사용 통계와 기존 결과 DTO 변환 (2026-10-27)
- 독립 검증기는 공통 `MagicUsed` 이벤트로 사람과 봇의 성공한 시전을 `(userId, magicId)`별로 집계하고 정렬된 `magics`를 반환한다. 화면용 이벤트는 매 프레임 비워 장시간 재생에서 누적하지 않는다.
- Rust adapter는 집계 행의 참가자, 양수 magicId/count, 최대 횟수와 중복 키를 검증한다. `VerifiedBattle.statistics`는 동일 초기 해시의 매치 시작 덱을 집계하고, 검증된 승패/시전 횟수/서버에서 받은 경과 시간으로 기존 `GameResult`를 구성한다. 재생 CPU 시간을 실제 경기 프레임 지연으로 취급하지 않아 `update_times`는 비운다.
- 통합 테스트에 사람 시전 1회/무시전 0회/봇 시전 포함, 실제 덱 15장, 승자 ID, 지정한 경기 경과 시간, 빈 CPU 통계 검사를 추가했다. 실제 DB 저장, MMR, 승수, PVE 클리어, lobby 종료 통지, 결과 화면 연결은 아직 남아 있다.
- 저장 경로 조사: `statistic_repository::save_game_result_dto`는 호출자 transaction을 사용할 수 있고 `game_session_record_repository::mark_ended`는 IN_PROGRESS 상태를 조건으로 갱신한다. 기존 MMR 함수는 자체 transaction을 사용한다. 완료 요청 재시도에서 중복 갱신되지 않도록 결과 저장과 보상 반영 경계를 다음 구현에서 연결해야 한다.
- `network-verifier-statistics-final.log`의 네 모드와 모든 거부 사례/통계 검사가 통과했다(39.48초). `verifier-statistics-build.log` 빌드 통과(기존 Fix64 경고 4개), `verifier-statistics-clippy.log`의 대상 테스트 -D warnings 통과. Runtime/Assets 변경이 없어 이번 추가로 Unity 재실행은 하지 않았다. 원본 대응 수는 869/915로 동일하다. 일회용 `ac-lockstep-statistics-test`를 종료했다.

### 완료 결과 영속화 테이블과 MMR transaction 경계 추가 (2026-10-27)
- 비어 있던 `database/`에 root가 가리키는 `11763bdee354d415bab87be05ea01e8361033122` 기준 worktree와 `lockstep` 브랜치를 만들었다. 기존 다른 checkout은 변경하지 않았다. origin fetch 후 전체 로컬/원격 ref 이력의 최대 migration V119와 별도 balance worktree의 V050까지 확인하고 V120을 사용했다. 현재 origin의 main/magic-card head는 존재하지 않지만 해당 이력이 남은 모든 ref의 파일명도 조사했다.
- `V120_20261027__add_lockstep_completed_results.sql`은 세션 ID PK, 초기 해시/버전/참가자/프레임 수, 통계 ID FK, 최초 결과 JSON을 저장한다. Git Bash로 `validate-migrations.sh HEAD`의 이름/중복/순서/불변성/태그 검사 모두 통과하고 일회용 Postgres에 실제 적용했다. WSL Git은 Windows worktree의 gitdir 경로를 해석하지 못해 순서/불변성 검사를 생략했으므로 그 결과를 통과 근거로 사용하지 않았다.
- `lockstep_result_repository::lock_and_find`는 아직 행이 없는 최초 요청도 PostgreSQL transaction advisory lock으로 직렬화한다. `insert`는 동일 transaction을 받아 결과·통계·보상을 함께 commit할 수 있게 한다. 호출자는 기존 행이 있으면 메타데이터를 대조하고 보상을 반복 적용하지 않아야 한다. 실제 HTTP 완료 경로는 아직 연결 전이다.
- MMR의 기존 `update_match_result`는 transaction을 만들고 commit하는 wrapper로 유지했다. 새 `update_match_result_in_transaction`은 호출자 transaction을 쓰며 양측 사용자 행을 ID 순서로 잠근다. 계산과 봇전의 사람 MMR 유지 규칙은 동일하다.
- `lockstep_result_transaction`은 실제 migration을 연결 전용 임시 테이블로 적용하여 통계 저장 오류 시 MMR/통계 롤백, 정상 저장 시 동시 반영, 완료 결과 재조회, 봇전 사람 MMR 유지를 검증했다. `lockstep-result-persistence.log` 통과. `mmr-unit.log`의 기존 MMR 단위 테스트 5개 통과. 동시 HTTP 요청·서버 재시작·보상 전체의 정확히 한 번 반영을 아직 검증한 것은 아니다.
- `lockstep-result-persistence-clippy.log`의 `cargo clippy -j 1 -p ac-data --test lockstep_result_transaction -- -D warnings` 통과. root/game-rust/database diff --check 통과. 일회용 `ac-lockstep-result-tx-test`를 종료했다. commit/push 및 parent submodule pointer commit은 하지 않았다.

### 검증 결과의 통계·MMR·보상 원자적 저장 서비스 추가 (2026-10-27)
- `lockstep_result::persist`는 검증된 결과를 기존 GameResult 형식으로 바꾼 뒤 세션별 완료 잠금을 잡는다. 최초 저장에서 통계·MMR·승수·PVE 클리어·온라인 복귀와 완료 응답을 한 transaction으로 commit한다. Practice에서 hospitality 봇을 이긴 경우 초기 snapshot의 persona를 기준으로 기존 novice progress 함수를 호출한다. 이 hospitality 승리 분기는 네트워크 테스트에서 아직 실행하지 않았다.
- 완료 행이 있으면 초기 해시/버전/참가자/프레임 수/확정 입력 해시를 대조하고 최초 응답을 반환한다. 다른 입력을 같은 프레임 수로 재생한 경우도 구분하도록 V120에 `confirmed_input_hash`를 추가했다. 이 migration은 아직 commit/배포되지 않았으며 일회용 DB에만 적용했다. 입력 해시는 외부 검증기 출력이 아니라 Rust가 실제 전달한 확정 로그에서 계산한다.
- 응답은 기존 `ResultDto`로 생성하여 `lastLeftPlayerMmr`, `newLeftPlayerMmr` 등 기존 wire 필드명을 그대로 사용한다. PVE는 기존처럼 MMR을 갱신하지 않고 결과 MMR 필드에 0을 담는다. 초기 수동 JSON 구현의 필드명 오류를 DTO 대조로 발견해 수정하고, 통합 테스트에 기존 DTO 역직렬화를 추가했다.
- 네트워크 fixture에 통계/사용자 상태/PVE 클리어 스키마와 실제 V120 적용을 추가했다. 실제 네 경기의 결과에서 저장 오류로 MMR/승수 롤백, 동시 두 저장 요청의 동일 응답/단일 완료 행, 중복 없는 승수, PVE FINISHED, 사용자 Online, 다른 입력 해시 거부를 검사한다. 실제 완료 HTTP API, Unity 결과 화면 호출, lobby 종료 통지와 세션 정리는 아직 연결 전이다.
- 최종 `network-result-persist-final.log`의 네 모드 전체 통과(39.98초), `result-persist-transaction.log`의 transaction/완료 행 재조회 검사 통과, `lockstep-persist-wire-clippy.log`의 -D warnings 통과. 수정된 V120의 Git Bash 정적 검사 모두 통과. 일회용 `ac-lockstep-persist-test`를 종료했다. 원본 이관 대응 수는 869/915로 동일하며 목표는 진행 중이다.

### 완료 HTTP API와 Unity 결과 전달 연결 (2026-10-27)
- `POST /api/lockstep/{id}/complete`는 인증된 참가자와 DB 기반 매치만 허용한다. `LOCKSTEP_VERIFIER_DLL`의 독립 검증기에 서버가 보관한 초기 상태와 확정 입력만 전달한다. 검증 중 입력이 늘어나면 저장하지 않으며, 검증 성공 후에는 입력을 고정해 DB 재시도에서도 같은 결과를 사용한다.
- 세션별 완료 잠금과 DB transaction으로 동시 요청을 직렬화한다. 저장된 기존 ResultDto를 반환하고 세션을 completed로 표시한 뒤 lobby 종료를 통지한다. 서버 재시작 후 완료 응답 복구, statistic_game_sessions 및 용량 관리 연결은 아직 남아 있다.
- Unity `LockstepConnection`은 로컬 전투 종료 후 완료 API를 요청한다. 503 등 일시 오류는 재시도하고, 남은 대기 시간에 맞춰 요청 timeout을 제한한다. 저장 응답의 승패와 MMR 필드를 검증한 뒤 기존 ResultHandler에 한 번 전달한다. 화면 이벤트의 예외를 JSON 형식 오류로 숨기지 않는다.
- `network-complete-http.log`에서 실제 DB/HTTP/STOMP의 무승부·사람 시전 승리·PVE·Rule 봇 네 모드가 통과했다(34.51초). 참가자 외 요청 403, 미완료 요청 409, 동시 완료의 동일 응답, 결과/보상 단회 저장, active=false, completed 이력, 경기당 lobby 통지 1회를 확인했다. lobby 통지는 로컬 HTTP 대역으로 확인했으며 실제 lobby 인증 통합 검사는 아니다.
- `lockstep-complete-relay.log`의 relay 단위 테스트 6개와 `lockstep-complete-final-clippy.log`의 -D warnings가 통과했다. Unity `unity-complete-http-results.xml`의 Lockstep 필터 27개도 통과했다. 새 검사는 완료 전/승패 불일치/필드 누락 거부, 중복 결과 전달 방지, 실제 UnityWebRequest의 503 후 POST 재시도와 Authorization 보존을 포함한다. 렌더링된 GameScene부터 ResultScene까지의 전체 실행 검증은 남아 있다.
- 원본 테스트 대응은 869/915로 유지한다. 이번 HTTP 검사를 원본 테스트 이관 수에 추가하지 않았다. 원본 46개와 doctest 2개, 모델 봇/관전자/전체 상태 해시 및 플랫폼별 전투 검증이 남아 있어 전체 목표를 완료로 표시하지 않는다.

### 경기 타이머와 벡터 원본 테스트 이관 (2026-10-27)
- `GameTimer`는 주입한 `IMillisClock`으로 남은 시간, 종료와 피버를 계산한다. `OverrideDuration`은 양수 기간만 받고 시작 시간을 다시 잡는다. BattleSessionRuntime의 종료/피버 판정에도 이 타이머와 기존 FrameMillisClock을 사용한다. 원본처럼 피버는 남은 시간이 기준보다 작아야 시작하며, 남은 시간은 종료 뒤 음수까지 유지한다.
- 원본 `counts_down_and_enters_fever`를 옮겨 시간 재설정과 잘못된 기간 거부를 검증했다. 정확한 피버 경계와 실패한 재설정이 기존 상태를 바꾸지 않는 검사도 추가했다.
- `SimulationVector`의 영벡터 정규화와 보간 범위 제한을 VineMagics/BombSprite의 실제 계산에 연결했다. 원본 vector3의 `normalize_of_zero_is_zero`, `distance_and_lerp`를 이관했다. Q32.32 나눗셈은 반올림하고 decimal 변환은 버림하므로 3/5와 4/5의 정확한 raw 값 2576980378/3435973837을 기대값으로 사용한다. 부동 소수점의 비트 일치를 주장하지 않는다.
- .NET `timer-vector-parity-final.log`와 Unity `unity-timer-vector-parity.log`에서 원본 862개/core/물리 10000틱이 통과하고 기존 물리 trace가 유지됐다. 실제 client `unity-timer-vector-client-results.xml`의 Lockstep 필터 27개도 통과했다. 독립 verifier 재빌드 통과(기존 Fix64 경고 4개).
- 최신 로그로 대응표를 갱신했다. Unity 원본 wire 테스트 10개를 합해 872/915 verified이며 원본 43개와 doctest 2개가 남는다. 전체 이관 및 렌더링된 경기 전체 검증은 진행 중이다.

### 봇 화면 이벤트 연결과 메시지 계약 이관 (2026-10-27)
- `LockstepConnection.ConfigureSnapshotBattle`에서 runtime의 `Emotes.Sent`와 `Bots.Thought`를 기존 화면 메시지로 변환해 전달한다. 복구 중에는 공통 PublishPresentation 경로로 과거 이벤트를 숨긴다. 기존 서버의 send_bot_thought/send_emote도 두 플레이어와 관전자에게 전달하는 것을 확인했다. 관전자 연결 자체는 아직 미지원이다.
- `BotThoughtInfo.cards`의 문자열 배열은 서버의 숫자 magic ID를 재직렬화하면 문자열로 바꾸고 있었다. 표시 전용 object 배열로 바꿔 현재 숫자 ID와 기존 카드 이름 메시지를 모두 보존한다. 사용하는 코드는 BotThoughtHandler의 string.Join이며, 기존 문자열 메시지 테스트도 유지했다.
- 원본 `game/dto/tests.rs::emote`, `bot_thought`를 실제 Unity mapper/DTO의 왕복 직렬화 테스트로 이관했다. emote 이름의 대소문자 구분도 확인한다. runtime 봇 emote가 화면으로 전달되고 recovery 동안 억제되는 검사도 추가했다.
- `unity-bot-presentation-results.xml`의 Lockstep 및 ServerMessageTests 43개가 모두 통과했다. 원본 대응은 .NET/Unity 코어 862개와 Unity wire 12개를 합한 874/915 verified이며 원본 41개와 doctest 2개가 남는다. 사람 emote의 확정 입력 전송, 관전자, 모델 봇, 전체 상태 해시, 실제 화면 전체 실행 검증은 계속 진행해야 한다.

### 사람 emote 확정 입력 연결 (2026-10-27)
- emote 선택 UI는 `TrySendEmote`를 통해 lockstep에서는 로컬 입력 큐, 기존 매치에서는 기존 STOMP destination을 사용한다. 연결/복구/종료 및 큐 용량 검사를 통과해야 입력을 받는다.
- 공통 명령에 `kind=emote`, `emote` 이름을 추가했다. emote의 magicId/좌표는 0이어야 하며 이름은 원본 다섯 가지와 대소문자가 일치해야 한다. 카드 명령에 emote 필드를 섞으면 거부한다. Rust relay와 C# 확정 입력 검증에 같은 조건을 적용했다. 복사/중복 프레임 fingerprint에도 emote를 포함한다.
- `LockstepBattleDriver`는 확정된 플레이어 슬롯 순서로 `SessionEmotes.ReceivePlayer`를 호출한다. 기존 3초 cooldown 및 봇 응답 예약을 같은 프레임에서 처리한다. 두 runtime의 61프레임 재생에서 같은 tick의 두 emote 중 첫 번째만 허용, cooldown 만료 후 허용, 중복 프레임 재수신 시 중복 이벤트 없음과 같은 이벤트 순서를 확인했다.
- .NET `emote-input-parity.log` 및 Unity `unity-emote-input-parity.log`에서 862개/core/물리 10000틱이 통과했다. 실제 client `unity-emote-input-client-results.xml`의 관련 43개도 통과했다. relay 단위 테스트는 새 충돌/입력 검사를 포함해 7개 통과(`emote-input-relay.log`). 원본 대응은 874/915로 유지하며 이번 추가 회귀 검사를 원본 수에 더하지 않는다.
- `network-emote-input.log`에서 실제 네 경기 모두 통과했다(28.31초). 첫 tick의 Greet를 HTTP/STOMP로 전달하고 연결 유지/재접속 클라이언트 모두 humanEmotes=1을 확인했다. 독립 verifier와 완료 API의 통계·보상·lobby 통지 검사도 통과했다. `emote-input-clippy.log`의 -D warnings 통과, 일회용 `ac-lockstep-emote-test` 종료, root/client/game-rust diff --check 통과. 실제 렌더링 화면 및 관전자·모델 봇·전체 상태 해시 검증은 남아 있다.

### 컴포넌트 확장 예제 테스트 이관 (2026-10-27)
- 원본 `tests/porting_examples.rs`의 세 테스트를 ObjectParityTests로 옮겼다. 예제 prefab은 파라미터에서 질량/반경을 읽고 실제 RigidBody, ZPhysics, TimedSelfDestroyer를 사용한다. 원본의 미등록 RockSlime/FireField는 빈 initializer로 명시해 실제 콘텐츠 누락을 거부하는 클라이언트 규칙을 유지했다.
- 수명 freeze/recover, 두 인터페이스 조회, 충돌 시 문맥 RNG를 이용한 속도 변경, 피해 이벤트, 피해에 따른 FireField 생성, 상태 구독을 검증한다. 삼각함수와 시간은 고정 소수점을 사용한다. 새 예제만 테스트하고 기존 구현 오류를 숨기는 대체 구현은 추가하지 않았다.
- .NET `porting-examples-parity.log`와 Unity `unity-porting-examples-parity.log`에서 원본 865개/core/물리 10000틱이 통과했다. 물리 trace는 기존과 동일하다. 이번에는 테스트 코드만 바꿔 실제 client의 직전 wire 12개 결과를 그대로 사용했다. 대응표는 877/915 verified, 실행 테스트 38개 미이관이다.
- 기존에 별도 기록한 doctest 2개는 `component.rs`의 component_interfaces 사용 예와 `pve_scenario_components_impl.rs`의 installer 설정 예다. 원본 둘 다 `ignore` 문서 블록이므로 원본 915개의 실행 테스트에 포함되지 않는다. 문서 예제의 C# 대응 확인은 별도로 남긴다. 전체 목표는 아직 진행 중이다.

### 파라미터 이름 해석과 누락 오류 이관 (2026-10-27)
- 원본 MapParameterSource는 객체 이름을 소문자로 정규화하지만 기존 C# GameParameters는 전체 키의 대소문자를 구분하고 있었다. BattleParameters를 실제 SimulationContext에 연결하여 객체 이름만 정규화하고 파라미터 이름의 대소문자는 유지했다. 점이 없는 기존 키도 보존한다. 명시적 fallback 조회 외에는 누락 값에 `Parameter not found: object, parameter` 오류를 낸다.
- `get_value_reads_keys_and_names_alike`, `get_value_panics_on_a_missing_row`를 실제 context 조회에 연결해 이관했다. .NET `parameter-lookup-parity.log`와 Unity `unity-parameter-lookup-parity.log`에서 원본 867개/core/물리 10000틱 통과, trace 동일. Unity 초기 import에는 새 파일 인식 전 CS0246이 있었으나 이후 새 파라미터 테스트 두 개를 포함한 재컴파일·실행과 종료코드 0을 확인했다.
- 실제 client `unity-parameter-lookup-client-results.xml`의 관련 43개 통과, 독립 verifier 재빌드 통과. 대응표는 Unity wire 12개를 합해 879/915 verified, 실행 테스트 36개 미이관이다.
- SQL fixture 로더 테스트 두 개는 아직 남는다. Java reference의 기존 WSL 경로는 없지만 `C:/Users/jys09/Projects/ArcaneCasters/game/src/test/resources/sql/`에서 두 파일을 찾았다. 해당 checkout HEAD는 `80eef7659367ccf2960fabdda89c4bddf094e134`이고 원본 기대값 tide_call.speed=4.5, towerback.sub_attack_range=1.15가 있다. 이 fixture의 출처와 내용을 검증해 후속 로더 이관에 사용한다.

### Java SQL fixture 로더 테스트 이관 (2026-10-27)
- Java checkout의 두 fixture에 변경이 없음을 확인하고 `Tools/LockstepProbe/Fixtures/`에 원본 그대로 복사했다. README에 출처 커밋과 복사 시 SHA-256을 기록했다. .NET에는 embedded resource로 넣고 Unity probe에는 같은 파일을 Resources의 TextAsset으로 복사한다. 파일이 없으면 테스트가 실패하며 외부 checkout 없이 실행된다.
- 테스트 전용 `ParameterSqlFixture`는 일반 SELECT/IN INSERT와 CTE VALUES seed 행을 읽고 decimal에서 고정 소수점으로 변환한다. INSERT 형식 오류를 거부하고 이미 있는 키는 원본 NOT EXISTS 규칙처럼 첫 값을 유지한다. 게임 런타임에 SQL 실행기를 추가한 것은 아니다.
- 원본 `loads_both_insert_shapes_of_the_java_fixture`, `loads_every_parameter_value_of_the_java_fixtures`를 ContextParityTests로 이관했다. .NET `parameter-fixture-parity.log`, Unity `unity-parameter-fixture-parity.log`에서 원본 869개/core/물리 10000틱이 통과했다. 두 fixture 테스트의 Unity 실행도 로그에서 별도 확인했다. 물리 trace는 동일하다.
- 검증 집계의 최신성 입력에 SQL fixture 및 probe 빌드 설정/진입점도 포함했다. 기존 Unity wire 12개와 합한 대응표는 881/915 verified이며 실행 테스트 34개가 남는다. 이번에는 runtime/실제 client 소스를 변경하지 않아 실제 client 43개 결과는 직전 실행을 사용했다. root/client diff --check 통과. 전체 목표는 진행 중이다.

### 맵 선택 규칙과 초기 상태 검증 연결 (2026-10-27)
- C# GameMapSelector에 Random/강제 맵, PVE 스테이지 우선, Playground Grassland 고정 규칙을 옮겼다. 원본 일곱 테스트로 동전 호출 횟수, 비-PVE의 저장소 미조회, 기본값/맵 이름, River만 지형을 갖는 규칙을 검증한다. 실제 BattleFieldInitializer도 같은 TerrainFor를 사용한다.
- 서버 초기 상태는 `mapPolicy`에 selection, 이미 사용한 동전 결과, scenarioMap을 함께 담는다. 별도 난수를 추가로 소비하지 않는다. BattleInitialState는 이 정책으로 계산한 맵이 안내된 map과 일치해야 runtime을 생성한다. 기존 정책 필드가 없는 초기 상태는 계속 읽는다. 서버가 lobby에 맵을 안내하는 역할은 유지하며 클라이언트에서도 같은 규칙을 실행·검증한다.
- .NET `map-policy-parity.log` 및 Unity `unity-map-policy-parity.log`에서 원본 876개/core/물리 10000틱 통과, trace 동일. 새 소스 인식 전 Unity 초기 import 오류 뒤 재컴파일과 해당 일곱 테스트 실행·종료코드 0을 확인했다. 독립 verifier 재빌드와 `map-policy-server.log`의 서버 초기 상태 직렬화 검사도 통과했다.
- 실제 client `unity-map-policy-client-results.xml`의 관련 44개 통과. Random 동전 누락/맵 불일치 거부, 강제 맵에서 동전 생략, Playground 우선순위, PVE 스테이지 맵을 실제 CreateRuntime 경로로 확인했다. `network-map-policy.log`의 네 경기·재접속·서버 검증·저장·lobby 통지 모두 통과(51.06초), `map-policy-clippy.log`의 -D warnings 통과. 일회용 `ac-lockstep-map-test` 종료와 root/client/game-rust diff --check를 마쳤다.
- 최신 원본 대응은 888/915 verified이며 실행 테스트 27개가 남는다. 모델 봇·관전자·전체 상태 해시와 렌더링된 전체 경기 검증을 포함한 최종 목표는 계속 진행 중이다.

### PVE wire 검증과 저장된 완료 결과 복구 (2026-10-27)
- 원본 `pve_script_event_has_no_type`를 실제 Unity JsonCodec/DTO 테스트로 이관했다. type 없는 원본의 key, speakerObjectId, lines, seq를 읽고 재직렬화하며, 같은 로컬 이벤트를 화면에 전달할 때는 pveScriptEvent type만 추가되는지 검증한다. 기존 GeneralHandler의 untyped 수신 경로는 유지한다.
- 실제 client `unity-pve-wire-client-results.xml`에서 관련 45개가 통과했다. 원본 대응표는 889/915 verified이며 26개가 남는다. 이번에는 시뮬레이션 코드를 바꾸지 않아 standalone 876개 결과는 직전 검증을 사용한다.
- 완료 결과가 이미 DB에 저장됐으나 서버 재시작/보관 기간 경과로 메모리 세션이 사라진 경우, 기존 POST /api/lockstep/{id}/complete가 저장 결과를 반환하도록 연결했다. 저장된 참가자만 조회할 수 있고 외부 사용자와 없는 결과는 404로 처리한다. verifier 재실행, MMR/보상 갱신, lobby 알림을 반복하지 않는다. DB 장애는 503으로 반환한다.
- `network-result-recovery.log`에서 네 경기(draw/cast/PVE/Rule bot), 재접속, 독립 검증 및 저장 검사 모두 통과했다(36.47초). 같은 DB를 사용하는 별도 서버 인스턴스를 세션/verifier 설정 없이 띄워 양 참가자의 동일 결과 복구, 비참가자/미인증/없는 결과 거부, 전체 사용자 MMR·승리 횟수 불변과 기존 종료 알림 1회를 검증했다. `result-recovery-clippy.log`의 -D warnings도 통과했다.
- 이 복구는 완료 결과 저장 이후의 클라이언트 재시도를 처리한다. 미완료 경기의 서버 재시작 복원, 저장 직후 프로세스 종료로 누락된 lobby 알림의 durable 재전송, 앱 재실행 후 화면 진입 복구는 아직 남는다. 모델 봇·관전자·전체 상태 해시·전체 경기 렌더링 검증을 포함한 목표는 진행 중이다.

### 봇 숫자 표기와 전체 이관 테스트 WebGL 실행 (2026-10-27)
- BotBrain의 숫자 표시를 고정 소수점 raw 값으로 되돌릴 수 있는 최소 소수 자릿수로 바꿨다. 일반값의 .0과 Java의 지수 표기 경계를 유지하며 double 계산은 추가하지 않았다. 원본 renders_doubles_the_way_java_does 여섯 사례, 음수/표기 경계/문화권/최소 raw/최솟값/최댓값 roundtrip을 검사했다.
- .NET `webgl-runner-desktop-parity.log`, Unity `unity-webgl-runner-desktop-parity.log`에서 원본 877개/core/물리 10000틱이 통과했다. 실제 client `unity-bot-number-format-client-results.xml`의 관련 45개 및 verifier 재빌드 통과. 원본 집계는 wire 13개를 포함해 890/915 verified, 25개 미이관이다.
- 전체 이관 코드를 Unity 2022.3.34f1 WebGL/IL2CPP로 빌드하고 실제 headless Chrome에서 실행했다. 첫 실행은 873개 통과와 Thread.Start 직접 사용 4개 실패를 확인했다. 큐의 지연 실행·봇 재진입 검사는 WebGL 동기 실행 방식에서도 같은 의미를 검사하도록 수정했다. 스레드 공유 자체를 검사하는 2개만 RequiresThreads로 명시하며 PARITY SKIP으로 별도 기록한다. .NET/Editor에서는 두 검사 모두 실제 스레드로 통과한다.
- 두 번째 빌드 `unity-full-parity-webgl-build-v2.log` 및 브라우저 `webgl-full-parity-v2.log`: 875개 통과, desktop thread contract 2개 제외, core 통과. 물리 10000틱 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D로 .NET/Editor와 일치한다. 봇 숫자 새 테스트의 브라우저 통과도 확인했다.
- Run-WebGLProbe.cjs와 README에 실행 방법·범위를 추가했다. 브라우저 도구 초기화 오류로 bundled Playwright와 별도 Chrome 프로필을 사용했고 생성한 브라우저 및 로컬 HTTP 서버를 종료했다. 실제 client의 Unity 자동 Android 아이콘 변경을 되돌렸다. 이 검사는 전체 GameScene 렌더링/네트워크 통합 검증을 대신하지 않는다. 모델 봇·관전자·전체 상태 해시·남은 원본 테스트를 포함한 목표는 계속 진행 중이다.

### 전투 런타임 시작·종료 상태와 연결 정리 (2026-10-27)
- BattleSessionRuntime에 HasStarted/IsRunning/IsTerminated, Close, 한 번만 실행하는 Terminated를 추가했다. 첫 확정 프레임 전에는 실행 중이 아니며, 정상 종료·명시적 종료·프레임 예외 이후에는 다음 프레임을 거부한다. 프레임 도중 Close는 현재 프레임의 처리가 끝난 뒤 종료 알림을 보낸다. 콜백 하나의 오류가 다른 정리를 막거나 최초 오류를 가리지 않으며 Failure에 보존된다.
- 재접속으로 runtime을 교체할 때 이전 인스턴스를 닫고, LockstepBattleDriver의 실패 및 LockstepConnection.Fail/OnDestroy에도 종료를 연결했다. 원본 stops_reporting_running_when_the_frame_panics와 on_terminated_runs_once_the_loop_ends를 확정 프레임 실행 경로로 이관했다. 원본 서버의 별도 OS 스레드를 클라이언트에 추가한 것은 아니다.
- .NET battle-lifecycle-parity.log 및 Unity unity-battle-lifecycle-parity.log에서 원본 879개/core/물리 10000틱이 통과했고 해시는 동일했다. verifier 재빌드도 통과했다. 실제 client의 unity-battle-lifecycle-client-v2-results.xml 관련 47개 통과. 첫 실행의 신규 2개 실패는 EditMode가 Awake/OnDestroy를 자동 호출한다고 가정한 테스트 준비 문제였으며, 수명 콜백을 명시 호출하여 검증하도록 수정했다. 실제 PlayMode 장면 전환 검증을 대신하지 않는다.
- network-battle-lifecycle.log에서 네 경기(draw/cast/PVE/Rule bot), 재접속, 검증·결과 저장, 별도 서버의 저장 결과 복구가 통과했다(35.78초). 일회용 ac-lockstep-lifecycle-test를 종료했고 client의 자동 Android 아이콘 변경을 되돌렸다.
- 현재 원본 대응은 892/915 verified, 23개 미이관이다. 이번 runtime 변경 이후 WebGL 재빌드는 아직 하지 않았으므로 직전 WebGL 875개 결과를 최신 코드 전체의 통과로 간주하지 않는다. 모델 봇·관전자·전체 상태 해시·실제 전체 경기 화면 검증을 포함한 목표는 계속 진행 중이다.

### 봇 실행기 공유·EmberSpirit 초기화 계약과 WebGL 갱신 (2026-10-27)
- 원본 the_agent_can_be_shared_with_the_executor_thread를 이관했다. C#에서는 두 작업 스레드가 같은 BotAgent에 각각 네 작업을 전달한 뒤, 예외 없이 입력 8개와 요청 ID 0..7이 보존되고 main thread에서 drain되는지 검증한다. RequiresThreads로 표시하여 WebGL 통과 수에 섞지 않는다.
- 원본 EmberSpirit initializer를 FireSlimeInitializer와 공통 slime 초기화 경로로 이관했다. 생산 FireSlime 등록도 같은 초기화기를 사용한다. 별도 EmberSpiritInitializer는 ember_spirit 행을 사용해 FireSlime을 만들며, 실제 EmberSpirit prefab 별칭은 원본대로 일반 FireSlime 초기화기/fire_slime 행을 사용한다. 두 경로의 HP를 다르게 설정해 혼동을 검사했고 원본 ember_spirit_prefab_is_a_fire_slime_built_from_the_ember_spirit_rows가 통과했다.
- bot-prefab-contract-parity.log 및 unity-bot-prefab-contract-parity.log에서 원본 881개/core/물리 10000틱 통과. 실제 client unity-bot-prefab-contract-client-results.xml의 47개 통과와 verifier 재빌드도 확인했다. 대응표는 894/915 verified, 21개 미이관이다.
- 최초 WebGL 빌드는 실행 핸들과 해당 프로젝트의 Unity/컴파일러 프로세스가 사라지고 wasm 산출물이 없는 상태로 중단됐다. 프로세스 부재를 확인한 뒤 unity-bot-prefab-webgl-build-retry.log로 재실행해 종료코드 0을 확인했다. unrelated Unity Editor는 건드리지 않았다.
- webgl-bot-prefab-contract.log에서 실제 Chrome WebGL/IL2CPP 원본 878개 통과, 데스크톱 스레드 전용 3개 제외, core 및 물리 10000틱 통과. SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D로 .NET/Editor와 일치한다. 직전 런타임 종료 처리도 포함한 현재 코드의 검사다. browser/HTTP 검증 프로세스를 정리하고 README 실행 결과를 갱신했다.
- 관전자 후속 작업의 진입점은 Admin RoomApiClient의 lobby /api/game-sessions 및 local /api/debug/game-sessions, RoomInfo, MatchedInfoDto.CreateSpectatingSession이다. 현재 관전 DTO에 lockstepSimulationVersion 전달이 없고 game-rust의 기존 SessionService 방 목록은 legacy session만 읽는다. 권한과 관전 replay 경로, 방 목록 계약을 함께 연결해야 한다. 전체 목표는 아직 진행 중이다.

### 관전 방 목록의 lockstep 메타데이터 연결 (2026-10-27)
- lobby RoomInfoDto, client RoomInfo와 CreateSpectatingSession에 lockstepSimulationVersion을 전달했다. lobby가 내부 서버 URL을 공개 URL로 바꾸면서 기존 mapType까지 버리던 경로도 수정했다. 구형 응답의 필드 생략과 새 응답의 맵/버전 roundtrip 회귀 검사를 추가했다.
- 실제 Unity unity-spectator-metadata-client-results.xml의 58개, Rust protocol wire 13개 및 spectator-metadata-clippy.log 검사가 통과했다. 원본 대응 수는 894/915로 그대로다.
- LockstepRegistry가 생성 시각, 참가자, 맵과 버전을 포함한 활성 방 정보를 제공한다. GameServer에서 같은 registry를 SessionServerController와 DebugController에 연결해 기존 두 방 목록 API에 합쳤다. 종료/검증 완료 방은 제외하고 생성 시각과 session ID로 정렬한다.
- spectator-room-registry-tests.log의 8개와 spectator-room-list-http-tests.log의 실제 HTTP 통합 테스트 4개가 통과했다. 서버/관리자 API의 방 정보와 일반 사용자 권한 거부, 기존 PVP 경기 완료를 확인했다. spectator-room-list-clippy.log의 -D warnings와 diff --check 통과.
- 전체 Rust lib 검사에서는 224개 통과/5개 실패했다. 로컬 HTTP 4개는 네트워크 허용 재실행에서 통과했지만 closed-port 테스트가 Windows에서 ConnectException 대신 Timeout으로 실패했다. 별도로 SystemTime의 1ns 표현 검사도 Windows에서 실패한다. 전체 suite 통과로 간주하지 않는다.
- lobby 첫 전체 검사는 기존 QuestRegistryTest의 keyOf 확장 함수 해석 오류로 compileTestKotlin에서 실패했다. 소스 의미상 같은 package 함수이므로 코드 변경 전에 --rerun-tasks -Pkotlin.incremental=false로 다시 검증 중이다. 실행 핸들 60489, 로그 lobby-spectator-metadata-clean-tests.log. 새 JUnit 메서드가 실제 실행됐는지 XML 확인이 필요하다.
- graphify update .는 명령 미설치로 실행하지 못했다. 관전 권한/읽기 전용 replay/GameScene 연결은 아직 남는다. 목록에 방이 보이는 것만으로 관전 완료로 간주하지 않는다.

### lockstep 관전자의 읽기 권한 연결 (2026-10-27)
- 초기 상태와 입력 기록 HTTP 조회, 실시간 STOMP 구독이 같은 authorize_view 검사를 사용한다. 양수 member ID를 가진 WORDONLINE_ADMIN/SUPER_ADMIN 관전자는 읽을 수 있고, 일반 사용자는 기존 참가자 검사에 따라 읽는다. UID 없는 서버 토큰과 0/음수 관리자 ID는 거부한다.
- 입력 submit과 POST complete는 참가자 전용으로 유지했다. spectator-readonly-network-tests.log의 실제 WebSocket 테스트 12개가 통과했다. 새 검사는 관리자 초기 상태 조회, 관전자/참가자 프레임 일치, 입력 기록 재조회, 관전자 입력/결과 확정 거부와 일반 외부 사용자/잘못된 관리자 ID의 HTTP 접근 거부를 확인했다.
- spectator-readonly-clippy.log의 -D warnings 및 game-rust diff --check 통과. 클라이언트 StompConnector의 관전 차단, LockstepConnection의 참가자 슬롯/입력 전송/결과 POST, LockstepBattleSession/SessionStart의 참가자 검증은 아직 분리해야 한다. 관전 완료를 주장하지 않는다.
- lobby 캐시 제외 재실행은 compileTestKotlin을 통과했고 전체 test 단계에서 실행 중이다. 기존 keyOf 오류를 수정하려고 무관한 소스를 변경하지 않았다. 핸들 60489와 lobby-spectator-metadata-clean-tests.log를 계속 확인해야 한다. 아직 새 JUnit XML을 확인하지 못했다.

### 관전자 전투 세션 검증과 lobby 전체 검사 (2026-10-27)
- SessionStart.Validate와 LockstepBattleSession에 명시적인 spectator 모드를 추가했다. 관전자는 참가자 슬롯 없이 초기 상태를 검증할 수 있으며, 일반 접속의 비참가자 거부는 유지한다. 양수 사용자 ID, 프로토콜 버전, 틱 속도, 초기 해시 및 재접속 시 참가자/해시 불변 검사도 유지한다. 실제 관전 권한은 서버에서 검사한다.
- BattleSessionChecks에 참가자와 관전자의 동일 공격 입력 재생, 전투 종료 결과/HP/마나 일치, 재접속 후 처음부터 재생, 잘못된 사용자 ID와 초기 상태 변경 거부를 추가했다. spectator-core-parity.log 및 unity-spectator-core-parity.log에서 원본 881개와 core 검사가 통과했다. 물리 10000틱 SHA256은 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D로 유지됐다.
- lobby-spectator-metadata-clean-tests.log에서 전체 Gradle 검사 BUILD SUCCESSFUL(15분 15초)을 확인했다. JUnit XML 합계 262개 중 241개 통과, 21개 제외, 실패/오류 0개다. GameSessionServiceTest의 새 구형/신형 방 정보 roundtrip 메서드가 실제 실행됐다. 처음 keyOf 컴파일 오류는 캐시 제외 재컴파일로 해소됐으며 무관한 퀘스트 소스를 수정하지 않았다.
- 관전 모드를 GameScene에 아직 활성화하지 않았다. LockstepConnection의 입력 전송 방지, 관전용 presentation/recovery, 서버의 저장 결과 읽기 전용 조회를 연결한 뒤 StompConnector의 관전 차단을 제거해야 한다.
- 실제 client unity-spectator-core-client-results.xml의 58개 통과와 spectator-core-verifier-build.log 빌드 성공도 확인했다. Unity가 자동 생성한 Android 아이콘 설정만 원복했다. 최신 대응표는 894/915 verified, 21개 미이관이다. WebGL은 이번 관전 모드 변경 이후 다시 빌드하지 않았으므로 직전 결과를 현재 코드의 검증으로 간주하지 않는다.

### GameScene 관전 모드와 저장 결과 조회 연결 (2026-10-27)
- StompConnector가 관전 모드로 LockstepConnection을 설정한다. 관전자는 슬롯 없이 전투를 재생하고 마나/손패가 없는 presentation과 recovery snapshot을 받는다. 카드 사용/선택, 감정표현, 빈 틱 입력을 모두 차단한다. PVE 목표/대사/상태는 왼쪽 참가자 채널에서 한 번 전달하고, 복구 조회는 시뮬레이션을 진행시키지 않는다.
- GET /api/lockstep/{id}/result를 양수 사용자 ID를 가진 관리자 관전자에게 제공한다. DB에 저장된 결과만 조회하며 아직 저장 전이면 202를 반환한다. 입력 검증기, 통계/보상 갱신, lobby 종료 알림을 호출하지 않는다. 세션이 메모리에서 사라진 재시작 인스턴스에서도 같은 저장 결과를 조회한다. 관전자 클라이언트는 POST complete 대신 이 GET을 사용하고 202/일시 실패를 재시도한다.
- 첫 네트워크 검사는 외부 검증기 30초 대기에서 타임아웃으로 종료됐다. 도구 응답도 20분 이상 지연됐고 Unity는 비정상적으로 긴 컴파일 시간을 기록했다. 이후 Unity 실행 핸들, 해당 프로젝트 프로세스, 결과 XML이 모두 없는 상태를 확인해 재실행했다. 기존 임시 DB 부재를 확인하고 새 전용 DB로 네트워크 검사를 재실행했다.
- unity-spectator-scene-retry-results.xml은 61개 통과/실패 0개다. 관전자의 GET 결과 202→200 재시도와 결과 1회 표시, 입력 API 거부, 복구 snapshot, PVE 상태 복구를 검사했다. spectator-result-network-retry.log는 draw/cast/PVE/규칙 봇 네 경기와 재접속/검증/저장을 22.06초에 통과했다. 각 경기의 저장 전 202, 권한 거부, 저장 후·재시작 후 관전 결과 일치, 보상 불변 및 종료 알림 1회를 확인했다. spectator-result-clippy.log도 통과했다.
- 검증용 ac-lockstep-spectator-result-retry DB를 정리하고 Unity 자동 Android 아이콘 변경만 원복했다. 이 검증은 실제 HTTP/STOMP와 Unity EditMode를 각각 실행한 것이다. 렌더링된 관전 GameScene에서 결과 화면까지 직접 완주하는 검증과 WebGL 재검증은 아직 필요하다. 원본 테스트 21개, 모델 봇, 전체 상태 hash/desync, 미완료 경기 서버 재시작 복구/종료 알림 outbox 등 전체 목표는 계속 남는다.

### 시전·카드 선택 입력 타입 검증과 원본 테스트 이관 (2026-10-27)
- StompConnector의 lockstep 입력 경로가 DTO 클래스만 보고 변조된 type도 받아들이던 문제를 수정했다. useMagic/selectCard/unselectCard를 각각 확인하며 null 시전 입력과 알 수 없는 선택 입력은 큐에 넣지 않고 false를 반환한다. 기존 서버 전달 경로는 변경하지 않았다.
- 원본 input_use_magic 및 input_card_aim_and_retired_types를 실제 Unity JsonCodec와 StompConnector/LockstepLocalInputs 경로로 이관했다. 원본 JSON의 magicId 34, 요청 ID 7, 좌표 (9,0,5), 시전 응답 ID 복원과 선택/해제 종류를 확인한다. toggleCard/cancelCard 및 다른 메시지 타입을 거부하고 큐가 비어 있는지도 검사한다. lockstep 입력에서는 위치를 Q32.32 raw로 옮기며 요청 ID는 화면 응답용 매핑으로 유지한다.
- 첫 검사에서 NUnit/Unity Property 이름 충돌이 발생해 NUnit 속성 alias로 수정했다. unity-input-kind-parity-fixed-results.xml에서 63개 전체 통과 및 새 원본 대응 메서드 두 개의 실행을 확인했다. Unity 자동 Android 아이콘 변경만 원복했다. 원본 대응은 896/915, 미이관 19개다.

### 실제 PVE GameScene 완주 검사 추가 (2026-10-27)
- LockstepPlayableSceneTests를 추가했다. opt-in 설정으로 실제 PlayMode/GameScene에 진입하고 플레이어 presentation 캡처, ResultScene 진입과 Win 제목 표시를 검사한다. Rust lockstep_client_network fixture의 AC_LOCKSTEP_UNITY_CONFIG 분기는 Unity가 PlayMode 진입 후 경기를 생성하도록 설정을 제공하고, 완료 보고 이후 DB 결과/PVE FINISHED/lobby 통지 1회를 검증한다.
- Rust fixture 컴파일과 Unity 테스트 컴파일은 통과했다. playable-pve-unity-v1.xml은 EnterPlayMode domain reload 후 지역 변수 소실로 실패했다. 설정 경로를 전환 후 다시 읽도록 수정했다. v2는 GameScene 진입 후 AdminOnly가 SceneContext.Instance 부재를 오류로 기록해 실패했다. 로그인 장면이 준비하는 SceneContext 인스턴스와 fixture JWKS 캐시를 테스트에 추가했고, 이 수정은 아직 Unity 재실행 전이다.
- 테스트 실패로 coroutine이 중단되어도 서버가 완료 보고를 기다리며 남지 않도록 UnityTearDown에서 실패 보고를 남기도록 추가했다. 실제 PVE 완주는 아직 미검증이다. v1 서버 핸들 62352는 중단(종료 코드 1), Unity 핸들 27345/53902는 종료 코드 2다. 일회용 ac-lockstep-playable-pve DB를 종료하고 Unity Android 아이콘 자동 변경만 원복했다. 다음 실행은 새 설정/보고 경로와 빈 DB를 사용해야 한다.

### 실제 Unity PVE 경기 완주 통과 (2026-10-27)
- 실제 GameScene 실행에서 PveObjectiveHud가 읽을 수 없는 내장 UI/Skin/UISprite.psd를 요청하는 오류를 확인했다. 목표 HUD와 대사 말풍선 fallback을 포함된 UI/Flat/FlatCard 자산으로 바꿨다. 장면 종료 때 OnPlayerDestroyController가 사망 tween을 새로 만들던 문제는 ServedObject.OnDestroyed에 연결하고 OnDestroy에서 해제하도록 수정했다.
- 기존 PingSender가 lockstep 경기에서도 legacy /app/game/input 경로로 ping을 보내 미연결 오류를 만들었다. lockstep에서는 매 틱 입력/확정 프레임으로 생존 여부를 관리하므로 기존 PingSender를 Awake에서 비활성화했다. 기존 경기 경로는 유지한다.
- playable-pve-unity-v3는 HUD 리소스/종료 tween 오류로 실패, v4는 legacy ping으로 실패했다. v5는 실제 ResultScene과 승리 표시까지 도달했으나 NoUnexpectedReceived가 정상 Log까지 실패로 처리했다. 과도한 검사를 제거하고 Unity Test Runner의 기본 오류/예외 검사는 유지했다.
- 최종 playable-pve-unity-v6.xml: 실제 PlayMode 테스트 1개 통과, Unity 종료 코드 0. playable-pve-server-v6.log: 1개 통과(70.80초), UNITY SCENE RESULT PERSISTED. DB 승리 결과, PVE FINISHED, lobby 종료 통지 1회 확인. playable-pve-v6.json.png 전장 카메라 캡처를 직접 확인했다. overlay 전체 UI 캡처는 아니다.
- 새 검증 실행법과 범위를 Tools/LockstepProbe/README.md에 기록했다. 이번 검사는 빈 손패의 Survive PVE 한 경기이며 실제 lobby 매칭 UI, 카드 시전/규칙 봇/PVP 장면 완주를 대신하지 않는다. 원본 테스트 19개, 모델 봇, 상태 해시/desync 등 전체 목표는 계속 남는다. 최종 일회용 ac-lockstep-playable-pve-v6 DB 종료 및 Unity Android 아이콘 설정 원복, client diff --check 통과. 최신 일반 EditMode 회귀 검사와 WebGL 재검증은 이번 화면 수정 이후 아직 수행하지 않았다.

### 실제 규칙 봇 GameScene 완주 통과 (2026-10-27)
- 실제 Unity 검사 fixture에 AC_LOCKSTEP_UNITY_MODE=bot 모드를 추가했다. Practice 경기에서 규칙 봇에게 lightning_explosion 덱을 제공하며 인간 손패는 비워 봇의 시전으로 발생한 패배를 확인한다. Unity는 설정의 참가자/세션/예상 결과를 사용해 같은 실제 GameScene/ResultScene 경로를 실행한다.
- playable-bot-unity-v1.xml: 실제 PlayMode 1개 통과, 종료 코드 0. playable-bot-server-v1.log: 1개 통과(65.43초), 서버 독립 검증 및 저장 결과 Lose와 lobby 통지 1회 확인. playable-bot-v1.json.png를 직접 열어 양쪽 캐릭터가 실제 전장에 표시됨을 확인했다. 캡처는 경기 시작 시점이며 시전 순간의 시각 검증을 대신하지 않는다.
- 일회용 ac-lockstep-playable-bot-v1 DB를 종료했다. Rust cargo fmt --check와 diff --check 통과. README에 두 모드의 실행 방법과 검증 범위를 기록했다. 인간 카드 입력, 실제 PVP/로비 UI부터의 경기, 모델 봇, 전체 상태 hash/desync, 남은 원본 테스트 이관은 계속 남는다.
- playable-scene-regression.xml에서 기존 관련 EditMode 검사 63개 통과, 실패 0개를 확인했다. 외부 fixture가 필요한 실제 장면 검사 1개는 일반 실행에서 의도적으로 제외됐으며, 별도 bot/PVE 실행 통과와 구분한다. Unity 종료 코드 0, Android 아이콘 자동 변경 원복 및 client diff --check 통과. Graphify CLI는 여전히 없어 갱신하지 못했다.

### 실제 카드 UI 시전과 PVP 결과 일치 검증 (2026-10-27)
- AC_LOCKSTEP_UNITY_MODE=cast를 추가했다. Unity가 경기 생성 후 ready 파일을 쓰면 fixture가 별도 .NET 상대 프로세스를 연결한다. 인간에게 lightning_explosion 손패를 제공하고 실제 CardUI.OnCardClicked → CardInputSender.TrySendInput 경로로 (17,0,5)에 시전한다. fixture 마법 목록은 실제 MagicInfoDataSource.ProcessResponse 경로로 메모리에 준비한다.
- 첫 playable-cast-unity-v1은 EnterPlayMode domain reload에서 lambda의 캡처 객체가 복원되지 않아 카운터 초기화 때 실패했다. 전환 후 생성한 CastCounter와 인스턴스 메서드 delegate로 바꿨다. 게임 코드 변경은 없었다.
- playable-cast-unity-v2.xml에서 실제 장면 검사 1개 통과, Unity 종료 코드 0. 카드 선택/시전 요청 성공, UI 시전 성공 응답 정확히 1회, ResultScene Win 제목을 확인했다. playable-cast-server-v2.log에서 1개 통과(49.57초), 상대 프로세스의 completed/acceptedCasts=1/RightPlayer 패배, 서버 저장 결과 Win 및 lobby 통지 1회를 확인했다.
- README에 cast 모드를 기록했다. 이 검사는 실제 카드 UI 메서드와 네트워크를 연결하지만 마우스 좌표 클릭, 실제 로비 매칭 API, 양쪽 Unity 화면 실행은 검증하지 않는다. 모델 봇/전체 상태 hash/desync/남은 원본 테스트 등 전체 목표는 계속 남는다.
- 일회용 ac-lockstep-playable-cast-v2 DB 종료, Unity Android 아이콘 자동 변경 원복, client/game-rust diff --check 및 cargo fmt --check 통과.

### 매칭·재접속 응답의 mapType 누락 수정 (2026-10-28)
- 실제 로비 진입 경로를 점검하다 게임 서버 readiness, 로비 SessionReadyResponse/MatchedInfoDto/SessionRecoveryInfo에서 mapType이 누락된 것을 확인했다. 이 상태에서는 River 전투 시뮬레이션과 기본 전장 화면이 달라질 수 있다. 서버는 확정 초기 snapshot의 map을 준비 응답에 포함하고, 로비는 최초 매칭 및 저장/복구 DTO에 문자열 그대로 전달한다. 구형 응답의 필드 부재는 null로 허용한다.
- lockstep_battle_database 실제 DB 검사 1개 통과(0.29초), River 준비 응답 추가 assertion 통과. match-map-clippy.log의 Rust clippy --lib -D warnings 통과. 로비 매칭 서비스와 복구 JSON 검사를 보강했다.
- Unity PlayMode 검사가 /api/server/lockstep-matches 응답의 mapType/버전을 사용하도록 바꿨다. AC_LOCKSTEP_UNITY_MAP=RIVER, cast 모드로 실행한 readiness-river-unity.xml은 1개 통과, readiness-river-server.log는 1개 통과(70.42초). 실제 강과 다리가 표시되는 PNG를 직접 확인했고 카드 시전/상대 결과 일치/Win 화면/DB 저장까지 확인했다. 이는 로비 Spring 전체 실행 또는 매칭 버튼 클릭 검증을 대신하지 않는다.
- 로비 전체 테스트 첫 실행은 PowerShell이 -Pkotlin.incremental=false 인수를 나눠 task 이름으로 전달하여 실행 전에 실패했다. 인수를 따옴표로 고정한 재실행은 Kotlin/Java 및 test 컴파일을 지나 test 단계에 있다. 핸들 19608과 client/Tools/LockstepProbe/.generated/lobby-match-map-tests-retry.log를 확인해야 한다. 최신 JUnit XML은 아직 생성되지 않았으며 전체 통과를 주장하지 않는다.
- 일회용 ac-lockstep-match-map 및 ac-lockstep-readiness-river DB 종료, Unity Android 아이콘 자동 변경 원복, client/game-rust/lobby diff --check 및 Rust fmt 검사 통과. 원본 테스트/모델 봇/상태 해시/desync/실제 로비 UI 등 전체 목표는 계속 남는다.

### 모델 봇 확정 이벤트 연결 검토 (2026-10-28)
- 현재 서버는 모델 봇 생성을 거부하며 클라이언트 SessionBotControl은 동기화된 decisionFactory를 요구한다. 이 차단을 먼저 해제하지 않는다. 기존 OpenRouter 계열은 요청 대기 중 None을 반환하고, JEV stance 계열은 기존 stance로 계속 판단한다. 응답의 단순 좌표 기록만으로는 원본의 현재 손패 확인/현재 전장 재조준/소환 고정 위치 규칙을 보존할 수 없다.
- plan-review 스킬의 fast/medium 검토를 수행했고 두 검토 모두 초안 NONPASS였다. 수락/거부/실패/backoff도 확정 기록에 포함, 두 정책의 대기 동작 분리, 관측 tick/candidate digest의 verifier 재구성, side/generation 식별, 사람 입력과 서버 모델 이벤트 분리, driver에서 protocol 오류 검출이 필수 수정으로 제시됐다.
- 수정안은 기존 v1 경기와 별도의 모델용 v2 계약, 서버 전용 confirmed modelEvents, exact Think 시점에 생성하는 (side,generation,sequence,observationTick,digest) intent를 사용한다. 인간+봇 경기에서는 그 인간만 요청을 제출한다. 모든 replica는 같은 순서로 후보/fallback을 한 번 계산해 RNG를 보존하고, 서버의 외부 응답은 관측 이후 아직 확정하지 않은 tick에 기록한다. provider/model/prompt 정책은 frozen persona와 서버 설정에서 정하며 클라이언트가 임의 지정하지 않는다.
- 첫 구현 단계는 실제 driver/source/factory/verifier에 기록 이벤트 재생 경로를 연결하는 것이다. 이후 OpenRouter와 JEV 정책/원본 테스트를 각각 고정 소수점으로 이관하고 서버의 기존 key/provider HTTP를 연결한다. 주입한 provider 응답으로 relay/history/recovery/verifier 검사를 통과한 뒤 생성 차단을 해제한다. 봇끼리의 headless client 실행은 별도 미완료 항목이며 성공 조건에서 제외하지 않는다.
- heavy 최종 검토가 진행 중이다. 아직 이 모델 프로토콜 수정안의 구현이나 검증 완료를 주장하지 않는다.

### 로비 전체 검사 결과와 타임아웃 재검사 (2026-10-28)
- lobby-match-map-tests-retry.log 전체 검사는 6분 59초에 종료됐다. 최신 JUnit XML 합계 262개 중 240 통과, 21 제외, 1 실패다. 실패는 DataControllerTest.getMagics_WithoutVersion_ReturnsAllMagics의 15초 blocking read timeout이다. 이번 mapType 변경 대상 LegacyGameMatchServiceTest 14개와 LockstepRecoveryContractTest 2개는 모두 통과했다.
- 실패 테스트의 소스는 변경하지 않았다. 정확한 클래스 이름으로 실행한 재검사는 핸들 80038, 로그 lobby-match-map-timeout-retry-v2.log에서 test 단계 실행 중이다. 이전 glob 실행은 WSL 기본 zsh의 no matches found로 시작하지 못했다. 전체 통과로 기록하지 않는다.

### 모델 봇 설계 최종 검토와 식별자 연결 (2026-10-28)
- 첫 heavy 검토는 요청 미제출 시 무한 pending과 기존 즉시 fallback의 시점 차이 때문에 NONPASS였다. intent는 관측 다음 InputBatch의 필수 manifest로 제출하고, 서버는 그 배치 수락과 같은 확정 프레임에 Accepted/Rejected를 기록한다. replica/verifier가 누락·추가·digest 충돌을 검사한다. 수락 응답에는 terminal 최대 tick을 포함하며 그 tick까지 완료/timeout이 없으면 재생을 거부한다. 재접속의 동일 요청은 provider를 다시 호출하지 않는다.
- 외부 capacity/health/provider 응답은 이를 담은 확정 tick부터 적용한다. 원본의 즉시 executor-full fallback은 다음 확정 프레임의 거부 응답 시점으로 이동한다. 이 필수 입력 지연을 기존과 정확한 dispatch frame 일치로 집계하지 않는다. 각 정책의 fallback/RNG/재조준 및 JEV의 대기 중 기존 stance 유지 규칙은 보존한다.
- 두 번째/최종 heavy 검토는 HEAVY REVIEW: PASS였다. 구현 전에 위 수정 계약을 확정했다. 현재 첫 단계에서 decisionFactory에 side와 generation을 전달하고, 확정 모델 프로토콜 오류가 ThinkFailed에만 남은 채 경기가 계속되지 않도록 runtime/driver 종료에 연결한다. 서버의 모델 봇 생성 차단은 유지한다. 이벤트 스트림/정책/provider 연결은 여전히 미완료다.
- lobby-match-map-timeout-retry-v2.log의 DataControllerTest 클래스 재검사는 BUILD SUCCESSFUL(2분 26초), 종료 코드 0이다. 첫 전체 suite의 240 통과/21 제외/1 timeout과 구분한다. 전체 suite 재통과를 주장하지 않는다.
- model-source-identity-parity.log와 unity-model-source-identity-parity.log에서 원본 881개, core, 물리 10000틱이 통과했다. 새 core 검사는 슬롯별 독립 generation, 생성 실패 후 generation 재사용, 확정 모델 프로토콜 오류 시 driver 실패/runtime 종료/종료 통지 1회/후속 프레임 거부를 확인한다. 원본 대응 수를 늘리는 테스트로 집계하지 않는다.
- model-source-identity-verifier.log 빌드 통과(기존 Fix64 경고 4개). 실제 client의 model-source-client.xml은 Lockstep 필터 39개 통과/0 실패/외부 fixture 장면 검사 1개 의도적 제외이며 Unity 종료 코드 0이다. 별도 isolated Unity probe도 종료 코드 0이다. 자동 Android 아이콘 변경은 그 한 hunk만 존재함을 확인한 뒤 원복했다. diff --check 통과, graphify update .는 CLI 미설치로 불가했다.

### Claude 구현 위임 시작 (2026-10-28)
- 사용자가 Codex 토큰 사용을 줄이기 위해 Claude를 적극 활용하도록 요청했다. Claude Code 설치/인증을 확인하고 모델 봇 v2 확정 요청·응답 replay slice 구현과 .NET 검사를 위임했다. 소유 범위는 client 시뮬레이션/관련 연결·검사이며 Rust/lobby/계획 편집 및 Unity 실행은 위임하지 않았다. 주 에이전트는 검토·통합 검증을 맡는다.
- 첫 CLI 호출은 API ENOTFOUND로 종료 코드 1, 코드 변경 없이 종료했다. 샌드박스 외부 네트워크 실행으로 재호출했으며 핸들 28738이 살아 있다. Claude session 1a65ff0b-9c4c-467a-a34c-e2033846c7a9의 최신 tool 호출에서 실제 LockstepProtocol.cs Read를 확인했다. 출력은 client/Tools/LockstepProbe/.generated/claude-model-stream-retry.json이며 완료 전에는 비어 있다. 초기 로그의 빈 파일만으로 중단으로 판단하지 않는다. 구현 완료나 통과를 아직 주장하지 않는다.
- Claude 핸들 28738의 실제 진행을 재확인했다. 초기 PowerShell dotnet 도구는 권한 거부됐으나 허용된 Bash 경로로 기준선 실행을 완료했다. claude-model-baseline.log에서 원본881/core/물리10000틱 통과와 동일 SHA256을 확인했다. 이후 BotLifecycle.cs Read와 관련 Grep이 계속 기록되고 있으며 CLI 핸들은 살아 있다. 새 구현 완료나 최종 통과로 집계하지 않는다.
- Claude가 ModelDecisionProtocol.cs를 작성하기 시작했고 주 에이전트가 읽었다. 완료 후 재검토할 항목: 후보 Plays/Aims 목록의 불변 복사, digest의 observed time 및 stance 선택 metadata 포함 여부, wire tick와 Think observationTick의 기준 일치, terminal event의 digest 필드 엄격성. 현재 작성 중인 파일이므로 결함 확정이나 검사 통과로 기록하지 않는다.
- ModelEventLedger.cs 초안을 읽었다. 최종 코드 재검토에서 terminal 응답의 동일 key/다른 payload 충돌, accepted와 terminal의 observationTick 결속, 동일 generation 재Attach 시 sequence 재사용, replaced generation의 late response 무시와 위조 응답 거부를 구분해야 한다. 아직 Claude 작성 중이며 수정 요청은 완성 보고 후 같은 세션 resume으로 전달한다. 소스 동시 수정은 하지 않았다.
- ModelDecisionSource.cs 초안과 원본 llm_decision_source.rs Think를 대조해 반드시 수정할 fidelity 차이를 확인했다. 현재 C# Think는 OpenRouter pending/요청 간격 제한/완료 wait/손패 소멸/명시적 aim에서도 fallback.Think와 candidate Build를 무조건 실행한다. 원본은 이 분기들에서 fallback을 호출하지 않으며, 결과가 실패면 한 번, reaim이 필요할 때만 standard를 계산한다. 난수 소비와 이후 판단이 바뀌므로 final review에서 원본 분기별 호출 횟수·RNG 상태 검사를 추가하고 수정해야 한다. JEV는 원본처럼 fallback을 먼저 계산하되 candidate Build에는 standard가 아니라 null을 전달한다. production-disabled slice여도 이 차이를 원본 동등 동작으로 집계하면 안 된다.
- v2 모델 필드 추가가 기존 .NET v1 network probe에 미치는 회귀를 확인했다. JsonCodec는 null 필드를 생략하지만 NetworkBattleProbe의 System.Text.Json 설정은 modelRequests:null을 보내며 Rust v1 InputBatch는 deny_unknown_fields로 거부한다. Claude 소유 범위 밖 NetworkBattleProbe의 v1 payload를 tick/commands 명시 anonymous DTO로 수정했다. 모델용 probe 연결을 대신하지 않으며 실제 v1 네트워크 재검사는 Claude 첫 slice 빌드 완료 후 수행한다.

### 모델 replay 첫 slice와 기존 네트워크 회귀 검증 (2026-10-28)
- Claude 첫 구현 세션 1a65ff0b-9c4c-467a-a34c-e2033846c7a9/핸들28738은 종료 코드0으로 완료됐다. ModelDecisionProtocol, ModelEventLedger, ModelDecisionSource, ModelBotDecisions 및 실제 driver/runtime/local inputs/GameScene 생성 경로를 연결했다. 후보 builder는 표준 선택지+wait 중심이며 전체 원본 후보 이관/서버 v2/provider/verifier 모델 연결/headless는 미완료다.
- claude-model-source-replay.log에서 원본881/core/물리10000틱 통과. 주 에이전트가 별도 UnityProbe에 첫 snapshot을 복사해 실행한 unity-claude-model-first-parity.log도 같은881/core/물리와 SHA256 BF7A3B87B1681C31BF98A630E4746B9CE2ED3C95C9ADF1F00AE4159F6B150C7D 통과, 종료 코드0이다. 실제 client Unity 실행과 최신 WebGL 검증을 대신하지 않는다.
- 검토 6개 수정사항을 .generated/claude-model-review.txt로 전달하고 같은 Claude 세션을 resume했다. 새 핸들50320, 최종 출력 .generated/claude-model-review-session.json이다. 원본 분기별 RNG 소비, terminal duplicate conflict/observationTick 결속, 메뉴 불변성/digest, terminal reason/digest 검증, v1 모델 필드 분리, generation Attach 원자성을 보완 중이다. 첫 통과를 원본 전체 동등성으로 간주하지 않는다.
- model-first-v1-network.log에서 실제 Rust 서버+독립 .NET probe/verifier+일회용 DB 경기 검사1개(4모드 draw/cast/PVE/Rule bot)가 23.74초에 통과했다. 재접속/전투결과 독립 검증/저장/복구 경로도 포함한다. 첫 모델 snapshot DLL을 .generated/ModelFirstNetwork에 복사해 Claude 후속 빌드와 격리했다. 일회용 ac-lockstep-model-first-network DB를 종료했다. 첫 docker 시작은 붙여 쓴 -p 인수로 invalid reference format이 났으며 --exec docker와 분리 -p 인수로 정상 시작했다. diff --check 통과.

### 모델 replay 검토 수정본 Unity 통과 및 전체 후보 이관 위임 (2026-10-28)
- Claude 검토 수정 세션50320은 종료 코드0으로 완료됐다. 분기별 지연 fallback/candidate 계산과 실제 seeded BotBrain 다음 판단 비교, accepted-terminal observationTick 결속·동일 본문 멱등·충돌 거부, frozen 후보/digest에 observed time·stance 선택 포함, bounded provider reason, v1 빈 모델 필드 거부, 단조 generation/Bind 원자성 및 회귀 검사를 추가했다.
- claude-model-review-fixes.log에서 원본881/core/물리10000틱 통과. 주 에이전트가 새 snapshot으로 실행한 unity-model-review-parity.log도881/core/물리10000틱과 기존 SHA256 통과, 종료 코드0이다. 실제 client model-review-client.xml의 Lockstep 필터39통과/0실패/1의도적 외부fixture 제외, 종료 코드0. 이 결과는 원본 server 모델 후보 전체 이관이나 v2 실제 네트워크/HTTP 검증을 뜻하지 않는다.
- Unity가 자동 추가한 Android 아이콘 93/1 한 hunk만 존재함을 확인해 원복했고 diff --check가 통과했다. 검사 중 뜬 자동 생성 whitespace 경고는 이 hunk와 함께 없어졌다.
- 다음 단계인 원본 llm_candidate_builder/llm_candidates 전체와 원본 모델 후보 테스트 이관을 같은 Claude 세션에 위임했다. 작업 지시 .generated/claude-model-candidate-task.txt, 새 핸들87136, 최종 출력 .generated/claude-model-candidate-session.json. 원본 server 모델 검사는 기존 simulation915 대응 수와 분리해 목록·통과 수를 기록하도록 지시했다. 임시 표준 후보+wait 및 JEV attack/save 빈 후보를 생산 full builder로 대체해야 한다. 서버 v2/provider/verifier 모델 연결과 headless/최신WebGL/남은19 simulation검사/실제로비UI/상태hash 목표는 그대로 남는다.

### 남은 원본 19개 테스트 읽기 전용 Claude 검토 시작 (2026-10-28)
- 모델 후보 구현 핸들87136이 살아 있음을 재확인했다. 사용자 요청에 따라 Claude 활용을 늘리되 구현과 검토의 소유 범위를 분리했다. parallel 스킬 및 subagent-model 지침을 읽고, 남은 simulation19개의 원본 의미·이관 위치·구조 변경 대안을 읽기 전용 Claude Sonnet 세션에 맡겼다.
- 새 핸들99308, 출력 .generated/claude-remaining-tests-audit.json. Read/Glob/Grep 도구만 허용했고 편집·shell·추가 agent를 금지했다. 보고가 나오기 전에는 이관 완료나 검증 증거로 집계하지 않는다. 기존 Claude 후보 구현과 공유 소스 쓰기 충돌이 없다.

### 남은 원본 테스트 검토의 적용 범위 (2026-10-28)
- 읽기 전용 Claude Sonnet 핸들99308은 종료 코드0으로 완료됐다. 보고 .generated/claude-remaining-tests-audit.json, 세션03059711-d60d-491f-bd61-7b2673196ab5. 원본19개 목록과 구조 차이 탐색에는 사용했지만, 17개를 범위 밖/불필요로 재분류하자는 권고는 사용자 전체 이관 목표를 축소하므로 채택하지 않는다. 대응표 상태를 바꾸지 않았다.
- 주 에이전트가 보고의 누락을 직접 확인했다. BattleSessionChecks.Run은 이미 PVE decided→send 순서와 zero MMR을 검사하며, Data/Magic/MagicInfoDto와 Vector3JsonConverter/테스트는 실제로 존재한다. 따라서 DTO/float 검사를 무조건 없애는 근거로 삼지 않는다. 또한 원본 PVE 검사는 online 복귀·비평점 hook까지 확인하므로 C# 순서 단언만 추가해 원본 전체 이관으로 세지 않는다. 원본 start/lifecycle 검사에도 await/fps 등 추가 보장이 있어 단일 IsRunning 단언으로 전체 통과를 부풀리지 않는다.
- 모델 후보 구현87136은 계속 실행 중이며, 테스트19개를 모두 제외하는 것으로 목표를 재정의하지 않는다. 이후 기존 실행 구조와 달라진 보장은 적절한 클라이언트/릴레이/로비 통합 경로에서 검증해야 한다.

### 모델 후보 이관 세션 재개 (2026-10-28)
- 이전 핸들87136이 Unknown process id가 됐고, 해당 session ID를 가진 실제 Claude 프로세스가 없음을 CIM에서 확인했다. 다른 사용자 Claude 프로세스들은 건드리지 않았다. 최종 출력이 비어 있어 완료로 간주하지 않았다.
- 첫 재개는 자동 승인 검토에서 private 소스의 Claude 전송/acceptEdits 권한 근거 부족으로 거부됐다. 우회하지 않고 claude auth status로 claude.ai/firstParty 로그인 및 customBaseUrlSet=false, 공식 WinGet Claude 실행 파일을 확인했다. 사용자의 worktree 전투 이관 지시와 'claude를 적극적으로 활용'하라는 직접 승인 문구를 근거로, 도구/수정 범위를 재차 한정하여 같은 세션 재개를 다시 요청했고 승인됐다.
- 새 핸들98270, 출력 .generated/claude-model-candidate-resume-session.json. 모델 후보/조준 이관 완료·원본 inventory·.NET 검사 마무리를 맡겼다. 주 에이전트의 model-candidate-local-check.log는 아직 변경 중인 ModelCandidateMenu 생성자와 제거된 StandardTacticCandidateBuilder를 참조하는 ModelDecisionChecks에서 컴파일 오류로 끝났다. 최신 후보 코드 통과를 주장하지 않는다. 이관 중 소스를 초기 통과본으로 되돌리지 않았다.

### 전체 모델 후보 첫 이관 Unity 통과와 생산 기본값 보완 (2026-10-28)
- 후보 재개98270은 종료 코드0으로 완료됐다. ModelCandidateBuilder/ModelText/ModelUnitGuide와 실제 Confirmed factory/ModelStanceTurn을 연결했고, JEV attack 테스트가 실제 시전·상대 HP 감소를 확인하도록 바뀌었다. claude-model-candidate-probe.log에서 simulation881/model-original36/core/물리10000틱 통과. 모델 inventory는 실제 원본44개 중36 ported/8 not_ported, no-test 파일 placeholder1개로 총45행이다. 기존 simulation915 대응 수를 늘리지 않았다.
- 주 에이전트가 독립 집계한 원본은 candidate_builder22, candidates0, unit_guide6, answer2, json2, descriptions3, stance9다. 묶인 카드 설명 관련2개와 provider 파싱/stance HTTP 관련6개가 아직 inventory 미이관이다. llm_decision_source 전체 provider/executor 테스트는 이44개 범위에도 포함되지 않으므로 별도 미완료다.
- 주 에이전트의 unity-model-candidate-parity.log에서 simulation881/model36/core/물리10000틱 및 기존 SHA256 통과, 종료 코드0. 실제 client model-candidate-client.xml의 Lockstep39통과/0실패/외부fixture1의도적 제외, 종료 코드0. Unity 자동 Android 아이콘 변경이93/1 한 hunk뿐임을 확인해 원복했고 diff --check 통과.
- 검토에서 기본 MagicDescriptions.Empty로 원본의 묶인 설명문이 사라지고, PlacementRandom이 상수+side+generation만 사용해 session seed를 쓰지 않는 생산 연결 공백을 확인했다. 같은 Claude 세션에 .generated/claude-model-bundled-task.txt의 두 수정을 위임했다. 새 핸들42644, 출력 .generated/claude-model-bundled-session.json. 묶인 리소스는 .NET/Mono/WebGL 동일 정적 데이터로 연결하고 원본2개를 추가, snapshot.randomSeed는 독립 placement RNG에 전달하며 기존 fallback/gameplay RNG 소비를 바꾸지 않도록 지시했다.

### 다음 서버 모델 연결의 고정 계약 확인 (2026-10-28)
- 현재 ModelRequest는 slot/generation/sequence/observationTick/digest만 담고 있어 서버가 실제 모델에 전달할 관측·후보 본문이 없다. 승인된 v2 계약의 다음 InputBatch에 full canonical observation/candidate payload를 함께 담고, verifier가 정확한 Think에서 이를 재구성해 digest/본문 일치를 확인하는 연결이 남는다. client 임의의 provider/model/URL/system prompt를 받는 구조로 대체하지 않는다.
- 원본 LlmBotProperties의 기본 간격은 OpenRouter1500ms/JEV500ms이며 JEV mode는 PLAY/STANCE/CARD(기본 STANCE)다. 현재 C# default30tick/BrainType.Jev→Stance/cardMenufalse만으로 실제 서버 설정 보존을 주장할 수 없다. server가 provider·model·policy·menu·min interval을 frozen 초기 설정으로 정하고 양쪽 replica와 verifier가 같은 값으로 생성해야 한다. URL/key/secret은 snapshot에 넣지 않는다.
- 기존 BotDecisionSourceFactory는 key 설정이 없으면 Rule source를 바로 사용하며, health와 bounded executor/HTTP/provider parser를 소유한다. 서버 v2 연결은 이 기존 IO/키/health 경로를 재사용하되 외부 capacity/health/outcome을 확정 이벤트로 기록해야 한다. 원본 provider 파싱/HTTP 검사를 단순 후보 테스트로 대체하지 않는다.

### 묶인 설명·세션 seed Unity 통과와 실제 모델 네트워크 연결 위임 (2026-10-28)
- Claude 설명/seed 세션42644는 종료 코드0. ModelMagicDescriptions 정적 문자열이 서버 원본 properties와 일치함을 주 에이전트가 빌드 assembly의 const 값으로 직접 대조했다(bundledMatchesOriginal=true). 기본 builder가 Bundled를 사용하며 Confirmed(sessionSeed)가 별도 placement RNG를 생성하고 GameScene이 snapshot.randomSeed를 전달한다. 묶인 설명 원본2개 추가로 model inventory는38 ported/6 not_ported(+no-test placeholder1)다. provider/executor 전체는 별도 미완료다.
- claude-model-bundled-probe.log에서 simulation881/model38/core/physics 통과. 주 에이전트의 unity-model-bundled-parity.log도 동일881/model38/core/물리10000틱 및 SHA256 통과, 종료 코드0. 실제 client model-bundled-client.xml Lockstep39통과/0실패/외부fixture1의도적 제외, 종료 코드0. Unity 자동 Android 아이콘93/1 한 hunk 확인·원복, diff --check 통과.
- 다음 실제 v2 인간+모델 네트워크 pipeline을 같은 Claude 세션에 맡겼다. 작업지시 .generated/claude-model-network-task.txt, 새 핸들93259, 출력 .generated/claude-model-network-session.json. 소유 범위를 필요한 client/game-rust/lobby로 확장하되 추가agent/Unity/commit/push/실서비스/인증·환경파일 접근 금지. 기존 approved v2 계약에 canonical payload 결속, 중첩 ModelJson State 불변성, server-frozen JEV mode/간격/key 미설정 fallback, capability/version 전달, 실제 기존 provider IO의 로컬 mock 실행, request idempotence/deadline/history/recovery/verifier/저장 검증을 포함했다. 생성 차단은 실제 end-to-end 증거 후 v2 경로에서만 해제하도록 지시했다.
- 로컬 Postgres ac-lockstep-model-v2-stream을 --rm/127.0.0.1:15439로 시작했고 이 작업만 사용할 AC_LOCKSTEP_TEST_DATABASE_URL/probe/verifier/migration 경로를 child에 전달했다. DB 이름은 lockstep_snapshot_test이며 실데이터 복제가 아니다. 현재 이 전용 컨테이너는 Claude 통합 검사 대기 중이라 살아 있다. 완료/중단 후 해당 이름만 종료해야 한다. 다른 Claude/Unity/DB 프로세스를 정리하지 않는다.

### 서버 모델 테스트 원본 전수 목록과 검증 기준선 분리 (2026-10-28)
- 주 에이전트가 tools/lockstep-model-test-inventory.py를 추가해 game-rust HEAD의 crates/server/src/bot/llm 원본 test/tokio::test attribute와 함수를 대조했다. 생성된 .plan/general/2026-10-28-lockstep-model-tests.csv는 원본127개를 source revision/line/hash와 함께 기록한다. 현재 후보 대응표38개는 과거 Unity38 통과 기준선이고, 해당 대응표의 미이관6개와 아직 매핑하지 않은83개도 누락 없이 남긴다. unmapped83개를 실패나 범위 제외로 분류하지 않았으며, 실제 server IO에 남아야 하는 부분도 이후 검증해야 한다.
- .plan/general/2026-10-28-lockstep-model-baseline.json에 실제 Unity 로그와 당시 ModelCandidateChecks snapshot의 hash를 고정했다. 이후 Prepare-UnityProbe가 snapshot을 덮어써도 과거 기준선 hash가 바뀌지 않는다. baseline log가 바뀌거나 원본 attribute를 함수에 대응하지 못하면 도구가 실패한다. 현재 runtime의 전체 통과를 주장하지 않으며 ported-baseline-pass를 명시한다.
- Python의 WindowsApps 실행이 샌드박스에서 접근 오류로 실패했으나, 같은 로컬 목록 생성 명령을 허용 환경에서 실행해127/38/6/83 집계와 재생성 일치를 확인했다. 별도 외부 전송/코드 수정은 하지 않는다. Claude 네트워크 구현93259는 여전히 살아 있고 실제 v2 network 통과 결과는 아직 없다.

### 모델 v2 실제 연결 중간 검토 (2026-10-28)
- Claude 네트워크 작업93259가 살아 있고, claude-model-network-run2.log에서 simulation881/model38/core/물리10000틱이 통과했음을 확인했다. 이것은 클라이언트 payload 결속/불변 상태 변경 단계의 .NET 결과이며, 실제 v2 server/mock HTTP 경기 완주를 증명하지 않는다.
- ModelRequest에 typed ModelRequestPayload와 payloadHash를 넣고, Accepted/Rejected에 서버 IO용 payloadHash를 포함해 verifier/replica가 재구성 값과 비교하는 경로가 작성됐다. criteria/state/aims 개수·본문 크기 제한과 복사를 추가했으며, ModelCandidateMenu.State 및 nested ModelJson도 Freeze 경로를 사용하도록 바뀌었다. 최종 Rust canonical hash와의 교차 검증은 아직 남는다.
- 전체 목표(실제 모델 provider IO/키 인터페이스·snapshot 설정·서버 기록·네트워크/복구·verifier/저장)는 그대로 진행 중이다. 기존38 통과를 server bot 테스트127 전체나 전체 이관 완료로 집계하지 않는다.

### v2 wire 벡터와 서버 중간 검토 기록 (2026-10-28)
- 독립 Python 구현으로 .plan/general/2026-10-28-lockstep-model-wire-vectors.json을 만들었다. big-endian4바이트 count/UTF-8 length framing에 한국어·이모지·줄바꿈, 조준 후보 및 9007199254740993 JSON 조각을 포함한2개다. 첫 C# 비교는 DLL이10:42 구 framing으로 빌드된 상태에서 실패했고, 소스10:43 이후에 새로 빌드된 DLL10:53으로 재검사해 두 hash 모두 일치했다. 이 중간 stale binary 관찰을 현재 소스 결함으로 간주하지 않는다.
- 현재 C# hash: unicode-and-newline=a643e710bb3e8fc118138240a92865a11bae7a41cb45978e403897ca9df5e4cc, aims-and-wide-integer=7a082043e1de0fee0a09ddba4648d583a467e871f3c7d45def65019365fd0033. Rust의 같은 벡터 검사는 아직 없다. 실제 server module lockstep_model.rs가 작성됐으나 registry/HTTP/최종 v2 경기 통과를 아직 주장하지 않는다.
- 중간 검토 사항을 .generated/claude-model-network-review.txt에 준비했다. admission의 per-slot pacing/outstanding/identity, provider health 기간과 resumeTick 결속, key fetch의 executor 밖 IO 및 health 반영, MAX_TICKS 근처 terminal 범위, Rust/C# 고정 wire 벡터를 최종 코드·검사와 대조해야 한다. 아직 작성 중이므로 발견 시점의 소스를 최종 결함으로 확정하지 않으며, 완료 후 같은 Claude 세션에 전달한다.

### Gateway 실제 mock IO 검사 확인 및 relay 통합 재개 (2026-10-28)
- Claude 네트워크 세션93259는 종료 코드0으로 끝났으나 작업량 때문에 relay/verifier/lobby/실제 경기 완주를 아직 연결하지 못했다고 보고했다. 전체 완료로 취급하지 않고 같은 세션을 즉시 재개했다. 새 핸들33057, 출력 .generated/claude-model-network-integration-session.json. 원래 task와 network-review의5개 검토 사항을 먼저 반영하고 실제 mock provider 경기/복구/verifier/저장까지 진행하도록 지시했다. 단순 작업량은 blocker로 취급하지 않았다.
- 주 에이전트가 Claude의 실제 tool_result를 읽어 cargo lib lockstep_model6통과, 실제 local axum/ReqwestLlmHttpClient/LlmThreadPool/LlmProviderHealth/fake-key provider통합16통과를 확인했다. 전체 server lib는233통과/2실패로 끝났으며 closed port의Windows timeout 분류와1ns Instant 표현이 실패했다. 이 두 기존 실패를 제외한 전체 통과로 표현하지 않는다. helper IO 검사가 성공해도 실제 lockstep 세션 경기 완주 증거는 아니다.
- 전용 DB ac-lockstep-model-v2-stream이 살아 있음을 해당 이름으로 확인했고 새 child에 같은 AC_LOCKSTEP_* 경로를 다시 전달했다. 실제 provider/운영 키/환경파일은 사용하지 않는다. v2 활성화/생성 차단 해제는 아직 최종 통합 증거가 없다.

### LLM 봇 매치 종료와 결과 저장 통합 통과 (2026-10-28)
- 사용자 우선순위를 실제 LLM 봇 매치 종료와 결과 저장으로 좁혔다. Claude 한도 소진 후 사용자 승인에 따라 GPT가 구현을 계속했다. 이번 단계에서 나머지 원본 테스트 이관과 신규 기능은 진행하지 않았다.
- Rust registry에 기존 BotDecisionSourceFactory를 등록하고 v2 초기 snapshot의 modelPolicies, InputBatch.modelRequests, ConfirmedFrame.modelEvents, 비동기 provider drain과 최종 verifier의 v2 허용을 연결했다. 기존 v1에는 모델 필드를 보내지 않으며 저수준 임의 snapshot 생성 경로는 v1만 허용한다. client GameScene과 verifier는 같은 frozen policy factory를 사용한다.
- 실제 ReqwestLlmHttpClient/LlmThreadPool/암호화 fake-key repository, 로컬 JEV HTTP mock, C# 별도 프로세스의 실제 WebSocket, disposable Postgres를 사용하는 lockstep_model_network 통합 검사 통과. 첫 PLAY fixture는 단일 선택 최적화로 모델을 생략해 실패했고, 모델에 반드시 묻는 CARD fixture로 교체했다. 제품 동작이나 통과 조건을 약화하지 않았다.
- 최종 기록: lockstep-v2, 54frames, modelRequests=1/modelAccepted=1/modelCompleted=1/modelRejected=0/modelFailed=0, botCasts=1, leftHp=0/rightHp=100, loser=LeftPlayer, verifiedComplete=true. /complete에서 서버 C# 재생 검증을 거쳐 저장했고 같은 기록의 독립 재검증도 통과했다. 완료 요청 반복 후 lockstep_completed_results=1/statistic_games=1, 봇 시전 통계 합계=1, 종료 알림=1, history.ended=completed를 확인했다. 증거: client/Tools/LockstepProbe/.generated/gpt-model-network-e2e.log; 재현 검사: game-rust/crates/server/tests/lockstep_model_network.rs.
- 검증: relay 기존8개 통과, gateway unit8/provider 실제 HTTP30개 통과, C# 원본881/model38/core/물리10000tick 통과 및 기존 물리SHA256 유지, probe/verifier Release build 오류0. cargo fmt --check 및 cargo clippy -j1 -p ac-game-server --all-targets -- -D warnings 통과(파일시스템 hardlink 캐시 warning만 존재), client/game-rust diff --check 통과. graphify update는 실행 파일 미설치로 불가했다.
- 범위: 유료 실제 모델 서비스, 운영 DB, 실제 lobby UI 매칭과 최신 Unity/WebGL 화면 실행을 이번 증거로 주장하지 않는다. lobby의 simulation-version 설정을 lockstep-v2로 지정하는 경로이며 기본값 lockstep-v1은 유지했다. 나머지 전체 이관 목표와 원본19개 미이관 집계는 완료로 바꾸지 않는다. root/client/game-rust 브랜치는 lockstep이며 commit/push하지 않았다.

### lockstep 브랜치 커밋·푸시 (2026-10-28)
- 사용자 요청으로 database 4f00e80, game-rust c056d24, lobby 752b2f3, client 5e57af80을 각각 origin/lockstep에 커밋·푸시했다. 루트 포인터는 이 게시된 커밋을 참조한다.
- Unity 실행 중 변경된 Assets/Art/Fonts/LilitaOne SDF.asset의 동적 glyph/atlas 캐시는 커밋에서 제외하고 작업 폴더에 보존했다. .generated 로그·빌드 산출물·환경파일도 포함하지 않았다.
- DB migration 정적 검사 전체 통과. 클라이언트에 포함한 upstream 물리엔진 원본과 Unity metadata에는 기존 trailing whitespace가 있어 일반 staged diff --check가 이를 보고한다. upstream 소스와 GUID metadata를 일괄 포맷하지 않았으며, EOL/EOF 공백만 제외한 검사와 다른 서브모듈 검사는 통과했다.

### 잔여 구현과 검증 완료 (2026-10-29)
현재 판정은 [최종 완료 계획](2026-10-29-lockstep-completion.md)을 따른다. 앞의 날짜별 수치와 미완료 메모는 당시 기록이다. 원본915/915와 모델127/127의 현재 소스 실행 증거, 매 tick 전체 상태 checkpoint, 재시작·lease·commit 응답 유실·outbox, .NET/Editor/WebGL, 실제 두 Unity의 로비→전투→결과를 확인했다. ignored doctest2개는 기존 실행 계약과 대응하며 literal pass로 세지 않았다. 운영 배포와 유료 모델 호출은 수행하지 않았다.
