#!/usr/bin/env bash
# Commit a version bump straight onto origin/dev through the GitHub Contents
# API, so no local checkout, branch, or working tree is touched.
# Usage: bump-version.sh <owner/repo> <file> <kind> <old> <new>
set -euo pipefail

repo=$1 file=$2 kind=$3 old=$4 new=$5
component=${repo##*/}
case "$kind" in
  gradle) old_line="version = '$old'"; new_line="version = '$new'" ;;
  unity)  old_line="  bundleVersion: $old"; new_line="  bundleVersion: $new" ;;
  *) echo "unknown kind: $kind" >&2; exit 2 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sha=$(gh api "repos/$repo/contents/$file?ref=dev" --jq .sha)
gh api "repos/$repo/contents/$file?ref=dev" --jq .content | tr -d '\n' | base64 -d > "$work/old"

matches=$(grep -Fxc "$old_line" "$work/old" || true)
[ "$matches" = 1 ] || { echo "expected exactly one \"$old_line\" in $repo:$file, found $matches" >&2; exit 1; }

awk -v old="$old_line" -v new="$new_line" '$0 == old { print new; next } { print }' "$work/old" > "$work/new"

changed=$(diff "$work/old" "$work/new" | grep -c '^[<>]' || true)
[ "$changed" = 2 ] || { echo "refusing to commit: $changed changed lines in $repo:$file" >&2; exit 1; }

python3 - "$work/new" "$sha" "chore(release): $component v$new" > "$work/body.json" <<'PY'
import base64, json, sys
path, sha, message = sys.argv[1:4]
with open(path, 'rb') as handle:
    content = base64.b64encode(handle.read()).decode()
json.dump({'message': message, 'content': content, 'sha': sha, 'branch': 'dev'}, sys.stdout)
PY

gh api -X PUT "repos/$repo/contents/$file" --input "$work/body.json" --jq '.commit.sha'
