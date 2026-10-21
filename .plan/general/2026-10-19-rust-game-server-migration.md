# 2026-10-19 — game server 를 Rust 로 이전

- Date: 2026-10-19
- GitHub Issue: None (마일스톤마다 새 저장소에 issue 를 연다)
- Status: Draft

## Goal

Java(Spring Boot) game server 와 같은 계약으로 동작하는 Rust game server 를 새 저장소에 만들고,
두 서버를 함께 운영하다가 Java 서버를 내린다.

- 계약은 그대로 둔다: lobby 가 부르는 HTTP API, client 가 쓰는 STOMP 메시지, 공유 database 의 읽기와 쓰기.
  lobby, client, admin, database 는 이전 때문에 바뀌지 않는다.
- 경기가 0개일 때 메모리 60MB 이하를 목표로 한다. 지금 Java 서버는 약 440MB 를 쓰고,
  그중 Metaspace 가 124MB, 쓰지 않는 heap 이 약 80MB 다 (2026-10-19 Prometheus 측정).
- 미국 서버(GCP e2-micro, 964MB)에서 swap 없이 돈다.

## Non-goals

- 게임 규칙, 밸런스, 프로토콜을 바꾸지 않는다. 바꿀 것이 생기면 이전이 끝난 뒤에 따로 한다.
  예외는 아래 "의도한 차이" 한 가지뿐이다.
- lobby, account, admin 서버는 Java 로 둔다.
- Java 서버에 새 기능을 넣지 않는다. 이전하는 동안 Java 는 버그 수정만 받는다 (2026-10-19 결정).

## Context / Constraints

### 결정 사항 (2026-10-19)

- 저장소: ArcaneCasters 에 새 repository 를 만들고 monorepo 에 submodule 로 추가한다.
- 전환 방식: Rust 서버를 `servers` 표에 한 대씩 추가해 Java 서버와 함께 돌리고,
  미국 서버부터 바꾼다. 문제가 생기면 그 행을 INACTIVE 로 돌려 되돌린다.
- Java 서버는 동결한다.

### 옮길 코드의 규모 (`game` origin/deploy 기준)

| 영역 | 줄 수 | 비고 |
|---|---|---|
| 시뮬레이션 (`game/domain/object`, `domain/magic`, `domain/bot`, `service/system`, loop, `util`) | 약 25,000 | 이전 작업의 대부분 |
| └ component | 약 11,000 | mob 5,044, magic 3,100, effect 1,861, physic 927 |
| └ prefab initializer 132개 | 약 5,900 | `PrefabType` 128개 |
| └ magic 92개 | 1,907 | 대부분 10줄 안팎이고 동작은 prefab 과 component 에 있다 |
| └ bot AI | 1,803 | |
| PVE 엔진 | 약 1,000 | |
| 인프라 (session, auth, lobby, statistic, preview, debug, playground, server, websocket, alert) | 약 5,000 | |
| 기존 test | 23,354 (204개 파일) | golden replay 파일은 없다 |

### 바깥 계약

**HTTP (app port 7777)**
- lobby 용, `WORDONLINE_SERVER` 권한의 service JWT:
  - `POST /api/server/game-sessions`: `attemptId` 기준으로 멱등이고, 첫 tick 까지 기다렸다가 `SessionReadyResponse` 를 돌려준다.
  - `GET /api/server/game-sessions/{id}/active`, `GET /api/server/game-sessions/length`, `GET /api/server/game-sessions`
  - `GET /api/server/magic-previews`, `GET /api/server/magic-previews/{name}?revision=`
  - `POST /api/admin/invalidate`: parameter, magic, tag, preview cache 를 비운다.
  - `POST /api/server/playgrounds`
- CI/CD: `POST /api/server/servers/mine/state/draining` (`WORDONLINE_CICD`). 세션이 0개가 되면 process 가 종료된다.
- admin: `/api/admin/bots` CRUD, `/api/debug/**`, `/api/dev/playgrounds/**`
- 인증 없음: `GET /healthcheck` 는 평문 `OK ac-game` 을 돌려준다. management port 8081 에 `/actuator/health` 와 `/actuator/prometheus` 가 있다.
- JWT 는 account server 의 `/.well-known/jwks` 로 검증한다. `scope` claim 이 권한, `memberId` claim 이 user id 다.

