#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${SCRIPT:-./build_odbc.sh}"   # your blackbox
C="${1:-10}"                          # concurrency (builders on this host)
PARG="${2:-4}"                        # either single P or a plan list "1,2,4,8"
THIRD="${3:-1}"                       # in plan mode: repeats_per_P; legacy: BATCHES

OUT_BASE="${OUT_BASE:-bench_results}"
TS="$(date +%Y%m%d_%H%M%S)"

# detect "plan mode" if PARG contains comma or whitespace AND isn't just an integer
plan_mode=0
if [[ "$PARG" =~ [,\ ] ]]; then
  plan_mode=1
fi

# Build plan array
declare -a PLAN=()
REPEATS_PER_P=1
LEGACY_BATCHES=1

if [ "$plan_mode" -eq 1 ]; then
  # Split on commas/spaces, drop empties
  read -r -a PLAN < <(echo "$PARG" | tr ',' ' ' | awk '{$1=$1; print}')
  REPEATS_PER_P="$THIRD"
else
  PLAN=("$PARG")
  LEGACY_BATCHES="$THIRD"
fi

PLAN_STR="$(printf "%s_" "${PLAN[@]}")"
PLAN_STR="${PLAN_STR%_}"

OUT="${OUT_BASE}/${TS}_C${C}_PLAN${PLAN_STR}"
mkdir -p "$OUT"/{logs,times,mon}

CSV="$OUT/results.csv"
echo "batch,plan_p,plan_rep,slot,concurrency,make_parallel,start_ts,end_ts,duration_s,exit_code" > "$CSV"

TIMEBIN=""
if command -v /usr/bin/time >/dev/null 2>&1; then TIMEBIN="/usr/bin/time"; fi

start_monitors() {
  if command -v vmstat >/dev/null 2>&1; then
    (stdbuf -oL -eL vmstat 1 > "$OUT/mon/vmstat.txt") &
    echo $! > "$OUT/mon/vmstat.pid"
  fi
  if command -v mpstat >/dev/null 2>&1; then
    (stdbuf -oL -eL mpstat -P ALL 1 > "$OUT/mon/mpstat.txt") &
    echo $! > "$OUT/mon/mpstat.pid"
  fi
  if command -v iostat >/dev/null 2>&1; then
    (stdbuf -oL -eL iostat -xz 1 > "$OUT/mon/iostat.txt") &
    echo $! > "$OUT/mon/iostat.pid"
  fi

  {
    echo "=== date ==="; date
    echo
    echo "=== uname ==="; uname -a
    echo
    echo "=== lscpu ==="; command -v lscpu >/dev/null && lscpu || true
    echo
    echo "=== free -h ==="; free -h || true
    echo
    echo "=== uptime ==="; uptime || true
    echo
    echo "=== plan_mode ==="; echo "$plan_mode"
    echo "=== concurrency C ==="; echo "$C"
    echo "=== PLAN ==="; printf "%s\n" "${PLAN[@]}"
    echo "=== REPEATS_PER_P ==="; echo "$REPEATS_PER_P"
    echo "=== LEGACY_BATCHES ==="; echo "$LEGACY_BATCHES"
  } > "$OUT/mon/host_info.txt" 2>&1
}

stop_monitors() {
  for f in "$OUT/mon/"*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" || true)"
    [ -n "${pid:-}" ] && kill "$pid" >/dev/null 2>&1 || true
  done
}

run_one() {
  local batch="$1"
  local plan_p="$2"
  local plan_rep="$3"
  local slot="$4"
  local P="$5"

  local log="$OUT/logs/b${batch}_P${P}_r${plan_rep}_s${slot}.log"
  local tfile="$OUT/times/b${batch}_P${P}_r${plan_rep}_s${slot}.time"

  local start end dur rc
  start="$(date +%s)"

  set +e
  if [ -n "$TIMEBIN" ]; then
    MAKE_PARALLEL="$P" BUILD_SLOT="$slot" \
      "$TIMEBIN" -v -o "$tfile" "$SCRIPT" >"$log" 2>&1
    rc=$?
  else
    MAKE_PARALLEL="$P" BUILD_SLOT="$slot" \
      "$SCRIPT" >"$log" 2>&1
    rc=$?
  fi
  set -e

  end="$(date +%s)"
  dur="$((end - start))"
  echo "${batch},${plan_p},${plan_rep},${slot},${C},${P},${start},${end},${dur},${rc}" >> "$CSV"
  return "$rc"
}

echo "Output: $OUT"
echo "SCRIPT=$SCRIPT"
echo "C=$C"
if [ "$plan_mode" -eq 1 ]; then
  echo "PLAN=${PLAN[*]}"
  echo "REPEATS_PER_P=$REPEATS_PER_P"
else
  echo "P=${PLAN[0]}"
  echo "BATCHES=$LEGACY_BATCHES"
fi

start_monitors
trap stop_monitors EXIT

batch=0
if [ "$plan_mode" -eq 1 ]; then
  # Each P value is a batch "type"; repeat each to reduce noise
  for plan_p in "${PLAN[@]}"; do
    for plan_rep in $(seq 1 "$REPEATS_PER_P"); do
      batch=$((batch + 1))
      P="$plan_p"
      echo "== Batch $batch :: P=$P (rep $plan_rep/$REPEATS_PER_P) =="

      pids=()
      for slot in $(seq 1 "$C"); do
        run_one "$batch" "$plan_p" "$plan_rep" "$slot" "$P" &
        pids+=("$!")
      done

      fail=0
      for pid in "${pids[@]}"; do
        wait "$pid" || fail=1
      done
      echo "Batch $batch done (fail=$fail)."
    done
  done
else
  # Legacy: same P for all batches
  P="${PLAN[0]}"
  for plan_rep in $(seq 1 "$LEGACY_BATCHES"); do
    batch=$((batch + 1))
    echo "== Batch $batch/$LEGACY_BATCHES :: P=$P =="

    pids=()
    for slot in $(seq 1 "$C"); do
      run_one "$batch" "$P" "$plan_rep" "$slot" "$P" &
      pids+=("$!")
    done

    fail=0
    for pid in "${pids[@]}"; do
      wait "$pid" || fail=1
    done
    echo "Batch $batch done (fail=$fail)."
  done
fi

echo "Done. Results: $CSV"
