#!/usr/bin/env bash
#
# Tab completion for a project's ./dev entry point. Works in bash and in zsh.
#
# Install it by sourcing this file from your shell startup file, pointing at the
# copy inside the project:
#
#   source ~/dev/my-project/.dev/completion.bash
#
# zsh needs its bash compatibility layer, which the file loads itself; compinit
# must already have run, which it has in any normal zsh setup.
#
# It asks the project's own ./dev for the names (`./dev complete`), so a new
# command file is completable the moment it exists, with nothing to regenerate.
#
# That does mean pressing TAB runs the project's ./dev, which sources every
# file in .dev/commands/. That is the same code that runs when you invoke
# ./dev at all, so it is no new exposure in a project you already work in — but
# do not install this for a repository whose code you would not run.

if [ -n "${ZSH_VERSION:-}" ]; then
  autoload -U +X bashcompinit && bashcompinit
fi

_dev_completion() {
  local launcher=${COMP_WORDS[0]} current=${COMP_WORDS[COMP_CWORD]}
  local candidates

  # Ask the launcher the person actually typed, so ./dev in this directory
  # answers for this project and a different one answers for its own.
  case $COMP_CWORD in
    1) candidates=$("$launcher" complete 2>/dev/null) ;;
    2) candidates=$("$launcher" complete "${COMP_WORDS[1]}" 2>/dev/null) ;;
    *) candidates=$("$launcher" complete "${COMP_WORDS[1]}" "${COMP_WORDS[2]}" 2>/dev/null) ;;
  esac

  [ -n "$candidates" ] || { COMPREPLY=(); return 0; }

  # shellcheck disable=SC2207
  COMPREPLY=($(compgen -W "$candidates" -- "$current"))
}

complete -F _dev_completion dev ./dev
