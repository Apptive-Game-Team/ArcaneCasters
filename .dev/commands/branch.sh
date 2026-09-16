#!/usr/bin/env bash
#
# ./dev branch - show and align the branch each component sits on.
#
# When one feature spans several submodules or sibling repositories, which
# component is on which branch is scattered and invisible. This command puts
# it in one table, moves them together, and remembers a combination by name.
#
# Component discovery order:
#   1. the DEV_COMPONENTS array in .dev/config.sh
#   2. the submodule paths in .gitmodules
#   3. the repository itself
#
# Which component moves, and where:
#
#   ./dev branch use feature/10                 every component, or main
#   ./dev branch use feature/10 lobby=main      the same, but lobby to main
#   ./dev branch use game=feature/12            only game; nothing else moves
#
# Naming a component moves that component. Naming a default branch as well is
# what pulls the rest along. A run that named only one component must not drag
# every other one onto main behind the person's back.
#
# This command never commits, never resets, and never stashes. Stash is shared
# across the worktrees of one repository, so what one session pushes onto it
# another can pop, silently taking someone else's work. Instead, if any
# component that would have to move has uncommitted changes, the whole
# operation is refused and the blocked components are listed.

SET_DIR="$DEV_ROOT/.dev/branches"

dev_describe() {
  echo '여러 component 의 branch 를 한 번에 보고 맞춥니다'
}

dev_verbs() {
  dev_verb show ''                                                    '각 component 의 현재 branch 와 변경 여부를 보여줍니다'
  dev_verb use  '[branch] [c=branch] [--fallback <b>] [--fetch] [--dry-run]' '이름을 댄 component 를 그 branch 로 옮깁니다. 기본 branch 를 같이 주면 나머지도 그 branch (없으면 fallback) 로 따라갑니다'
  dev_verb save '<이름>'                                              '지금 각 component 의 branch 조합을 그 이름으로 저장합니다'
  dev_verb load '<이름> [--fetch] [--dry-run]'                        '저장한 조합대로 맞춥니다. 조합에 없는 component 는 건드리지 않습니다'
  dev_verb list ''                                                    '저장된 조합을 보여줍니다'
}

dev_run() {
  local verb=$1
  shift

  case $verb in
    show) branch_show ;;
    use)  branch_use "$@" ;;
    save) branch_save "$@" ;;
    load) branch_load "$@" ;;
    list) branch_list ;;
    *)    die "unhandled subcommand: $verb" ;;
  esac
}

# --- discovering components --------------------------------------------------

branch_components() {
  if declare -p DEV_COMPONENTS >/dev/null 2>&1; then
    printf '%s\n' "${DEV_COMPONENTS[@]}"
    return 0
  fi

  if [ -f "$DEV_ROOT/.gitmodules" ]; then
    git -C "$DEV_ROOT" config --file .gitmodules --get-regexp '^submodule\..*\.path$' |
      awk '{ print $2 }'
    return 0
  fi

  echo '.'
}

branch_path() {
  case $1 in
    .) printf '%s\n' "$DEV_ROOT" ;;
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$DEV_ROOT" "$1" ;;
  esac
}

branch_is_component() {
  local candidate=$1 component
  while read -r component; do
    [ "$component" = "$candidate" ] && return 0
  done < <(branch_components)
  return 1
}

# --- reading one component ---------------------------------------------------

branch_current() {
  local path=$1 name
  name=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
    echo '(git 저장소가 아님)'
    return 0
  }

  if [ "$name" = HEAD ]; then
    # Detached HEAD. Show the commit, since there is no branch name.
    printf '(detached %s)\n' "$(git -C "$path" rev-parse --short HEAD)"
  else
    printf '%s\n' "$name"
  fi
}

branch_is_dirty() {
  local path=$1 output
  output=$(git -C "$path" status --porcelain 2>/dev/null) || return 1
  [ -n "$output" ]
}

# branch_resolve <path> <name>
# Prints local when the branch exists locally, remote when it exists only on
# origin, and returns 1 with no output when it exists in neither.
branch_resolve() {
  local path=$1 name=$2

  if git -C "$path" rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1; then
    echo local
    return 0
  fi

  if git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/$name" >/dev/null 2>&1; then
    echo remote
    return 0
  fi

  return 1
}

