#!/usr/bin/env bash
#
# ./dev server - the game, lobby, account and admin servers running against
# the clone. A thin wrapper over .agents/skills/test-env/scripts/testenv.sh.

# shellcheck source=/dev/null
source "$DEV_ROOT/.dev/lib/testenv.bash"

dev_describe() {
  echo 'clone 에 대해 돌아가는 game/lobby/account/admin server'
}

dev_verbs() {
  dev_verb up          '[module...]' 'module 의 server 를 clone 에 대해 띄웁니다. module 을 생략하면 game 과 lobby 를 띄웁니다'
  dev_verb stop        ''            '띄운 server 를 모두 멈춥니다 (database container 는 그대로 둡니다)'
  dev_verb logs        '<module>'    '해당 module server 의 log 를 실시간으로 따라갑니다'
  dev_verb ports       ''            'module 별 application port 와 actuator port 배정, 그리고 각 port 를 잡고 있는 process 를 보여줍니다'
  dev_verb run-cmd     '<module>'    '해당 module server 를 clone 에 대해 foreground 로 띄우는 명령을 그대로 출력합니다 (직접 붙여넣어 실행)'
  dev_verb env-patch   '<module>'    '해당 module 의 .env 를 clone 을 가리키도록 다시 씁니다. 원본은 자동으로 backup 됩니다'
  dev_verb env-restore '<module>'    '해당 module 의 .env 를 env-patch 이전 상태로 되돌립니다. 평소 개발로 돌아가기 전에 반드시 실행해야 합니다'
}

dev_run() {
  local verb=$1
  shift

  case $verb in
    up)          server_up "$@" ;;
    stop)        testenv_run stop ;;
    logs)        server_logs "$@" ;;
    ports)       testenv_run ports ;;
    run-cmd)     server_run_cmd "$@" ;;
    env-patch)   server_env_patch "$@" ;;
    env-restore) server_env_restore "$@" ;;
    *)           die "unhandled subcommand: $verb" ;;
  esac
}

server_up() {
  local modules=("$@")
  [ ${#modules[@]} -gt 0 ] || modules=(game lobby)

  local module
  for module in "${modules[@]}"; do
    # testenv.sh serve takes exactly one module, so up calls it once per
    # requested module.
    testenv_run serve "$module"
  done
}

server_run_cmd() {
  [ $# -ge 1 ] || die "run-cmd needs a module"
  testenv_run run-cmd "$1"
}

server_env_patch() {
  [ $# -ge 1 ] || die "env-patch needs a module"
  testenv_run env-patch "$1"
}

server_env_restore() {
  [ $# -ge 1 ] || die "env-restore needs a module"
  testenv_run env-restore "$1"
}

server_logs() {
  [ $# -ge 1 ] || die "logs needs a module"
  local module=$1
  local logfile="$DEV_ROOT/.claude/testenv/logs/$module.log"
  [ -f "$logfile" ] || die "log file not found: ${logfile#"$DEV_ROOT"/}. $module 을 아직 띄우지 않았을 수 있습니다. 먼저 실행하십시오: $DEV_NAME server up $module"
  exec tail -f "$logfile"
}
