# 개발 명령어

이 저장소의 로컬 test 환경 작업은 루트의 `./dev` 하나로 합니다. docker 와 같은
`./dev <command> <subcommand>` 문법입니다. `./dev` 는 `.agents/skills/test-env/scripts/testenv.sh`
를 그대로 감싼 것이고, 실제 clone·migration·server 실행은 모두 그 script 가
합니다.

```bash
./dev
```

command 목록이 나옵니다. `./dev <command>` 는 그 command 의 subcommand 목록을
보여줍니다.

## 빠른 시작

처음 환경을 만들 때는 이 순서로 칩니다.

```bash
./dev setup env    # .db.env 를 game/.env 의 dev database 값으로 만듭니다
./dev db clone      # game database 를 로컬 Docker Postgres container 로 clone 합니다
./dev server up     # game 과 lobby server 를 clone 에 대해 띄웁니다
./dev db psql       # clone 에 psql session 을 엽니다
```

`./dev db clone` 은 `.db.env` 에 적힌 source 를 화면에 보여주고 확인을 묻습니다.
`.db.env` 가 가리키는 database 가 무엇인지 먼저 읽고 승인하십시오 — 아래
"clone 은 실제 데이터입니다" 를 반드시 읽으십시오.

무언가 막히면 `./dev setup check` 로 Docker daemon, migration, `.db.env`,
port 상태를 한 번에 확인하십시오.

### `.db.env` 는 credential 을 손으로 옮겨 적지 않습니다

`./dev setup env` 는 `game/.env` (없으면 `admin/.env`) 에 이미 있는 dev
database 값을 그대로 옮겨서 `.db.env` 를 만듭니다. 그 값은 이 machine 에
이미 있는 credential 이므로, 이 command 는 host 나 user, password 를 사람에게
다시 입력하라고 묻지 않습니다. `.db.env` 가 이미 있으면 새로 만들지 않고
source label 과 host, database 이름만 보여줍니다.

## 준비물

- Docker 가 실행 중이어야 합니다. host 에 `psql`, `pg_dump`, `flyway` 는 없어도
  됩니다 — 셋 다 container 안에서 돕니다.
- submodule 이 초기화되어 있어야 합니다 (`database/migration` 이 있어야
  합니다):

  ```bash
  git submodule update --init --recursive
  ```

- 저장소 루트에 `.db.env` 가 있어야 합니다. `.db.env` 가 없으면
  `./dev setup env` 로 만드십시오.

### clone 은 실제 데이터입니다

`./dev db clone` 은 `.db.env` 가 가리키는 실제 database 를 복사합니다.
`.db.env` 가 어느 환경을 가리키는지 정하며, 그게 dev 환경이 아닐 수도
있습니다 — 반드시 화면에 뜨는 source 를 확인한 뒤 승인하십시오. clone 된
행은 실제 사용자 데이터입니다. 로컬에만 두고, 어디에도 올리지 마십시오.

## 여러 component 의 branch 맞추기

이 저장소는 `game`, `lobby`, `client`, `database`, `admin`, `account`,
`website`, `infra` 여덟 개 submodule 로 나뉘어 있습니다. 기능 하나가 이 중
여러 submodule 에 걸쳐 있을 때, 각 component 가 지금 어느 branch 에 있는지
한 번에 보고 맞추거나, 나중에 다시 쓰려고 그 조합을 이름 붙여 저장하려면
`./dev branch` 를 씁니다. subcommand 는 `show`, `use`, `save`, `load`,
`list` 다섯 개입니다.

```bash
./dev branch show   # 각 component 의 현재 branch 와 변경 여부를 봅니다
```

component 목록은 `.dev/config.sh` 의 `DEV_COMPONENTS` 배열을 먼저 찾고,
없으면 `.gitmodules` 의 submodule 경로를 씁니다. 이 저장소는
`DEV_COMPONENTS` 를 정의하지 않으므로 `.gitmodules` 에 적힌 여덟 submodule
이 그대로 component 목록이 됩니다.

### `use` — 누구를 옮길지 정하는 규칙

component 이름을 대면 그 component 만 옮깁니다. 이름 대지 않은 기본
branch 를 같이 주면, 이름을 대지 않은 나머지 component 도 그 branch (없으면
fallback branch) 를 따라갑니다. 즉 이름을 대는 것이 옮길 대상을 정하고,
기본 branch 는 나머지를 끌고 오는 역할입니다.