# --- show --------------------------------------------------------------------

branch_show() {
  local component path current mark

  # printf pads by byte count, but a Hangul character takes three bytes and
  # two display columns. So the branch name, whose width varies, goes last,
  # and the Hangul column only ever holds values of equal byte length.
  printf '%-14s %-8s %s\n' 'component' '변경' 'branch'
  while read -r component; do
    [ -n "$component" ] || continue
    path=$(branch_path "$component")

    if [ ! -d "$path" ]; then
      printf '%-14s %-8s %s\n' "$component" '모름' '(경로 없음)'
      continue
    fi

    current=$(branch_current "$path")

    # A path that is not a git repository cannot be asked whether it is dirty.
    # Reporting it as clean would be a lie, so report it as unknown.
    if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
      mark='모름'
    elif branch_is_dirty "$path"; then
      mark='있음'
    else
      mark='없음'
    fi

    printf '%-14s %-8s %s\n' "$component" "$mark" "$current"
  done < <(branch_components)
}

# --- moving ------------------------------------------------------------------

# WANTED holds the explicit per-component requests. DEFAULT_BRANCH is what
# every other component follows; empty means the others are left alone.
# FALLBACK_BRANCH is where a component goes when the default branch is not
# there.
#
# These are declared by branch_use and branch_load, not here. The dispatcher
# sources a command file from inside its load_command function, so a declare
# at this file's top level would be local to that function and gone before
# dev_run runs. bash's dynamic scoping makes the caller's locals visible to
# branch_apply_plan, which is what this relies on.

branch_fetch_all() {
  local component path
  while read -r component; do
    [ -n "$component" ] || continue
    path=$(branch_path "$component")
    [ -d "$path" ] || continue
    printf 'fetch %s\n' "$component" >&2
    git -C "$path" fetch --quiet origin || die "$component 에서 fetch 가 실패했습니다."
  done < <(branch_components)
}

