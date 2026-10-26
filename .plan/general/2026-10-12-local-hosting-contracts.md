# 2026-10-12 — 1단계 온라인 로컬 호스팅: 저장소 사이 계약

- Date: 2026-10-12
- GitHub Issue: 저장소별 issue 는 아래 "작업 분담" 참고
- Status: Draft
- 상위 계획: `.plan/general/2026-10-10-local-game-server.md` 의 "1단계 설계"

database, lobby, game, client 네 저장소가 동시에 작업하므로, 저장소 사이를 오가는 값은 모두 이 문서가 정합니다. 구현하다가 이 문서와 다르게 해야 할 이유가 생기면 혼자 바꾸지 말고 보고합니다.

## 상위 계획에서 바뀐 점

- **경기 결과는 client 가 lobby 에 보고합니다.** 상위 계획은 로컬 서버가 직접 보고한다고 적었지만, client 가 죽으면 stdin EOF 로 로컬 서버도 함께 끝나므로 로컬 서버가 보고해도 얻는 것이 없습니다. 로컬 서버는 결과를 stdout 으로 client 에 넘기고, client 가 자기 JWT(`AuthSession` 이 갱신하는 값)로 lobby 에 보고합니다. 그래서 로컬 서버는 lobby 주소와 사용자 JWT 를 몰라도 됩니다.
- **경기 WebSocket 은 로컬 token 으로 인증합니다.** client 는 로컬 경기에서 `SceneContext.JwtToken` 대신 로컬 token 을 query 와 STOMP 헤더에 넣습니다.

## 1. 정적 데이터 JSON (`static.json`)

lobby 가 만들고, client 가 저장하고, 로컬 서버가 H2 에 넣습니다.

```json
{
  "schemaVersion": 1,
  "staticVersion": "<sha256 hex>",
  "generatedAt": "2026-10-12T03:00:00Z",
  "tables": {
    "magics": {
      "columns": ["id", "name", "access_type", "..."],
      "rows": [[1, "fire_shot", "FREE", "..."]]
    }
  }
}
```

- `schemaVersion`: 정수. 이 문서의 형식과 표 목록이 바뀔 때만 올립니다. 지금은 `1`.
- `staticVersion`: `tables` 를 표 이름 순, 각 표의 행을 첫 열(대개 `id`) 순으로 정렬해 직렬화한 UTF-8 byte 의 sha256 hex. 내용이 같으면 같은 값이어야 합니다.
- 값 형식: 숫자, 문자열, boolean, null. `jsonb` 와 `json` 열은 JSON 문자열, timestamp 는 ISO-8601 문자열, Postgres enum 은 문자열.
- 표 목록과 행 범위:

| 표 | 행 |
|---|---|
| `parameters`, `parameter_values`, `magic_parameters`, `game_objects`, `prefab_elements`, `magics`, `magic_game_object_aliases`, `tags`, `tag_counter_rules`, `game_object_tags`, `magic_tags` | 전체, 모든 열 |
| `adventures`, `stages`, `scenarios` | 전체, 모든 열 |
| `pve_scenario_objectives`, `pve_scenario_installers`, `pve_scenario_events`, `pve_scenario_event_lines`, `pve_scenario_event_actions`, `pve_scenario_rules`, `pve_scenario_shields` | 전체, 모든 열 (표가 없으면 빼고 보고) |
| `bot_personas` | 전체, 모든 열 |
| `users` | **`id < 0` 인 봇 행만**, 열은 `id`, `selected_deck_id`, `mmr`, `status`, `total_wins`, `novice_progress` 만 |
| `decks` | `user_id < 0` 인 행만, 모든 열 |
| `deck_cards` | 위 `decks` 에 속한 행만, 모든 열 |

- 실제 사용자(`id >= 0`)의 행은 어떤 표에서도 나가면 안 됩니다. lobby 테스트로 검사합니다.
- 로컬 서버는 자기 H2 schema 에 있는 열만 넣고, schema 에 없는 열은 무시하고 경고 log 를 남깁니다. 로컬 서버에 필요한데 목록에 없는 표가 있으면 보고합니다.

