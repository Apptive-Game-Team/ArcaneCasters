# 2026-10-10 — 로컬 game server (desktop client 가 봇전과 모험을 자기 PC 에서 실행, 이후 오프라인 플레이)

- Date: 2026-10-10
- GitHub Issue: None
- Status: Draft

## Goal

세 단계로 나눠서 진행합니다. 각 단계는 따로 배포할 수 있습니다.

- **0단계 — FPS 와 무관한 simulation**: game server 의 tick rate 를 세션마다 정할 수 있게 하고, frame 수를 기준으로 하던 로직을 시간 기준으로 바꿉니다. 같은 경기가 20 FPS 와 60 FPS 에서 같은 시간 흐름으로 진행되어야 합니다. 공유 서버는 계속 20 FPS 로 돌립니다.
- **1단계 — 온라인 로컬 호스팅**: Windows, macOS, Linux desktop client 가 로그인한 상태에서 봇전(Practice)과 모험(PVE)을 자기 PC 의 game server 에서 실행합니다. 목표는 세 가지입니다.
  - 서버 부하 분산: desktop 사용자의 봇전과 모험이 공유 game server 에서 빠집니다.
  - 레이턴시 감소: 경기 통신이 PC 안에서 끝납니다.
  - 프레임 상향: 로컬 서버는 모니터 주사율에 맞춘 tick rate(60, 120, 144 등, 상한 240)로 돌리고, PC 가 따라가지 못하면 다음 경기부터 자동으로 낮춥니다.
  - 경기 결과는 lobby 에 보고하고, lobby 가 검사를 통과한 결과만 계정에 반영합니다.
- **2단계 — 오프라인 플레이**: 1단계 기반 위에 네트워크 없이 시작하는 경로를 추가합니다. 마지막 로그인 계정의 복사본으로 플레이하고, 결과는 로컬에만 남깁니다.

## Non-goals

- WebGL 과 Android 에서의 로컬 호스팅. 이 두 플랫폼은 계속 공유 서버에서 경기합니다.
- PvP 와 친선전의 로컬 호스팅. 상대가 있는 경기는 신뢰할 수 있는 서버가 판정해야 합니다.
- 공유 서버의 tick rate 상향. CPU 와 STOMP 메시지가 FPS 에 비례해서 늘어나므로 20 을 유지합니다.
- 오프라인 결과의 서버 업로드 (2단계). 오프라인 결과는 시간 검사를 할 수 없습니다.
- simulation 을 C# 으로 옮기는 방식.

## Context / Constraints

조사는 2026-10-10 에 했습니다. 이 workspace 의 game checkout 은 `origin/dev` 보다 뒤처져 있었으므로(`PveTriggerType` 에 `SecondsGte` 가 없음), 구현을 시작할 때 각 저장소의 `origin/dev` 에서 아래 목록을 다시 확인합니다.

### game server 구조

- 경기 로직은 모두 game server 안에 있습니다. 봇전과 모험에서 lobby 가 하는 일은 세션 id 발급(`bot-<n>`, `pve-<n>`), 봇 선택(초보자는 접대봇), 서버 선택 세 가지뿐입니다.
- 경기가 끝나면 game server 가 공유 DB 에 직접 씁니다 (`SessionService.onLoopTerminated`): `user_scenarios` FINISHED, `users.total_wins`, 접대봇 승리 시 `novice_progress` +0.15, `statistic_*`. lobby 는 세션 종료 알림을 받아 match ticket 만 닫습니다.
- 기동할 때 Postgres(`ServerStatusTracker`, `DatabaseMagicParser`)와 기본값 없는 환경 변수 7개가 필요하고, 인증은 account JWKS 로 검증하는 JWT 뿐입니다.
- 테스트는 이미 H2 와 `src/test/resources/schema-h2.sql` 로 repository 를 돌립니다. `StatisticRepository` 만 Postgres 전용 SQL 입니다.
- 사람이 마법을 시전할 때마다 `MagicRepository.existUserMagic` 이 `user_magics` 를 조회합니다.

### frame 수에 의존하는 곳 (0단계 대상)

