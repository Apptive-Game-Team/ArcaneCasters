---
name: itch-devlog
description: Draft an English itch.io devlog for ArcaneCasters as copyable HTML, with tags and images to attach, and short Korean Google Play release notes. Use after a deploy promotion or when asked for release notes for either store.
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

3. Write the title and HTML body:
   - Title that names the release and the main change, such as
     `v0.8.0 adds the Frost Wyrm adventure and three new spells`. Take the version from
     the client release, since the client is what players download.
   - A two-line intro that says what the update is about.
   - Use an HTML fragment with `<p>` for paragraphs, `<h2>` for New, Changed,
     and Fixed, and `<ul>` and `<li>` for lists. Leave out an empty group.
   - A closing paragraph with an HTML link to Google Play
     `https://play.google.com/store/apps/details?id=com.team6515.wordonline`.
   - Mark image placement with an HTML comment such as
     `<!-- Insert the faction selection screenshot here. -->`.
   - Never claim a feature the commits do not show.

4. Show the title separately and put the body in a fenced `html` block for
   pasting into the itch.io HTML editor. Put relevant itch.io tags on a separate
   plain-text line with a comma and a space between tags and a trailing comma,
   for example `strategy, card-game, fantasy,`. Keep tags outside the HTML and
   omit hashtag prefixes. List the image files below the tags for attachment.
   Show the images and attach them when the chat supports file attachments.

5. Provide separate, copyable Google Play release notes in Korean plain text.
   Default to about three short lines in 해요체. Summarize what players will
   notice at a high level, leaving out internal details, exact numbers, and
   minor fixes. Use a longer note when a significant player-facing feature is
   worth highlighting, and spend the extra space on what players can do with
   it. When asked only for Google Play notes, return only that draft.