## 2. lobby API

### `GET /api/offline-pack` (인증 없음)

query: `staticVersion` (선택). client 가 가진 값과 같으면 `staticData` 를 `null` 로 보냅니다.

```json
{
  "schemaVersion": 1,
  "staticVersion": "<sha256 hex>",
  "staticData": { "...1번 형식..." },
  "localSessionsEnabled": true,
  "localServer": {
    "version": "1.3.0",
    "minimumVersion": "1.3.0",
    "assets": {
      "windows-x64": "https://github.com/Apptive-Game-Team/ArcaneCastersGame/releases/download/v1.3.0/local-server-windows-x64.zip",
      "macos-x64": "...",
      "macos-arm64": "...",
      "linux-x64": "..."
    }
  }
}
```

- `localServer` 는 lobby 설정에서 옵니다: `local-server.version`, `local-server.minimum-version`, `local-server.asset-url-template` (기본 `https://github.com/Apptive-Game-Team/ArcaneCastersGame/releases/download/v{version}/local-server-{platform}.zip`). `version` 이 비어 있으면 `localServer` 를 `null` 로 보냅니다.
- `localSessionsEnabled` 는 설정 `local-sessions.enabled` (기본 `true`). `false` 면 client 는 로컬 경기를 시도하지 않습니다. 배포 없이 로컬 경기를 끄는 스위치입니다.
- 정적 데이터는 lobby 안에서 cache 하고 일정 간격(기본 5분)으로 다시 만듭니다.

### `POST /api/local-sessions` (사용자 JWT)

요청:

```json
{ "type": "PRACTICE", "scenarioId": null }
```

- `type`: `PRACTICE` 또는 `PVE`. `PVE` 면 `scenarioId` 필수.
- 봇 선택은 기존 `GameMatchService.matchPractice` 와 같은 규칙(초보자는 접대봇, 아니면 무작위)을 그대로 씁니다. 세션 id 는 기존 Redis counter 로 `local-<n>`.
- `PVE` 는 그 사용자의 `user_scenarios` 가 `ACTIVE` 또는 `FINISHED` 인 시나리오만 받습니다. 아니면 `409`.
- `local-sessions.enabled` 가 `false` 면 `503`.

응답 `201`:

```json
{
  "sessionId": "local-123",
  "type": "PRACTICE",
  "scenarioId": null,
  "leftUserId": 5,
  "rightUserId": -54,
  "leftUser": { "id": 5, "name": "...", "email": "..." },
  "rightUser": { "id": -54, "name": "...", "email": "bot@theevilent.com" },
  "leftDeckCardIds": [1, 1, 1, 7, 7],
  "ownedMagicIds": [1, 7, 9],
  "noviceProgress": 0.5,
  "staticVersion": "<sha256 hex>",
  "issuedAt": "2026-10-12T03:00:00Z"
}
```

- `PVE` 는 `rightUserId` 가 `-1`, `rightUser` 는 기존 PVE 와 같은 dummy (`id 0`, `name "dummy"`).
- `leftUser`, `rightUser` 는 client 가 `MatchedInfoDto` 를 만들 때 씁니다. 기존 `MatchedInfoDto` 를 만드는 코드와 같은 출처(account server 조회, 봇은 `BotMemberMaker`)에서 가져옵니다.
- `leftDeckCardIds` 는 기존 PVP 세션 생성이 game server 에 넘기는 `leftDeckCardIds` 와 같은 형식입니다.
- Redis 에 `local-session:{sessionId}` 로 `{userId, type, scenarioId, rightUserId, hospitalityBot, issuedAt, state: "ISSUED"}` 를 TTL 2시간으로 저장합니다.

### `POST /api/local-sessions/{sessionId}/result` (사용자 JWT)

요청:

```json
{
  "outcome": "WIN",
  "winUserId": 5,
  "lossUserId": -54,
  "durationMillis": 154000,
  "frameCount": 9240,
  "tickRate": 60,
  "localServerVersion": "1.3.0",
  "decks": [{ "userId": 5, "magicId": 1, "count": 3 }],
  "magics": [{ "userId": 5, "magicId": 1, "count": 4 }]
}
```

