#!/usr/bin/env bash
#
# ./dev setup - gets someone who just cloned this repository ready to run the
# local test environment without filling in .db.env by hand.
#
# It follows the procedure in
# .agents/skills/test-env/references/initialize-db-env.md exactly. It does not
# call testenv.sh, so it does not source .dev/lib/testenv.bash: it only writes
# .db.env and reads state, and never runs a command that touches a database.

dev_describe() {
  echo '로컬 test 환경 준비 — .db.env 를 만들고 실행 준비 상태를 확인합니다'
}

dev_verbs() {
  dev_verb env   '' '.db.env 를 game/.env (없으면 admin/.env) 의 dev database 값으로 만듭니다. 이미 있으면 만들지 않고 SOURCE_LABEL 과 host, database 이름만 보여줍니다'
  dev_verb check '' 'Docker daemon, database/migration, .db.env, LOCAL_DB_PORT/LOCAL_REDIS_PORT 상태를 한 줄씩 보여줍니다. 문제가 있으면 exit code 가 0이 아닙니다'
}

dev_run() {
  local verb=$1
  shift

  case $verb in
    env)   setup_env ;;
    check) setup_check ;;
    *)     die "unhandled subcommand: $verb" ;;
  esac
}

# --- env ---------------------------------------------------------------------

setup_env() {
  local target="$DEV_ROOT/.db.env"

  if [ -f "$target" ]; then
    report_existing_env "$target"
    return 0
  fi

  local example="$DEV_ROOT/.db.env.example"
  [ -f "$example" ] || die "$example 가 없습니다. 저장소가 온전한지 확인하십시오."

  setup_env_source # fills SOURCE_FILE, SRC_URL, SRC_USER, SRC_PW

  # Credentials land in the file between the cp and the chmod 600, so narrow
  # the permissions with umask first rather than widening them afterwards.
  ( umask 077; cp "$example" "$target" )

  dev_config_set "$target" SOURCE_LABEL dev
  dev_config_set "$target" SOURCE_DATABASE_URL "$SRC_URL"
  dev_config_set "$target" SOURCE_DATABASE_USER "$SRC_USER"
  dev_config_set "$target" SOURCE_DATABASE_PASSWORD "$SRC_PW"

  local account_configured=0
  local account_file="$DEV_ROOT/account/.env"
  if [ -f "$account_file" ]; then
    local acc_url acc_user acc_pw
    if acc_url=$(dev_config_get "$account_file" ACCOUNT_DATABASE_URL) \
      && acc_user=$(dev_config_get "$account_file" ACCOUNT_DATABASE_USERNAME) \
      && acc_pw=$(dev_config_get "$account_file" ACCOUNT_DATABASE_PASSWORD); then
      dev_config_set "$target" SOURCE_ACCOUNT_DATABASE_URL "$acc_url"
      dev_config_set "$target" SOURCE_ACCOUNT_DATABASE_USER "$acc_user"
      dev_config_set "$target" SOURCE_ACCOUNT_DATABASE_PASSWORD "$acc_pw"
      account_configured=1
    fi
  fi

  chmod 600 "$target"

  if ! git -C "$DEV_ROOT" check-ignore -q "$target"; then
    rm -f "$target"
    die ".db.env 를 git 이 무시하지 않습니다. 방금 만든 파일은 지웠습니다 — credential 이 든 파일이 git 에 잡히는 쪽이 파일이 없는 쪽보다 나쁩니다. .gitignore 의 *.env 규칙을 확인하십시오."
  fi

  report_new_env "$target" "$account_configured"
}

