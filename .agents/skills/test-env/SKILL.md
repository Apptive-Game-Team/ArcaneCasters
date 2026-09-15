---
name: test-env
description: Clone the shared game database into a local Docker Postgres, apply the WordOnlineDatabase Flyway migrations to the clone, and run the game, lobby, account and admin servers against it. Use when the user asks for a test environment, a local database copy, a psql session against real data, or invokes $test-env.
---

# Local Test Environment

Build a disposable test environment: a local Docker Postgres holding a clone of
the shared game database, migrated to the tip of `database/migration`, with the
servers pointed at it.

Everything runs through `scripts/testenv.sh`. Do not hand-roll the Docker,
`pg_dump`, or Flyway commands — the script encodes the ordering and the safety
rules below.

## Why cloning, not building from empty

`database/migration/V000` opens with `create database` and carries a
`pg_catalog` dump, so the Flyway chain cannot be replayed against an empty
database (WordOnlineDatabase issue #23). The clone arrives with its
`flyway_schema_history` intact, so Flyway applies only the pending migrations.
That is the whole reason this skill copies a real database instead of
provisioning a fresh one.

## Safety Rules

- The source database is **read-only**. It is only ever an argument to
  `pg_dump`. Never migrate it, never write to it, never drop it.
- Always show the resolved source host, database, and `SOURCE_LABEL` to the
  user and get explicit approval **before** passing `--yes`. `.db.env` decides
  which environment is cloned, and it may point at production.
- Never commit `.db.env`, a dump file, or any value read out of them. The root
  `.gitignore` covers `*.env`; verify before staging anything.
- Never print credentials, JWT keys, or connection strings containing
  passwords into a summary the user did not ask for.
- Never modify a module's `.env` without the script's backup step. `env-patch`
  copies the original to `.claude/testenv/backups/<module>.env` first — outside
  the submodule, so a file full of credentials never shows up as untracked in
  that submodule's `git status`.
- Cloned rows are real user data. Keep the clone local; do not upload dumps.

## Prerequisites

- Docker running. The host needs **no** `psql`, `pg_dump`, or `flyway` — the
  script runs all three in containers.
- Submodules initialized. `database/migration` must exist:

  ```bash
  git submodule update --init --recursive
  ```

- `.db.env` in the monorepo root. **If it is missing, do not ask the user to
  type credentials.** Follow
  [references/initialize-db-env.md](references/initialize-db-env.md): it maps
  the submodule `.env` files onto the template and defaults the source to the
  **dev** database. `.db.env` is gitignored, so a fresh checkout always needs
  this step once.

## Workflow

1. Confirm `.db.env` exists — if not, compose it per
   [references/initialize-db-env.md](references/initialize-db-env.md). Read
   back only the non-secret fields (`SOURCE_LABEL`, host, database name) to the
   user.

2. Get approval for that target, then bring the environment up:

   ```bash
   .agents/skills/test-env/scripts/testenv.sh up --yes --with game,lobby
   ```

   The script, in order: checks Docker and the migration directory, detects the
   source server's major version and matches the local image to it, starts the
   Postgres and Redis containers, `pg_dump | pg_restore`s the source into
   `LOCAL_DB_NAME`, runs `flyway migrate`, then starts the requested servers.

   Drop `--with` to bring up the database only.

3. Report the connection details and the Flyway `info` tail. Server logs land
   in `.claude/testenv/logs/<module>.log`.

4. Hand the user a psql session when they want one:

   ```bash
   .agents/skills/test-env/scripts/testenv.sh psql
   ```

5. Tear down when the user is done:

   ```bash
   .agents/skills/test-env/scripts/testenv.sh down
   ```

   Add `--purge` to also drop the dump volume and the Docker network.

## Servers

`game` and `lobby` are the default set. The script starts them with Spring
command-line arguments, which outrank the module's `.env`, so the checked-out
`.env` is left untouched and still points wherever it did before.

Only the database settings are overridden. Ports, JWT keys and service URLs
still come from the module's own `.env`, which is gitignored and therefore
absent from a fresh submodule clone — copy one in before starting a server.

`up --with` returns as soon as the servers are launched; they keep running
detached. Watch startup in `.claude/testenv/logs/<module>.log` rather than
waiting on the command.

To run one server in the foreground instead — to watch its log live, or to
drive it under a debugger — hand the user the generated command rather than
composing one by hand. It carries the database overrides and a conflict-free
actuator port:

```bash
.agents/skills/test-env/scripts/testenv.sh run-cmd lobby
```

### The server registry travels with the clone

`servers` lists which game servers are alive, and the clone brings the source
environment's rows along with its content. The lobby will match a player onto any
row it finds `ACTIVE`, so a local match can run on **dev's** game server against
**dev's** database: a deck edited here never reaches the match, and a value changed
here never takes effect. `up` and `migrate` therefore delete every `GAME` row whose
domain is not `127.0.0.1`. A server started by this script registers itself, which
puts the only usable row back.

Do not repair this by setting `state = 'INACTIVE'` by hand. The lobby's
`GameServerManagementService` revives a server as soon as one health check
succeeds, and the row comes back.

### The registered address must be `127.0.0.1`

Not `localhost`, not `::1`. The script passes `--server.domain=127.0.0.1` when it
starts the game server, so `game/.env` can hold whatever it holds; override it with
`LOCAL_GAME_DOMAIN` only if you know why.

Two separate rules force this, and only the IPv4 literal satisfies both.

**It has to be loopback.** The Unity client ships with `insecureHttpOption: 0` in
`ProjectSettings`, which blocks plain `http` to anything but loopback. Point the
server at a LAN address and the client fails with
`InvalidOperationException: Insecure connection not allowed` before it ever reaches
the game server.

**It has to be IPv4.** The client runs on Windows, the servers run in WSL, and the
Windows-to-WSL loopback forwarding carries IPv4 only. Measured 2026-09-15 with
`networkingMode=mirrored`:

| from | to | result |
|---|---|---|
| WSL | `[::1]:7777` | 200 — the server does listen dual stack |
| Windows | `[::1]:7777` | `ETIMEDOUT` — black-holed, not refused |
| Windows | `127.0.0.1:7777` | connects in 2ms |
| Windows | `localhost:7777` | connects, after 266ms of trying `::1` first |

Windows resolves `localhost` to `::1` before `127.0.0.1`. Node and curl fall back to
IPv4 after the timeout, so probing the address by hand makes it look fine. Unity's
`System.Net.WebSockets.ClientWebSocket` does not fall back.

**Recognise the symptom, because nothing reports an error.** The WebSocket handshake
reaches the game server and gets its `101`, a session is created, and the client then
drops the connection 19-35ms later without ever sending a STOMP `CONNECT` frame. The
game server logs `Upgrading to WebSocket`, `New StandardWebSocketSession`, then
`java.io.EOFException`. The client logs only `[STOMP] 연결 재시도` and ends at
`[SessionLoss] 판정: Lost (404)`. The same client connects to dev without trouble,
because a real host never touches loopback forwarding — so "works on dev, fails
locally" is the tell.

To check the Windows side of the boundary, run a probe through Windows `node.exe`
over interop rather than PowerShell: `Invoke-WebRequest` times out on WinHTTP proxy
handling even when the port is fine, and PowerShell 5.1's `ClientWebSocket` refuses
its own request once `Options.Proxy` is set. Both give false negatives.

### Ports

Every module's `application.yml` defaults `management.server.port` to `8081`,
so the second server to start dies with `Port 8081 was already in use`. The
application ports differ per module and come from each `.env`; only the
actuator port needs assigning, and the skill gives each module its own from
`LOCAL_MANAGEMENT_PORT_BASE`. `ports` prints the assignment and what is holding
each one.

**`account` and `admin` are opt-in — start them only when the user asks.** They
read their database settings from `.env` only, so they must be wired with
`env-patch` first. The script refuses to serve them otherwise, rather than
silently starting them against the shared database:

```bash
.agents/skills/test-env/scripts/testenv.sh env-patch account
.agents/skills/test-env/scripts/testenv.sh up --yes --with account,admin
.agents/skills/test-env/scripts/testenv.sh env-restore account
```

Always run `env-restore` before the user goes back to normal development, and
say so explicitly in the summary — a forgotten patch silently points a server
at the clone.

### The account database

`account` uses its own database, cloned only when `SOURCE_ACCOUNT_DATABASE_URL`
is set in `.db.env`. Without it, `env-patch account` points
`ACCOUNT_DATABASE_URL` at a database that was never populated.

Check which environment that URL names before cloning. It is a different host
from the game database and its name may carry no `dev` marker, so `SOURCE_LABEL`
does not describe it. Cloning it copies real account records — get explicit
approval first.

**This skill applies no migrations to the account clone — the account server
does it itself.** Since AccountServer#41 the account server carries its own
Flyway chain in `src/main/resources/db/migration` and migrates at startup, so
starting it against the clone baselines the clone and applies whatever is
pending. Verified against a clone: Flyway baselines at the chain's baseline
version, the baseline migration is recorded but not executed, and the cloned
rows are left untouched.

Never point `database/migration` at the account database. That chain targets
the shared game database only (`database/README.md`) and would corrupt the
clone.

`ACCOUNT_MIGRATION_DIR` in `.db.env` stays available for migrating the account
clone *without* starting the server. Leave it empty otherwise — with the server
running the chain, setting it only duplicates work.

### Module key map

Each module names its database settings differently. The script already encodes
this; the table is here for verification.

| Module | Driver | Keys |
|---|---|---|
| `game` | JDBC | `DATABASE_URL`, `DATABASE_USER`, `DATABASE_PW` |
| `lobby` | R2DBC | `DATABASE_URL`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `REDIS_HOST`, `REDIS_PORT` |
| `admin` | JDBC | `DATABASE_URL`, `DATABASE_USER`, `DATABASE_PW`, `DEV_DATABASE_*` |
| `account` | R2DBC | `GAME_DATABASE_*`, `ACCOUNT_DATABASE_*` (two databases) |

## Re-running

- Schema changed after adding a migration: `testenv.sh migrate`.
- Data drifted or the clone is dirty: `testenv.sh up --yes` re-dumps and
  recreates the local database. The local database is dropped; the source is
  not touched.
- `testenv.sh status` shows containers, connection strings, and running servers.

## Failure Handling

- **`docker daemon not reachable`**: Docker is not started. Do not fall back to
  a host-installed Postgres; the host has no client tools.
- **Cannot connect to the source**: report the host and port from `.db.env` and
  stop. Do not retry with other credentials or other hosts.
- **`the clone has no flyway_schema_history table`**: the source is not
  Flyway-managed. Do not baseline it to force the migration through — that
  records migrations as applied that never ran. Report it and ask which
  database to point at.
- **`pg_restore` warnings about roles or extensions**: expected. The script
  restores with `--no-owner --no-acl` and verifies the table count afterwards.
  Only a zero table count is a failure.
- **`Port 8081 was already in use`**: two servers are competing for the default
  actuator port. Run `ports` to see the assignment and the holder, and start
  the server with `run-cmd <module>` — a hand-written `bootRun` without
  `--management.server.port` will collide again.
- **Port already in use (database or Redis)**: change `LOCAL_DB_PORT` or
  `LOCAL_REDIS_PORT` in `.db.env` rather than stopping whatever holds the port.
- **`flyway migrate` fails**: report the failing migration version verbatim.
  That is a real defect in `database/migration`, not a local environment
  problem — surface it rather than working around it.
- **`newer than the latest available migration`**: the clone has migrations the
  checkout does not. The `database` submodule pointer is behind the source.
  Report it — the environment still runs, but it does not match what the
  servers deploy against, so schema work done here is unreliable. Do not bump
  the submodule pointer as a side effect; that is a deliberate commit
  (`AGENTS.md` §5).