- `outcome`: `WIN`, `DRAW`, `ABANDONED`. `WIN` 이 아니면 `winUserId`, `lossUserId` 는 `null`. 형식은 game 의 `GameResultDto` 와 같습니다.

응답:

- 세션 기록이 없으면 `404`, 이미 보고된 세션이면 `409`.
- 그 외에는 검사 결과와 관계없이 `200` `{ "accepted": true }` 또는 `{ "accepted": false, "reason": "<code>" }`. 거절을 `4xx` 로 돌려주면 client 가 재시도하므로 `200` 으로 답합니다.

검사 (하나라도 걸리면 거절, 상태는 `REPORTED` 로 바꿔 재보고를 막음):

| reason | 조건 |
|---|---|
| `WRONG_USER` | 세션의 `userId` 와 JWT 사용자가 다름 |
| `DURATION_EXCEEDS_WALL_CLOCK` | `issuedAt` 부터 지금까지의 실제 시간 < `durationMillis` |
| `FRAME_DURATION_MISMATCH` | `frameCount / tickRate` 와 `durationMillis / 1000` 의 차이가 10% 초과 |
| `TOO_SHORT` | `outcome == WIN` 이고 `durationMillis` < 30000 (설정 `local-sessions.minimum-win-millis`) |
| `PARTICIPANT_MISMATCH` | `winUserId`, `lossUserId` 가 세션의 두 참가자가 아님 |
| `DAILY_LIMIT` | 그 사용자가 오늘(UTC) 받아들여진 로컬 결과가 100개 이상 (설정 `local-sessions.daily-result-limit`) |

받아들인 결과의 기록 (지금 game server 가 공유 서버 경기에서 하는 것과 같은 값):

- `statistic_games` (`hosted_locally = true`, `server_version = localServerVersion`, `game_type` 은 세션 type), `statistic_game_decks`, `statistic_game_magics`.
- `PVE` 이고 사용자가 이겼고 그 시나리오가 지금 `ACTIVE` 면 `user_scenarios.state = 'FINISHED'`. 이미 `FINISHED` 면 그대로.
- 사용자가 이겼으면 `users.total_wins + 1`.
- `PRACTICE` 이고 상대가 접대봇이고 사용자가 이겼으면 `novice_progress` 를 game server 의 `advanceNoviceProgress` 와 같은 규칙으로 올림.

거절한 결과는 `local_session_rejections` 에 `user_id`, `session_id`, `reason`, `payload`(요청 JSON) 를 남깁니다.

## 3. database migration

