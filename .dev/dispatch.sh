#!/usr/bin/env bash
#
# dispatch.sh - runs a project's development commands under a docker-like
# `<command> <subcommand>` grammar.
#
# This file is the shared runtime the dev-tool skill ships. The only files
# that differ per project are .dev/commands/<command>.sh and .dev/config.sh,
# so do not edit this one inside a project: replace it wholesale from the
# skill instead.
#
# One command file is one command. It defines three functions:
#
#   dev_describe          echo the command's one-line description
#   dev_verbs             call dev_verb <name> <arguments> <description> per subcommand
#   dev_run <sub> [args]  do the work
#
# The dispatcher sources a command file whenever it builds a listing or the
# documentation table, so a command file's top level must define functions
# and variables only, and must have no side effects.

set -euo pipefail

[ -n "${DEV_ROOT:-}" ] || {
  printf 'error: DEV_ROOT is empty. Run the project'"'"'s ./dev launcher instead of this file.\n' >&2
  exit 1
}

COMMAND_DIR="$DEV_ROOT/.dev/commands"
DOC_FILE="$DEV_ROOT/DEV_TOOL.md"
DOC_START='<!-- dev:commands:start -->'
DOC_END='<!-- dev:commands:end -->'

# .dev/config.sh is optional. A project adds one only to change the display
# name and the one-line tagline.
DEV_NAME='./dev'
DEV_TAGLINE='프로젝트 개발 명령어'
# shellcheck source=/dev/null
[ -f "$DEV_ROOT/.dev/config.sh" ] && source "$DEV_ROOT/.dev/config.sh"

BUILTINS='help docs complete'

# complete is plumbing for the shell, not something a person types, so it is
# offered as a completion for neither itself nor anything else.
COMPLETABLE_BUILTINS='help docs'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- helpers a command file can use ------------------------------------------
#
# Asking for input and persisting a setting go wrong in a slightly different
# way every time they are written from scratch. Two failures repeat: hanging
# on a prompt in a non-interactive run, and printing a secret. The dispatcher
# provides these six so each command file does not solve them again.

# Whether there is a person to ask. It looks at /dev/tty rather than stdin so
# a prompt still works when stdout is piped somewhere else.
dev_interactive() {
  # [ -r /dev/tty ] is not enough. A process with no controlling terminal
  # still has /dev/tty present as a file node, so that test passes and the
  # failure only arrives at open time as "No such device or address".
  # Opening it is the only reliable check.
  { : < /dev/tty; } 2>/dev/null || return 1
  { : > /dev/tty; } 2>/dev/null || return 1
  return 0
}

# dev_ask <variable-name> <question> [default]
# Stores the answer in the named variable: dev_ask name 'Name' 'game'; echo "$name"
#
# It stores instead of printing for a correctness reason. Written as
# name=$(dev_ask ...), the call runs in a command substitution subshell, so a
# die inside it exits only that subshell: the caller carries on with an empty
# value and exit status 0.
dev_ask() {
  [ $# -ge 2 ] || die "dev_ask takes a variable name and a question"
  local name=$1 question=$2 fallback=${3:-} answer

  dev_assert_variable_name "$name"

  if ! dev_interactive; then
    [ -n "$fallback" ] || die "'$question' 을 물어봐야 하는데 terminal 이 없습니다. 값을 인자로 주고 다시 실행하십시오."
    printf -v "$name" '%s' "$fallback"
    return 0
  fi

  if [ -n "$fallback" ]; then
    printf '%s [%s]: ' "$question" "$fallback" > /dev/tty
  else
    printf '%s: ' "$question" > /dev/tty
  fi

  IFS= read -r answer < /dev/tty || answer=''
  [ -n "$answer" ] || answer=$fallback
  printf -v "$name" '%s' "$answer"
}

# dev_ask_secret <variable-name> <question>
# Reads with terminal echo off and stores into the named variable. Never print
# a value that came from this.
dev_ask_secret() {
  [ $# -eq 2 ] || die "dev_ask_secret takes a variable name and a question"
  local name=$1 question=$2 answer

  dev_assert_variable_name "$name"
  dev_interactive || die "'$question' 은 secret 이라 terminal 에서만 받을 수 있습니다."

  printf '%s: ' "$question" > /dev/tty
  IFS= read -rs answer < /dev/tty || answer=''
  printf '\n' > /dev/tty
  printf -v "$name" '%s' "$answer"
}

dev_assert_variable_name() {
  case $1 in
    [A-Za-z_]*) ;;
    *) die "not a variable name: $1" ;;
  esac
  case $1 in
    *[!A-Za-z0-9_]*) die "not a variable name: $1" ;;
  esac
}

