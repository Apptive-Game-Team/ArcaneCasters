#!/usr/bin/env bash
#
# How many concurrent bot sessions a game server holds at a given CPU and memory limit.
#
# One trial is one fresh container: it is started with BOT_AUTO_MATCH_TARGET_GAMES set to the
# candidate count, given time to fill and settle, and then its loop frame rate is sampled off
# the Prometheus endpoint. A trial passes while the mean loop frame rate stays at or above
# --fps-pass (the loops target 20). The script doubles the candidate until a trial fails and
# then binary searches between the last pass and the first failure.
#
# Requires: setup-db.sh has been run, and an image built from the tree under test.
#
# Usage: capacity-search.sh --image ac-loadtest-game:local [options]

set -euo pipefail

IMAGE="${IMAGE:-ac-loadtest-game:local}"
NETWORK="${NETWORK:-ac-loadtest}"
PG_CONTAINER="${PG_CONTAINER:-ac-loadtest-postgres}"
CONTAINER="${CONTAINER:-ac-loadtest-game}"
PUBLIC_KEY="${PUBLIC_KEY:-$HOME/dev/arcane-casters/keys/public.pem}"
CPUS="${CPUS:-1}"
MEMORY="${MEMORY:-1g}"
FPS_PASS="${FPS_PASS:-15}"
START="${START:-4}"
MAX="${MAX:-256}"
WARMUP="${WARMUP:-45}"
SAMPLE="${SAMPLE:-60}"
POLL="${POLL:-5}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
FILL_TIMEOUT="${FILL_TIMEOUT:-180}"
APP_PORT="${APP_PORT:-18080}"
MGMT_PORT="${MGMT_PORT:-18081}"
OUT="${OUT:-capacity-search.csv}"
SINGLE="${SINGLE:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --image)     IMAGE="$2";     shift 2 ;;
        --cpus)      CPUS="$2";      shift 2 ;;
        --memory)    MEMORY="$2";    shift 2 ;;
        --fps-pass)  FPS_PASS="$2";  shift 2 ;;
        --start)     START="$2";     shift 2 ;;
        --max)       MAX="$2";       shift 2 ;;
        --warmup)    WARMUP="$2";    shift 2 ;;
        --sample)    SAMPLE="$2";    shift 2 ;;
        --poll)      POLL="$2";      shift 2 ;;
        --out)       OUT="$2";       shift 2 ;;
        --single)    SINGLE=1;       shift 1 ;;
        --network)   NETWORK="$2";   shift 2 ;;
        --pg)        PG_CONTAINER="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

metric() { # metric <name>; prints the value or nothing
    curl -sf --max-time 5 "http://127.0.0.1:$MGMT_PORT/actuator/prometheus" 2>/dev/null \
        | awk -v name="$1" '$1 ~ "^"name"[{ ]" { print $NF; exit }'
}

stop_container() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }

start_container() { # start_container <target sessions>
    stop_container
    docker run -d --name "$CONTAINER" --network "$NETWORK" \
        --cpus="$CPUS" --memory="$MEMORY" \
        -p "$APP_PORT":8080 -p "$MGMT_PORT":8081 \
        -e PORT=8080 -e EXTERNAL_PORT=8080 -e PROTOCOL=http -e DOMAIN="$CONTAINER" \
        -e MANAGEMENT_PORT=8081 -e MAX_SESSIONS=100000 \
        -e DATABASE_URL="jdbc:postgresql://$PG_CONTAINER:5432/wordonline" \
        -e DATABASE_USER=loadtest -e DATABASE_PW=loadtest \
        -e DISCORD_WEBHOOK_URL= -e LOBBY_BASE_URL= -e JWT_FILE_PATH= \
        -e ACCOUNT_SERVER_URL=http://127.0.0.1:9 \
        -e JWT_PUBLIC_KEY="$(cat "$PUBLIC_KEY")" \
        -e BOT_AUTO_MATCH_ENABLED=true \
        -e BOT_AUTO_MATCH_TARGET_GAMES="$1" \
        -e BOT_AUTO_MATCH_CHECK_INTERVAL_MS=5000 \
        -e BOT_AUTO_MATCH_MAX_SESSIONS_PER_SWEEP="${SWEEP_CAP:-1000}" \
        -e WATCHDOG_CHECK_INTERVAL_MS=5000 \
        -e SESSION_STALL_CHECK_INTERVAL_MS=5000 \
        -e LOOP_FPS_SAMPLE_INTERVAL_MS=2000 \
        "$IMAGE" >/dev/null
}

