#!/usr/bin/env bash
#
# Shared by .dev/commands/db.sh and .dev/commands/server.sh. Its name does not
# end in .sh, so the dispatcher never picks it up as a command: list_commands
# in .dev/dispatch.sh globs .dev/commands/*.sh only.
#
# Like a command file, this one can be sourced every time the dispatcher builds
# a listing, so its top level defines functions only and has no side effects.

TESTENV_SCRIPT="$DEV_ROOT/.agents/skills/test-env/scripts/testenv.sh"

# testenv_run <testenv.sh arguments...>
#
# Prints the testenv.sh command to stderr, then runs it, so the person always
# sees what actually executes. With DEV_DRY_RUN=1 it prints and runs nothing.
testenv_run() {
  local quoted
  quoted=$(printf ' %q' "$TESTENV_SCRIPT" "$@")
  printf '+%s\n' "$quoted" >&2

  if [ "${DEV_DRY_RUN:-0}" = 1 ]; then
    return 0
  fi

  "$TESTENV_SCRIPT" "$@"
}