| 명령어 | 결과 |
| --- | --- |
| `./dev branch use magic-card` | 모든 component 를 `magic-card` 로 옮깁니다. `magic-card` 가 없는 component 는 fallback branch (기본값 `main`) 로 갑니다 |
| `./dev branch use magic-card lobby=main` | 위와 같지만 `lobby` 만 `main` 으로 갑니다 |
| `./dev branch use game=feature/12` | `game` 만 옮깁니다. 다른 component 는 손대지 않습니다 |

`component=branch` 로 이름 댄 branch 가 그 component 에 없으면 fallback
으로 대신 보내지 않고 그 자리에서 전체 operation 을 막습니다. 예를 들어
`game=magic-card` 인데 `game` 에 `magic-card` branch 가 없으면 막힌
component 목록에 `game: magic-card 이(가) 없습니다` 라고 보여주고
아무것도 옮기지 않습니다 — 이름을 대며 요청한 branch 는 사람이 원한
것이므로, 조용히 다른 곳으로 돌려보내면 안 됩니다.

### 변경사항이 있으면 전체를 거부합니다

옮길 대상에 든 component 중 commit 하지 않은 변경사항이 있는 것이
하나라도 있으면, `./dev branch use` 는 그 component 만 건너뛰는 게 아니라
전체 operation 을 거부합니다. checkout 을 하나도 하지 않고, 어느 component
가 막혔는지와 그 이유만 보여줍니다.

이 command 는 `git stash` 를 쓰지 않습니다. stash 는 같은 저장소의 worktree
사이에서 공유되므로, 이 command 가 변경사항을 stash 로 밀어 넣으면 다른
session 이 그걸 pop 해서 남의 작업을 가져갈 수 있습니다. 그래서 변경사항이
있는 component 는 사람이 직접 commit 하거나 되돌린 뒤 다시 실행해야 합니다.

### `--dry-run` 으로 먼저 계획을 봅니다

`--dry-run` 을 주면 각 component 를 어디로 옮길지 계획만 보여주고
아무것도 바꾸지 않습니다. `use` 와 `load` 양쪽 모두에서 쓸 수 있습니다.
실제로 checkout 하기 전에 계획을 먼저 확인하려면 `--dry-run` 으로
실행하십시오.

### 조합을 저장하고 불러오기 — `save`, `load`, `list`

`./dev branch save <이름>` 은 지금 각 component 가 있는 branch 를
`.dev/branches/<이름>` 파일에 `component=branch` 로 한 줄씩 적습니다.
detached HEAD 인 component 는 적을 branch 이름이 없으므로 건너뛰고 그
이유를 알려줍니다.

`./dev branch load <이름> [--fetch] [--dry-run]` 은 그 파일에 적힌 대로
각 component 를 옮깁니다. 파일에 없는 component 는 손대지 않습니다 —
저장할 때 detached 라서 빠진 component 처럼, 조합에 없는 component 는
`load` 가 지금 있는 자리 그대로 둡니다.

`./dev branch list` 는 저장된 조합 이름과 그 안의 `component -> branch`
목록을 보여줍니다. 저장된 조합이 없으면 그렇게 말하고 exit code 0 으로
끝납니다.

저장한 조합은 이 저장소에 commit 되지 않습니다. 루트 `.gitignore` 에
`.dev/branches/` 가 있어서 git 이 무시합니다. 조합 파일에는 개인 작업
branch 이름이 들어가므로 각자 자기 것만 갖습니다.

### submodule pointer 를 commit 하는 것은 따로 정합니다

`./dev branch use` 나 `./dev branch load` 로 submodule 의 branch 를 바꾸면
working tree 의 submodule pointer 도 함께 달라집니다. 이 pointer 를
commit 할지는 이 command 가 정하지 않고 따로 정합니다 — 이 저장소의
`AGENTS.md` 5번 절 "Submodule Change Management" 의 순서를 따르십시오:
submodule 안에서 먼저 commit 하고 push 한 뒤, 루트로 돌아와 pointer 를
commit 합니다.

## 명령어

아래 표는 `./dev docs` 가 `.dev/commands/` 를 읽어서 다시 만듭니다. 손으로
고치지 마십시오. 설명을 바꾸려면 command 파일의 `dev_describe` 와 `dev_verb`
줄을 고치고 `./dev docs` 를 다시 실행하십시오.