alive() { [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; }

oom_killed() { [ "$(docker inspect -f '{{.State.OOMKilled}}' "$CONTAINER" 2>/dev/null)" = "true" ]; }

heap_exhausted() { docker logs "$CONTAINER" 2>&1 | grep -q "OutOfMemoryError"; }

mem_mb() { # container memory usage, MiB
    docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER" 2>/dev/null \
        | awk '{ sub(/\/.*/, "", $0); n = $0 + 0
                 if ($0 ~ /GiB/) n *= 1024; else if ($0 ~ /KiB/) n /= 1024
                 printf "%.0f", n }'
}

# Globals a trial reports through.
T_VERDICT=; T_MEAN=; T_P10=; T_WORST=; T_SESSIONS=; T_MEM=; T_STALLED=; T_NOTE=

trial() { # trial <target sessions>
    local target="$1" waited=0 value samples=0 sum=0 p10_sum=0 worst=999 sess_sum=0 stalled_max=0
    T_VERDICT=fail; T_MEAN=0; T_P10=0; T_WORST=0; T_SESSIONS=0; T_MEM=0; T_STALLED=0; T_NOTE=

    echo "--- trial: $target sessions, cpus=$CPUS memory=$MEMORY"
    start_container "$target"

    while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
        curl -sf --max-time 5 "http://127.0.0.1:$MGMT_PORT/actuator/health" 2>/dev/null | grep -q '"UP"' && break
        alive || { T_NOTE="container exited during boot"; return; }
        sleep 3; waited=$((waited + 3))
    done
    if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then T_NOTE="boot timeout"; return; fi
    echo "    booted in ${waited}s, filling"

    # The scheduler tops the server up to the target every five seconds; sessions also end on
    # their own, so the count is only ever approximately the target.
    local filled=0
    waited=0
    while [ "$waited" -lt "$FILL_TIMEOUT" ]; do
        value=$(metric wordonline_loop_sessions); value=${value:-0}
        awk -v v="$value" -v t="$target" 'BEGIN { exit !(v >= 0.9 * t) }' && { filled=1; break; }
        alive || { T_NOTE="container died while filling"; return; }
        sleep 5; waited=$((waited + 5))
    done
    [ "$filled" = 1 ] || T_NOTE="fill timeout (reached ${value:-0})"
    echo "    sessions: ${value:-0} after ${waited}s, warming up ${WARMUP}s"

    sleep "$WARMUP"
    alive || { T_NOTE="container died during warmup"; return; }

    # Only stalls in the settled window count. Creating the whole target in one scheduler tick
    # is an artefact of the harness, and the burst it causes says nothing about steady state.
    local reaped_before
    reaped_before=$(docker logs "$CONTAINER" 2>&1 | grep -c "Loop stalled" || true)

    local elapsed=0
    while [ "$elapsed" -lt "$SAMPLE" ]; do
        alive || { T_NOTE="container died while sampling"; return; }
        local mean p10 min sess stalled
        mean=$(metric wordonline_loop_fps_mean); p10=$(metric wordonline_loop_fps_p10)
        min=$(metric wordonline_loop_fps_min); sess=$(metric wordonline_loop_sessions)
        stalled=$(metric wordonline_loop_stalled)
        if [ -n "$mean" ]; then
            samples=$((samples + 1))
            sum=$(awk -v a="$sum" -v b="$mean" 'BEGIN { printf "%.4f", a + b }')
            p10_sum=$(awk -v a="$p10_sum" -v b="${p10:-0}" 'BEGIN { printf "%.4f", a + b }')
            sess_sum=$(awk -v a="$sess_sum" -v b="${sess:-0}" 'BEGIN { printf "%.2f", a + b }')
            worst=$(awk -v a="$worst" -v b="${min:-0}" 'BEGIN { printf "%.2f", (b < a ? b : a) }')
            stalled=${stalled%.*}; stalled=${stalled:-0}
            [ "$stalled" -gt "$stalled_max" ] && stalled_max="$stalled"
        fi
        sleep "$POLL"; elapsed=$((elapsed + POLL))
    done

    [ "$samples" -gt 0 ] || { T_NOTE="no samples"; return; }
    T_MEAN=$(awk -v s="$sum" -v n="$samples" 'BEGIN { printf "%.2f", s / n }')
    T_P10=$(awk -v s="$p10_sum" -v n="$samples" 'BEGIN { printf "%.2f", s / n }')
    T_WORST="$worst"
    T_STALLED="$stalled_max"
    T_SESSIONS=$(awk -v s="$sess_sum" -v n="$samples" 'BEGIN { printf "%.1f", s / n }')
    T_MEM=$(mem_mb)

    local reaped
    reaped=$(( $(docker logs "$CONTAINER" 2>&1 | grep -c "Loop stalled" || true) - reaped_before ))

    if oom_killed; then T_NOTE="OOM killed"
    elif heap_exhausted; then T_NOTE="java heap OutOfMemoryError"
    elif [ "$stalled_max" -gt 0 ]; then T_NOTE="$stalled_max loop(s) stalled past 10s"
    elif [ "$reaped" -gt 0 ]; then T_NOTE="$reaped loop(s) reaped by the watchdog"
    fi

    if [ -z "$T_NOTE" ] && awk -v f="$T_P10" -v p="$FPS_PASS" 'BEGIN { exit !(f >= p) }'; then
        T_VERDICT=pass
    fi
    echo "    $T_VERDICT: p10 fps $T_P10, mean $T_MEAN, worst $T_WORST, sessions $T_SESSIONS, stalled $stalled_max, reaped $reaped, mem ${T_MEM}MiB ${T_NOTE:+($T_NOTE)}"
}