- `GameLoop.FPS = 20` 은 `static final` 이고 설정할 수 없습니다. 한 frame 길이를 `1000 / FPS` 정수 ms 로 계산하므로 60 이면 16ms(62.5 FPS)가 됩니다.
- `deltaTime` 은 직전 frame 에 실제로 걸린 시간입니다(`GameLoop.java:193`). 이동, 물리, 대부분의 timer 는 이미 `deltaTime` 을 곱하거나 누적하므로 FPS 와 무관합니다.
- frame 수를 그대로 쓰는 곳:
  - `ManaCharger`: `frameNum % (int)(FPS * 0.25f)` 로 0.25초마다 마나 +1
  - `CardDeck`: `frameNum % (int)(FPS * cardDrawInterval)`. fever 때 간격이 절반으로 바뀌면서 위상이 어긋납니다.
  - `PVEBossMob`: cooldown 을 `cooldownUntilFrame` 으로 저장
  - `PveScriptSystem` 의 `FrameNumGte` trigger: baseline 의 `pve_scenario_events` 9행이 값 10, 20 (0.5초, 1초)을 씁니다. 나머지 행은 이미 `SecondsGte` 입니다.
  - `BotAgent`: `bot_personas.reaction_interval_frames`(2~24)로 반응 주기를 셉니다.
  - `GameLoop.SYNC_FRAME_INTERVAL = 10`: 10 frame(0.5초)마다 전체 snapshot
  - `MovementSpeedTracker.SAMPLE_FRAME_COUNT = 3`: 150ms 표본 구간
  - `FrameRateAlerter`: 경보 기준 `ALERT_FPS_THRESHOLD=15` 가 절대값
- 간격이 끝나면 `counter = 0` 으로 되돌리는 timer(`Spawner`, `SelfAttacker`, `AreaEffectProvider` 등)는 남은 시간을 버립니다. 20 FPS 에서는 주기마다 최대 50ms, 60 FPS 에서는 최대 16ms 가 늦어져서 FPS 에 따라 생성 속도가 달라집니다. `DOTStatusEffect` 와 `SpiritBombChannel` 은 남은 시간을 이어 가는 방식이라 그대로 둡니다.
- 충돌 판정은 이동 뒤 겹침 검사이고 연속 충돌 검사가 없습니다. 빠른 투사체는 FPS 에 따라 맞는 횟수가 조금 달라질 수 있습니다.
- client 는 tick rate 를 모릅니다. `GameConfig.FRAME_DURATION = 0.05f` 를 위치 보간 tween 길이(`PositionUpdater.cs:43`), 방향 전환 기준, 파괴 지연에 쓰고, 방향 전환은 위치 갱신 10번(`FLIP_THRESHOLD`)을 셉니다. 서버가 보내는 메시지에는 tick rate 가 없습니다.
- frame 수에 의존하는 테스트: `SnapshotBuildFrequencyTest`, `SyncFrameDataSystemBroadcastTest`, `GameLoopWatchdogTest`. `ManaCharger`, `CardDeck`, `BotAgent`, `PVEBossMob`, `PveScriptSystem` 은 테스트가 없습니다.

### client 구조

- 봇전은 `GET /api/match/practice/me`, 모험은 `GET /api/scenarios/{id}/play` 로 시작하고, 둘 다 `MatchedInfoDto` 를 받아 `webSocketUrl` 로 접속합니다.
- `LoginSceneInitializer` 는 `/api/deploy/status` 가 HEALTHY 가 아니면 진행을 멈춥니다. `/api/members/me` 와 덱 목록 조회는 실패하면 LoginScene 으로 돌아갑니다.
- `ServerList.AccountServer` 는 고정된 static readonly 값입니다.
- desktop 은 Mono backend 이고 `game-ci/unity-builder` 기본 설정으로 build 합니다 (`release.yml` 의 StandaloneWindows64, StandaloneOSX, StandaloneLinux64). `Process.Start` 사용 사례는 없습니다.
- 이 작업 환경에서는 Unity Editor 를 실행할 수 없습니다. 새 UI 는 기존 prefab subtree 를 복제하고 fileID 를 검증합니다.

### lobby 구조

- lobby 퀘스트는 끝낸 stage 수로 보상을 줍니다 (`quest/repository/QuestConditionRepository.kt` 의 `countFinishedStages`). 모험 진행도를 반영하는 경로는 보상과 이어집니다.
- 세션 id 는 Redis counter 로 발급합니다 (`matchingQueueRepository.nextSessionId()`).
- 새 코드는 Kotlin 과 `suspend` 함수로 작성합니다 (`lobby/AGENTS.md`).

### 저장소 규칙

- 통합 branch 는 각 저장소의 `dev` 입니다. pull request 는 draft 로 열고 version 은 올리지 않습니다.
- database pull request 는 stack 하고, migration 번호는 stack 맨 위 기준으로 정합니다.
- 구현 전에 `game/AGENTS.md`, `lobby/AGENTS.md`, `client/AGENTS.md`, `client/CLAUDE.md`, `database` 의 AGENTS.md 를 다시 읽습니다.

## 0단계 설계 — FPS 와 무관한 simulation

### tick rate 를 세션 설정으로

- `GameLoop.FPS` 상수를 없애고 `GameContext.tickRate` 로 옮깁니다. 기본값은 `@ConfigurationProperties` 의 `game.tick-rate`(기본 20)이고, 세션을 만들 때 덮어쓸 수 있습니다.
- frame 길이는 nanosecond 로 계산해서 60 FPS 가 실제로 60 이 되게 합니다.
- `deltaTime` 은 지금처럼 직전 frame 의 실제 시간을 씁니다. 고정 step 으로 바꾸면 서버가 바쁠 때 지연을 흡수하는 방식이 달라지므로 이번 범위에서 바꾸지 않습니다.

