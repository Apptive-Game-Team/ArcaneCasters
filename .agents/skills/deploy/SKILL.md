---
name: deploy
description: Create or reuse GitHub pull requests from dev to deploy across the ArcaneCasters monorepo root and its Git submodules, bump each versioned component once per promotion, then merge, tag, and release. Use when the user invokes $deploy or asks to promote, merge, or deploy all eligible repository dev branches into deploy.
---

# Deploy Dev Branches

Promote `dev` to `deploy` independently in each Git repository. Versioned
components get their single version bump here, at promotion time, not in feature
pull requests. Preserve every local checkout and working tree.

## Safety Rules

- Run from ArcaneCasters monorepo root containing `.gitmodules`.
- Include root repository and every initialized submodule declared in `.gitmodules`.
- Use `origin/dev` and `origin/deploy` as source of truth after fetching.
- Never create a missing `dev` or `deploy` branch. A repository with no `deploy`
  branch yet is skipped, not treated as an error: mark it
  `skipped: missing deploy` and carry it into the final report like any other
  skip. Re-check with step 3 rather than assuming which repositories qualify;
  at the time of writing this covers the monorepo root `ArcaneCasters`,
  `ArcaneCastersInfra`, `ArcaneCastersClient`, and `theevilent` (the website
  repository).
- Never switch branches, pull, reset, stash, or edit files in any local checkout.
  Local checkouts sit on unrelated feature branches with uncommitted work.
- The only write to `dev` is the version bump commit, made remotely through the
  GitHub Contents API by `scripts/bump-version.sh`. Never `git push` from a local
  checkout.
- Never bypass conflicts, required checks, reviews, or branch protection.
- Never delete `dev` or `deploy`.
- `dev` is both ahead of and behind `deploy` in every repository that has a
  `deploy` branch. The commits only on `deploy` are historical merge commits
  from the old `main` track; that is expected. Merge with `--merge` only, never
  squash. A squash breaks the merge base and makes every later promotion
  conflict.
- Process repositories independently. One failure must not block other eligible repositories.
- When `gh` authentication fails only inside sandbox, retry same `gh` command with escalated execution before reporting auth failure.

## Versioned Components

Only these five repositories carry a version, and only they get a bump, tag, and
release. Every other repository is promoted without any of the three.

| Path | Version file | Kind |
|---|---|---|
| `game` | `build.gradle` | `gradle` |
| `lobby` | `build.gradle` | `gradle` |
| `account` | `build.gradle` | `gradle` |
| `admin` | `build.gradle` | `gradle` |
| `client` | `ProjectSettings/ProjectSettings.asset` | `unity` |

## Workflow

1. Verify tools and root. The scripts need `git`, `gh`, `python3`, `awk`, and
   `base64`; they do not need `jq`, which is absent on this machine.

   ```bash
   git rev-parse --show-toplevel
   test -f .gitmodules
   gh auth status
   ```

2. Build repository list:
   - Add `.` first.
   - Read submodule paths with Git config, not manual text parsing:

     ```bash
     git config -f .gitmodules --get-regexp '^submodule\..*\.path$'
     ```

   - Skip declared submodules that are not initialized Git repositories.

3. For each repository path:
   - Resolve and record `origin` URL.
   - Refresh remote refs without changing local branches:

     ```bash
     git -C <path> fetch --prune origin
     ```

   - Verify both refs:

     ```bash
     git -C <path> show-ref --verify --quiet refs/remotes/origin/dev
     git -C <path> show-ref --verify --quiet refs/remotes/origin/deploy
     ```

   - If either remote branch does not exist, mark `skipped: missing dev` or
     `skipped: missing deploy`. This is expected, not an error, for a
     repository that has never had a `deploy` branch cut yet; report it like
     any other skip and never create the branch.
   - Count source-only commits (commits reachable from `dev` but not yet on
     `deploy`; commits only on `deploy` do not affect this count and do not
     block promotion):

     ```bash
     git -C <path> rev-list --count origin/deploy..origin/dev
     ```

   - If count is `0`, mark `skipped: up to date`. Do not create a PR.

4. Build the release plan for the versioned components:

   ```bash
   .agents/skills/deploy/scripts/plan-versions.sh
   ```

   The script fetches, then prints one tab-separated row per component:
   `path`, `owner/repo`, `file`, `kind`, `commits`, `deploy_version`,
   `dev_version`, `level`, `next_version`, `state`.

   It derives `level` from the Conventional Commit subjects and bodies in
   `origin/deploy..origin/dev`, ignoring merge commits:

   - `MAJOR` when any commit uses a `!` marker such as `feat!:` or `fix(api)!:`,
     or carries a `BREAKING CHANGE` trailer.
   - `MINOR` when any commit is `feat:` or `feat(scope):`.
   - `PATCH` otherwise, including commits whose subject is not a Conventional
     Commit at all.

   `state` is one of:

   - `bump`: `dev` and `deploy` hold the same version, so this promotion bumps it.
   - `already bumped`: `dev` already carries a version ahead of `deploy`, left
     over from a promotion that was blocked after its bump commit landed. Reuse
     `dev_version` and do not bump again.
   - `skipped: up to date`, `skipped: missing <branch>`, `failed: <reason>`.

5. Show the plan and get explicit approval before writing anything:

   | Repository | Commits | Level | Version |
   |---|---:|---|---|
   | owner/repo | 4 | minor | 0.7.0 to 0.8.0 |
   | owner/repo | 2 | - | 0.0.2 (already bumped) |

   State the level for each bump and which commit drove it. Stop here when the
   user wants a different level, and pass the corrected `next_version` through
   step 6 unchanged. Do not proceed without approval.