`ArcaneCastersDatabase` 의 열린 stack 맨 위(`feature/89`, PR #90, V035) 위에 V036 하나:

- `statistic_games.hosted_locally boolean NOT NULL DEFAULT false`
- `local_session_rejections (id bigserial PK, user_id bigint NOT NULL, session_id varchar(64) NOT NULL, reason varchar(64) NOT NULL, payload jsonb, created_at timestamp NOT NULL DEFAULT now())`, `user_id, created_at` index

## 4. 로컬 서버 실행과 stdin/stdout

### 묶음 구조와 실행

release asset `local-server-{platform}.zip` 과 `local-server-{platform}.zip.sha256` (sha256 hex 한 줄). platform 은 `windows-x64`, `macos-x64`, `macos-arm64`, `linux-x64`.

```
local-server/
  VERSION                 # game version 한 줄, 예: 1.3.0
  local-server.jar        # game bootJar
  jre/                    # jlink JRE 21
```

실행: `jre/bin/java` (Windows 는 `jre\bin\java.exe`) `-Xmx512m -jar local-server.jar --spring.profiles.active=local`. 작업 directory 는 `local-server/`.

### stdin (client → 서버), 한 줄에 JSON 하나

- 첫 줄: `{"type":"init","token":"<32 byte 이상 무작위 hex>","dataDir":"<절대 경로>","staticDataPath":"<static.json 절대 경로>"}`
  - 서버는 이 줄을 받기 전에는 포트를 열지 않습니다.
- `{"type":"shutdown"}`: 진행 중인 경기를 끝내고 종료.
- stdin EOF: 바로 종료.

### stdout (서버 → client), 한 줄에 JSON 하나. 이 줄들 말고는 아무것도 쓰지 않음

- `{"type":"ready","port":51234,"serverVersion":"1.3.0","schemaVersion":1,"staticVersion":"<sha256 hex>"}`
- `{"type":"error","reason":"<사람이 읽는 문장>"}`: 기동 실패. 직후 종료.
- `{"type":"matchStats","sessionId":"local-123","targetTickRate":60,"meanFps":59.9,"p10Fps":58.7}`: 경기가 끝날 때.
- `{"type":"matchResult","sessionId":"local-123", ...2번 result 요청 body 의 모든 필드...}`: 경기가 끝날 때. client 는 `sessionId` 를 뺀 나머지를 그대로 lobby 에 보냅니다.

log 는 `dataDir/logs/` 파일로만 씁니다. JVM 이 stderr 에 쓰는 것은 client 가 읽어서 버립니다(또는 log 파일로 저장).

### `POST /api/local/sessions` (로컬 서버, `Authorization: Bearer <init token>`)

요청 = lobby `POST /api/local-sessions` 응답 전체 + `"tickRate": 60`.

응답 `201`: `{ "sessionId": "local-123", "webSocketUrl": "ws://127.0.0.1:51234/ws" }`

- 로컬 서버는 요청의 `leftUserId` 로 `users` 행(`novice_progress` 포함)과 `user_magics`(`ownedMagicIds`, count 3)를 H2 에 넣거나 갱신하고, `leftDeckCardIds` 로 세션을 만듭니다.
- 동시에 진행하는 세션은 하나입니다. 이전 세션이 남아 있으면 끝내고 새로 만듭니다.
- WebSocket handshake 의 `?token=` 과 STOMP CONNECT 의 `Authorization: Bearer` 에는 init token 이 옵니다. 로컬 서버는 이 token 을 마지막으로 만든 세션의 `leftUserId` 사용자로 인증합니다.
- `ready` 이후 `GET /healthcheck` 는 지금처럼 동작합니다(인증 없음).

## 5. client 쪽 규칙 (client 안에서만 쓰지만 참고용)

- 저장 위치: `Application.persistentDataPath/local-server/` 아래 `bundles/<version>/` (압축을 푼 묶음), `static.json`, `pending-results/` (보고 실패한 결과).
- 정적 데이터는 `static.json`(내려받은 것)과 `StreamingAssets/Offline/static.json`(설치본) 중 `schemaVersion` 이 서버와 같고 lobby 의 `staticVersion` 과 같은 것을 씁니다. lobby 와 다르면 경기 전에 자동으로 받습니다.
- 로컬 경기 조건: desktop(Windows, macOS, Linux) 이고, 설정이 켜져 있고, `localSessionsEnabled` 이고, 설치된 묶음 version >= `minimumVersion` 이고, 서버가 `ready` 상태. 하나라도 아니면 기존 `GET /api/match/practice/me`, `GET /api/scenarios/{id}/play` 를 씁니다. lobby 가 `503` 을 주면 같은 fallback.
- tick rate 는 상위 계획의 "tick rate 정하기" 규칙(20 에서 시작, 모니터 주사율 상한, `matchStats` 로 올리고 내리기).

## 작업 분담

| track | 저장소 | branch base | 범위 |
|---|---|---|---|
| D | database | `feature/89` (stack) | 3번 migration |
| L | lobby | `origin/dev` | 2번 API 세 개, 1번 생성, 설정, 테스트 |
| G | game | `feature/113` (stack) | 4번 전부, local profile, 1번 import, `localServerDist`, release workflow |
| C | client | `feature/302` (stack) | 5번 전부, `LocalServerHost`, 묶음 설치·업데이트, 결과 보고, 설정 화면, release workflow 의 `static.json` |