### frame 기준 로직을 시간 기준으로

| 대상 | 바꾸는 방식 |
|---|---|
| `ManaCharger` | 누적 시간이 0.25초를 넘을 때마다 +1 하고 남은 시간을 이어 갑니다 |
| `CardDeck` | 같은 누적 방식. fever 로 간격이 바뀌어도 누적값은 유지합니다 |
| `PVEBossMob` cooldown | 남은 초로 저장합니다 |
| 간격 timer 의 `counter = 0` | `counter -= interval` 로 남은 시간을 이어 갑니다 |
| `SYNC_FRAME_INTERVAL` | 0.5초마다 snapshot |
| `MovementSpeedTracker` | 150ms 표본 구간 |
| `BotAgent` 반응 주기 | DB 열은 그대로 두고 `reaction_interval_frames` 를 "20 FPS 기준 frame" 으로 해석해서 값 × 50ms 로 바꿉니다 |
| `FrameNumGte` trigger | DB 는 그대로 두고 값을 "20 FPS 기준 frame" 으로 해석해서 값 ÷ 20 초로 바꿉니다 |
| FPS 경보 | 목표 tick rate 의 75% 미만일 때 경보 |

- `counter -= interval` 변경과 누적 방식은 **20 FPS 에서도** 동작을 조금 바꿉니다. 지금은 주기마다 최대 50ms 씩 늦게 생성되던 것이 정확한 간격으로 생성되므로, 소환과 공격 속도가 약간 빨라집니다. 이 변경은 공유 서버에도 그대로 적용합니다.
- DB 열 이름과 값을 바꾸지 않는 이유: `reaction_interval_frames` 는 admin server 가 DB 에 직접 쓰고(`BotAdminRepository`), dev DB 는 database pull request 가 merge 되자마자 migration 이 적용됩니다. 열을 바꾸면 아직 배포되지 않은 game server 와 admin server 가 깨지므로, 0단계는 game 안에서 단위를 해석하는 것으로 끝냅니다. 열 이름을 ms 단위로 바꾸는 작업은 database, game, admin 을 순서대로 배포하는 후속 작업으로 둡니다.

### client 가 tick rate 를 알게

- 서버가 첫 frame 메시지(또는 `MatchedInfoDto`)에 `tickRate` 를 실어 보냅니다.
- `PositionUpdater` 의 tween 길이는 `1 / tickRate` 로, 방향 전환 기준은 위치 갱신 횟수 대신 0.5초로, 파괴 지연은 `1 / tickRate` 로 바꿉니다.
- `tickRate` 가 없는 메시지(구 version 서버)를 받으면 20 으로 간주합니다.

## 1단계 설계 — 온라인 로컬 호스팅

### 흐름

1. client 가 LobbyScene 에 들어오면, 서버 묶음이 설치되어 있고 설정의 "내 PC 에서 경기 실행" 이 켜져 있을 때 로컬 서버를 background 로 미리 띄우고 `ready` 를 기다립니다. 기동 시간(예상 5~10초)을 경기 시작 전에 숨기기 위해서입니다.
2. 봇전이나 모험 버튼을 누르면 client 가 lobby 에 `POST /api/local-sessions` (`{type: PRACTICE | PVE, scenarioId}`)를 보냅니다.
3. lobby 는 지금과 같은 규칙으로 처리합니다: 세션 id 발급(`local-<n>`), 봇 선택(접대봇 규칙 포함), 모험이면 시나리오가 ACTIVE 인지 확인. 그리고 Redis 에 세션 기록 `{userId, type, scenarioId, botId, issuedAt, state=ISSUED}` 를 2시간 TTL 로 저장하고, 응답으로 세션 id, 봇 id, 내 선택 덱 카드, 보유 마법 id, 요구하는 정적 데이터 version 을 돌려줍니다.
4. client 가 이 응답과 자기 JWT 를 로컬 서버의 `POST /api/local/sessions` 로 넘기고, 받은 `webSocketUrl` 로 접속합니다. 이후 경기는 지금과 같습니다.
5. 경기가 끝나면 **로컬 서버**가 lobby 의 `POST /api/local-sessions/{id}/result` 로 결과를 보냅니다. client 가 결과 화면 전에 꺼져도 보고가 남도록 로컬 서버가 보냅니다. 실패하면 로컬 서버가 파일에 남겨 두고 다음 기동 때 다시 보냅니다(세션 기록 TTL 안에서만).
6. 아래 경우에는 지금처럼 `GET /api/match/practice/me`, `GET /api/scenarios/{id}/play` 로 공유 서버에서 경기합니다: 서버 묶음 미설치, 설정 꺼짐, 로컬 서버가 30초 안에 `ready` 를 보내지 않거나 `error` 를 보냄, 서버 묶음 version 이 lobby 가 요구하는 최소 version 보다 낮음.

