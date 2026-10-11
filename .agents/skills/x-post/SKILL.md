---
name: x-post
description: Draft an English X (Twitter) post with one image for the ArcaneCasters account from the player-facing changes in a commit range, and show it in the chat for the user to post by hand. Use after a deploy promotion, when asked for an X post, a tweet, or an announcement of what changed in a release.
---

# X Post Draft

Draft one post for the ArcaneCasters X account. The account posts in English.
Suggest only: never post, never log in to X, and never write the draft into a
repository.

## Input

One commit range per repository, as `<path> <from-sha> <to-sha>`. After a
deploy promotion, `<from-sha>` is the pre-merge `deploy` SHA that the `deploy`
skill records in its step 3, and `<to-sha>` is `origin/deploy`. Without a
deploy, ask the user for the range or use the latest release tags.

## Workflow

1. Collect the commit messages in each range:

   ```bash
   git -C <path> log --no-merges --format='%s%n%b' <from-sha>..<to-sha>
   ```

2. Keep only what a player notices: `feat:` and `fix:` commits in `client`,
   `game`, `lobby`, and `database` (new magic, summons, adventures, balance
   changes), plus `website`. Drop `chore`, `ci`, `refactor`, `test`, `docs`,
   version bumps, and every `infra`, `account`, and `admin` change. When
   nothing remains, say so in one line and write no draft.

3. Pick one image that shows the biggest change, from files the range added or
   changed:

   ```bash
   git -C <path> diff --name-only --diff-filter=AM <from-sha> <to-sha> -- '*.png' '*.jpg'
   ```

   Prefer in-game sprites and UI under `client/Assets` over `.art/concept`
   source sheets. When no image changed, ask for a screen capture, or fall back
   to `website/public/arcane-casters-thumbnail-16x9.png` and say that it is a
   fallback. To put several sprites in one picture, compose them with Pillow in
   a scratchpad virtual environment; ImageMagick is not installed. X crops
   single images toward 16:9, so pad a tall sprite onto a 16:9 canvas.

4. Write the post:
   - At most 280 characters, counting every link as 23.
   - Lead with the single biggest change and name it by its in-game name.
   - Short plain sentences about what the player gets. Never claim a feature
     the commits do not show.
   - End with one play link and two or three hashtags such as
     `#indiedev #gamedev #ArcaneCasters`.

   Play links:
   - Google Play: `https://play.google.com/store/apps/details?id=com.team6515.wordonline`
   - itch.io: `https://theevilent.itch.io/arcane-casters`

5. Show the result in the chat: the post in its own fenced code block so it can
   be copied whole, the character count under it, and the image path. Show the
   image with Read, and send it with SendUserFile so it reaches other devices.
