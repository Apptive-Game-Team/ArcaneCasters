#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/plan-versions.sh"
check() {
  local actual
  actual=$(classify_log "$1" "$2")
  [[ "$actual" = "$3" ]] || { echo "Expected $3, got $actual" >&2; exit 1; }
}
check client 'fix: optional rendering correction' patch
check client $'fix: required protocol correction\n\nRequired-Update: true' minor
check client $'fix: optional correction\n\nRequired-Update: false' patch
check client $'fix!: protocol replacement\n\nRequired-Update: true' major
check client $'fix: protocol replacement\n\nBREAKING CHANGE: new contract' major
check client 'feat: new client capability' minor
check game $'fix: correction\n\nRequired-Update: true' patch
[[ $(next_version 1.5.9 minor) = 1.6.0 ]]
[[ $(next_version 1.5.9 patch) = 1.5.10 ]]
echo '9 release-version policy checks passed'