### 결과 검사 (lobby)

결과 body: `{winnerSide, durationSeconds, frameCount, tickRate, magicCastCounts, deckSummary}`.

- 세션 기록이 있고, 보고한 사용자의 것이고, state 가 ISSUED 인지 확인합니다. 받으면 REPORTED 로 바꿔서 같은 세션의 두 번째 보고를 거절합니다.
- `issuedAt` 부터 보고 시각까지의 실제 시간이 `durationSeconds` 보다 짧으면 거절합니다. `frameCount / tickRate` 와 `durationSeconds` 의 차이가 10% 를 넘어도 거절합니다.
- 경기 시간이 최소 시간(봇전 30초, 모험은 시나리오별 값이 없으면 30초)보다 짧은 승리는 거절합니다.
- 모험 승리는 그 시나리오가 지금도 ACTIVE 일 때만 받습니다. 순서를 건너뛴 시나리오는 받지 않습니다.
- 사용자마다 하루에 받는 로컬 결과 수를 제한합니다(초기값 100, 설정값).
- 거절한 결과는 사유와 함께 로그와 통계 표에 남겨서, 기준이 너무 엄격한지 나중에 확인합니다.
- 통과하면 지금 game server 가 하던 기록을 lobby 가 합니다: `user_scenarios` FINISHED, `users.total_wins` +1, 접대봇 승리 시 `novice_progress` +0.15, `statistic_games` 등. 통계 표에는 `hosted_locally` 열(database migration)을 추가해서 공유 서버 경기와 구분합니다. 사람의 MMR 은 봇전에서 지금도 바뀌지 않으므로 그대로 둡니다.

### 로컬 서버 (`local` profile)

| 의존 | 대체 |
|---|---|
| Postgres | H2 in-memory. 기동할 때 정적 데이터를 넣고, 세션을 만들 때 lobby 응답의 내 덱과 보유 마법을 넣습니다 |
| account JWKS | client 가 실행할 때마다 만든 무작위 token 하나만 받는 `JwtDecoder` |
| `servers` heartbeat, 봇 자동 대전, 공유 DB 통계 | 끕니다 |
| 경기 종료 기록 | DB 대신 lobby 결과 보고로 바꿉니다 |

- 경기 통신은 공유 서버와 같은 STOMP over WebSocket 을 `127.0.0.1` 에서 그대로 씁니다. loopback 은 왕복 1ms 미만이고, 실제 비용은 매 frame 의 JSON 직렬화에 있어서 전송 방식을 바꿔도 줄지 않습니다. 같은 `StompConnector` 와 서버 STOMP 처리를 쓰므로 로컬 경기만 다르게 동작할 여지가 없습니다.
- `server.address=127.0.0.1`, management port `-1`. loopback 에만 열어서 방화벽 확인 창이 뜨지 않게 합니다.
### tick rate 정하기

simulation tick 은 제한 없이 돌리지 않습니다. 잠들지 않는 loop 는 CPU core 하나를 100% 쓰고, tick 마다 frame 메시지를 보내므로 client 가 초당 수천 개의 JSON 을 처리해야 하며, 모니터 주사율을 넘는 tick 은 화면에 나오지 않습니다. 대신 "PC 가 할 수 있는 만큼" 을 화면 주사율까지로 정의합니다.

- **상한 = 모니터 주사율**: client 가 `Screen.currentResolution.refreshRateRatio` 를 읽어 정수로 반올림하고 240 이하로 자릅니다. 주사율을 읽지 못하면 상한은 60 입니다.
- **첫 경기는 20 에서 시작합니다.** 공유 서버와 같은 값이라 어떤 PC 에서도 첫 경기가 끊기지 않습니다. 단계는 20 → 30 → 60 → 120 → 144 → 240 이고, 상한을 넘는 단계는 건너뜁니다(예: 상한 75 이면 20 → 30 → 60 → 75).
- 로컬 서버가 경기 중 실제 FPS 를 측정해서, 경기가 끝나면 stdout 으로 `{"type":"matchStats","sessionId":"...","targetTickRate":60,"p10Fps":59.4}` 를 보냅니다. 경기 도중에는 tick rate 를 바꾸지 않고, 아래 규칙은 다음 경기에 적용합니다.
- **올리기**: 하위 10% FPS 가 목표의 98% 이상이면 한 단계 올립니다. 처음 올라가는 동안에는 한 경기마다 올리고, 한 번이라도 낮춘 뒤에는 3경기 연속 98% 이상일 때만 올립니다. 낮췄던 값으로 계속 다시 올라갔다 떨어지는 것을 막기 위해서입니다.
- **낮추기**: 하위 10% FPS 가 목표의 90% 미만이면 한 단계 낮춥니다. 20 아래로는 내려가지 않습니다.
- 현재 값과 "한 번 낮췄는지" 상태는 PlayerPrefs 에 저장해서 다음 실행에도 이어 씁니다. 모니터 주사율이 바뀌면 상한만 다시 계산합니다.
- **설정 화면**: "자동" 이 기본이고, 20, 30, 60, 120, 144 를 직접 고를 수도 있습니다. 직접 고르면 자동 낮춤과 다시 올리기를 하지 않습니다.
- 서버는 0단계에서 양수 tick rate 를 모두 받게 했으므로 서버 쪽 추가 작업은 `matchStats` 출력뿐입니다. tick rate 는 세션마다 정하므로 `init` 이 아니라 `POST /api/local/sessions` 요청에 넣습니다.

