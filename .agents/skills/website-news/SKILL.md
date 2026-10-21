---
name: website-news
description: Add one Korean and English entry for a release to the update news page of the ArcaneCasters website (theevilent repository, `/arcane-casters/news`) from the player-facing changes in a commit range, and open a draft pull request. Use after a deploy promotion, or when asked to add a release to the website news page.
---

# Website News Entry

Add one release entry to `src/content/newsContent.ts` in the website
repository (`website/`, GitHub `Apptive-Game-Team/theevilent`). The page at
`/arcane-casters/news` renders that file; nothing is fetched at runtime, so a
release that is not added here never shows on the site.

Unlike `itch-devlog` and `x-post`, this skill writes to a repository: it ends
with a draft pull request. Never mark it ready and never merge it; the
developer reviews the copy and runs `gh pr ready`.

## Input

The same input as the `x-post` skill (`.agents/skills/x-post/SKILL.md`): one
commit range per repository, as `<path> <from-sha> <to-sha>`. Run its steps 1
and 2 to collect and filter the player-facing changes; when nothing remains,
say so in one line and open no pull request.

## Workflow

1. Read `website/AGENTS.md` and `website/.agents/docs/workflow.md`. They set
   the issue, branch, label, and validation rules this skill follows.

2. Work in a new worktree from the website's `dev`, never in the shared
   `website/` checkout, and never use `git stash`:

   ```bash
   git -C website fetch origin
   git -C website worktree add --detach /home/yunseong/dev/worktrees/website-news-<version> origin/dev
   ```

3. Decide the entry's `version` and `date`:
   - `version` is the client release tag, such as `v1.4.0`, because the client
     is what players download. `date` is that release's date in ISO form.
   - When the promotion did not release the client, fold the server and
     database changes into the next client release instead of adding an entry
     with a server version. Say so in the report.
   - When the version is already in `newsReleases`, update that entry instead
     of adding a second one.

4. Write the entry at the top of `newsReleases` (newest first):
   - `ko.title` and `en.title` are labels: `v1.4.0 업데이트` and
     `v1.4.0 Update`.
   - 3 to 8 items. Fewer is fine when the release has fewer player-facing
     changes; never invent one to reach 3. Every item must trace to a commit or
     a release note in the range.
   - Korean: short, natural 해요체. Name the magic, adventure, or mode and give
     the number for balance changes (`화염탄 피해가 120에서 140으로 늘었어요`).
   - English: plain and short, the same facts as the Korean item.
   - Magic, summon, and adventure names come from the client's Korean and
     English localization, following `website/AGENTS.md` ("Arcane Casters
     Content Sources"). Use the name the magic compendium already shows
     (`magicConcepts.json` `korean`, `magicGameData.json` `nameEn`).
   - Leave out refactors, CI, tooling, infra, account and admin work, as the
     `itch-devlog` filter does.

5. Pick up to three images for the entry's `images` field, one per main
   change, the way step 3 of the `x-post` skill picks one: files the range
   added or changed, preferring in-game sprites and UI under `client/Assets`
   over `.art/concept` source sheets. Look at each candidate with Read and keep
   it only when it shows the change. An entry without a fitting image gets no
   image; do not fill it with the site thumbnail.
   - Check `website/public/game-assets` for an existing display copy first.
   - Otherwise convert to WebP under `public/news/<version>/<kebab-name>.webp`,
     under about 200 KB, keeping transparency. Scale small sprites up with
     nearest-neighbour. ImageMagick is not installed; use Pillow in a
     scratchpad virtual environment, which can also compose several sprites
     into one picture.
   - Give each image `alt` text in Korean and English that names what it
     shows, with the localized in-game name.

6. Validate in the worktree. When `npm` fails on the lazy nvm function, put
   `~/.nvm/versions/node/<version>/bin` on `PATH` first.

   ```bash
   npm ci
   npm run build
   npm run lint
   npx playwright test tests/news.spec.ts
   ```

   `tests/news.spec.ts` counts the releases. Update the expected count and the
   newest version in it along with the entry.

7. Open the pull request:
   - `gh issue create --label feature --assignee @me` with a title such as
     `업데이트 소식에 v1.4.0 항목 추가`, then `git switch -c feature/<issue>`.
   - Commit as `feat(news): v1.4.0 업데이트 소식 추가 (#<issue>)`.
   - `gh pr create --draft --base dev --head feature/<issue> --assignee @me --label feature`.
     Pass `--head` explicitly. The body has `Closes #<issue>` and lists the
     commits or release notes each item and image came from.

8. Report in the chat: the pull request link, both language versions of
   the entry, and the images with their source paths, so the developer can review the copy without opening the diff.
