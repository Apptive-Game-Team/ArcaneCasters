# PVE engine vocabulary

What the game server reads for one scenario (`game` `PveScenarioRepository`),
and what each value does. Anything not listed here needs a game server change.

## Structures present at start — `pve_scenario_installers`

| column | meaning |
|---|---|
| `installer_id` | name used by objectives, events, and actions in this scenario |
| `prefab_type` | a `PrefabType` enum name; bosses are `PveNatureSlimeNest`, `PveWaterSlimeNest`, `PveVineColony`, `PveVineWitch`, but any unit or building works |
| `master` | always `RightPlayer` for enemies |
| `position_x`, `position_y`, `position_z` | enemy side is x = 14, y = 0, lanes z = 3, 5, 7 |
| `max_hp` | NULL keeps the prefab's `hp` parameter; a value overrides it for this installer only |
| `sort_order` | install order |

A scenario with no installer row fails to load.

## Win condition — `pve_scenario_rules` (optional, one row per scenario)

| `win_condition` | cleared when |
|---|---|
| `DestroyObjectives` (default when there is no row) | every installer in `pve_scenario_objectives` is destroyed |
| `Survive` | `survive_seconds` have passed with the player alive; objectives are ignored |

The player loses when their master dies, in every scenario.

Objectives are looked up by installer id on every check, so an objective that
an `InstallObject` action creates later works. An objective that is never
installed makes the scenario unwinnable.

## Events — `pve_scenario_events`

Every event fires at most once, checked every frame in `sort_order`. When it
fires, its speech is sent (if it has lines) and then its actions run in
`action_order`.

| `trigger_type` | fires when | `trigger_value` | `target_installer_id` |
|---|---|---|---|
| `FrameNumGte` | frame number ≥ value (20 frames per second) | frames | — |
| `SecondsGte` | elapsed seconds ≥ value | seconds | — |
| `InstallerHpPercentLte` | the target's hp ≤ value % of its max, while alive | 1–100 | required |
| `InstallerDestroyed` | the target is destroyed | 0 | required |

An event whose target is not installed yet waits.

`speaker_installer_id` puts the speech bubble over that structure. `message_key`
is required when the event has lines and may be NULL for an action-only event.
Lines live in `pve_scenario_event_lines` (`line_order`, `line_text`); the client
shows only the last line of an event, so use one line per event.

## Actions — `pve_scenario_event_actions`

Every object an action creates belongs to `RightPlayer`.

| `action_type` | effect | columns |
|---|---|---|
| `SpawnWave` | spawn `count` × `prefab_type` at (`position_x`, `position_z`), 0.5 apart on x | `prefab_type`, `count`, `position_x`, `position_z` |
| `InstallObject` | install a new structure under `installer_id`; later events, speakers, and objectives can name it | `installer_id`, `prefab_type`, `position_x`, `position_z`, optional `max_hp` |
| `SetSpawner` | replace the periodic spawner on `installer_id` with `count` × `prefab_type` every `interval_seconds`; `count = 0` removes it | `installer_id`, `count`, and `prefab_type` + `interval_seconds` when `count > 0` |

Wave units keep their normal parameters, shared with PVP. Difficulty comes from
count, timing, lane, and structure `max_hp`.