6. Commit the bump onto `dev` for every `bump` row:

   ```bash
   .agents/skills/deploy/scripts/bump-version.sh <owner/repo> <file> <kind> <old> <new>
   ```

   The script reads the file from `dev` through the GitHub Contents API,
   replaces the single version line, refuses to commit when the diff is anything
   other than that one line, and pushes the commit
   `chore(release): <repo> v<new>` straight to `dev`. It prints the new commit
   SHA. No local checkout is touched.

   Then refresh the remote refs so the bump commit is visible locally:

   ```bash
   git -C <path> fetch --prune origin
   ```

   If a bump fails, mark the repository `failed: bump` and do not open or merge
   its PR. Leave the other repositories running.

7. For each repository with source-only commits:
   - Run every GitHub command with explicit `-R <owner/repo>`.
   - Find an existing open PR whose base is `deploy` and head is `dev`.

     ```bash
     gh pr list -R <owner/repo> --state open --base deploy --head dev \
       --json number,url
     ```

   - Reuse that PR when found. Never create a duplicate. A reused PR picks up the
     bump commit automatically because its head is `dev`.
   - Otherwise create:

     ```bash
     gh pr create -R <owner/repo> --base deploy --head dev \
       --title "Deploy dev to deploy" \
       --body "Promotes the current dev branch to deploy."
     ```

8. Validate PR before merge:
   - Confirm base is `deploy`, head is `dev`, state is open, and PR is mergeable.
   - Confirm the head commit includes the bump for versioned components.
   - Wait for required checks:

     ```bash
     gh pr checks -R <owner/repo> <pr> --required --watch --fail-fast
     ```

   - If no required checks are configured, continue.
   - If checks fail, PR conflicts, reviews are required, or protection blocks merge, leave PR open and mark `blocked`.

9. Merge eligible PR:

   ```bash
   gh pr merge -R <owner/repo> <pr> --merge
   ```

   Do not pass `--admin`, `--auto`, or `--delete-branch`.

10. Tag and release each merged versioned component. A tag without a release is
    not done: the client build workflow triggers on `release: published`, so a
    bare tag ships nothing. Always end this step with a release that exists.

    Refresh refs including tags, then check the release and the tag separately:

    ```bash
    git -C <path> fetch --prune --tags --force origin
    gh release view -R <owner/repo> v<new> --json tagName   # release present?
    git -C <path> rev-parse -q --verify refs/tags/v<new>    # tag present?
    git -C <path> rev-parse origin/deploy                   # what deploy points at
    ```

    Then take exactly one branch:

    - Release exists: mark `released: existing`, create nothing.
    - No release, no tag: create both on the tip of `deploy`.

      ```bash
      gh release create -R <owner/repo> v<new> \
        --target "$(git -C <path> rev-parse origin/deploy)" \
        --title "<path> v<new>" \
        --generate-notes
      ```

    - No release, tag already points at the tip of `deploy`: create the release
      on the existing tag. Omit `--target`; it is ignored for an existing tag.

      ```bash
      gh release create -R <owner/repo> v<new> \
        --title "<path> v<new>" \
        --generate-notes
      ```

    - No release, tag points at a different commit: report `blocked: tag exists`.
      Never move or delete the tag.

    Verify before reporting success:

    ```bash
    gh release view -R <owner/repo> v<new> --json tagName,isDraft,publishedAt
    ```

    - A missing release, or one with `isDraft: true` or a null `publishedAt`,
      counts as a failure, not a success: the build workflow never fires.
    - Tag name is always `v<version>`, matching the version file value.
    - Never tag a repository whose merge was `blocked` or `failed`.
    - A release failure after a successful merge is reported as
      `merged, release failed: <reason>`. It never rolls back the merge.
    - Before the final report, re-check every versioned repository that carries a
      tag from an earlier promotion but no matching release, and backfill it
      through the existing-tag branch above. Report each backfill as
      `released: backfilled v<version>`.

11. Report one row per repository:

    | Repository | Commits | Version | PR | Result |
    |---|---:|---|---|---|
    | owner/repo | 3 | 0.7.0 to 0.8.0 | URL | merged, released v0.8.0 |
    | owner/repo | 1 | - | URL | merged |
    | owner/repo | 0 | - | - | skipped: up to date |
    | owner/repo | - | - | - | skipped: missing deploy |
    | owner/repo | 2 | 0.1.0 to 0.1.1 | URL | blocked: checks failed |

    End with totals for `merged`, `released`, `skipped`, `blocked`, and `failed`.

## Failure Handling

- `fetch` network failure: retry once with escalated execution when sandbox networking is likely responsible.
- GitHub auth failure: retry with user session credentials through escalated execution.
- Ambiguous multiple matching PRs: do not merge; report `blocked`.
- Bump rejected because the version line is missing, duplicated, or the diff is
  larger than one line: report the exact script error and skip that repository.
  Never edit the file by hand to work around it.
- Contents API `409` or `422 sha mismatch`: someone pushed to `dev` between the
  plan and the bump. Re-run `plan-versions.sh` for that repository and retry once.
- Merge command failure: refresh PR state once, report exact GitHub reason, continue to next repository.
- Tag name already taken by a different commit: report `blocked: tag exists`, and
  do not move or delete the existing tag.
- `release create` refusing with `tag already exists`: the `--target` was passed
  for a tag that is already on the remote. Retry once without `--target`.
- Release created but `gh release view` reports it as a draft: publish it with
  `gh release edit -R <owner/repo> v<new> --draft=false`. `release: published`
  never fires for a draft.