### 프로세스 제어 (stdin/stdout)

client 와 로컬 서버 프로세스 사이의 기동, 준비 알림, 종료는 stdin/stdout 으로 주고받습니다. 경기 데이터는 이 경로로 보내지 않습니다.

- 형식: 한 줄에 JSON 하나(UTF-8, `\n` 구분).
- client → 서버 (stdin)
  - 첫 줄 `{"type":"init","token":"...","dataDir":"...","lobbyBaseUrl":"..."}`. token 을 실행 인자로 넘기지 않으므로 같은 PC 의 다른 사용자가 프로세스 목록에서 볼 수 없습니다.
  - `{"type":"shutdown"}`: 진행 중인 결과 보고를 마치고 종료합니다.
- 서버 → client (stdout)
  - `{"type":"ready","port":51234,"serverVersion":"1.4.0","staticVersion":"..."}`: 서버가 포트 0 으로 열고 실제 포트를 알립니다. client 가 빈 포트를 골라 넘기는 사이에 다른 프로그램이 포트를 가져가는 문제가 없습니다.
  - `{"type":"matchStats",...}`: 경기가 끝날 때 목표 tick rate 와 측정한 FPS. 위 "tick rate 정하기" 의 자동 낮춤에 씁니다.
  - `{"type":"error","reason":"..."}`: 기동 실패 사유. client 는 이것을 받거나 30초 안에 `ready` 가 없으면 공유 서버로 fallback 합니다.
- 종료: client 가 어떤 이유로든 죽으면 OS 가 pipe 를 닫고, 서버는 stdin EOF 를 받으면 바로 종료합니다. Windows, macOS, Linux 에서 똑같이 동작하므로 parent pid 감시와 `/healthcheck` 반복 호출이 필요 없습니다.
- 기동 순서: 작은 launcher `main` 이 stdin 첫 줄(`init`)을 읽은 뒤 그 값으로 Spring context 를 띄웁니다. token 이 정해지기 전에는 포트를 열지 않습니다.
- stdout 은 이 프로토콜 전용입니다. local profile 에서는 Spring 과 logback 의 console 출력을 끄고 log 를 `dataDir/logs/` 파일로만 씁니다. JVM 자체 오류 출력은 stderr 로 나오므로, client 는 stderr 를 계속 읽어서 log 파일에 저장합니다. 읽지 않으면 pipe buffer 가 차서 서버가 멈춥니다.

### 정적 데이터와 서버 묶음

- lobby 에 인증 없는 `GET /api/offline-pack` 을 추가합니다. `?serverVersion=&staticVersion=` 을 받아서 바뀐 부분만 돌려줍니다.
  - `staticData`: 마법, parameter, game object, tag, 모험·stage·시나리오, `pve_scenario_*`, `bot_personas`, 봇(`user_id < 0`)의 `users`·`decks`·`deck_cards`. 실제 사용자 행은 하나도 넣지 않고, 이것을 lobby 테스트로 검사합니다.
  - `server`: 플랫폼별 서버 묶음의 version, URL, sha256, 그리고 lobby 가 받아 주는 최소 version.
- 정적 데이터는 client release workflow 가 build 할 때 `StreamingAssets/Offline/static.json` 으로도 넣습니다(수백 KB). 온라인에서는 lobby 가 요구하는 version 과 다르면 경기 전에 자동으로 받습니다. 공유 서버와 같은 값으로 경기해야 밸런스가 같기 때문입니다.
- 서버 묶음(100MB 이상)은 자동으로 받지 않습니다. 설정 화면에 "로컬 서버 설치", "업데이트", 진행률, 취소를 둡니다. 2단계에서 같은 UI 를 로그인 화면에도 둡니다.
- game 에 Gradle task `localServerDist` 를 추가합니다. bootJar 와 jlink JRE 21 을 플랫폼별 zip 으로 묶습니다: `windows-x64`, `macos-x64`, `macos-arm64`, `linux-x64`. Linux runner 에서 각 플랫폼 JDK 의 jmods 로 jlink 합니다. game release workflow 가 zip 과 sha256 을 release asset 으로 올립니다.
- macOS 와 Linux 는 압축을 푼 뒤 `java` 에 실행 권한을 줍니다. macOS 에서 브라우저가 아닌 방식으로 내려받은 파일에 quarantine 속성이 붙지 않는지 실제 기기에서 확인합니다.