record() {
    # A trial that ends before sampling reports nothing else, so say why here.
    [ "$T_VERDICT" = pass ] || [ -n "$T_MEAN" ] && [ "$T_MEAN" != 0 ] || echo "    fail: $T_NOTE"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$1" "$T_VERDICT" "$T_P10" "$T_MEAN" "$T_WORST" "$T_SESSIONS" "$T_STALLED" "$T_MEM" "$T_NOTE" >>"$OUT"
}

echo "target,verdict,p10_fps,mean_fps,worst_session_fps,avg_sessions,stalled,mem_mib,note" >"$OUT"
trap stop_container EXIT

if [ "$SINGLE" = 1 ]; then
    # One trial at --start, no search. Used by the A/B comparison, where the point is two
    # builds measured at the same session count rather than each build's own boundary.
    trial "$START"; record "$START"
    exit 0
fi

lo=0        # highest count known to pass
hi=0        # lowest count known to fail, 0 while none has
n="$START"
while [ "$n" -le "$MAX" ]; do
    trial "$n"; record "$n"
    if [ "$T_VERDICT" = pass ]; then lo="$n"; n=$((n * 2)); else hi="$n"; break; fi
done

if [ "$hi" -eq 0 ]; then
    echo
    echo "no failure up to $MAX sessions at ${CPUS} cpu / ${MEMORY}; raise --max"
    exit 0
fi

while [ $((hi - lo)) -gt 1 ]; do
    mid=$(((lo + hi) / 2))
    trial "$mid"; record "$mid"
    if [ "$T_VERDICT" = pass ]; then lo="$mid"; else hi="$mid"; fi
done

echo
echo "capacity at ${CPUS} cpu / ${MEMORY}, pass threshold ${FPS_PASS} fps at the tenth percentile: $lo sessions (first failure at $hi)"
echo "trials written to $OUT"