# Builds the plan from WANTED, DEFAULT_BRANCH and FALLBACK_BRANCH without
# changing anything, then either applies it or stops. A run that failed halfway
# would leave some components moved and some not, which is the state hardest to
# notice and hardest to undo.
branch_apply_plan() {
  local dry_run=$1
  local plan_components=() plan_targets=() plan_kinds=()
  local blocked=() skipped=()
  local blocked_by_dirty=0
  local component

  while read -r component; do
    [ -n "$component" ] || continue

    local path target kind current explicit=0
    path=$(branch_path "$component")

    # A missing path or a non-repository was never movable in the first place.
    # An uninitialized submodule is the common case, and one of those must not
    # stop every other component from moving. Report it instead of blocking.
    [ -d "$path" ] || { skipped+=("$component: 경로가 없습니다"); continue; }
    git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || {
      skipped+=("$component: git 저장소가 아닙니다")
      continue
    }

    if [ -n "${WANTED[$component]:-}" ]; then
      explicit=1
      target=${WANTED[$component]}
    elif [ -n "$DEFAULT_BRANCH" ]; then
      target=$DEFAULT_BRANCH
    else
      # Not named, and no default branch given: leave it where it is.
      continue
    fi

    if kind=$(branch_resolve "$path" "$target"); then
      :
    elif [ "$explicit" -eq 1 ]; then
      # An explicit request that cannot be honoured is an error, not a reason
      # to quietly put that component somewhere else.
      blocked+=("$component: $target 이(가) 없습니다")
      continue
    elif kind=$(branch_resolve "$path" "$FALLBACK_BRANCH"); then
      target=$FALLBACK_BRANCH
    else
      blocked+=("$component: $DEFAULT_BRANCH 도 $FALLBACK_BRANCH 도 없습니다")
      continue
    fi

    current=$(branch_current "$path")
    if [ "$current" = "$target" ]; then
      kind=keep
    elif branch_is_dirty "$path"; then
      # No stash. The person has to deal with their own changes.
      blocked+=("$component: 변경사항이 있습니다. 지금 $current, 옮기려던 곳 $target")
      blocked_by_dirty=1
      continue
    fi

    plan_components+=("$component")
    plan_targets+=("$target")
    plan_kinds+=("$kind")
  done < <(branch_components)

  local i
  if [ "${#plan_components[@]}" -eq 0 ]; then
    printf '계획: 옮길 component 가 없습니다.\n' >&2
  else
    printf '계획:\n' >&2
    for i in "${!plan_components[@]}"; do
      case ${plan_kinds[$i]} in
        keep)   printf '  %-14s %s (그대로)\n' "${plan_components[$i]}" "${plan_targets[$i]}" >&2 ;;
        local)  printf '  %-14s %s\n' "${plan_components[$i]}" "${plan_targets[$i]}" >&2 ;;
        remote) printf '  %-14s %s (origin 에서 새로 만듭니다)\n' "${plan_components[$i]}" "${plan_targets[$i]}" >&2 ;;
      esac
    done
  fi

  if [ "${#skipped[@]}" -gt 0 ]; then
    printf '\n건너뜁니다:\n' >&2
    local note
    for note in "${skipped[@]}"; do
      printf '  %s\n' "$note" >&2
    done
  fi

  if [ "${#blocked[@]}" -gt 0 ]; then
    printf '\n막힌 component:\n' >&2
    local reason
    for reason in "${blocked[@]}"; do
      printf '  %s\n' "$reason" >&2
    done
    printf '\n아무것도 바꾸지 않았습니다.\n' >&2
    if [ "$blocked_by_dirty" -eq 1 ]; then
      printf '변경사항은 commit 하거나 직접 되돌린 뒤 다시 실행하십시오.\n' >&2
      printf 'stash 는 worktree 사이에서 공유되므로 이 command 는 쓰지 않습니다.\n' >&2
    fi
    return 1
  fi

  if [ "$dry_run" -eq 1 ]; then
    printf '\n--dry-run 이라 여기서 멈춥니다.\n' >&2
    return 0
  fi

  local moved=0
  for i in "${!plan_components[@]}"; do
    local path=${plan_components[$i]}
    path=$(branch_path "$path")

    case ${plan_kinds[$i]} in
      keep) continue ;;
      local)
        git -C "$path" checkout --quiet "${plan_targets[$i]}" ||
          die "${plan_components[$i]} 에서 ${plan_targets[$i]} 로 checkout 이 실패했습니다."
        ;;
      remote)
        git -C "$path" checkout --quiet -b "${plan_targets[$i]}" --track "origin/${plan_targets[$i]}" ||
          die "${plan_components[$i]} 에서 origin/${plan_targets[$i]} 를 받아오지 못했습니다."
        ;;
    esac
    [ "$moved" -eq 0 ] && printf '\n' >&2
    moved=$((moved + 1))
    printf '%-14s -> %s\n' "${plan_components[$i]}" "${plan_targets[$i]}" >&2
  done

  if [ "$moved" -eq 0 ]; then
    printf '\n옮길 것이 없습니다.\n' >&2
    return 0
  fi

  # Only true once something actually moved. Saying it after a run that
  # changed nothing sends the person looking for a change that is not there.
  if [ -f "$DEV_ROOT/.gitmodules" ]; then
    printf '\nsubmodule pointer 가 달라졌습니다. commit 할지는 따로 정하십시오.\n' >&2
  fi
}

# --- use ---------------------------------------------------------------------