# Takes the dev database source from game/.env, falling back to admin/.env.
# Fills SOURCE_FILE, SRC_URL, SRC_USER and SRC_PW as globals.
setup_env_source() {
  local url_key user_key pw_key

  if [ -f "$DEV_ROOT/game/.env" ]; then
    SOURCE_FILE="$DEV_ROOT/game/.env"
    url_key=DATABASE_URL user_key=DATABASE_USER pw_key=DATABASE_PW
  elif [ -f "$DEV_ROOT/admin/.env" ]; then
    SOURCE_FILE="$DEV_ROOT/admin/.env"
    url_key=DEV_DATABASE_URL user_key=DEV_DATABASE_USER pw_key=DEV_DATABASE_PW
  else
    die "game/.env 도 admin/.env 도 없습니다. submodule 이 초기화되지 않았습니다. 실행: git submodule update --init --recursive"
  fi

  local label="${SOURCE_FILE#"$DEV_ROOT"/}"
  SRC_URL=$(dev_config_get "$SOURCE_FILE" "$url_key") \
    || die "$label 에 $url_key 항목이 없습니다. dev database 값이 채워진 파일이 있어야 합니다."
  SRC_USER=$(dev_config_get "$SOURCE_FILE" "$user_key") \
    || die "$label 에 $user_key 항목이 없습니다."
  SRC_PW=$(dev_config_get "$SOURCE_FILE" "$pw_key") \
    || die "$label 에 $pw_key 항목이 없습니다."
}

report_existing_env() {
  local target=$1 label url
  label=$(dev_config_get "$target" SOURCE_LABEL) || label='(설정되지 않음)'
  url=$(dev_config_get "$target" SOURCE_DATABASE_URL) \
    || die "$target 에 SOURCE_DATABASE_URL 이 없습니다. 파일이 손상되었을 수 있습니다."
  parse_source_url "$url"

  printf '이미 .db.env 가 있어 새로 만들지 않았습니다.\n'
  printf '  source label    : %s\n' "$label"
  printf '  source database : %s/%s\n' "$PARSED_HOST" "$PARSED_DB"
  printf '\n다음을 실행하십시오: ./dev db clone\n'
}

report_new_env() {
  local target=$1 account_configured=$2
  parse_source_url "$SRC_URL"

  printf '.db.env 를 만들었습니다 (%s).\n' "${SOURCE_FILE#"$DEV_ROOT"/}"
  printf '  source label    : dev\n'
  printf '  source database : %s/%s\n' "$PARSED_HOST" "$PARSED_DB"
  if [ "$account_configured" -eq 1 ]; then
    printf '  account database: account/.env 값으로 함께 설정했습니다\n'
  else
    printf '  account database: 설정하지 않았습니다 (account/.env 가 없습니다). account server 를 쓸 계획이면 채워 넣으십시오\n'
  fi
  printf '\n다음을 실행하십시오: ./dev db clone\n'
}

