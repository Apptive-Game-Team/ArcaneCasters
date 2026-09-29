---
name: adventure-authoring
description: Design and add an adventure (PVE campaign) to ArcaneCasters — stages, scenarios, enemy waves, boss phases, win conditions, dialogue, rewards, and the battle scene theme — with balance checked against the player's mana income. Use when asked to make, add, rework, rebalance, or review an adventure, stage, scenario, PVE level, boss fight, or wave, or when an adventure "is boring".
---

# Adventure Authoring

One adventure touches three repositories: rows in the shared game database, story
and theme assets in the Unity client, and nothing in the servers unless the
design needs a building block the engine does not have yet. This skill is the
order to do it in and the numbers to check it against.

Read [references/engine.md](references/engine.md) before designing: it lists every
trigger, action, and win condition the game server understands, with the columns
each one needs. A design that needs something outside that list is an engine
change in `game/` first, not a content change.

## What an adventure is

```
adventures (id, name, access_type)            one card in the adventure list
  stages (id, adventure_id)                    one reward; one panel in the client
    scenarios (id, stage_id)                   one match
      pve_scenario_installers                  enemy structures present at start
      pve_scenario_objectives                  installers that must die to win
      pve_scenario_rules                       win condition (optional row)
      pve_scenario_events -> _event_lines      triggers + in-match speech
                          -> _event_actions    waves, late structures, boss phases
quests (stage_clear_pc) + reward_params        the reward for clearing stages
```

The lobby unlocks the lowest scenario id of every `FREE` adventure, then each
next scenario id inside the same adventure once the previous one is `FINISHED`
(`lobby` `UserScenarioRepository`). So scenario ids must increase in play order,
and stage ids must increase with them.

## Design rules

These exist because the first adventure broke most of them: four matches,
each "destroy one static structure", one reward at the very end.

1. **Size follows the story.** An adventure ends at the boss its story builds
   to; do not pad it with stages after that. The forest is one stage of four
   matches ending at the vine witch, the fortress two stages of three. A
   scenario lasts 90–180 seconds. The map shows one node per scenario.
2. **One new thing per scenario.** Each scenario introduces exactly one element
   the player has not seen in this adventure — a unit type, a trigger reaction,
   a second structure, a win condition — and keeps the earlier ones. Write the
   new element down next to each scenario in the design table; if a row has
   none, cut or merge that scenario.
3. **Vary the win condition.** At least one `Survive` scenario per adventure,
   and at least one scenario with two objectives or an objective installed
   mid-match (`InstallObject`).
4. **Shape every scenario the same way:** a calm opening (0–15 s: one line of
   speech, at most one small wave), pressure (timed waves), a peak (a boss
   phase or the largest wave), and a finish. After any wave above pressure 1.5,
   give 10 seconds with no new wave.
5. **Bosses get phases.** The last scenario of every stage has a boss with at
   least two `InstallerHpPercentLte` events (for example at 60 and 30). Each
   phase changes the boss's spawner (`SetSpawner`), adds a wave, and says one
   line. The adventure's final boss also gets a phase that installs a new
   structure.
6. **Use the lanes.** The enemy side is x = 14; lanes are z = 3, 5, 7. Over one
   scenario, waves use at least two lanes. Never send two consecutive waves
   down the same lane in the last scenario of a stage.
7. **Reward per stage, not per adventure.** One quest per stage (see Rewards).
8. **One line per event.** The in-match bubble shows only the last line of an
   event and stays 3.5 seconds, so a two-line event hides its first line. Put
   each line in its own event, at least 4 seconds apart.
9. **Check what a borrowed structure attacks.** Player-magic buildings used as
   enemy structures keep their own targeting: `GroundTower` hits only air units
   and never the player's ground army, while `GroundCannon` and `RockTurret`
   hit ground. Read the prefab initializer's `TargetMask` before placing one.
   Their lifetime (`TimedSelfDestroyer`) is removed by the engine for scenario
   structures, so an objective never expires on its own.
10. **Theme.** Every adventure names a battle theme; forest is the default.
   Enemies should fit it or the story should explain them (the fortress
   adventure's story is that the witch's vines took the fortress).

## Balance

Measure enemy pressure against what the player can spend.

- The player earns **4 mana per second** (`ManaCharger`: 1 mana every 0.25 s),
  capped at **120**, and has **1000 hp** (`player` parameters).
- A unit's value is its `mana_cost / quantity`. Units nobody casts directly
  (slimes, tadpoles, spirits from nests) use the table in
  `scripts/adventure-check.py` — about 3 mana for a 20 hp slime.
- **Pressure** is the value of the waves arriving in a 30 second window divided
  by the player's 120 mana income over that window.

| Scenario position | Pressure band | Boss hp (`max_hp`) |
|---|---|---|
| first scenario of the adventure | 0.45 – 0.75 | 800 – 1300 |
| middle scenarios | 0.75 – 1.2 | 1300 – 2000 |
| last scenario of a stage | 1.2 – 1.5, peaks to 1.8 | 2000 – 2600 |
| final scenario of the adventure | 1.2 – 1.5, one peak ≤ 2.0 for ≤ 20 s | 2600 – 3300 |

These bands were raised by half on 2026-09-29 after the first playtest found
the original ones (0.3 – 1.3) far too easy with a starter deck. Treat them as
the floor, not the target, until more playtests say otherwise.

The adventure after this one starts again near the bottom band: a new
adventure is chosen freely from the list, so it must not assume the player
cleared another one.