### client

- `LocalServerHost`: 플랫폼별 묶음 경로 선택, `System.Diagnostics.Process` 로 실행(stdin, stdout, stderr redirect), token 생성과 `init` 전송, `ready` 대기(30초), stderr 를 log 파일로 저장, `Application.quitting` 에서 `shutdown` 전송 후 stdin 닫기. `#if UNITY_STANDALONE` 으로 desktop 에서만 컴파일합니다. Editor 에서는 손으로 띄운 서버 주소를 쓰는 개발용 경로를 둡니다.
- `LocalServerPackStore`: 서버 묶음 설치·업데이트, 정적 데이터 갱신, sha256 검증.
- `MatchQueueApiService.MatchPractice` 와 `AdventureApiService.RequestPVE` 앞에 로컬 경로를 두고, 조건이 맞지 않으면 기존 경로로 돌아갑니다.
- 설정 화면: "내 PC 에서 경기 실행" 토글, tick rate 선택(자동 기본), 설치·업데이트 UI.
- `LocalTickRatePolicy`: 모니터 주사율로 상한 계산, 20 에서 시작, `matchStats` 로 단계 올리기와 낮추기, PlayerPrefs 저장. 규칙은 Unity 에 의존하지 않는 순수 C# 으로 두고 EditMode 테스트를 붙입니다.
- 화면 문구는 Localization table 에 en 과 ko-KR 로 추가합니다.

## 2단계 설계 — 오프라인 플레이

1단계와 다른 점만 적습니다.

- **계정 복사본**: lobby 에 `GET /api/users/mine/offline-pack/account` 를 추가하고, client 는 온라인 로그인할 때마다 자동으로 저장합니다: 이름, `selected_deck_id`, `novice_progress`, 덱, `user_magics`, `user_scenarios`. 보유 마법은 마지막 로그인 계정의 값을 그대로 씁니다.
- **오프라인 프로필**: 로그인하지 않은 상태이고, 계정 복사본으로 시작합니다. 화면의 이름 옆에 "오프라인" 을 표시하고, 로그아웃과 계정 설정처럼 로그인이 필요한 메뉴를 숨깁니다.
- **로컬 서버**: H2 를 파일 DB 로 바꾸고, 1단계에서 lobby 가 하던 일을 local profile 이 대신합니다.
  - 봇 선택: lobby 의 규칙 그대로. `novice_progress` 가 1.0 미만이면 `enabled AND hospitality` 인 봇 가운데 `user_id` 가 가장 작은 봇, 아니면 `enabled AND NOT hospitality` 가운데 무작위.
  - client 가 오프라인에서 부르는 lobby·account endpoint 를 같은 경로와 응답 형태로 제공합니다: `/api/members/me`, `/api/users/mine`, `/api/data/parameters`, `/api/data/magics`, `/api/users/mine/magics`, `/api/users/mine/cardLists`, `/api/users/mine/cards`, 덱 CRUD 와 선택, `/api/adventures`(해금 규칙 포함), `/api/match/practice/me`, `/api/scenarios/{id}/play`, `/api/users/mine/match-info`(빈 응답), `/api/deploy/status`(HEALTHY). lobby 응답 JSON fixture 로 contract test 를 합니다.
  - 경기 결과는 lobby 에 보고하지 않고 파일 DB 에만 씁니다.
- **다음 온라인 로그인 때 합치기**: 서버로는 아무것도 올리지 않습니다.
  - `user_scenarios`: 시나리오마다 더 진행된 상태(INACTIVE < ACTIVE < FINISHED)를 로컬에 남깁니다.
  - `novice_progress`: 큰 값을 로컬에 남깁니다.
  - 덱, 선택한 덱, 보유 마법, 이름: 서버 값으로 덮어씁니다.
- **client**
  - 로그인 화면과 설정 화면에 같은 "오프라인 플레이" UI(설치·업데이트·시작)를 prefab 하나로 둡니다. 로그인 화면의 설치·업데이트는 로그인 없이 동작합니다. 계정 복사본이 없으면 시작 버튼을 끄고 "한 번 로그인하면 오프라인 플레이를 시작할 수 있어요" 를 보여 줍니다.
  - `DeployStatusChecker` 가 실패해서 서버 점검 화면이 뜰 때도 이 UI 를 보여 줍니다. 지금은 그 화면에서 진행이 멈추므로 오프라인 UI 를 deploy status 확인보다 먼저 그립니다.
  - `ServerList.AccountServer` 를 바꿀 수 있게 하고, 오프라인에서는 lobby 와 account 를 모두 로컬 서버로 지정합니다. `AuthSession` 의 refresh loop 와 JWKS 조회를 건너뛰고, `MatchmakingCoordinator` 의 SSE 를 시작하지 않고, PvP·퀘스트·프로필·상점 버튼을 숨기고, `SessionLossReporter` 를 끕니다.