# dev_confirm <question>
# Returns 0 on yes, 1 otherwise. With no terminal it returns 1 without asking,
# so an unattended run never takes the dangerous branch.
dev_confirm() {
  local question=$1 answer

  dev_interactive || return 1

  printf '%s [y/N]: ' "$question" > /dev/tty
  IFS= read -r answer < /dev/tty || answer=''
  case $answer in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# dev_config_set <file> <key> <value>
# Writes one KEY=value line: replaces the existing line for that key, appends
# when there is none. A file it creates starts at mode 0600. An existing file
# has its contents rewritten in place, so its permissions survive.
dev_config_set() {
  [ $# -eq 3 ] || die "dev_config_set takes 3 arguments: file, key, value"
  local file=$1 key=$2 value=$3

  [ -f "$file" ] || {
    umask 077
    : > "$file"
  }

  local temporary
  temporary=$(mktemp)
  DEV_CONFIG_VALUE=$value awk -v key="$key" '
    BEGIN { value = ENVIRON["DEV_CONFIG_VALUE"]; written = 0 }
    substr($0, 1, length(key) + 1) == key "=" {
      if (!written) { print key "=" value; written = 1 }
      next
    }
    { print }
    END { if (!written) print key "=" value }
  ' "$file" > "$temporary"

  cat "$temporary" > "$file"
  rm -f "$temporary"
}

# dev_config_get <file> <key>
# Prints the value. Returns 1 with no output when the file or the key is absent.
dev_config_get() {
  [ $# -eq 2 ] || die "dev_config_get takes 2 arguments: file, key"
  local file=$1 key=$2 value

  [ -f "$file" ] || return 1

  value=$(awk -v key="$key" '
    substr($0, 1, length(key) + 1) == key "=" { print substr($0, length(key) + 2) }
  ' "$file" | tail -n 1)

  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# --- command files -----------------------------------------------------------

list_commands() {
  local file
  for file in "$COMMAND_DIR"/*.sh; do
    [ -e "$file" ] || continue
    basename "$file" .sh
  done
}

# Collected subcommands. load_command clears and refills these on every call.
VERB_NAMES=()
VERB_ARGS=()
VERB_TEXTS=()

dev_verb() {
  [ $# -eq 3 ] || die "dev_verb takes 3 arguments: name, arguments, description"
  VERB_NAMES+=("$1")
  VERB_ARGS+=("$2")
  VERB_TEXTS+=("$3")
}

load_command() {
  local command=$1 file="$COMMAND_DIR/$1.sh"
  [ -f "$file" ] || die "unknown command: $command. Run: $DEV_NAME help"

  VERB_NAMES=(); VERB_ARGS=(); VERB_TEXTS=()
  unset -f dev_describe dev_verbs dev_run 2>/dev/null || true

  # shellcheck source=/dev/null
  source "$file"

  declare -F dev_run >/dev/null || die "$file defines no dev_run function"
  declare -F dev_verbs >/dev/null && dev_verbs
  return 0
}

describe_command() {
  # This runs while building a listing, so read the file in a subshell: one
  # broken command file must not take down the whole listing. A file with no
  # dev_describe yields an empty line.
  ( load_command "$1" >/dev/null 2>&1 || exit 0
    declare -F dev_describe >/dev/null && dev_describe ) 2>/dev/null || true
}

# --- help --------------------------------------------------------------------

print_root_help() {
  printf '%s - %s\n\n' "$DEV_NAME" "$DEV_TAGLINE"
  printf '사용법:\n  %s <command> <subcommand> [options]\n\n' "$DEV_NAME"

  local command found=0
  printf 'command:\n'
  while read -r command; do
    [ -n "$command" ] || continue
    found=1
    printf '  %-12s %s\n' "$command" "$(describe_command "$command")"
  done < <(list_commands)
  [ "$found" -eq 1 ] || printf '  (없음. .dev/commands/ 에 command 파일을 추가하십시오.)\n'

  printf '  %-12s %s\n' 'help' '이 도움말'
  printf '  %-12s %s\n' 'docs' 'DEV_TOOL.md 의 명령어 표를 다시 만듭니다'
  printf '\n%s <command> 만 치면 그 command 의 subcommand 목록이 나옵니다.\n' "$DEV_NAME"
}

print_command_help() {
  local command=$1
  load_command "$command"

  local description
  description=$(declare -F dev_describe >/dev/null && dev_describe || true)
  printf '%s %s - %s\n\n' "$DEV_NAME" "$command" "$description"
  printf 'subcommand:\n'

  # Usage on one line, description indented under it. A single line cannot
  # hold both once a subcommand declares several flags, and padding the
  # arguments column to fit the longest one wastes the width every other row
  # needs for its description.
  local i usage
  for i in "${!VERB_NAMES[@]}"; do
    usage=${VERB_NAMES[$i]}
    [ -n "${VERB_ARGS[$i]}" ] && usage="$usage ${VERB_ARGS[$i]}"
    printf '  %s\n      %s\n' "$usage" "${VERB_TEXTS[$i]}"
  done
  [ "${#VERB_NAMES[@]}" -gt 0 ] || printf '  (이 command 는 subcommand 를 알려주지 않습니다.)\n'
}

# --- docs --------------------------------------------------------------------

render_command_table() {
  local command i
  while read -r command; do
    [ -n "$command" ] || continue
    load_command "$command"
    printf '\n### `%s %s` — %s\n\n' "$DEV_NAME" "$command" \
      "$(declare -F dev_describe >/dev/null && dev_describe || true)"
    printf '| 명령어 | 하는 일 |\n| --- | --- |\n'
    for i in "${!VERB_NAMES[@]}"; do
      local usage="$DEV_NAME $command ${VERB_NAMES[$i]}"
      [ -n "${VERB_ARGS[$i]}" ] && usage="$usage ${VERB_ARGS[$i]}"
      printf '| `%s` | %s |\n' "$usage" "${VERB_TEXTS[$i]}"
    done
  done < <(list_commands)
}

cmd_docs() {
  [ -f "$DOC_FILE" ] || die "$DOC_FILE not found. Write it first; docs only refreshes the table."
  grep -qF "$DOC_START" "$DOC_FILE" || die "$DOC_FILE has no $DOC_START marker"
  grep -qF "$DOC_END" "$DOC_FILE" || die "$DOC_FILE has no $DOC_END marker"

  local table temporary
  table=$(render_command_table)
  temporary=$(mktemp)
  awk -v block="$table" -v start="$DOC_START" -v stop="$DOC_END" '
    index($0, start) { print; printf "%s\n\n", block; skipping = 1; next }
    index($0, stop)  { skipping = 0 }
    !skipping        { print }
  ' "$DOC_FILE" > "$temporary"
  mv "$temporary" "$DOC_FILE"
  printf 'updated the command table in %s\n' "$DOC_FILE" >&2
}

# --- completion ---------------------------------------------------------------
#
# Machine-readable listings for a shell completion script: names only, one per
# line, no descriptions and no decoration. The completion script in
# templates/completion.bash calls these.

cmd_complete() {
  if [ $# -eq 0 ]; then
    list_commands
    printf '%s\n' $COMPLETABLE_BUILTINS
    return 0
  fi

  local command=$1
  shift

  # An unknown command is not an error here. The person is still typing.
  [ -f "$COMMAND_DIR/$command.sh" ] || return 0
  load_command "$command" >/dev/null 2>&1 || return 0
  [ "${#VERB_NAMES[@]}" -gt 0 ] || return 0

  if [ $# -eq 0 ]; then
    printf '%s\n' "${VERB_NAMES[@]}"
    return 0
  fi

  # Third word on: offer the flags the subcommand declared in its arguments
  # string, e.g. '[--fallback <b>] [--fetch]' yields --fallback and --fetch.
  local verb=$1 i
  for i in "${!VERB_NAMES[@]}"; do
    [ "${VERB_NAMES[$i]}" = "$verb" ] || continue
    printf '%s\n' "${VERB_ARGS[$i]}" | grep -oE '\-\-[A-Za-z][A-Za-z0-9-]*' || true
    return 0
  done
}

# --- main --------------------------------------------------------------------

assert_no_reserved_command_file() {
  local name
  for name in $BUILTINS; do
    [ -f "$COMMAND_DIR/$name.sh" ] && \
      die "$COMMAND_DIR/$name.sh 는 built-in 이름 $name 을 씁니다. 이 파일은 실행될 수 없으니 이름을 바꾸십시오."
  done
  return 0
}

main() {
  [ -d "$COMMAND_DIR" ] || die "$COMMAND_DIR not found. dev-tool 스킬로 다시 설치하십시오."
  assert_no_reserved_command_file

  local command=${1:-help}
  [ $# -gt 0 ] && shift

  case $command in
    help|-h|--help) print_root_help; return 0 ;;
    docs) cmd_docs; return 0 ;;
    complete) cmd_complete "$@"; return 0 ;;
  esac

  [ -f "$COMMAND_DIR/$command.sh" ] || {
    printf 'error: unknown command: %s\n\n' "$command" >&2
    print_root_help >&2
    exit 1
  }

  local verb=${1:-help}
  [ $# -gt 0 ] && shift

  if [ "$verb" = help ] || [ "$verb" = -h ] || [ "$verb" = --help ]; then
    print_command_help "$command"
    return 0
  fi

  load_command "$command"

  if [ "${#VERB_NAMES[@]}" -gt 0 ]; then
    local known=0 name
    for name in "${VERB_NAMES[@]}"; do
      [ "$name" = "$verb" ] && known=1
    done
    [ "$known" -eq 1 ] || {
      printf 'error: %s has no subcommand %s\n\n' "$command" "$verb" >&2
      print_command_help "$command" >&2
      exit 1
    }
  fi

  dev_run "$verb" "$@"
}

main "$@"
