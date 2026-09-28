#!/usr/bin/env python3
"""Lint one adventure's PVE rows and print a pressure timeline per scenario.

Reads the test-env Postgres clone through `docker exec`, so run it after
`.agents/skills/test-env/scripts/testenv.sh up` (or `migrate`) has applied the
migration under review. The host needs no psql.

    .agents/skills/adventure-authoring/scripts/adventure-check.py <adventure_id>

Exit status 1 when any lint error is found. Warnings do not fail the run.
"""

import csv
import io
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

PG_CONTAINER = "wordonline-testenv-db"

# Player economy, from the game server: ManaCharger adds 1 mana every 0.25 s,
# and the `player` parameters hold max_mana 120 and hp 1000.
PLAYER_MANA_PER_SECOND = 4.0

# Units a player never casts directly have no mana_cost row. Price them by the
# magic that produces them, divided by how many bodies one cast makes.
FALLBACK_UNIT_VALUE = {
    "leaf_slime": 3, "water_slime": 3, "fire_slime": 3, "rock_slime": 3,
    "electric_slime": 3, "wind_slime": 4, "slime": 3,
    "ember_spirit": 6, "seed_spirit": 8, "fire_child_spirit": 12,
    "fire_tadpole": 5, "lightning_tadpole": 5, "mini_rock": 12,
}

# Pressure bands, as a share of the player's mana income. See SKILL.md.
PEAK_WARN = 1.3

VALID_TRIGGERS = {"FrameNumGte", "SecondsGte", "InstallerHpPercentLte", "InstallerDestroyed"}
TARGETED_TRIGGERS = {"InstallerHpPercentLte", "InstallerDestroyed"}
FPS = 20