## Approach (Checklist)

단계마다 저장소별 pull request 로 나눕니다. 같은 저장소 안의 pull request 는 stack 합니다.

- [x] **Recon** (game, lobby, client, database, frame 의존 목록 조사 완료)
- [ ] **0단계 — FPS 와 무관한 simulation**
  - [x] game ([ArcaneCastersGame#113](https://github.com/Apptive-Game-Team/ArcaneCastersGame/issues/113), `feature/113`): `GameContext.tickRate`, nanosecond frame 길이, 위 표의 시간 기준 변환, sync 메시지 `tickRate`, FPS 경보 기준 → draft [ArcaneCastersGame#114](https://github.com/Apptive-Game-Team/ArcaneCastersGame/pull/114)
  - [x] game 테스트: `ManaCharger`, `CardDeck`(fever 포함), `BotAgent`, `PVEBossMob`, `PveScriptSystem`, 간격 timer 의 tick rate 20·60 결과 비교. frame 수에 의존하던 기존 테스트 수정
  - [x] client ([ArcaneCastersClient#302](https://github.com/Apptive-Game-Team/ArcaneCastersClient/issues/302), `feature/302`): `tickRate` 수신, tween 길이·방향 전환·파괴 지연을 tick rate 기준으로 → draft [ArcaneCastersClient#305](https://github.com/Apptive-Game-Team/ArcaneCastersClient/pull/305)
  - [x] 검증: 봇 대 봇 80 세션 15분씩, 기존 20·새 20·새 60 FPS 각 약 390판. 새 20 과 새 60 은 평균 경기 시간 −3.0%, 왼쪽 승률 +5.7%p(유의하지 않음). 기존 대비 새 20 은 무승부(시간 초과) 3.1% → 7.9%. 결과표는 ArcaneCastersGame#114 설명
- [ ] **1단계 — 온라인 로컬 호스팅**
  - 계약: `.plan/general/2026-10-12-local-hosting-contracts.md`. issue: ArcaneCastersDatabase#91, ArcaneCastersLobby#71, ArcaneCastersGame#115 (`feature/113` 위), ArcaneCastersClient#314 (`feature/302` 위)
  - 바뀐 점: 경기 결과는 로컬 서버가 아니라 client 가 lobby 에 보고합니다(client 가 죽으면 로컬 서버도 같이 끝나므로)
  - [ ] database: 통계 표 `hosted_locally` 열, 거절 기록 표
  - [ ] lobby: `POST /api/local-sessions`, `POST /api/local-sessions/{id}/result`(검사와 기록), 인증 없는 `GET /api/offline-pack`
  - [ ] game: stdin/stdout launcher(`init`·`ready`·`matchStats`·`error`·`shutdown`, stdin EOF 종료, 포트 0, console log 끄기), `local` profile(H2 in-memory, local token, heartbeat·자동 대전·DB 통계 끄기), `POST /api/local/sessions`, lobby 결과 보고와 재전송, `localServerDist` 4개 플랫폼, release asset
  - [ ] client: `LocalServerHost`, `LocalServerPackStore`, `LocalTickRatePolicy`, 봇전·모험 경로 분기와 공유 서버 fallback, 설정 화면 UI
  - [ ] client release workflow: `static.json` 포함
- [ ] **2단계 — 오프라인 플레이**
  - [ ] lobby: `GET /api/users/mine/offline-pack/account`
  - [ ] game: 파일 H2, 오프라인 봇 선택, lobby·account endpoint 대체와 contract test
  - [ ] client: 계정 복사본 저장과 합치기, 오프라인 프로필, 로그인 화면 UI, 온라인 의존 지점 분기

## Validation

- **0단계**
  - `cd game && ./gradlew test`, client 의 compile 확인
  - 봇 대 봇 비교에서 tick rate 20 과 60 의 persona 별 승률 차이가 5%p 안, 평균 경기 시간 차이가 5% 안
  - dev 배포 후 공유 서버(20 FPS) 경기에서 FPS 경보와 경기 시간 분포가 배포 전과 비슷한지 확인
- **1단계**
  - lobby 결과 검사 테스트: 정상 보고, 두 번째 보고, 실제 시간보다 긴 경기 시간, frame 수와 시간 불일치, ACTIVE 가 아닌 시나리오, 하루 상한 초과
  - Windows, macOS, Linux 실기기에서: 서버 묶음 설치 → 봇전 1판 → 모험 첫 시나리오 승리 → lobby 에 진행도 반영 확인 → client 를 작업 관리자나 `kill -9` 로 강제 종료한 뒤 `java` 프로세스가 stdin EOF 로 끝나는지 확인 → 로컬 서버를 일부러 막고 공유 서버로 fallback 되는지 확인
  - 공유 DB 에서 `hosted_locally = true` 인 경기 기록이 생기는지 확인
  - 144Hz 모니터에서 20 → 30 → 60 → 120 → 144 로 한 경기씩 올라가는지, CPU 에 다른 부하를 걸었을 때 다음 경기부터 한 단계씩 내려가는지, 내려간 뒤에는 3경기를 채워야 다시 올라가는지 확인
  - game 의 tick rate 테스트(마나, 카드, 봇, 보스, trigger, 간격 timer)에 144 와 240 경우 추가
- **프로세스 제어 테스트 (game)**
  - launcher 에 `init` 을 보내면 `ready` 의 포트로 WebSocket 접속이 되는지, 잘못된 token 이 거절되는지, stdin 을 닫으면 5초 안에 종료되는지, 기동 중 예외가 `error` 한 줄로 나오는지, stdout 에 프로토콜 외의 줄이 섞이지 않는지 확인합니다.
- **2단계**
  - 네트워크를 끈 상태에서 오프라인 플레이 → 덱 편집 → 봇전 → 모험 해금 → 재실행 후 진행도 유지 → 온라인 로그인 후 합치기 규칙 확인
  - 한 번도 로그인하지 않은 설치본에서 시작 버튼이 꺼져 있는지 확인

## Risks & Rollback

- **Risks:**
  - 밸런스 변화: 0단계의 남은 시간 이어 가기는 20 FPS 공유 서버에서도 소환·공격 주기를 최대 50ms 앞당깁니다. 봇 대 봇 비교로 크기를 재고, 영향이 크면 해당 parameter 를 조정하는 migration 을 함께 냅니다.
  - 충돌 판정 차이: 60 FPS 에서 빠른 투사체의 적중이 20 FPS 와 다를 수 있습니다. 봇 대 봇 비교에서 마법별 적중률을 따로 봅니다.
  - 결과 조작: 로컬 결과는 조작할 수 있습니다. 검사는 시간 조건과 순서 조건으로 이득을 제한할 뿐 막지는 못합니다. 걸린 것은 모험 진행도, 승수, 퀘스트 보상입니다. 거절 기록으로 남용을 지켜보고, 문제가 생기면 lobby 설정으로 로컬 결과 반영을 끕니다.
  - H2 호환성: `jsonb`(`magics.indicator`) 같은 Postgres 전용 열이 더 있을 수 있습니다. local profile 테스트에서 경기를 끝까지 돌려 확인합니다.
  - schema 어긋남: 정적 데이터의 열이 바뀌면 `schema-local.sql` 과 pack 형태를 함께 고쳐야 합니다. pack 에 schema version 을 넣고, 모르는 version 이면 로컬 실행을 끄고 공유 서버를 씁니다.
  - lobby 와 game 의 기록 로직 중복: 경기 종료 기록이 game(공유 서버 경기)과 lobby(로컬 경기) 두 곳에 생깁니다. 같은 SQL 을 쓰도록 하고 양쪽 테스트에서 같은 fixture 로 확인합니다.
  - 백신 프로그램이나 macOS Gatekeeper 가 `java` 실행을 막을 수 있습니다. 실행 실패는 fallback 으로 처리하고 설정 화면에 사유를 보여 줍니다.
  - 높은 tick rate 의 부하: 144 FPS 는 20 FPS 의 7배가 넘는 CPU 와 메시지를 씁니다. 20 에서 시작해 한 단계씩 올리므로 저사양 PC 도 첫 경기는 공유 서버와 같은 품질이고, 끊기는 경기는 최대 한 경기입니다.
  - 기동 시간과 메모리: Spring Boot 기동 5~10초, 메모리 300MB 안팎으로 예상합니다. 길면 AppCDS archive 를 묶음에 넣습니다.
- **Rollback steps:**
  - 0단계: game, client pull request 를 `git revert` 합니다. DB 는 바꾸지 않습니다.
  - 1단계: lobby 설정으로 `POST /api/local-sessions` 를 끄면 client 는 모두 공유 서버로 fallback 합니다. 배포 없이 되돌릴 수 있습니다.
  - 2단계: client 의 오프라인 UI 를 숨기거나 pull request 를 `git revert` 합니다.

## Open Questions

- 로컬 경기 결과의 최소 경기 시간과 하루 상한 초기값(30초, 100판)이 적당한지 확인이 필요합니다.
- 오프라인 경기 기록을 밸런스 분석용으로 따로 올리는 기능은 2단계 이후 후보로 둡니다.
