-- Template for one adventure. Copy into database/migration/V<NNN>_<yyyymmdd>__add_<name>_adventure.sql
-- and replace every <...>. Ids are explicit so the client assets and quests can name them;
-- pick ids above the current maximum of each table on origin/dev.

-- 1. Adventure, stages, scenarios. Scenario ids increase in play order (the lobby unlocks by id).
INSERT INTO adventures (id, name, access_type) VALUES (<adventure_id>, '<name>', 'FREE');

INSERT INTO stages (id, adventure_id) VALUES
    (<stage_1>, <adventure_id>),
    (<stage_2>, <adventure_id>);

INSERT INTO scenarios (id, stage_id) VALUES
    (<scenario_1>, <stage_1>),
    (<scenario_2>, <stage_1>),
    (<scenario_3>, <stage_1>);

-- 2. One block per scenario.
INSERT INTO pve_scenario_installers
    (installer_id, prefab_type, master, position_x, position_y, position_z, max_hp, sort_order, scenario_id)
VALUES
    ('boss', 'PveNatureSlimeNest', 'RightPlayer', 14, 0, 5, 800, 1, <scenario_1>);

INSERT INTO pve_scenario_objectives (installer_id, sort_order, scenario_id) VALUES
    ('boss', 1, <scenario_1>);

-- Survive scenarios only:
-- INSERT INTO pve_scenario_rules (scenario_id, win_condition, survive_seconds) VALUES (<scenario_n>, 'Survive', 120);

INSERT INTO pve_scenario_events
    (event_id, trigger_type, trigger_value, target_installer_id, speaker_installer_id, message_key, sort_order, scenario_id)
VALUES
    ('intro',       'SecondsGte',            1,  NULL,   'boss', 'pve_<name>_1_intro',  1, <scenario_1>),
    ('wave_1',      'SecondsGte',            20, NULL,   NULL,   NULL,                  2, <scenario_1>),
    ('phase_2',     'InstallerHpPercentLte', 50, 'boss', 'boss', 'pve_<name>_1_phase2', 3, <scenario_1>);

-- One line per event: the client only shows an event's last line.
INSERT INTO pve_scenario_event_lines (event_row_id, line_order, line_text)
SELECT e.id, 1, v.line_text
FROM (VALUES
    ('intro',   '<first line>'),
    ('phase_2', '<phase line>')
) AS v(event_id, line_text)
JOIN pve_scenario_events e ON e.event_id = v.event_id AND e.scenario_id = <scenario_1>;

INSERT INTO pve_scenario_event_actions
    (event_row_id, action_order, action_type, installer_id, prefab_type, count, interval_seconds, position_x, position_z, max_hp)
SELECT e.id, v.action_order, v.action_type, v.installer_id, v.prefab_type, v.count, v.interval_seconds,
       v.position_x, v.position_z, v.max_hp
FROM (VALUES
    ('wave_1',  1, 'SpawnWave', NULL,   'LeafSlime',  4, NULL::real, 14, 3, NULL::int),
    ('phase_2', 1, 'SetSpawner', 'boss', 'VineSpirit', 1, 12,         NULL, NULL, NULL),
    ('phase_2', 2, 'SpawnWave', NULL,   'LeafSlime',  6, NULL,       14, 7, NULL)
) AS v(event_id, action_order, action_type, installer_id, prefab_type, count, interval_seconds,
       position_x, position_z, max_hp)
JOIN pve_scenario_events e ON e.event_id = v.event_id AND e.scenario_id = <scenario_1>;

-- 3. Rewards: one stage_clear quest per stage. require_value is the global count of cleared
-- stages, so use the total number of stages that exist after this migration, counting up.
INSERT INTO quests (id, progress_checker, require_value, reward_giver, access_type) VALUES
    (<quest_1>, 'stage_clear_pc', <n_stages_before + 1>, 'magic_rg', 'DEFAULT');
INSERT INTO reward_params (quest_id, name, value) VALUES
    (<quest_1>, 'magic_id', <magic_id>);

-- 4. Sequences for every table inserted into with explicit ids or defaults.
SELECT setval('adventures_id_seq', (SELECT max(id) FROM adventures));
SELECT setval('stages_id_seq', (SELECT max(id) FROM stages));
SELECT setval('scenarios_id_seq', (SELECT max(id) FROM scenarios));
SELECT setval('quests_id_seq', (SELECT max(id) FROM quests));