<!-- dev:commands:start -->

### `./dev branch` — 여러 component 의 branch 를 한 번에 보고 맞춥니다

| 명령어 | 하는 일 |
| --- | --- |
| `./dev branch show` | 각 component 의 현재 branch 와 변경 여부를 보여줍니다 |
| `./dev branch use [branch] [c=branch] [--fallback <b>] [--fetch] [--dry-run]` | 이름을 댄 component 를 그 branch 로 옮깁니다. 기본 branch 를 같이 주면 나머지도 그 branch (없으면 fallback) 로 따라갑니다 |
| `./dev branch save <이름>` | 지금 각 component 의 branch 조합을 그 이름으로 저장합니다 |
| `./dev branch load <이름> [--fetch] [--dry-run]` | 저장한 조합대로 맞춥니다. 조합에 없는 component 는 건드리지 않습니다 |
| `./dev branch list` | 저장된 조합을 보여줍니다 |

### `./dev db` — 로컬 test database clone — game database 를 Docker Postgres container 로 가져옵니다

| 명령어 | 하는 일 |
| --- | --- |
| `./dev db clone [--yes]` | game database 를 로컬 clone 으로 가져옵니다. --yes 없이 실행하면 source 를 보여주고 확인을 묻습니다 |
| `./dev db psql [database]` | 로컬 clone 에 psql session 을 엽니다. database 를 생략하면 game database 를 엽니다 |
| `./dev db migrate` | 기존 clone 에 database/migration 의 Flyway migration 을 다시 적용합니다 |
| `./dev db status` | container 상태와 clone 의 연결 정보를 보여줍니다 |
| `./dev db down [--purge]` | clone container 를 내립니다. --purge 를 주면 dump volume 과 network 도 지웁니다 |

### `./dev server` — clone 에 대해 돌아가는 game/lobby/account/admin server

| 명령어 | 하는 일 |
| --- | --- |
| `./dev server up [module...]` | module 의 server 를 clone 에 대해 띄웁니다. module 을 생략하면 game 과 lobby 를 띄웁니다 |
| `./dev server stop` | 띄운 server 를 모두 멈춥니다 (database container 는 그대로 둡니다) |
| `./dev server logs <module>` | 해당 module server 의 log 를 실시간으로 따라갑니다 |
| `./dev server ports` | module 별 application port 와 actuator port 배정, 그리고 각 port 를 잡고 있는 process 를 보여줍니다 |
| `./dev server run-cmd <module>` | 해당 module server 를 clone 에 대해 foreground 로 띄우는 명령을 그대로 출력합니다 (직접 붙여넣어 실행) |
| `./dev server env-patch <module>` | 해당 module 의 .env 를 clone 을 가리키도록 다시 씁니다. 원본은 자동으로 backup 됩니다 |
| `./dev server env-restore <module>` | 해당 module 의 .env 를 env-patch 이전 상태로 되돌립니다. 평소 개발로 돌아가기 전에 반드시 실행해야 합니다 |

### `./dev setup` — 로컬 test 환경 준비 — .db.env 를 만들고 실행 준비 상태를 확인합니다

| 명령어 | 하는 일 |
| --- | --- |
| `./dev setup env` | .db.env 를 game/.env (없으면 admin/.env) 의 dev database 값으로 만듭니다. 이미 있으면 만들지 않고 SOURCE_LABEL 과 host, database 이름만 보여줍니다 |
| `./dev setup check` | Docker daemon, database/migration, .db.env, LOCAL_DB_PORT/LOCAL_REDIS_PORT 상태를 한 줄씩 보여줍니다. 문제가 있으면 exit code 가 0이 아닙니다 |

<!-- dev:commands:end -->

## 명령어 추가하기

1. `.dev/commands/<이름>.sh` 를 만듭니다. 기존 파일 하나를 복사하는 게 빠릅니다.
2. `dev_describe`, `dev_verbs`, `dev_run` 세 함수를 정의합니다.
3. `chmod +x` 는 필요 없습니다. dispatcher 가 source 합니다.
4. `testenv.sh` 를 부르는 명령이면 `.dev/lib/testenv.bash` 의 `testenv_run` 을
   통해서 부르십시오. 실행할 명령을 stderr 에 먼저 찍고, `DEV_DRY_RUN=1` 이면
   찍기만 하고 실행하지 않습니다.