**WebSocket / STOMP (`/ws`)**
- handshake 에서 `?token=<JWT>` 를, STOMP CONNECT 에서 `Authorization: Bearer <JWT>` header 를 검사한다.
- 받는 곳: `/app/game/input/{sessionId}/{userId}`. `type` 은 `useMagic`, `ping`, `emote`, `selectCard`, `unselectCard`, `pveSync` 다.
- 보내는 곳: `/game/{sessionId}/frameInfos/{userId}`, 관전용 `/game/{sessionId}/frameInfos/0`
- 보내는 메시지의 `type`: `frame`, `sync` (frame 1 과 0.5초마다), `magicValid`, `result`, `emote`, `botThought`, `pveObjective`, `playgroundEnded`.
  PVE 대사 메시지에는 `type` 이 없다. enum 철자(`LeftPlayer`, `Win`, `Practice`)와 필드 이름을 그대로 맞춘다.

**밖으로 보내는 호출**
- lobby: `POST {LOBBY_BASE_URL}/api/internal/game-sessions/{id}/ended`, body `{"instanceId"}`, token 은 `JWT_FILE_PATH` 파일에서 읽는다.
- Discord webhook (FPS 경보)

**database**
- JPA 는 `servers` 표 하나에만 쓴다. `(domain, port)` 로 upsert 하고 10초마다 heartbeat 를 쓴다. `target_bot_sessions` 는 쓰지 않는다.
- 참조 데이터: `magics`, `parameter_values`/`game_objects`/`parameters`, tag 표들. 처음 쓸 때 읽어서 cache 하고, invalidate 로만 비운다.
- 세션마다 읽는 표: deck, `bot_personas`, `users.novice_progress`, PVE 시나리오 표 8개 (cache 없이 5 + 2N 번 query).
- 경기가 끝날 때 쓰는 표: `statistic_*` (한 transaction), `statistic_game_sessions`, `users.mmr/status/total_wins/novice_progress`, `user_scenarios`.
- 경기 종료 때 쓰는 순서는 `SessionService.onLoopTerminated` 와 같아야 한다. 다만 아래 "의도한 차이" 는 예외다.
- Postgres enum (`game_type`, `bot_tier`, `bot_temperament`) 에는 cast 가 필요하다.

### 의도한 차이 하나

Java 는 통계를 저장하고 lobby 에 알린 뒤에야 `user_scenarios` 를 FINISHED 로 쓴다. 미국 서버에서는 이 과정이
결과가 나온 뒤 9초나 걸려서, Forest 3단계가 잠겨 보이는 버그가 생겼다 (2026-10-14 플레이테스트).
Rust 서버는 결과가 정해지는 즉시 FINISHED 를 쓰고, 통계 저장과 lobby 알림은 그 뒤에 한다.

### 시뮬레이션 parity 를 막는 요인

- `deltaTime` 이 고정값이 아니라 직전 frame 의 실제 경과 시간이다.
- 시드 없는 난수가 10곳 넘게 있다: spawn jitter, meteor, `DeathField`, PVE boss, `Vector3.randomXZ`, `BotBrain`, map 선택.
- 충돌 쌍을 `HashSet` 으로 순회해서 순서가 정해져 있지 않다.
- object id 가 모든 세션이 함께 쓰는 static counter 에서 나온다.
- bot 판단이 executor 에서 돌아서, 결과가 몇 번째 frame 에 들어올지 정해져 있지 않다.
- `float` 연산 순서와 `sin`/`cos` 의 마지막 bit.
- 결정적으로 도는 경로는 deck 섞기 하나다 (`java.util.Random` + `Collections.shuffle`).

## Approach (Checklist)

### 기술 선택

- runtime: `tokio`. HTTP 와 WebSocket 은 `axum` 으로 처리한다.
- STOMP: 쓰는 frame 이 CONNECT, SUBSCRIBE, SEND, MESSAGE, DISCONNECT 뿐이라 직접 작성한다 (약 500줄 예상).
  Spring simple broker 의 destination 규칙과 heartbeat 를 맞춘다.
