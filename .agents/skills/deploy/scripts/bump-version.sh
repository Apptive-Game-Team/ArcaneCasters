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
  cargo)  old_line="version = \"$old\""; new_line="version = \"$new\"" ;;
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

if [ "$kind" = cargo ]; then
  # The workspace version also sits in Cargo.lock, once per workspace crate, and the image
  # builds with --locked; a commit that bumps Cargo.toml alone would not build. Both files go
  # into one commit through the Git Data API.
  gh api "repos/$repo/contents/Cargo.lock?ref=dev" --jq .content | tr -d '\n' | base64 -d > "$work/lock.old"
  python3 - "$work/lock.old" "$work/lock.new" "$old" "$new" <<'PY'
import re, sys
source, target, old, new = sys.argv[1:5]
text = open(source).read()
blocks = text.split("\n[[package]]\n")
bumped = 0
for index, block in enumerate(blocks):
    # Workspace crates are the packages with no `source` line.
    if index == 0 or "\nsource = " in block:
        continue
    replaced = re.sub(r'(?m)^version = "' + re.escape(old) + r'"$', 'version = "' + new + '"', block, count=1)
    if replaced != block:
        blocks[index] = replaced
        bumped += 1
if bumped == 0:
    sys.exit("no workspace crate at " + old + " in Cargo.lock")
open(target, "w").write("\n[[package]]\n".join(blocks))
print(f"Cargo.lock: {bumped} workspace crates", file=sys.stderr)
PY
  base=$(gh api "repos/$repo/git/ref/heads/dev" --jq .object.sha)
  base_tree=$(gh api "repos/$repo/git/commits/$base" --jq .tree.sha)
  python3 - "$work" "$base_tree" > "$work/tree.json" <<'PY'
import json, sys
work, base_tree = sys.argv[1:3]
entries = [{"path": "Cargo.toml", "mode": "100644", "type": "blob", "content": open(f"{work}/new").read()},
           {"path": "Cargo.lock", "mode": "100644", "type": "blob", "content": open(f"{work}/lock.new").read()}]
json.dump({"base_tree": base_tree, "tree": entries}, sys.stdout)
PY
  tree=$(gh api -X POST "repos/$repo/git/trees" --input "$work/tree.json" --jq .sha)
  commit=$(gh api -X POST "repos/$repo/git/commits" -f message="chore(release): $component v$new" -f tree="$tree" -f "parents[]=$base" --jq .sha)
  # Not forced: if dev moved since $base, this fails instead of dropping someone's commit.
  gh api -X PATCH "repos/$repo/git/refs/heads/dev" -f sha="$commit" -F force=false --jq .object.sha
  exit 0
fi

python3 - "$work/new" "$sha" "chore(release): $component v$new" > "$work/body.json" <<'PY'
import base64, json, sys
path, sha, message = sys.argv[1:4]
with open(path, 'rb') as handle:
    content = base64.b64encode(handle.read()).decode()
json.dump({'message': message, 'content': content, 'sha': sha, 'branch': 'dev'}, sys.stdout)
PY

gh api -X PUT "repos/$repo/contents/$file" --input "$work/body.json" --jq '.commit.sha'