5. `./dev docs` 로 이 문서의 표를 갱신합니다.

command 파일은 목록을 만들 때마다 source 되므로, 최상위에서 무언가를 실행하면
안 됩니다. 실행은 전부 `dev_run` 안에서 하십시오.

## Tab completion

Shell 시작 파일에 아래 한 줄을 추가하면 `./dev` 와 `dev` 양쪽 모두에 tab
completion 이 켜집니다.

```sh
source /home/yunseong/dev/arcane-casters/.dev/completion.bash
```

이 한 줄로 bash 와 zsh 양쪽에서 다 동작합니다 — zsh 에서는 이 파일이 필요한
`bashcompinit` 을 스스로 불러옵니다.

TAB 을 누르는 위치에 따라 다른 후보가 나옵니다.

- `./dev ` 뒤에서 TAB 을 누르면 command 이름 (`branch`, `db`, `server`,
  `setup`, `help`, `docs`) 이 나옵니다.
- `./dev <command> ` 뒤에서 TAB 을 누르면 그 command 의 subcommand 이름이
  나옵니다.
- `./dev <command> <subcommand> ` 뒤에서 TAB 을 누르면 그 subcommand 의
  `dev_verb` 인자 문자열에 적힌 긴 flag 이름이 나옵니다.

completion 은 매번 `./dev complete` 를 새로 실행해서 후보를 얻습니다. 그래서
`.dev/commands/` 에 새 command 파일을 추가해도 다시 만들 것이 없습니다 — 새
command 는 추가한 그 순간부터 바로 completion 대상이 됩니다.

TAB 을 누르는 순간 실제로 `./dev` 가 실행되어 `.dev/commands/` 의 모든
파일을 source 합니다. 이것은 평소 `./dev` 를 손으로 칠 때와 같은 코드
경로이므로 completion 이 새로운 노출을 더하는 것은 아니지만, 분명히
적어 둡니다.

## 구조

| 경로 | 무엇 |
| --- | --- |
| `dev` | 진입점. 프로젝트 루트를 찾아 dispatcher 에 넘깁니다. |
| `.dev/dispatch.sh` | 공용 dispatcher. dev-tool 스킬이 배포하며 여기서 고치지 않습니다. |
| `.dev/completion.bash` | bash 와 zsh 용 tab completion 함수. dev-tool 스킬이 배포하며 여기서 고치지 않습니다. `./dev complete` 가 내놓는 이름으로 후보를 만듭니다. |
| `.dev/config.sh` | 이름과 한 줄 소개. |
| `.dev/commands/branch.sh` | 여러 component 의 branch 를 한 번에 보고 맞추는 명령. |
| `.dev/commands/setup.sh` | `.db.env` 를 만들고 실행 준비 상태를 확인하는 명령. |
| `.dev/commands/db.sh` | 로컬 test database clone 명령. |
| `.dev/commands/server.sh` | clone 에 대해 돌아가는 server 명령. |
| `.dev/lib/testenv.bash` | `db.sh` 와 `server.sh` 가 같이 쓰는 helper. `testenv.sh` 명령을 찍고 실행합니다. command 가 아니므로 `./dev` 목록에는 나오지 않습니다. |

## 문제가 생기면

- **Docker daemon 이 응답하지 않습니다 (`docker daemon not reachable`)**:
  Docker Desktop 이나 Docker daemon 을 켜고 다시 실행하십시오. host 에 설치된
  Postgres 로 대신할 수 없습니다 — host 에는 client 도구가 없습니다.
- **port 가 이미 쓰이고 있습니다 (database 또는 Redis)**: 다른 무언가를
  내리지 말고, `.db.env` 의 `LOCAL_DB_PORT` 또는 `LOCAL_REDIS_PORT` 값을
  바꾸십시오.
- **actuator port 8081 이 충돌합니다 (`Port 8081 was already in use`)**:
  모든 module 의 `application.yml` 이 `management.server.port` 기본값을
  8081 로 두고 있어서, 두 번째로 뜨는 server 가 이 port 에서 죽습니다.
  `./dev server ports` 로 module 별 actuator port 배정과 그 port 를 잡고
  있는 process 를 확인하고, `./dev server run-cmd <module>` 이 만들어 주는
  명령으로 띄우십시오 — `--management.server.port` 없이 손으로 `bootRun` 을
  돌리면 다시 충돌합니다.
