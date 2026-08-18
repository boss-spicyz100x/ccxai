#!/usr/bin/env bash
# The failure-recovery machinery: what happens when a run does NOT finish cleanly.
#
# Two silent holes lived here. Timed-out and unparseable runs exited without ever
# appending to runs.jsonl, so `ccx stats` -- which filters failures on
# test("blocked|timeout|killed") -- searched for a status the hot path never
# wrote. And the reconcile lock was released only by a RETURN trap, which does
# not run on SIGTERM, so one killed pass disabled crash repair permanently.
#
# Stub GROK_BIN, throwaway CCX_HOME -- no worker, no money.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCX="${CCX:-$ROOT/plugins/ccx/bin/ccx}"
[[ -x "$CCX" ]] || { echo "FAIL setup: ccx not executable at $CCX"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok(){ echo "PASS $1"; }
no(){ echo "FAIL $1"; fail=1; }

hdr() {   # the two probe calls every stub must answer
  cat <<'H'
case "$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume --tools"; exit 0 ;;
esac
H
}

# --- 1. a timed-out run must reach runs.jsonl -----------------------------------
{ echo '#!/usr/bin/env bash'; hdr; echo 'sleep 30'; } > "$T/grok-slow"
chmod +x "$T/grok-slow"
H1="$T/h1"
CCX_HOME="$H1" GROK_BIN="$T/grok-slow" "$CCX" run --read --cwd "$ROOT" \
  --timeout 1 -- probe >/dev/null 2>&1 && rc=0 || rc=$?
if [[ "$rc" -ne 4 ]]; then
  no "a worker over its budget must exit 4 (got $rc)"
else ok "a worker over its budget exits 4"; fi

if [[ ! -f "$H1/runs.jsonl" ]]; then
  no "a timed-out run must be appended to runs.jsonl (no file was written)"
elif ! jq -e 'select(.status=="timeout")' "$H1/runs.jsonl" >/dev/null 2>&1; then
  no "a timed-out run must be logged with status=timeout"
else ok "a timed-out run is logged with status=timeout"; fi

# stats is the consumer that motivated the fix: it must actually surface it
if [[ -f "$H1/runs.jsonl" ]]; then
  if CCX_HOME="$H1" GROK_BIN="$T/grok-slow" "$CCX" stats 2>/dev/null | grep -q 'timeout'; then
    ok "ccx stats surfaces the timed-out run"
  else no "ccx stats must surface the timed-out run"; fi
fi

# --- 2. an unparseable worker response must reach runs.jsonl --------------------
{ echo '#!/usr/bin/env bash'; hdr; echo 'echo "not json at all"'; } > "$T/grok-garbage"
chmod +x "$T/grok-garbage"
H2="$T/h2"
CCX_HOME="$H2" GROK_BIN="$T/grok-garbage" "$CCX" run --read --cwd "$ROOT" \
  -- probe >/dev/null 2>&1 && rc=0 || rc=$?
if [[ "$rc" -ne 5 ]]; then
  no "an unparseable response must exit 5 (got $rc)"
else ok "an unparseable response exits 5"; fi

if [[ ! -f "$H2/runs.jsonl" ]]; then
  no "an unparseable run must be appended to runs.jsonl (no file was written)"
else ok "an unparseable run is appended to runs.jsonl"; fi

# it must NOT be left as status=running, or reconcile will later "recover" a run
# that already terminated
if [[ -f "$H2/runs.jsonl" ]] && jq -e 'select(.status=="running")' "$H2/runs.jsonl" >/dev/null 2>&1; then
  no "a terminated run must not be logged as still running"
else ok "a terminated run is not logged as still running"; fi

# --- 3. a leaked reconcile lock must not disable repair forever -----------------
# RETURN does not fire on SIGTERM, so a killed `ccx ls` leaves the lock dir behind
# and every later pass hits `mkdir || return 0` and gives up -- silently.
H3="$T/h3"; mkdir -p "$H3/runs/20200101-000000-stale-1"
cat > "$H3/runs/20200101-000000-stale-1/meta.json" <<'STALE'
{"run":"20200101-000000-stale-1","session":"aaaaaaaa-0000-0000-0000-000000000000",
 "status":"running","profile":"read","effort":"xhigh","timeout_s":60,
 "cwd":"/tmp","label":"stale","sub":"run"}
STALE
# age the meta well past timeout_s + 600 so reconcile is allowed to touch it
touch -t 202001010000 "$H3/runs/20200101-000000-stale-1/meta.json"
mkdir -p "$H3/.reconcile.lock"
touch -t 202001010000 "$H3/.reconcile.lock"          # a demonstrably stale lock

CCX_HOME="$H3" GROK_BIN="$T/grok-slow" "$CCX" ls >/dev/null 2>&1 || true
st=$(jq -r '.status' "$H3/runs/20200101-000000-stale-1/meta.json" 2>/dev/null || echo "?")
if [[ "$st" == "running" ]]; then
  no "a stale reconcile lock must not disable repair (run still status=running)"
else ok "a stale reconcile lock is broken and repair proceeds (status=$st)"; fi

# a FRESH lock must still be respected -- otherwise two passes race
H4="$T/h4"; mkdir -p "$H4/runs/20200101-000000-stale-1"
cp "$H3/runs/20200101-000000-stale-1/meta.json" "$H4/runs/20200101-000000-stale-1/meta.json" 2>/dev/null || true
cat > "$H4/runs/20200101-000000-stale-1/meta.json" <<'STALE2'
{"run":"20200101-000000-stale-1","status":"running","profile":"read","effort":"xhigh",
 "timeout_s":60,"cwd":"/tmp","label":"stale","sub":"run"}
STALE2
touch -t 202001010000 "$H4/runs/20200101-000000-stale-1/meta.json"
mkdir -p "$H4/.reconcile.lock"                       # fresh: created just now
CCX_HOME="$H4" GROK_BIN="$T/grok-slow" "$CCX" ls >/dev/null 2>&1 || true
st4=$(jq -r '.status' "$H4/runs/20200101-000000-stale-1/meta.json" 2>/dev/null || echo "?")
if [[ "$st4" == "running" ]]; then
  ok "a fresh reconcile lock is still respected"
else no "a fresh reconcile lock must be respected (status became $st4)"; fi

# --- 4. SIGTERM must take the worker down with the dispatcher -------------------
# bash does not service traps while a foreground child runs, so a signal arriving
# during dispatch was only handled after the worker finished -- i.e. never. ccx
# died, the worker kept running and kept BILLING, meta stayed "running", and
# nothing reached runs.jsonl. `ccx stats` filters failures on a "killed" status
# that nothing in the codebase ever wrote.
{ echo '#!/usr/bin/env bash'; hdr; echo 'echo $$ > "$STUB_PIDFILE"'; echo 'sleep 120'; } > "$T/grok-hang"
chmod +x "$T/grok-hang"
H5="$T/h5"; PF="$T/worker.pid"
STUB_PIDFILE="$PF" CCX_HOME="$H5" GROK_BIN="$T/grok-hang" \
  "$CCX" run --read --cwd "$ROOT" --timeout 300 -- probe >/dev/null 2>&1 &
CCXPID=$!
for _ in $(seq 1 60); do [[ -s "$PF" ]] && break; /bin/sleep 0.2; done
WPID=$(cat "$PF" 2>/dev/null || echo "")

if [[ -z "$WPID" ]]; then
  no "setup: worker stub never started"
else
  kill -TERM "$CCXPID" 2>/dev/null || true
  gone=0
  for _ in $(seq 1 25); do kill -0 "$WPID" 2>/dev/null || { gone=1; break; }; /bin/sleep 0.2; done
  if [[ "$gone" -eq 1 ]]; then ok "SIGTERM to ccx terminates the worker"
  else no "SIGTERM to ccx left the worker running (orphaned, still billing)"; kill -9 "$WPID" 2>/dev/null || true; fi

  wait "$CCXPID" 2>/dev/null || true
  st=$(jq -r '.status' "$H5"/runs/*/meta.json 2>/dev/null | head -1)
  if [[ "$st" == "killed" ]]; then ok "a signalled run is recorded as killed"
  else no "a signalled run must be recorded as killed (got '${st:-none}')"; fi

  if [[ -f "$H5/runs.jsonl" ]] && jq -e 'select(.status=="killed")' "$H5/runs.jsonl" >/dev/null 2>&1; then
    ok "a signalled run reaches runs.jsonl"
  else no "a signalled run must reach runs.jsonl"; fi

  # the session id is the only way to recover the work -- it must be reported
  if jq -e '.session | test("^[0-9a-f-]{36}$")' "$H5"/runs/*/meta.json >/dev/null 2>&1; then
    ok "a signalled run keeps its session id"
  else no "a signalled run must keep its session id"; fi
fi

# --- 5. interrupting fanout must not orphan the whole fleet ---------------------
# fanout spawned each worker in a `( ... ) &` subshell and never signalled them.
# One Ctrl-C left N workers running and billing, untracked.
{ echo '#!/usr/bin/env bash'; hdr
  echo 'echo $$ >> "$STUB_PIDFILE"'; echo 'sleep 120'; } > "$T/grok-fleet"
chmod +x "$T/grok-fleet"
BR="$T/fleetbriefs"; mkdir -p "$BR"
for nm in one two; do echo "GOAL $nm" > "$BR/$nm.md"; done
H6="$T/h6"; FPF="$T/fleet.pids"; : > "$FPF"
STUB_PIDFILE="$FPF" CCX_HOME="$H6" GROK_BIN="$T/grok-fleet" \
  "$CCX" fanout --cwd "$ROOT" --briefs "$BR" --read --concurrency 2 >/dev/null 2>&1 &
FPID=$!
for _ in $(seq 1 80); do [[ $(wc -l < "$FPF") -ge 2 ]] && break; /bin/sleep 0.25; done
# mapfile is bash 4+; /bin/bash on macOS is 3.2, where it silently does not exist
FLEET=()
while IFS= read -r _pid; do [[ -n "$_pid" ]] && FLEET+=("$_pid"); done < "$FPF"

if (( ${#FLEET[@]} < 2 )); then
  no "setup: fanout did not start 2 workers (got ${#FLEET[@]})"
  kill -TERM "$FPID" 2>/dev/null || true
else
  kill -TERM "$FPID" 2>/dev/null || true
  alive=0
  for _ in $(seq 1 30); do
    alive=0
    for pid in "${FLEET[@]}"; do kill -0 "$pid" 2>/dev/null && alive=$((alive+1)); done
    (( alive == 0 )) && break
    /bin/sleep 0.25
  done
  if (( alive == 0 )); then ok "interrupting fanout terminates every worker"
  else
    no "interrupting fanout left $alive of ${#FLEET[@]} worker(s) running"
    for pid in "${FLEET[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
  fi
  wait "$FPID" 2>/dev/null || true
fi

exit "$fail"
