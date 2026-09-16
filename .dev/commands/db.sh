#!/usr/bin/env bash
#
# ./dev db - the local test database clone. A thin wrapper over
# .agents/skills/test-env/scripts/testenv.sh.

# shellcheck source=/dev/null
source "$DEV_ROOT/.dev/lib/testenv.bash"

dev_describe() {
  echo '로컬 test database clone — game database 를 Docker Postgres container 로 가져옵니다'
}

dev_verbs() {
  # clone calls testenv.sh up unchanged; only the name differs, because
  # naming the subcommand after what it does reads better than up. Every
  # other subcommand keeps the name testenv.sh already uses, so someone can
  # move between the two without relearning.
  dev_verb clone    '[--yes]'   'game database 를 로컬 clone 으로 가져옵니다. --yes 없이 실행하면 source 를 보여주고 확인을 묻습니다'
  dev_verb psql     '[database]' '로컬 clone 에 psql session 을 엽니다. database 를 생략하면 game database 를 엽니다'
  dev_verb migrate  ''          '기존 clone 에 database/migration 의 Flyway migration 을 다시 적용합니다'
  dev_verb status   ''          'container 상태와 clone 의 연결 정보를 보여줍니다'
  dev_verb down     '[--purge]' 'clone container 를 내립니다. --purge 를 주면 dump volume 과 network 도 지웁니다'
}

dev_run() {
  local verb=$1
  shift

  case $verb in
    clone)   testenv_run up "$@" ;;
    psql)    testenv_run psql "$@" ;;
    migrate) testenv_run migrate ;;
    status)  testenv_run status ;;
    down)    testenv_run down "$@" ;;
    *)       die "unhandled subcommand: $verb" ;;
  esac
}