# parse_source_url <url>
# Pulls only the host and the database name out of a URL prefixed with jdbc:,
# r2dbc:, or postgres[ql]://, into PARSED_HOST and PARSED_DB. It does not
# handle the user or the password; this command never reads or prints either.
#
# Same rules as parse_url in testenv.sh. That function is internal to
# testenv.sh, so the rules are restated here rather than reached into.
parse_source_url() {
  local url=$1
  url=${url#jdbc:}
  url=${url#r2dbc:}
  url=${url#postgresql://}
  url=${url#postgres://}
  case $url in
    */*) : ;;
    *) die "database URL 에서 database 이름을 찾을 수 없습니다 (/<database> 부분이 없습니다): $url" ;;
  esac

  local hostport=${url%%/*}
  local dbpart=${url#*/}
  PARSED_DB=${dbpart%%\?*}
  PARSED_HOST=${hostport%%:*}

  [ -n "$PARSED_HOST" ] || die "database URL 에서 host 를 찾을 수 없습니다: $url"
  [ -n "$PARSED_DB" ] || die "database URL 에서 database 이름을 찾을 수 없습니다: $url"
}

# --- check -------------------------------------------------------------------

setup_check() {
  local ok=1

  if docker info >/dev/null 2>&1; then
    printf 'OK    Docker daemon 이 응답합니다\n'
  else
    printf 'FAIL  Docker daemon 이 응답하지 않습니다\n'
    printf '      -> Docker Desktop 이나 Docker daemon 을 켜고 다시 실행하십시오\n'
    ok=0
  fi

  check_migrations || ok=0
  check_db_env || ok=0

  local envfile="$DEV_ROOT/.db.env"
  if [ -f "$envfile" ]; then
    local db_port redis_port
    db_port=$(dev_config_get "$envfile" LOCAL_DB_PORT) || db_port=55432
    redis_port=$(dev_config_get "$envfile" LOCAL_REDIS_PORT) || redis_port=56379

    check_port "$db_port" wordonline-testenv-db 'local database' || ok=0
    check_port "$redis_port" wordonline-testenv-redis 'local Redis' || ok=0
  else
    printf 'SKIP  local database/Redis port 는 .db.env 가 있어야 확인할 수 있습니다\n'
  fi

  [ "$ok" -eq 1 ]
}

check_migrations() {
  local dir="$DEV_ROOT/database/migration"
  if [ ! -d "$dir" ]; then
    printf 'FAIL  database/migration 이 없습니다\n'
    printf '      -> git submodule update --init --recursive\n'
    return 1
  fi

  local count
  count=$(find "$dir" -name 'V*.sql' | wc -l | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    printf 'FAIL  database/migration 은 있지만 migration 파일(V*.sql)이 없습니다\n'
    printf '      -> git submodule update --init --recursive\n'
    return 1
  fi

  printf 'OK    database/migration 에 migration %s개가 있습니다\n' "$count"
  return 0
}

check_db_env() {
  local envfile="$DEV_ROOT/.db.env"
  if [ ! -f "$envfile" ]; then
    printf 'FAIL  .db.env 가 없습니다\n'
    printf '      -> ./dev setup env\n'
    return 1
  fi

  if ! git -C "$DEV_ROOT" check-ignore -q "$envfile"; then
    printf 'FAIL  .db.env 가 있지만 git 이 무시하지 않습니다\n'
    printf '      -> .gitignore 의 *.env 규칙을 확인하십시오. credential 이 든 파일입니다\n'
    return 1
  fi

  printf 'OK    .db.env 가 있고 git 이 무시합니다\n'
  return 0
}

# check_port <port> <container> <label>
# Passes when the container is actually publishing that port, which is the
# normal state once the clone exists, and fails when anything else holds it.
# Checking only whether the container is running is not enough: after the port
# value in .db.env changes, the container can still be up while publishing the
# old port rather than the new one.
check_port() {
  local port=$1 container=$2 label=$3 holder

  if container_publishes_port "$container" "$port"; then
    printf 'OK    %s port %s 는 이미 떠 있는 container %s 가 쓰고 있습니다\n' "$label" "$port" "$container"
    return 0
  fi

  holder=$(port_holder "$port")
  if [ -n "$holder" ]; then
    printf 'FAIL  %s port %s 를 다른 process 가 쓰고 있습니다: %s\n' "$label" "$port" "$holder"
    printf '      -> .db.env 의 LOCAL_DB_PORT 또는 LOCAL_REDIS_PORT 값을 바꾸거나, 그 process 를 멈추십시오\n'
    return 1
  fi

  printf 'OK    %s port %s 는 비어 있습니다\n' "$label" "$port"
  return 0
}

container_publishes_port() {
  local container=$1 port=$2 hit
  hit=$(docker ps -q --filter "name=^/${container}\$" --filter "publish=${port}" 2>/dev/null)
  [ -n "$hit" ]
}

# Same rules as port_holder in testenv.sh, restated here rather than sourcing
# the whole of testenv.sh through .dev/lib/testenv.bash for one function.
port_holder() {
  local port=$1 out=""
  if command -v ss >/dev/null 2>&1; then
    out=$(ss -ltnp 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {print $NF; exit}')
  elif command -v lsof >/dev/null 2>&1; then
    out=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fc 2>/dev/null | sed -n 's/^c//p' | head -1)
  fi
  printf '%s' "$out"
}