branch_use() {
  local fetch=0 dry_run=0
  local -A WANTED=()
  local DEFAULT_BRANCH=''
  local FALLBACK_BRANCH=main

  while [ $# -gt 0 ]; do
    case $1 in
      --fallback) [ $# -ge 2 ] || die '--fallback 은 branch 이름이 필요합니다'; FALLBACK_BRANCH=$2; shift 2 ;;
      --fetch) fetch=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      -*) die "unknown option: $1" ;;
      *=*)
        local component=${1%%=*} wanted=${1#*=}
        branch_is_component "$component" ||
          die "$component 은(는) 이 프로젝트의 component 가 아닙니다. 목록: $DEV_NAME branch show"
        [ -n "$wanted" ] || die "$component 에 줄 branch 이름이 비어 있습니다."
        WANTED["$component"]=$wanted
        shift ;;
      *)
        [ -z "$DEFAULT_BRANCH" ] || die "기본 branch 는 하나만 줍니다: $DEFAULT_BRANCH, $1"
        DEFAULT_BRANCH=$1
        shift ;;
    esac
  done

  [ -n "$DEFAULT_BRANCH" ] || [ "${#WANTED[@]}" -gt 0 ] ||
    die "옮길 branch 를 주십시오: $DEV_NAME branch use <branch> 또는 $DEV_NAME branch use <component>=<branch>"

  [ "$fetch" -eq 1 ] && branch_fetch_all
  branch_apply_plan "$dry_run"
}

# --- save, load, list --------------------------------------------------------

branch_set_file() {
  local name=$1
  case $name in
    *[!A-Za-z0-9._-]*|''|.|..) die "조합 이름에는 영문, 숫자, . _ - 만 씁니다: $name" ;;
  esac
  printf '%s/%s\n' "$SET_DIR" "$name"
}

branch_save() {
  [ $# -ge 1 ] || die "저장할 이름을 주십시오: $DEV_NAME branch save <이름>"
  local file
  file=$(branch_set_file "$1")

  mkdir -p "$SET_DIR"
  : > "$file"

  local component path current saved=0
  while read -r component; do
    [ -n "$component" ] || continue
    path=$(branch_path "$component")
    [ -d "$path" ] || continue
    git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || continue

    current=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
    if [ "$current" = HEAD ]; then
      # A detached HEAD has no branch name to record, and writing the commit
      # would make load check out a commit rather than a branch.
      printf '건너뜀: %s 는 detached HEAD 라 적을 branch 이름이 없습니다\n' "$component" >&2
      continue
    fi

    dev_config_set "$file" "$component" "$current"
    saved=$((saved + 1))
  done < <(branch_components)

  [ "$saved" -gt 0 ] || { rm -f "$file"; die "저장할 branch 가 하나도 없습니다."; }

  printf '%s 에 component %s개를 저장했습니다.\n' "${file#"$DEV_ROOT"/}" "$saved"
  printf '적용: %s branch load %s\n' "$DEV_NAME" "$1"
}

branch_load() {
  [ $# -ge 1 ] || die "불러올 이름을 주십시오: $DEV_NAME branch load <이름>"

  local name=$1
  shift
  local file
  file=$(branch_set_file "$name")
  [ -f "$file" ] || die "$name 이라는 조합이 없습니다. 목록: $DEV_NAME branch list"

  local fetch=0 dry_run=0
  while [ $# -gt 0 ]; do
    case $1 in
      --fetch) fetch=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done

  local -A WANTED=()
  local DEFAULT_BRANCH=''
  local FALLBACK_BRANCH=main

  local component wanted
  while read -r component; do
    [ -n "$component" ] || continue
    wanted=$(dev_config_get "$file" "$component") || continue
    WANTED["$component"]=$wanted
  done < <(branch_components)

  [ "${#WANTED[@]}" -gt 0 ] || die "$name 에 이 프로젝트의 component 가 하나도 없습니다."

  [ "$fetch" -eq 1 ] && branch_fetch_all
  branch_apply_plan "$dry_run"
}

branch_list() {
  [ -d "$SET_DIR" ] || { printf '저장된 조합이 없습니다. 만들기: %s branch save <이름>\n' "$DEV_NAME"; return 0; }

  local file found=0
  for file in "$SET_DIR"/*; do
    [ -f "$file" ] || continue
    found=1
    printf '%s\n' "$(basename "$file")"
    sed -n 's/^\([^=]*\)=\(.*\)$/    \1 -> \2/p' "$file"
  done

  [ "$found" -eq 1 ] || printf '저장된 조합이 없습니다. 만들기: %s branch save <이름>\n' "$DEV_NAME"
}
