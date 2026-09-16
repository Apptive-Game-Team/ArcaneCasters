#!/usr/bin/env bash
# Print the release plan for every versioned component, one TSV row per row:
#   path  owner/repo  file  kind  commits  deploy_version  dev_version  level  next_version  state
# Run from the ArcaneCasters monorepo root. Reads only remote-tracking refs; never
# touches a working tree, index, or local branch.
set -uo pipefail

COMPONENTS='game|build.gradle|gradle
lobby|build.gradle|gradle
account|build.gradle|gradle
admin|build.gradle|gradle
client|ProjectSettings/ProjectSettings.asset|unity'

read_version() { # <path> <ref> <file> <kind>
  case "$4" in
    gradle) git -C "$1" show "$2:$3" 2>/dev/null | sed -n "s/^version = '\(.*\)'\r\?$/\1/p" | head -1 ;;
    unity)  git -C "$1" show "$2:$3" 2>/dev/null | sed -n "s/^  bundleVersion: \(.*\)\r\?$/\1/p" | head -1 ;;
  esac
}

classify() { # <path>: conventional-commit level over origin/deploy..origin/dev
  local log
  log=$(git -C "$1" log --no-merges --format='%s%n%b%n--' origin/deploy..origin/dev 2>/dev/null)
  if grep -qE '^[a-z]+(\([^)]*\))?!:' <<<"$log" || grep -q 'BREAKING[ -]CHANGE' <<<"$log"; then
    echo major
  elif grep -qE '^feat(\([^)]*\))?:' <<<"$log"; then
    echo minor
  else
    echo patch
  fi
}

next_version() { # <current> <level>
  local IFS=.
  read -r major minor patch <<<"${1%%-*}"
  case "$2" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
  esac
}

while IFS='|' read -r path file kind; do
  [ -d "$path/.git" ] || [ -f "$path/.git" ] || { printf '%s\t-\t%s\t%s\t-\t-\t-\t-\t-\tskipped: not initialized\n' "$path" "$file" "$kind"; continue; }
  slug=$(git -C "$path" remote get-url origin | sed -E 's#^.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')
  git -C "$path" fetch --prune --quiet origin || { printf '%s\t%s\t%s\t%s\t-\t-\t-\t-\t-\tfailed: fetch\n' "$path" "$slug" "$file" "$kind"; continue; }
  for ref in dev deploy; do
    git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$ref" || {
      printf '%s\t%s\t%s\t%s\t-\t-\t-\t-\t-\tskipped: missing %s\n' "$path" "$slug" "$file" "$kind" "$ref"
      continue 2
    }
  done
  commits=$(git -C "$path" rev-list --count origin/deploy..origin/dev)
  deploy_version=$(read_version "$path" origin/deploy "$file" "$kind")
  dev_version=$(read_version "$path" origin/dev "$file" "$kind")
  [ -n "$dev_version" ] || { printf '%s\t%s\t%s\t%s\t%s\t-\t-\t-\t-\tfailed: no version in dev\n' "$path" "$slug" "$file" "$kind" "$commits"; continue; }
  if [ "$commits" = 0 ]; then
    state='skipped: up to date'; level='-'; next="$dev_version"
  elif [ "$dev_version" != "$deploy_version" ]; then
    state='already bumped'; level='-'; next="$dev_version"
  else
    level=$(classify "$path"); next=$(next_version "$dev_version" "$level"); state='bump'
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$path" "$slug" "$file" "$kind" "$commits" "${deploy_version:--}" "$dev_version" "$level" "$next" "$state"
done <<<"$COMPONENTS"
