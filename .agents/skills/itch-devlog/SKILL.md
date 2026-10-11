---
name: itch-devlog
description: Draft an English itch.io devlog for ArcaneCasters from the player-facing changes in a commit range, with the images to attach, and show it in the chat for the user to publish by hand. Use after a deploy promotion, when asked for an itch.io devlog, patch notes, or an update post on itch.io.
---

# itch.io Devlog Draft

Draft one devlog for `https://theevilent.itch.io/arcane-casters`. The devlog is
in English. Suggest only: never publish, never log in to itch.io, and never
write the draft into a repository.

## Input

The same input as the `x-post` skill (`.agents/skills/x-post/SKILL.md`): one
commit range per repository, as `<path> <from-sha> <to-sha>`. Run its steps 1
and 2 to collect and filter the player-facing changes; when nothing remains,
say so in one line and write no draft.

## Workflow

1. Group the player-facing changes as New, Changed, and Fixed. Merge commits
   that describe one feature into one bullet. Name magic, summons, and
   adventures by their in-game names, and give numbers for balance changes
   (`Fireball damage 120 to 140`).

2. Pick up to three images from files the range added or changed, using the
   `git diff --name-only` command in step 3 of the `x-post` skill. A devlog has
   room for more than one image, so take one per main change. Use the same
   fallback when none changed.

3. Write the devlog:
   - Title that names the release and the main change, such as
     `v0.8.0: Frost Wyrm adventure and three new spells`. Take the version from
     the client release, since the client is what players download.
   - A two-line intro that says what the update is about.
   - The New, Changed, and Fixed lists. Leave out an empty group.
   - A closing line with the Google Play link
     `https://play.google.com/store/apps/details?id=com.team6515.wordonline`.
   - Mark where each image goes with a line such as `[image: <path>]`.
   - Never claim a feature the commits do not show.

4. Show the result in the chat: the devlog in its own fenced Markdown block so
   it can be pasted into the itch.io editor, followed by the image paths. Show
   each image with Read, and send them with SendUserFile.
