#!/usr/bin/env bash
#
# testenv.sh - clone the shared game database into a local Docker Postgres,
# apply database/migration with Flyway, and run the servers against the clone.
#
# The source database is read-only to this script: it is only ever the argument
# to pg_dump. Every mutating command targets a local container.
#
# Usage: testenv.sh <command> [options]
# Run `testenv.sh help` for the command list.

set -euo pipefail

# --- constants ---------------------------------------------------------------

NET=wordonline-testenv
PG_CONTAINER=wordonline-testenv-db
REDIS_CONTAINER=wordonline-testenv-redis
DUMP_VOLUME=wordonline-testenv-dumps

# game and lobby take their database settings as Spring command-line arguments,
# which outrank the module .env. account and admin are wired through .env
# instead, so they must be env-patched before they can be served.
ARGS_MODULES="game lobby"
ENV_MODULES="account admin"
SERVE_MODULES="game lobby account admin"
ALL_MODULES="game lobby account admin"

# --- output ------------------------------------------------------------------

log()  { printf '%s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- root and config ---------------------------------------------------------

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/../../../.." && pwd)
[ -f "$ROOT/.gitmodules" ] || die "not a WordOnline monorepo root: $ROOT"

STATE_DIR="$ROOT/.claude/testenv"
LOG_DIR="$STATE_DIR/logs"
RUN_DIR="$STATE_DIR/run"
# .env backups live outside the module on purpose. Inside it they are untracked
# files holding real credentials, which show up in the submodule's git status
# and can be committed by accident (AGENTS.md section 4). This directory is
# ignored wholesale by .claude/testenv/.gitignore.
BACKUP_DIR="$STATE_DIR/backups"

module_env_backup() { printf '%s/%s.env' "$BACKUP_DIR" "$1"; }
module_is_patched() { [ -f "$(module_env_backup "$1")" ]; }

load_config() {
  [ -f "$ROOT/.db.env" ] || die "$ROOT/.db.env not found. Copy .db.env.example to .db.env and fill it in."

  set -a
  # shellcheck disable=SC1090
  . "$ROOT/.db.env"
  set +a

  : "${SOURCE_LABEL:=unlabelled}"
  : "${SOURCE_DATABASE_URL:=}"
  : "${SOURCE_DATABASE_USER:=}"
  : "${SOURCE_DATABASE_PASSWORD:=}"
  : "${SOURCE_ACCOUNT_DATABASE_URL:=}"
  : "${SOURCE_ACCOUNT_DATABASE_USER:=}"
  : "${SOURCE_ACCOUNT_DATABASE_PASSWORD:=}"
  : "${SOURCE_DUMP_ARGS:=}"
  : "${LOCAL_DB_PORT:=55432}"
  : "${LOCAL_DB_NAME:=wordonline_test}"
  : "${LOCAL_ACCOUNT_DB_NAME:=account_test}"
  : "${LOCAL_DB_USER:=wordonline}"
  : "${LOCAL_DB_PASSWORD:=wordonline}"
  : "${LOCAL_REDIS_PORT:=56379}"
  : "${LOCAL_MANAGEMENT_PORT_BASE:=58080}"
  : "${LOCAL_POSTGRES_IMAGE:=}"
  : "${FLYWAY_IMAGE:=flyway/flyway:11}"
  : "${ACCOUNT_MIGRATION_DIR:=}"

  [ -n "$SOURCE_DATABASE_URL" ] || die "SOURCE_DATABASE_URL is empty in .db.env"
  [ -n "$SOURCE_DATABASE_USER" ] || die "SOURCE_DATABASE_USER is empty in .db.env"
  [ -n "$SOURCE_DATABASE_PASSWORD" ] || die "SOURCE_DATABASE_PASSWORD is empty in .db.env"

  parse_url "$SOURCE_DATABASE_URL"
  SRC_HOST=$PU_HOST SRC_PORT=$PU_PORT SRC_DB=$PU_DB

  if [ -n "$SOURCE_ACCOUNT_DATABASE_URL" ]; then
    parse_url "$SOURCE_ACCOUNT_DATABASE_URL"
    SRC_ACCOUNT_HOST=$PU_HOST SRC_ACCOUNT_PORT=$PU_PORT SRC_ACCOUNT_DB=$PU_DB
  else
    SRC_ACCOUNT_HOST= SRC_ACCOUNT_PORT= SRC_ACCOUNT_DB=
  fi
}

# Accepts jdbc:postgresql://, r2dbc:postgresql://, postgres[ql]://, or host:port/db.
parse_url() {
  local url=$1
  url=${url#jdbc:}
  url=${url#r2dbc:}
  url=${url#postgresql://}
  url=${url#postgres://}
  case $url in
    */*) : ;;
    *) die "cannot parse database URL, no /<database> part: $1" ;;
  esac

  local hostport=${url%%/*}
  local dbpart=${url#*/}
  PU_DB=${dbpart%%\?*}
  PU_HOST=${hostport%%:*}
  if [ "$hostport" = "${hostport#*:}" ]; then PU_PORT=5432; else PU_PORT=${hostport##*:}; fi

  [ -n "$PU_HOST" ] || die "cannot parse host from database URL: $1"
  [ -n "$PU_DB" ] || die "cannot parse database name from database URL: $1"
}

# --- preflight ---------------------------------------------------------------

preflight() {
  command -v docker >/dev/null 2>&1 || die "docker not found. This skill runs every database tool in a container."
  docker info >/dev/null 2>&1 || die "docker daemon not reachable. Start Docker and retry."
  [ -d "$ROOT/database/migration" ] || die "database/migration missing. Initialize submodules first: git submodule update --init --recursive"

  local count
  count=$(find "$ROOT/database/migration" -name 'V*.sql' | wc -l | tr -d ' ')
  [ "$count" -gt 0 ] || die "no migrations found in database/migration"
  log "preflight ok: docker present, $count migrations in database/migration"
}

# --- docker helpers ----------------------------------------------------------

ensure_network() {
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = true ]
}

# Runs a postgres client container on the test network with PGPASSWORD set.
pg_client() {
  local password=$1; shift
  docker run --rm --network "$NET" \
    -e PGPASSWORD="$password" \
    -v "$DUMP_VOLUME:/dump" \
    "$PG_IMAGE" "$@"
}

# Resolves PG_IMAGE from LOCAL_POSTGRES_IMAGE, or from the source server version.
resolve_pg_image() {
  if [ -n "$LOCAL_POSTGRES_IMAGE" ]; then
    PG_IMAGE=$LOCAL_POSTGRES_IMAGE
    log "postgres image: $PG_IMAGE (pinned in .db.env)"
    return
  fi

  # Probe with a recent client; a newer psql talks to older servers fine.
  PG_IMAGE=postgres:17-alpine
  ensure_network
  local version_num
  if ! version_num=$(pg_client "$SOURCE_DATABASE_PASSWORD" psql \
        -h "$SRC_HOST" -p "$SRC_PORT" -U "$SOURCE_DATABASE_USER" -d "$SRC_DB" \
        -tAc 'SHOW server_version_num' 2>/dev/null); then
    die "cannot connect to source database $SRC_HOST:$SRC_PORT/$SRC_DB as $SOURCE_DATABASE_USER. Check .db.env and network access."
  fi

  version_num=$(printf '%s' "$version_num" | tr -dc '0-9')
  [ -n "$version_num" ] || die "source server returned no version"
  local major=$((version_num / 10000))
  PG_IMAGE="postgres:${major}-alpine"
  log "source server is Postgres $major; using image $PG_IMAGE"
}

# --- confirmation ------------------------------------------------------------

ASSUME_YES=0

show_target() {
  cat >&2 <<EOF

  source label   : $SOURCE_LABEL
  source database: $SRC_HOST:$SRC_PORT/$SRC_DB (user $SOURCE_DATABASE_USER, read-only)
EOF
  if [ -n "$SRC_ACCOUNT_DB" ]; then
    log "  account source : $SRC_ACCOUNT_HOST:$SRC_ACCOUNT_PORT/$SRC_ACCOUNT_DB (read-only)"
  fi
  cat >&2 <<EOF
  local clone    : localhost:$LOCAL_DB_PORT/$LOCAL_DB_NAME (container $PG_CONTAINER)
EOF
}

confirm() {
  show_target
  if [ "$ASSUME_YES" = 1 ]; then
    log "  confirmed via --yes"
    return
  fi
  log ""
  printf 'Clone this source database? Type yes to continue: ' >&2
  local reply
  read -r reply || reply=
  [ "$reply" = yes ] || die "aborted"
}

# --- database lifecycle ------------------------------------------------------

start_containers() {
  step "starting local containers"
  ensure_network
  docker volume inspect "$DUMP_VOLUME" >/dev/null 2>&1 || docker volume create "$DUMP_VOLUME" >/dev/null

  if container_running "$PG_CONTAINER"; then
    log "$PG_CONTAINER already running"
  else
    docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$PG_CONTAINER" --network "$NET" \
      -e POSTGRES_USER="$LOCAL_DB_USER" \
      -e POSTGRES_PASSWORD="$LOCAL_DB_PASSWORD" \
      -e POSTGRES_DB="$LOCAL_DB_NAME" \
      -p "$LOCAL_DB_PORT:5432" \
      "$PG_IMAGE" >/dev/null
    log "started $PG_CONTAINER on localhost:$LOCAL_DB_PORT"
  fi

  if container_running "$REDIS_CONTAINER"; then
    log "$REDIS_CONTAINER already running"
  else
    docker rm -f "$REDIS_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$REDIS_CONTAINER" --network "$NET" \
      -p "$LOCAL_REDIS_PORT:6379" redis:7-alpine >/dev/null
    log "started $REDIS_CONTAINER on localhost:$LOCAL_REDIS_PORT"
  fi

  wait_for_db
}

wait_for_db() {
  local i
  for i in $(seq 1 60); do
    if docker exec "$PG_CONTAINER" pg_isready -U "$LOCAL_DB_USER" -d "$LOCAL_DB_NAME" >/dev/null 2>&1; then
      log "local postgres ready"
      return
    fi
    sleep 1
  done
  die "local postgres did not become ready within 60s. Check: docker logs $PG_CONTAINER"
}

# local_psql <database> <args...>
local_psql() {
  local db=$1; shift
  docker exec -e PGPASSWORD="$LOCAL_DB_PASSWORD" "$PG_CONTAINER" \
    psql -U "$LOCAL_DB_USER" -d "$db" "$@"
}

recreate_local_db() {
  local db=$1
  log "recreating local database $db"
  local_psql postgres -v ON_ERROR_STOP=1 -qtAc \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid()" >/dev/null
  local_psql postgres -v ON_ERROR_STOP=1 -qc "DROP DATABASE IF EXISTS \"$db\"" >/dev/null
  local_psql postgres -v ON_ERROR_STOP=1 -qc "CREATE DATABASE \"$db\" OWNER \"$LOCAL_DB_USER\"" >/dev/null
}

# dump_and_restore <label> <host> <port> <db> <user> <password> <target-db> <dumpfile>
dump_and_restore() {
  local label=$1 host=$2 port=$3 db=$4 user=$5 password=$6 target=$7 file=$8

  step "cloning $label: $host:$port/$db -> $target"

  # shellcheck disable=SC2086
  pg_client "$password" pg_dump \
    -h "$host" -p "$port" -U "$user" -d "$db" \
    --format=custom --no-owner --no-acl --file "/dump/$file" \
    $SOURCE_DUMP_ARGS \
    || die "pg_dump failed for $host:$port/$db"

  local size
  size=$(docker run --rm -v "$DUMP_VOLUME:/dump" "$PG_IMAGE" \
    sh -c "du -h /dump/$file | cut -f1")
  log "dump complete ($size)"

  recreate_local_db "$target"

  # pg_restore reports non-fatal noise for roles and extensions that do not
  # exist locally. --no-owner/--no-acl removes most of it; a non-zero exit with
  # only warnings is expected, so the schema is verified afterwards instead.
  if ! pg_client "$LOCAL_DB_PASSWORD" pg_restore \
      -h "$PG_CONTAINER" -p 5432 -U "$LOCAL_DB_USER" -d "$target" \
      --no-owner --no-acl --exit-on-error "/dump/$file"; then
    log "pg_restore reported errors; retrying without --exit-on-error to restore what it can"
    pg_client "$LOCAL_DB_PASSWORD" pg_restore \
      -h "$PG_CONTAINER" -p 5432 -U "$LOCAL_DB_USER" -d "$target" \
      --no-owner --no-acl "/dump/$file" || true
  fi

  local tables
  tables=$(local_psql "$target" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" | tr -d ' \r')
  [ "${tables:-0}" -gt 0 ] || die "restore produced no tables in $target"
  log "restored $tables tables into $target"
}

# --- flyway ------------------------------------------------------------------

# flyway_run <database> <host-migration-dir> <flyway-args...>
flyway_run() {
  local db=$1 dir=$2; shift 2
  docker run --rm --network "$NET" \
    -v "$dir:/flyway/sql:ro" \
    "$FLYWAY_IMAGE" \
    -url="jdbc:postgresql://$PG_CONTAINER:5432/$db" \
    -user="$LOCAL_DB_USER" \
    -password="$LOCAL_DB_PASSWORD" \
    -locations=filesystem:/flyway/sql \
    -connectRetries=10 \
    "$@"
}

# migrate_database <database> <host-migration-dir> <label>
migrate_database() {
  local db=$1 dir=$2 label=$3

  step "applying $label with Flyway"

  local has_history
  has_history=$(local_psql "$db" -tAc \
    "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL" | tr -d ' \r')
  if [ "$has_history" != t ]; then
    die "the $db clone has no flyway_schema_history table.
Its source database is not Flyway-managed, so a migration chain cannot be
resumed against it. Do not baseline it to force the migrations through: that
records migrations as applied that never ran. For the game database, note that
V000 opens with 'create database' and carries a pg_catalog dump, so the chain
cannot be replayed from empty either (WordOnlineDatabase issue #23)."
  fi

  local out
  if ! out=$(flyway_run "$db" "$dir" migrate 2>&1); then
    printf '%s\n' "$out" >&2
    die "flyway migrate failed against $db"
  fi
  printf '%s\n' "$out" >&2

  # The source can be ahead of the checkout: the submodule pointer is committed
  # in the monorepo and lags whenever migrations land without the pointer being
  # bumped. Flyway only warns, but a clone whose schema is newer than the
  # checked-out migrations will not reproduce what the servers run against.
  if printf '%s' "$out" | grep -q 'newer than the latest available migration'; then
    log ""
    log "warning: the $db clone contains migrations that $label does not have."
    log "That submodule is behind the source. Check out a newer commit before"
    log "trusting this environment for schema work."
  fi

  flyway_run "$db" "$dir" info | tail -n 25 >&2 || true
}

# The clone carries the source environment's server registry, not just its content:
# `servers` lists whichever game servers were alive in dev, and the lobby matches a
# player onto any row it finds ACTIVE. A local match then runs on dev's game server,
# reading dev's database - so a deck edited here never reaches the match and a value
# changed here never takes effect. That cost an hour on 2026-09-15 before the lobby
# log gave it away (issue #36).
#
# Marking those rows INACTIVE does not hold. The lobby's GameServerManagementService
# revives a server the moment one health check succeeds, so the rows have to go.
# A game server started by this script registers itself on startup, which puts the
# only row that can work here back in the table.
retire_foreign_game_servers() {
  local removed
  removed=$(local_psql "$LOCAL_DB_NAME" -v ON_ERROR_STOP=1 -qtAc \
    "DELETE FROM servers
      WHERE type = 'GAME'
        AND domain NOT IN ('localhost', '127.0.0.1', '::1')
      RETURNING id" 2>/dev/null | grep -c '[0-9]') || removed=0

  if [ "${removed:-0}" -gt 0 ]; then
    log "removed $removed game server row(s) pointing at another environment"
  fi
}

migrate_all() {
  migrate_database "$LOCAL_DB_NAME" "$ROOT/database/migration" "database/migration"

  # The account server owns a separate database, and as of today the account
  # repository has no migration chain at all: no Flyway dependency, no history
  # table, and spring.sql.init.mode is never. database/README.md scopes the
  # game chain to the game database, so pointing it here would corrupt the
  # clone. Set ACCOUNT_MIGRATION_DIR once that repository grows a real chain;
  # until then the cloned schema is what the account server runs against.
  if [ -z "$ACCOUNT_MIGRATION_DIR" ]; then
    return
  fi
  if [ -z "$SRC_ACCOUNT_DB" ]; then
    die "ACCOUNT_MIGRATION_DIR is set but SOURCE_ACCOUNT_DATABASE_URL is not. There is no account clone to migrate."
  fi

  local dir=$ACCOUNT_MIGRATION_DIR
  case $dir in /*) : ;; *) dir="$ROOT/$dir" ;; esac
  [ -d "$dir" ] || die "ACCOUNT_MIGRATION_DIR does not exist: $dir"

  migrate_database "$LOCAL_ACCOUNT_DB_NAME" "$dir" "${dir#"$ROOT/"}"
}

# --- module wiring -----------------------------------------------------------

local_jdbc_url() { printf 'jdbc:postgresql://localhost:%s/%s' "$LOCAL_DB_PORT" "$1"; }
local_r2dbc_url() { printf 'r2dbc:postgresql://localhost:%s/%s' "$LOCAL_DB_PORT" "$1"; }

# Every module's application.yml defaults management.server.port to 8081, so
# the second server to start fails with "Port 8081 was already in use". The
# application ports differ per module and come from .env; only the actuator
# port needs assigning. Offsets are fixed so a port always means the same
# module across restarts.
module_management_port() {
  case $1 in
    game)    printf '%s' "$((LOCAL_MANAGEMENT_PORT_BASE + 1))" ;;
    lobby)   printf '%s' "$((LOCAL_MANAGEMENT_PORT_BASE + 2))" ;;
    account) printf '%s' "$((LOCAL_MANAGEMENT_PORT_BASE + 3))" ;;
    admin)   printf '%s' "$((LOCAL_MANAGEMENT_PORT_BASE + 4))" ;;
    *) die "unknown module: $1 (expected one of: $ALL_MODULES)" ;;
  esac
}

# Prints `KEY=VALUE` lines for a module's database wiring against the clone.
module_env_pairs() {
  printf 'MANAGEMENT_PORT=%s\n' "$(module_management_port "$1")"
  case $1 in
    game)
      printf 'DATABASE_URL=%s\n' "$(local_jdbc_url "$LOCAL_DB_NAME")"
      printf 'DATABASE_USER=%s\n' "$LOCAL_DB_USER"
      printf 'DATABASE_PW=%s\n' "$LOCAL_DB_PASSWORD"
      ;;
    lobby)
      printf 'DATABASE_URL=%s\n' "$(local_r2dbc_url "$LOCAL_DB_NAME")"
      printf 'DATABASE_USERNAME=%s\n' "$LOCAL_DB_USER"
      printf 'DATABASE_PASSWORD=%s\n' "$LOCAL_DB_PASSWORD"
      printf 'REDIS_HOST=%s\n' localhost
      printf 'REDIS_PORT=%s\n' "$LOCAL_REDIS_PORT"
      ;;
    admin)
      printf 'DATABASE_URL=%s\n' "$(local_jdbc_url "$LOCAL_DB_NAME")"
      printf 'DATABASE_USER=%s\n' "$LOCAL_DB_USER"
      printf 'DATABASE_PW=%s\n' "$LOCAL_DB_PASSWORD"
      printf 'DEV_DATABASE_URL=%s\n' "$(local_jdbc_url "$LOCAL_DB_NAME")"
      printf 'DEV_DATABASE_USER=%s\n' "$LOCAL_DB_USER"
      printf 'DEV_DATABASE_PW=%s\n' "$LOCAL_DB_PASSWORD"
      ;;
    account)
      printf 'GAME_DATABASE_URL=%s\n' "$(local_r2dbc_url "$LOCAL_DB_NAME")"
      printf 'GAME_DATABASE_USERNAME=%s\n' "$LOCAL_DB_USER"
      printf 'GAME_DATABASE_PASSWORD=%s\n' "$LOCAL_DB_PASSWORD"
      printf 'ACCOUNT_DATABASE_URL=%s\n' "$(local_r2dbc_url "$LOCAL_ACCOUNT_DB_NAME")"
      printf 'ACCOUNT_DATABASE_USERNAME=%s\n' "$LOCAL_DB_USER"
      printf 'ACCOUNT_DATABASE_PASSWORD=%s\n' "$LOCAL_DB_PASSWORD"
      ;;
    *) die "unknown module: $1 (expected one of: $ALL_MODULES)" ;;
  esac
}

# Prints Spring command-line arguments, which outrank the module's .env file.
module_boot_args() {
  case $1 in
    game)
      printf -- '--management.server.port=%s ' "$(module_management_port game)"
      printf -- '--spring.datasource.url=%s ' "$(local_jdbc_url "$LOCAL_DB_NAME")"
      printf -- '--spring.datasource.username=%s ' "$LOCAL_DB_USER"
      printf -- '--spring.datasource.password=%s' "$LOCAL_DB_PASSWORD"
      ;;
    lobby)
      printf -- '--management.server.port=%s ' "$(module_management_port lobby)"
      printf -- '--spring.r2dbc.url=%s ' "$(local_r2dbc_url "$LOCAL_DB_NAME")"
      printf -- '--spring.r2dbc.username=%s ' "$LOCAL_DB_USER"
      printf -- '--spring.r2dbc.password=%s ' "$LOCAL_DB_PASSWORD"
      printf -- '--spring.data.redis.host=localhost '
      printf -- '--spring.data.redis.port=%s' "$LOCAL_REDIS_PORT"
      ;;
    # The database settings come from .env via env-patch, but the actuator port
    # is passed here too so a server started by hand cannot collide.
    account|admin)
      printf -- '--management.server.port=%s' "$(module_management_port "$1")"
      ;;
    *) die "unknown module: $1 (expected one of: $ALL_MODULES)" ;;
  esac
}

env_patch() {
  local module=$1
  local file="$ROOT/$module/.env"
  [ -f "$file" ] || die "$file not found. Create the module .env from its example first."

  mkdir -p "$BACKUP_DIR"
  local backup
  backup=$(module_env_backup "$module")
  if [ -f "$backup" ]; then
    log "$module: backup already exists at ${backup#"$ROOT/"}, leaving it untouched"
  else
    cp "$file" "$backup"
    chmod 600 "$backup"
    log "$module: backed up .env to ${backup#"$ROOT/"}"
  fi

  local pairs key value tmp
  pairs=$(module_env_pairs "$module")
  tmp=$(mktemp)
  cp "$file" "$tmp"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%=*}
    value=${line#*=}
    if grep -qE "^[[:space:]]*$key=" "$tmp"; then
      # Rewrite in place; the value is a local URL or credential with no
      # regex-special characters, so a plain delimiter swap is safe.
      awk -v k="$key" -v v="$value" \
        'BEGIN{FS=OFS="="} $0 ~ "^[ \t]*" k "=" {print k "=" v; next} {print}' "$tmp" >"$tmp.new"
      mv "$tmp.new" "$tmp"
    else
      printf '%s=%s\n' "$key" "$value" >>"$tmp"
    fi
    log "  $key -> $value"
  done <<<"$pairs"

  mv "$tmp" "$file"
  log "$module: .env now points at the local clone"
}

env_restore() {
  local module=$1
  local file="$ROOT/$module/.env"
  local backup
  backup=$(module_env_backup "$module")
  [ -f "$backup" ] || die "no backup at ${backup#"$ROOT/"}; nothing to restore for $module"
  mv "$backup" "$file"
  log "$module: .env restored from backup"
}

# --- servers -----------------------------------------------------------------

serve() {
  local module=$1
  case " $SERVE_MODULES " in
    *" $module "*) : ;;
    *) die "serve supports only: $SERVE_MODULES" ;;
  esac
  [ -x "$ROOT/$module/gradlew" ] || die "$module/gradlew not found. Initialize submodules first."

  # account and admin read their database settings from .env only, so serving
  # them before env-patch would silently point them at whatever the checked-out
  # .env holds — which is the shared database, not the clone.
  case " $ENV_MODULES " in
    *" $module "*)
      module_is_patched "$module" || \
        die "$module is not wired to the clone. Run: $0 env-patch $module" ;;
  esac
  # Only the database settings are overridden on the command line. Ports, JWT
  # keys and service URLs still come from the module's own .env, which is
  # gitignored and so absent from a fresh submodule clone.
  [ -f "$ROOT/$module/.env" ] || die "$module/.env not found. The server needs it for PORT, JWT keys and service URLs; this skill only overrides the database settings."

  mkdir -p "$LOG_DIR" "$RUN_DIR"
  local pidfile="$RUN_DIR/$module.pid" logfile="$LOG_DIR/$module.log"

  if module_running "$([ -f "$pidfile" ] && cat "$pidfile" || echo "")" "$module"; then
    log "$module already running, log: ${logfile#"$ROOT/"}"
    return
  fi

  # Another checkout of the same module, or another session, can already hold
  # this module's application port. Detection above is scoped to this ROOT on
  # purpose so the skill never kills someone else's server — which means the
  # collision only surfaces at the end of a multi-minute Gradle build, as
  # "Port <n> was already in use". Catch it now instead.
  local app_port holder
  app_port=$(module_app_port "$module")
  if [ "$app_port" != unset ]; then
    holder=$(port_holder "$app_port")
    [ -z "$holder" ] || die "$module cannot start: port $app_port is already in use by $holder.
This skill did not start it — it is most likely the same module running from
another checkout, or another session. Stop that process, or change PORT in
$module/.env."
  fi

  local args
  args=$(module_boot_args "$module")
  log "starting $module against the local clone"

  # The whole subshell is backgrounded with its own fds, so the server never
  # inherits the caller's stdout. Without this, `up` appears to hang forever:
  # the script has finished, but a pipe reading its output stays open as long
  # as the server holds the write end. `exec` replaces the subshell with
  # gradlew so the recorded pid is the launcher itself, not a wrapper shell.
  if [ -n "$args" ]; then
    ( cd "$ROOT/$module" && exec ./gradlew bootRun --args="$args" ) \
      </dev/null >"$logfile" 2>&1 &
  else
    ( cd "$ROOT/$module" && exec ./gradlew bootRun ) \
      </dev/null >"$logfile" 2>&1 &
  fi
  local pid=$!
  echo "$pid" >"$pidfile"
  disown "$pid" 2>/dev/null || true
  log "$module pid $pid, log: ${logfile#"$ROOT/"}"
}

# gradlew is only a launcher: it starts a Gradle daemon which forks the server
# JVM, so the recorded pid is never the whole story. Everything is matched by
# absolute path under this module directory, which cannot collide with an
# unrelated process or with a server started from another checkout.
module_process_pattern() { printf '%s/%s/(gradle/wrapper|build/classes|bin/main)' "$ROOT" "$1"; }

module_running() {
  local pid=$1
  { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } && return 0
  pgrep -f "$(module_process_pattern "$2")" >/dev/null 2>&1
}

stop_servers() {
  local module pidfile pid pattern i
  for module in $SERVE_MODULES; do
    pidfile="$RUN_DIR/$module.pid"
    pid=$([ -f "$pidfile" ] && cat "$pidfile" || echo "")
    pattern=$(module_process_pattern "$module")

    if ! module_running "$pid" "$module"; then
      rm -f "$pidfile"
      continue
    fi

    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
    pkill -TERM -f "$pattern" 2>/dev/null || true

    for i in $(seq 1 20); do
      module_running "$pid" "$module" || break
      sleep 1
    done

    if module_running "$pid" "$module"; then
      [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
      pkill -KILL -f "$pattern" 2>/dev/null || true
      log "force-killed $module"
    else
      log "stopped $module"
    fi
    rm -f "$pidfile"
  done
}

# --- commands ----------------------------------------------------------------

cmd_up() {
  local with=""
  while [ $# -gt 0 ]; do
    case $1 in
      --yes) ASSUME_YES=1 ;;
      --with) shift; with=${1:-} ;;
      --with=*) with=${1#--with=} ;;
      *) die "unknown option for up: $1" ;;
    esac
    shift
  done

  preflight
  load_config

  # Validate the requested servers before dumping anything. Discovering a typo
  # or an unpatched .env after a multi-minute clone wastes the whole run.
  local module
  for module in ${with//,/ }; do
    case " $SERVE_MODULES " in
      *" $module "*) : ;;
      *) die "unknown module in --with: $module (expected one of: $SERVE_MODULES)" ;;
    esac
    [ -x "$ROOT/$module/gradlew" ] || die "$module/gradlew not found. Initialize submodules first."
    [ -f "$ROOT/$module/.env" ] || die "$module/.env not found. The server needs it for PORT, JWT keys and service URLs."
    case " $ENV_MODULES " in
      *" $module "*)
        module_is_patched "$module" || \
          die "$module is not wired to the clone. Run '$0 env-patch $module' before serving it." ;;
    esac
  done

  resolve_pg_image
  confirm
  start_containers

  dump_and_restore "game database" \
    "$SRC_HOST" "$SRC_PORT" "$SRC_DB" "$SOURCE_DATABASE_USER" "$SOURCE_DATABASE_PASSWORD" \
    "$LOCAL_DB_NAME" game.dump

  if [ -n "$SRC_ACCOUNT_DB" ]; then
    dump_and_restore "account database" \
      "$SRC_ACCOUNT_HOST" "$SRC_ACCOUNT_PORT" "$SRC_ACCOUNT_DB" \
      "$SOURCE_ACCOUNT_DATABASE_USER" "$SOURCE_ACCOUNT_DATABASE_PASSWORD" \
      "$LOCAL_ACCOUNT_DB_NAME" account.dump
  fi

  migrate_all
  retire_foreign_game_servers

  if [ -n "$with" ]; then
    step "starting servers: $with"
    local module
    for module in ${with//,/ }; do serve "$module"; done
  fi

  cmd_status
}

cmd_status() {
  load_config
  step "test environment"
  local c
  for c in "$PG_CONTAINER" "$REDIS_CONTAINER"; do
    if container_running "$c"; then log "  $c: running"; else log "  $c: stopped"; fi
  done
  log "  clone   : jdbc:postgresql://localhost:$LOCAL_DB_PORT/$LOCAL_DB_NAME"
  log "  r2dbc   : r2dbc:postgresql://localhost:$LOCAL_DB_PORT/$LOCAL_DB_NAME"
  log "  user/pw : $LOCAL_DB_USER / $LOCAL_DB_PASSWORD"
  log "  redis   : localhost:$LOCAL_REDIS_PORT"

  local module pidfile
  for module in $SERVE_MODULES; do
    pidfile="$RUN_DIR/$module.pid"
    if module_running "$([ -f "$pidfile" ] && cat "$pidfile" || echo "")" "$module"; then
      log "  $module: running, log ${LOG_DIR#"$ROOT/"}/$module.log"
    fi
  done
  log ""
  log "  psql: $0 psql"
}

port_holder() {
  local port=$1 out=""
  if command -v ss >/dev/null 2>&1; then
    out=$(ss -ltnp 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {print $NF; exit}')
  elif command -v lsof >/dev/null 2>&1; then
    out=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fc 2>/dev/null | sed -n 's/^c//p' | head -1)
  fi
  printf '%s' "$out"
}

module_app_port() {
  local file="$ROOT/$1/.env" port=""
  [ -f "$file" ] && port=$(grep -m1 '^PORT=' "$file" | cut -d= -f2- | tr -d '\r')
  printf '%s' "${port:-unset}"
}

cmd_ports() {
  load_config
  step "port map"
  log "Every module defaults management.server.port to 8081, so the second"
  log "server to start would fail with 'Port 8081 was already in use'. This"
  log "skill assigns one actuator port per module instead."
  log ""
  printf '  %-8s %-10s %-12s %s\n' module app actuator "actuator holder" >&2

  local module app mgmt holder
  for module in $ALL_MODULES; do
    app=$(module_app_port "$module")
    mgmt=$(module_management_port "$module")
    holder=$(port_holder "$mgmt")
    printf '  %-8s %-10s %-12s %s\n' "$module" "$app" "$mgmt" "${holder:--}" >&2
  done

  holder=$(port_holder 8081)
  if [ -n "$holder" ]; then
    log ""
    log "note: something is still listening on the old default 8081: $holder"
    log "That is not this skill. Stop it, or ignore it now that each module has"
    log "its own actuator port."
  fi
}

cmd_run_cmd() {
  load_config
  local module=$1
  case " $ALL_MODULES " in
    *" $module "*) : ;;
    *) die "unknown module: $module (expected one of: $ALL_MODULES)" ;;
  esac

  case " $ENV_MODULES " in
    *" $module "*)
      module_is_patched "$module" || \
        log "warning: $module is not env-patched, so this command will use the database its .env already points at. Run '$0 env-patch $module' first." ;;
  esac

  # Printed on stdout, unlike every other message, so it can be piped or copied
  # without the surrounding log lines.
  printf 'cd %s && ./gradlew bootRun --args="%s"\n' "$ROOT/$module" "$(module_boot_args "$module")"
}

cmd_psql() {
  load_config
  container_running "$PG_CONTAINER" || die "$PG_CONTAINER is not running. Run: $0 up"
  local db=${1:-$LOCAL_DB_NAME}
  exec docker exec -it -e PGPASSWORD="$LOCAL_DB_PASSWORD" "$PG_CONTAINER" \
    psql -U "$LOCAL_DB_USER" -d "$db"
}

cmd_down() {
  local purge=0
  [ "${1:-}" = --purge ] && purge=1
  load_config
  stop_servers
  docker rm -f "$PG_CONTAINER" "$REDIS_CONTAINER" >/dev/null 2>&1 || true
  log "containers removed"
  if [ "$purge" = 1 ]; then
    docker volume rm "$DUMP_VOLUME" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    log "dump volume and network removed"
  fi
  local module
  for module in $ALL_MODULES; do
    if module_is_patched "$module"; then
      log "note: $module/.env is still patched; run '$0 env-restore $module'"
    fi
  done
}

usage() {
  cat >&2 <<EOF
testenv.sh - local test environment cloned from the shared game database

  up [--yes] [--with game,lobby]
      Clone the source database into a local Docker Postgres, apply
      database/migration with Flyway, and optionally start servers.
      Without --yes it prints the source target and asks for confirmation.

  status              Show containers, connection strings, running servers.
  ports               Show the per-module app and actuator port assignment,
                      and what is holding each one. Use this on a
                      "Port 8081 was already in use" failure.
  run-cmd <module>    Print a ready-to-paste command that runs one server in
                      the foreground against the clone, with a conflict-free
                      actuator port.
  psql [database]     Open psql against the local clone.
  migrate             Re-apply database/migration against the existing clone.
  serve <module>      Start one server against the clone (background).
  stop                Stop the servers, leave the database containers running.
  env-patch <module>  Point a module's .env at the clone, backing up the original.
  env-restore <module>  Restore a module's .env from the backup.
  down [--purge]      Stop servers and containers. --purge also drops the dump volume.

Configuration lives in .db.env at the monorepo root; see .db.env.example.
EOF
}

main() {
  local cmd=${1:-help}
  shift || true
  case $cmd in
    up) cmd_up "$@" ;;
    status) cmd_status ;;
    ports) cmd_ports ;;
    run-cmd) [ $# -ge 1 ] || die "run-cmd needs a module: $ALL_MODULES"; cmd_run_cmd "$1" ;;
    psql) cmd_psql "$@" ;;
    migrate)
      preflight; load_config
      container_running "$PG_CONTAINER" || die "$PG_CONTAINER is not running. Run: $0 up"
      migrate_all; retire_foreign_game_servers ;;
    serve) [ $# -ge 1 ] || die "serve needs a module: $SERVE_MODULES"; load_config; serve "$1" ;;
    env-patch) [ $# -ge 1 ] || die "env-patch needs a module: $ALL_MODULES"; load_config; env_patch "$1" ;;
    env-restore) [ $# -ge 1 ] || die "env-restore needs a module: $ALL_MODULES"; env_restore "$1" ;;
    stop) stop_servers; log "containers left running; run '$0 status' for connection details" ;;
    down) cmd_down "$@" ;;
    help|-h|--help) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