- database: `sqlx` (Postgres, compile-time query 검사는 쓰지 않고 runtime query 로 시작한다).
- JWT: `jsonwebtoken` + JWKS 를 받아 cache 한다.
- metrics: `metrics` + `metrics-exporter-prometheus` 로 8081 에 `/actuator/prometheus` 와 같은 경로를 연다.
- log: `tracing`. Spring log 와 같은 문구(`[Game Result]`, `Session created`)를 남겨서 log 를 보는 방법이 바뀌지 않게 한다.
- 시뮬레이션: async 를 쓰지 않는 별도 crate 로 둔다. 세션마다 OS thread 하나를 쓰고, 다른 thread 와는 channel 로만 주고받는다.
  Java 의 구조(`GameObject` + component 목록 + system 순서)를 그대로 옮긴다. ECS(bevy_ecs 등)로 다시 설계하지 않는다.
  1:1 로 옮겨야 Java 코드와 나란히 놓고 검토할 수 있고, parity test 가 어긋났을 때 원인을 찾을 수 있다.
  component 는 trait object 로 시작하고, 성능 문제가 측정되면 그때 enum dispatch 로 바꾼다.

### 저장소 구성 (안)

```
ac-game-rs/
  crates/sim/        # 시뮬레이션: GameObject, component, system, prefab, magic, bot, PVE. I/O 없음
  crates/data/       # database 접근 (sqlx), parameter cache, 시나리오 loader
  crates/protocol/   # DTO (serde), STOMP codec
  crates/server/     # axum, session 관리, JWT, lobby client, heartbeat, watchdog, metrics
  tools/parity/      # Java preview JSON 과 Rust 출력을 비교하는 도구
```

### 마일스톤

각 마일스톤은 새 저장소의 issue 하나와 draft pull request 여러 개로 나눈다.

- [ ] **M0: 저장소와 뼈대**
  - ArcaneCasters 에 repository 생성, monorepo 에 submodule 추가, `AGENTS.md`, CI (fmt, clippy, test), Docker image (distroless 또는 scratch).
  - 설정 읽기 (Java 와 같은 환경 변수 이름), `/healthcheck`, `servers` 행 upsert 와 heartbeat, `instance_id`, JWT 검증, metrics.
  - 완료 기준: dev 환경에서 container 가 뜨고, `servers` 에 행이 생기며, lobby healthcheck 를 통과한다. 이때 메모리를 처음 측정한다.
- [ ] **M1: 시뮬레이션 핵심**
  - `Vector3`, parameter (database 또는 test SQL fixture 에서 읽기), `GameObject`, component trait, `GameContext`, system 실행 순서.
  - `PhysicSystem` 과 collider 3종 (Circle, Cylinder, Edge), `ZPhysics`, `RigidBody`.
  - `deltaTime` 주입, 시드를 받는 RNG, 충돌 쌍을 정해진 순서로 순회하도록 처음부터 설계한다.
  - `java.util.Random` 과 `Collections.shuffle` 을 bit 단위로 똑같이 구현한다 (deck 순서 parity).
- [ ] **M2: effect, prefab, magic + preview parity**
  - status effect 17종, `EffectProvider`/`EffectReceiver`, `ElementalChart`.
  - prefab initializer 132개와 magic 92개. magic 계열(spawn, shoot, build, explode, drop)별로 작업을 나눠 병렬로 진행한다.
  - preview 생성기와 `/api/server/magic-previews` endpoint.
  - parity: Java 의 preview test (`MagicScenarioPreviewTest` 등, 85개 magic, 129개 상황)를 deltaTime 을 고정하고 난수를 끈 상태로 돌려
    JSON 을 뽑고, Rust 출력과 비교한다. 위치는 오차 범위 안에서 비교하고, id 와 충돌 순서는 정규화한다.
  - 완료 기준: 129개 상황이 모두 오차 범위 안에서 일치한다.
- [ ] **M3: 세션과 프로토콜 (PVP)**
  - `POST /api/server/game-sessions` (멱등, 첫 tick 대기), 세션 thread, `GameActionQueue`, input 처리, 카드, 마나, fever.
  - STOMP endpoint, `frame`/`sync`/`magicValid`/`result`/`emote` 메시지, 관전 stream.
  - DTO 의 JSON 을 Java 와 비교하는 contract test (같은 입력으로 만든 메시지를 필드 단위로 비교).
  - 완료 기준: dev 의 servers 표에 Rust 서버만 남기고, Unity client 로 PVP 한 판을 끝까지 한다.
- [ ] **M4: bot AI 와 Practice**
  - `BotBrain`, `BotAgent`, `BotEmoteDirector`, hospitality, persona 읽기, `botThought` 메시지, bot 자동 경기 scheduler.
