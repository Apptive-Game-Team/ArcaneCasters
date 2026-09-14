# Agent Instructions for the WordOnline Monorepo

This repository is a multi-module monorepo composed of Git submodules. Agents working in this repository must follow the repository-level rules below and the module-specific instructions for the target component.

## 1. Scope and Instruction Precedence

Before making changes:

1. Identify the module that owns the requested behavior.
2. Change the working directory to that module.
3. Read the module's `AGENTS.md` and `CLAUDE.md` files when present.
4. Follow module-specific build commands, coding conventions, branch rules, skills, and documentation.

Module-specific instructions supplement this file. When instructions conflict, the more specific instruction for the target module takes precedence.

## 2. Module Map

- `client/`: Unity web and desktop client
- `game/`: Spring Boot in-game server
- `lobby/`: Spring Boot matchmaking and lobby server
- `account/`: Spring Boot authentication and key-value server
- `admin/`: Spring Boot administration web server
- `website/`: React and Vite web frontend
- `database/`: Flyway database migrations
- `infra/`: Deployment and runtime configuration for the servers (private repository)

Keep changes within the owning module unless the task requires an explicit cross-module contract change.

## 3. Graphify Knowledge Graph

This repository maintains a Graphify knowledge graph in `graphify-out/`. Use it as the primary navigation and architecture-discovery source when the graph is available.

### Required Workflow

- When `/graphify` is invoked, load the `graphify` skill before performing other work.
- For codebase or architecture questions, if `graphify-out/graph.json` exists, run `graphify query "<question>"` before manually searching the repository.
- To inspect a concept and its immediate relationships, run `graphify explain "<concept>"`.
- To trace the shortest relationship between two concepts, run `graphify path "<A>" "<B>"`.
- After modifying code, run `graphify update .` from the repository root to refresh the deterministic AST graph. This update does not require additional LLM extraction.

Treat Graphify output as navigational evidence, not a substitute for validating relevant source files before editing.

## 4. Security

- Never commit `.env` files from the repository root or any submodule.
- When environment-related files change, verify the applicable root or module-level `.gitignore`.
- Never expose credentials, tokens, private endpoints, or other secrets in source, logs, tests, documentation, or generated artifacts.

## 5. Submodule Change Management

Each submodule has an independent Git history. For submodule changes:

1. Commit and push changes from within the submodule.
2. Return to the monorepo root.
3. Update and commit the submodule pointer in the parent repository.

Do not commit a parent-repository submodule pointer that references an unpublished submodule commit.

### The magic-card branch

On this branch, `game`, `lobby`, `client`, `database`, and `admin` track their own `magic-card` branch instead of `main`. `.gitmodules` records `branch = magic-card` for those five, so `git submodule update --remote` follows it. Update and commit the pointer here every time a submodule pull request merges into that submodule's `magic-card`.

`account`, `website`, and `infra` are not part of the redesign and keep pointing at `main`.

This configuration exists only on the `magic-card` branch. Do not carry it to `main`. See [`docs/magic-card.md`](docs/magic-card.md).

## 6. Component Versioning

Deployable components use independent Semantic Versions:

- `game/build.gradle`: game server
- `lobby/build.gradle`: lobby server
- `account/build.gradle`: account server
- `admin/build.gradle`: admin server
- `client/ProjectSettings/ProjectSettings.asset` (`bundleVersion`): Unity client

Do not bump a version in a feature pull request. Every version bump happens once
per promotion, in the `deploy` skill: it commits `chore(release): <repo> vX.Y.Z`
to `main`, merges `main` into `deploy`, then tags and releases `vX.Y.Z` on the
merge commit. Bumping per pull request produced constant conflicts on the same
version line, so the single bump per release replaced it.

The `deploy` skill derives the level from the Conventional Commit messages
promoted in that release: MAJOR for a `!` marker or a `BREAKING CHANGE` trailer,
MINOR for `feat:`, PATCH otherwise. Write accurate commit types; they are the
only input to the released version number.

Do not use `-SNAPSHOT` for deployable versions. Server builds embed their Gradle
version through Spring Boot build info; do not maintain a second version value.

## 7. Branch Tracks

`main` and `magic-card` are two long-lived tracks that exist in every repository
of this workspace. They are not merged into each other, in either direction.
`magic-card` will not land on `main`.

- Work on the track the request targets. Branch from it, open the pull request
  against it, and stack on that track's open chain.
- A feature both tracks need is built twice, against each track's own data
  model, rather than cherry-picked across. The two models differ: `magic-card`
  drops `magics.cast_type`, adds `element`, `cast_kind` and `prefab`, and moves
  ownership onto magics, while `main` keeps cards and recipes. A file written
  for one track does not apply on the other.
- Something already built on `magic-card` is not available to `main`. When
  `main` needs it, write it again for `main`'s model.
- The worked example is the aim indicator document: WordOnlineDatabase V090
  (magic-card) and V091 (main), WordOnlineClient #657 and #661, root #30 and
  #32. Each pair carries the same contract against a different chain.
- WordOnlineDatabase migration numbers must be unique across **both** tracks.
  The validation workflow only compares a pull request against its own base
  branch, so a number that passes on one track can still collide on the other.
- The redesign's design notes live on the root `magic-card` branch
  (`docs/magic-card.md`, `.plan/issues/2026-09-08-issue-23-magic-card-redesign.md`).
  `main` carries no copy, so read them from that branch.