Tune difficulty with wave count, timing, lane, and boss `max_hp`. Never change a
unit's parameters for an adventure: parameters are shared with PVP, and the live
values diverge from migrations (read them from the test-env clone, not from
old migration files).

The boss prefabs also run a spawner built into their Java initializer from the
start of the match; count it in the pressure:

| Prefab | Built-in spawner |
|---|---|
| `PveNatureSlimeNest` | 1 `LeafSlime` every 10 s |
| `PveWaterSlimeNest` | 1 `WaterSlime` every 10 s |
| `PveVineColony` | 2 of one random `LeafSlime`/`WaterSlime`/`VineSpirit` every 10 s |
| `PveVineWitch` | 2 of one random `LeafSlime`/`WaterSlime`/`VineSpirit` every 8 s; casts `vine_toss`, `vine_colony`, `vinefan` |

A `SetSpawner` with `count = 0` switches the built-in spawner off, which is how a
scenario takes full control of its pressure.

## Rewards

`stage_clear_pc` counts every fully finished stage across **all** adventures
(`lobby` `UserScenarioRepository.countFinishedStageByUserId`), so a quest with
`require_value = N` pays out on the player's N-th cleared stage, whichever
adventure it was in. Add one quest per new stage with `require_value` set to the
number of stages that exist once the migration lands, so the total stays
reachable. The reward is `magic_rg` with a `magic_id` in `reward_params`; pick
magics that fit the adventure's element and are not already quest rewards.

## Procedure

### 1. Design table first

Before any SQL, write the design as a table in the pull request description,
one row per scenario:

| id | stage | new element | win condition | structures (hp) | waves: time → units × count @ lane | phases | pressure peak |

Check it against every design rule above. Rule 2 is the one that fails most.

### 2. Database migration

Follow `database/AGENTS.md` and its workflow document. One migration per
adventure, numbered unique across both tracks (`AGENTS.md` section 8). Start
from [references/migration-template.sql](references/migration-template.sql):
explicit ids for adventures, stages, scenarios, and quests; subqueries on
`event_id` for action rows; `setval` on every sequence you inserted into.
Reworking an existing adventure deletes that adventure's scenario content rows
and re-inserts them; keep the `scenarios` ids so player progress survives.

### 3. Client

Follow `client/AGENTS.md`, especially `hand-edited-assets.md` and
`localization.md` — the Editor cannot run here.

- `Assets/ScriptableObject/Adventures/<Name>Adventure.asset`: `adventureId`
  matching the database, `iconImage`, `adventureName`, `stages`, `battleTheme`.
- One `AdventureStageScriptableObject` per stage: `stageId`, `backgroundImage`,
  `stageName`, and `scenarioStories` for the story shown before each scenario
  (portraits and localized lines, both languages).
- **A stage-select map for every new adventure.** The adventure map screen
  (`AdventureMapController`) shows the first stage's `backgroundImage` as an
  867×256 banner and puts one node per stage at fixed normalized waypoints
  `(0.24, 0.70)`, `(0.42, 0.70)`, `(0.58, 0.70)`, `(0.71, 0.58)`. Draw a new
  banner in the adventure's theme at that size, with a road that passes under
  those waypoints, and check it by compositing node circles on it before
  committing. Reusing another adventure's banner makes every adventure look
  like the first one. Save it under `Assets/Art/Images/Adventure/`.
- The map node is one stage, and its play button starts the stage's first
  unfinished scenario; the caption shows how many of the stage's scenarios are
  cleared.
- Localization rows for the adventure name and every story line, in both the
  English and Korean `Adventure` tables.
- Battle theme: reuse a `BattleThemeScriptableObject` under
  `Assets/ScriptableObject/BattleThemes/`, or make a new one. New theme art
  must match the forest set's canvas sizes and bottom-center pivots listed in
  `.art/concept/field-environment-prompts/README.md`; the 271 prop placements in
  `GameScene.unity` are shared by every theme and tuned to those sizes. Use the
  client's `make-game-art` skill to generate it.

In-match speech is localized on the client by the event's `message_key`
(`pve_<scenario>_<event_id>`): `PveScriptEventHandler` looks the key up in the
`Adventure` string table and shows the server's `pve_scenario_event_lines` text
only when the key is missing. Add every new `message_key` to the `Adventure`
table in English and Korean; the server line stays as the English fallback.

### 4. Check

1. `database/scripts/ci/validate-migrations.sh origin/dev`.
2. Bring the migration up on a clone with the `test-env` skill
   (`.agents/skills/test-env/SKILL.md`), then run
   `.agents/skills/adventure-authoring/scripts/adventure-check.py <adventure_id>`
   from the monorepo root checkout (it reads `.db.env`, including
   `LOCAL_INSTANCE`, and the `game` submodule from there). It fails on references that would make a scenario unwinnable or crash the
   loader, and prints each scenario's pressure per 30 seconds; compare it to
   the band table and fix the design before moving on.
3. Play every scenario once against the test-env game server with a starter
   deck, through the client. There is no headless shortcut yet: the game
   server's `POST /api/server/game-sessions` needs a `WORDONLINE_SERVER` JWT
   issued by the account server, which test-env does not mint. Record the clear time and the lowest player hp for each in the pull
   request. A scenario cleared in under 60 seconds or lost twice with a starter
   deck is out of band.

### 5. Pull requests

One draft pull request per repository (database, client), each linking the
other, with the design table and the check results in both. Never mark them
ready and never merge them.