- [ ] **M5: PVE 엔진**
  - 시나리오 loader (표 8개), `PveScriptSystem`, `PveObjectiveSystem`, `PveResultChecker`, 대사 메시지와 `pveSync`, shield.
  - 완료 기준: Forest, Fortress, Gate 모험을 처음부터 끝까지 깬다.
- [ ] **M6: 경기 종료와 운영 기능**
  - 통계 저장 (한 transaction), MMR, `total_wins`, `novice_progress`, `user_scenarios` (의도한 차이 포함), lobby 종료 알림.
  - watchdog, draining 과 종료, 재시작 때 남은 세션을 ABANDONED 로 처리, FPS Discord 경보.
  - `/api/admin/bots`, `/api/debug/**`, playground, invalidate.
- [ ] **M7: 전환**
  - 미국 서버: Rust container 를 다른 포트로 띄우고 `servers` 에 행을 추가해 Java 와 함께 돌린다. 1주 동안 log, FPS, 메모리를 본다.
  - 문제가 없으면 미국 서버의 Java 행을 INACTIVE 로 바꾸고 container 를 내린다.
  - 한국 서버(blue/green)도 같은 순서로 바꾼다. 마지막으로 `game` 저장소를 보관 상태로 바꾼다.

### 병렬로 진행할 수 있는 부분

- M0 과 M1 은 서로 쓰는 범위가 겹치지 않아 동시에 시작할 수 있다.
- M2 의 magic 계열 5개는 M1 이 끝나면 서로 다른 파일에서 병렬로 진행한다.
- M3 의 STOMP codec 과 DTO 는 M1, M2 와 동시에 만들 수 있다.

## Validation

- **Commands to run:**
  - `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`
  - parity: Java 쪽 `./gradlew test --tests '*PreviewTest' -PpreviewExport=true` 로 JSON 을 뽑고, `tools/parity` 로 비교한다.
  - 메모리: dev container 의 RSS 를 경기 0개, 1개, 10개일 때 잰다. 결과는 각 마일스톤 pull request 에 적는다.
  - 부하: `game-capacity-test` skill 로 같은 CPU·메모리 제한에서 Java 와 Rust 가 버티는 세션 수를 비교한다.
- **Expected output:** test 통과, preview 129개 일치, 경기 0개일 때 RSS 60MB 이하, Java 보다 세션 수가 적지 않음.

## Risks & Rollback

- **Risks:**
  - 규모: 시뮬레이션 25,000줄을 1:1 로 옮겨야 한다. 마일스톤 하나가 몇 주씩 걸릴 수 있다.
  - parity: `float` 오차와 시드 없는 난수 때문에 완전히 같은 결과는 나오지 않는다. 오차 범위를 정하는 기준이 필요하다.
    Java 쪽에 deltaTime 고정과 난수 시드를 넣는 test 전용 hook 이 필요할 수 있다. 이것은 동작을 바꾸지 않는 test 변경이므로 동결 대상에서 뺀다.
  - client 계약: Unity client 가 기대하는 JSON 필드를 하나라도 다르게 보내면 client 가 조용히 깨진다. contract test 로 막는다.
  - 동결 기간: 이전이 길어지면 그동안 새 마법이나 시나리오를 넣지 못한다. 마일스톤마다 일정을 다시 확인한다.
  - 버그 수정 이중 작업: 동결 중에도 Java 에 들어가는 버그 수정은 Rust 에도 반영해야 한다. Java 쪽 commit 을 마일스톤마다 확인한다.
- **Rollback steps:**
  - 전환 중에는 Rust 서버의 `servers` 행을 INACTIVE 로 바꾸면 lobby 가 Java 서버로만 세션을 보낸다.
  - Java image 와 container 는 M7 이 끝날 때까지 지우지 않는다.

## Open Questions

- 새 저장소 이름 (예: `ac-game-rs`). 지금 image 이름이 `ac-game` 이라 어떻게 구분할지 정해야 한다.
- 미국 서버 database 거리 문제: 세션 생성 query 수는 Rust 에서도 같으므로 190ms 왕복은 남는다.
  PVE 시나리오를 cache 하는 것을 "의도한 차이" 로 추가할지 정해야 한다.
- Forest 3단계 버그를 Rust 이전 전에 Java 에서 먼저 고칠지 (동결 중 버그 수정으로 허용되는 범위).