def load_db_env():
    root = Path(__file__).resolve().parents[4]
    env = {"LOCAL_DB_NAME": "wordonline_test", "LOCAL_DB_USER": "wordonline",
           "LOCAL_DB_PASSWORD": "wordonline"}
    path = root / ".db.env"
    if path.exists():
        for line in path.read_text().splitlines():
            m = re.match(r"\s*([A-Z_]+)=(.*)", line)
            if m and m.group(1) in env:
                env[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return env


def query(env, sql):
    out = subprocess.run(
        ["docker", "exec", "-i", "-e", f"PGPASSWORD={env['LOCAL_DB_PASSWORD']}", PG_CONTAINER,
         "psql", "-U", env["LOCAL_DB_USER"], "-d", env["LOCAL_DB_NAME"],
         "-v", "ON_ERROR_STOP=1", "--csv", "-c", sql],
        check=True, capture_output=True, text=True).stdout
    return list(csv.DictReader(io.StringIO(out)))


def snake(prefab_type):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", prefab_type).lower()


def prefab_types():
    """PrefabType names from the game server source on origin/dev."""
    game = Path(__file__).resolve().parents[4] / "game"
    path = "src/main/java/com/wordonline/server/game/domain/object/prefab/PrefabType.java"
    try:
        src = subprocess.run(["git", "-C", str(game), "show", f"origin/dev:{path}"],
                             check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError:
        return None
    return set(re.findall(r"^\s*([A-Z][A-Za-z0-9]*)\(\"", src, re.M))


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        sys.exit(__doc__)
    adventure_id = int(sys.argv[1])
    env = load_db_env()

    scenarios = query(env, f"""
        SELECT sc.id AS scenario_id, st.id AS stage_id
        FROM scenarios sc JOIN stages st ON st.id = sc.stage_id
        WHERE st.adventure_id = {adventure_id} ORDER BY st.id, sc.id""")
    if not scenarios:
        sys.exit(f"adventure {adventure_id} has no scenarios")
    ids = ",".join(s["scenario_id"] for s in scenarios)

    installers = query(env, f"SELECT * FROM pve_scenario_installers WHERE scenario_id IN ({ids})")
    objectives = query(env, f"SELECT * FROM pve_scenario_objectives WHERE scenario_id IN ({ids})")
    events = query(env, f"SELECT * FROM pve_scenario_events WHERE scenario_id IN ({ids}) ORDER BY sort_order")
    lines = query(env, f"""SELECT l.event_row_id, count(*) AS n FROM pve_scenario_event_lines l
        JOIN pve_scenario_events e ON e.id = l.event_row_id
        WHERE e.scenario_id IN ({ids}) GROUP BY l.event_row_id""")
    actions = query(env, f"""SELECT a.*, e.scenario_id FROM pve_scenario_event_actions a
        JOIN pve_scenario_events e ON e.id = a.event_row_id
        WHERE e.scenario_id IN ({ids}) ORDER BY a.event_row_id, a.action_order""")
    rules = {r["scenario_id"]: r for r in query(
        env, f"SELECT * FROM pve_scenario_rules WHERE scenario_id IN ({ids})")}
    params = query(env, """SELECT g.name AS object, p.name AS param, v.value
        FROM parameter_values v JOIN parameters p ON p.id = v.parameter_id
        JOIN game_objects g ON g.id = v.game_object_id
        WHERE p.name IN ('mana_cost', 'quantity', 'hp')""")

    stats = defaultdict(dict)
    for p in params:
        if p["value"] not in ("", None):
            stats[p["object"]][p["param"]] = float(p["value"])

    def unit_value(prefab):
        name = snake(prefab)
        s = stats.get(name, {})
        if "mana_cost" in s and s["mana_cost"] > 0:
            return s["mana_cost"] / max(1.0, s.get("quantity", 1.0))
        return FALLBACK_UNIT_VALUE.get(name)

    known_prefabs = prefab_types()
    line_count = {l["event_row_id"]: int(l["n"]) for l in lines}
    errors, warnings = [], []

    for sc in scenarios:
        sid = sc["scenario_id"]
        tag = f"scenario {sid} (stage {sc['stage_id']})"
        sc_inst = [i for i in installers if i["scenario_id"] == sid]
        sc_obj = [o for o in objectives if o["scenario_id"] == sid]
        sc_evt = [e for e in events if e["scenario_id"] == sid]
        sc_act = [a for a in actions if a["scenario_id"] == sid]
        rule = rules.get(sid, {"win_condition": "DestroyObjectives", "survive_seconds": ""})

        installed = {i["installer_id"] for i in sc_inst}
        late = {a["installer_id"] for a in sc_act if a["action_type"] == "InstallObject"}
        every = installed | late

        if not sc_inst:
            errors.append(f"{tag}: no installer row; the game server rejects the scenario")
        for pref in [i["prefab_type"] for i in sc_inst] + [a["prefab_type"] for a in sc_act if a["prefab_type"]]:
            if known_prefabs is not None and pref not in known_prefabs:
                errors.append(f"{tag}: prefab_type {pref} is not a PrefabType name")
        for o in sc_obj:
            if o["installer_id"] not in every:
                errors.append(f"{tag}: objective {o['installer_id']} is never installed; the scenario cannot be won")
        if rule["win_condition"] == "DestroyObjectives" and not sc_obj:
            errors.append(f"{tag}: DestroyObjectives with no objective rows")
        if rule["win_condition"] == "Survive" and sc_obj:
            warnings.append(f"{tag}: Survive ignores its {len(sc_obj)} objective rows")

        for e in sc_evt:
            if e["trigger_type"] not in VALID_TRIGGERS:
                errors.append(f"{tag}: event {e['event_id']} has unknown trigger {e['trigger_type']}")
            if e["trigger_type"] in TARGETED_TRIGGERS and e["target_installer_id"] not in every:
                errors.append(f"{tag}: event {e['event_id']} watches {e['target_installer_id']}, which is never installed")
            if e["speaker_installer_id"] and e["speaker_installer_id"] not in every:
                warnings.append(f"{tag}: event {e['event_id']} speaker {e['speaker_installer_id']} is never installed")
            has_lines = line_count.get(e["id"], 0) > 0
            has_actions = any(a["event_row_id"] == e["id"] for a in sc_act)
            if not has_lines and not has_actions:
                warnings.append(f"{tag}: event {e['event_id']} has no lines and no actions")
            if has_lines and not e["message_key"]:
                errors.append(f"{tag}: event {e['event_id']} has lines but no message_key")

        for a in sc_act:
            t = a["action_type"]
            if t == "SpawnWave" and not (a["prefab_type"] and a["count"] and a["position_x"] and a["position_z"]):
                errors.append(f"{tag}: SpawnWave {a['id']} needs prefab_type, count, position_x, position_z")
            if t == "InstallObject" and not (a["installer_id"] and a["prefab_type"] and a["position_x"] and a["position_z"]):
                errors.append(f"{tag}: InstallObject {a['id']} needs installer_id, prefab_type, position")
            if t == "SetSpawner":
                if a["installer_id"] not in every:
                    errors.append(f"{tag}: SetSpawner {a['id']} targets {a['installer_id']}, which is never installed")
                if a["count"] and int(a["count"]) > 0 and not (a["prefab_type"] and a["interval_seconds"]):
                    errors.append(f"{tag}: SetSpawner {a['id']} with count > 0 needs prefab_type and interval_seconds")
            if a["prefab_type"] and t != "InstallObject" and unit_value(a["prefab_type"]) is None:
                warnings.append(f"{tag}: no value for {a['prefab_type']}; add it to FALLBACK_UNIT_VALUE")

        # Pressure timeline: SpawnWave actions on timed triggers, in 30 s buckets.
        # Hp and destroy triggers depend on the player, so they are listed apart.
        buckets, reactive = defaultdict(float), []
        evt_by_row = {e["id"]: e for e in sc_evt}
        for a in sc_act:
            if a["action_type"] != "SpawnWave":
                continue
            value = (unit_value(a["prefab_type"]) or 0) * int(a["count"] or 0)
            e = evt_by_row[a["event_row_id"]]
            if e["trigger_type"] == "SecondsGte":
                buckets[int(e["trigger_value"]) // 30] += value
            elif e["trigger_type"] == "FrameNumGte":
                buckets[int(e["trigger_value"]) // FPS // 30] += value
            else:
                reactive.append((e["event_id"], e["trigger_type"], e["target_installer_id"], e["trigger_value"], value))

        print(f"\n== {tag}: {rule['win_condition']}"
              + (f" {rule['survive_seconds']} s" if rule["win_condition"] == "Survive" else ""))
        for i in sc_inst:
            hp = i["max_hp"] or stats.get(snake(i["prefab_type"]), {}).get("hp", "?")
            print(f"   installer {i['installer_id']:<20} {i['prefab_type']:<22} hp {hp}"
                  f" at ({i['position_x']}, {i['position_z']})")
        income = PLAYER_MANA_PER_SECOND * 30
        for b in sorted(buckets):
            ratio = buckets[b] / income
            flag = "  <-- above peak band" if ratio > PEAK_WARN else ""
            print(f"   {b * 30:>4}-{b * 30 + 30:<4}s  waves worth {buckets[b]:6.0f} mana  pressure {ratio:4.2f}{flag}")
            if ratio > PEAK_WARN:
                warnings.append(f"{tag}: pressure {ratio:.2f} at {b * 30} s exceeds {PEAK_WARN}")
        for eid, ttype, target, val, value in reactive:
            print(f"   on {ttype} {target} {val}: waves worth {value:.0f} mana ({eid})")
        print("   (boss prefabs also run their built-in spawner; see SKILL.md)")

    print()
    for w in warnings:
        print(f"warning: {w}")
    for e in errors:
        print(f"error: {e}")
    print(f"\n{len(errors)} error(s), {len(warnings)} warning(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
