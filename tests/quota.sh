#!/usr/bin/env bash
# An exhausted subscription must be distinguishable from a worker bug.
#
# Before this, grok refusing on quota/auth surfaced as "exit 5, worker produced
# no parseable JSON" -- identical to a crash or a malformed reply. An orchestrator
# cannot tell those apart, so it retries, and `ccx fanout` dispatched every
# remaining brief into the same wall.
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

mkstub() {   # $1 = path, $2 = stderr text, $3 = exit code
  cat > "$1" <<STUB
#!/usr/bin/env bash
case "\$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume --tools"; exit 0 ;;
  models)    echo "${4:-stub-auth-ok}"; exit 0 ;;
esac
echo "$2" >&2
exit ${3:-1}
STUB
  chmod +x "$1"
}

# --- 1. a quota refusal is exit 6, not exit 5 ----------------------------------
mkstub "$T/grok-quota" "Error: rate limit exceeded (429). Your plan's quota is exhausted." 1
H1="$T/h1"
out=$(CCX_HOME="$H1" GROK_BIN="$T/grok-quota" "$CCX" run --read --cwd "$ROOT" -- probe 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 6 ]]; then ok "a quota refusal exits 6"
else no "a quota refusal must exit 6, not $rc (5 = indistinguishable from a worker bug)"; fi

if grep -qi 'STOP DISPATCHING' <<<"$out"; then ok "the message tells the orchestrator to stop"
else no "the message must tell the orchestrator to stop dispatching"; fi

if [[ -f "$H1/.quota-block" ]]; then ok "a quota refusal arms the breaker"
else no "a quota refusal must arm the breaker"; fi

if [[ -f "$H1/runs.jsonl" ]] && jq -e 'select(.status=="quota")' "$H1/runs.jsonl" >/dev/null 2>&1; then
  ok "a quota refusal is logged with status=quota"
else no "a quota refusal must be logged with status=quota"; fi

# --- 2. the breaker makes the NEXT run refuse without dispatching --------------
# the stub below would SUCCEED; if it is reached, the breaker did not hold
cat > "$T/grok-ok" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume --tools"; exit 0 ;;
  models)    echo "stub-auth-ok"; exit 0 ;;
esac
echo "DISPATCHED" >> "$STUB_MARKER"
echo '{"text":"{}","stopReason":"end_turn","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":1,"total_cost_usd":0,"usage":{},"structuredOutput":{"status":"done","summary":"s","files_changed":[],"evidence":[],"open_questions":[]}}'
STUB
chmod +x "$T/grok-ok"
MK="$T/dispatched.log"; : > "$MK"
out=$(STUB_MARKER="$MK" CCX_HOME="$H1" GROK_BIN="$T/grok-ok" \
        "$CCX" run --read --cwd "$ROOT" -- probe 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 6 ]]; then ok "the breaker refuses the next run fast"
else no "the breaker must refuse the next run (exit $rc)"; fi
if [[ -s "$MK" ]]; then no "the breaker must refuse BEFORE dispatching (grok was invoked)"
else ok "the breaker refuses before dispatching"; fi

# --- 3. the breaker expires, and doctor clears it once auth answers -----------
out=$(CCX_BREAKER_TTL=0 STUB_MARKER="$MK" CCX_HOME="$H1" GROK_BIN="$T/grok-ok" \
        "$CCX" run --read --cwd "$ROOT" -- probe 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then ok "an expired breaker stops blocking"
else no "an expired breaker must stop blocking (exit $rc)"; fi

CCX_HOME="$H1" GROK_BIN="$T/grok-quota" "$CCX" run --read --cwd "$ROOT" -- probe >/dev/null 2>&1 || true
[[ -f "$H1/.quota-block" ]] || no "setup: breaker not re-armed"
out=$(CCX_HOME="$H1" GROK_BIN="$T/grok-ok" "$CCX" doctor 2>&1) || true
if [[ -f "$H1/.quota-block" ]]; then
  no "doctor must clear the breaker when auth answers normally"
else ok "doctor clears the breaker when auth answers normally"; fi

# doctor must NOT clear it while auth itself still reports a quota problem
CCX_HOME="$H1" GROK_BIN="$T/grok-quota" "$CCX" run --read --cwd "$ROOT" -- probe >/dev/null 2>&1 || true
mkstub "$T/grok-badauth" "boom" 1 "Error: 401 unauthorized - please sign in"
out=$(CCX_HOME="$H1" GROK_BIN="$T/grok-badauth" "$CCX" doctor 2>&1) || true
if [[ -f "$H1/.quota-block" ]]; then ok "doctor keeps the breaker while auth still looks wrong"
else no "doctor must keep the breaker while auth still reports a quota/auth problem"; fi

# --- 4. fanout stops dispatching the rest of the fleet ------------------------
B="$T/briefs"; mkdir -p "$B"
for nm in a b c d; do echo "GOAL $nm" > "$B/$nm.md"; done
H2="$T/h2"
out=$(CCX_HOME="$H2" GROK_BIN="$T/grok-quota" "$CCX" fanout --cwd "$ROOT" \
        --briefs "$B" --read --concurrency 1 2>&1) && rc=0 || rc=$?
if grep -qi 'NOT dispatched' <<<"$out"; then ok "fanout reports the briefs it skipped"
else no "fanout must report the briefs it did not dispatch"; fi
started=$(ls "$H2"/runs 2>/dev/null | wc -l | tr -d ' ')
if (( started < 4 )); then ok "fanout stops dispatching after a quota refusal ($started/4 started)"
else no "fanout dispatched all $started briefs into the same quota wall"; fi

# --- 5. an EXPIRED breaker must not block fanout --------------------------------
# `ccx run` honoured the TTL but fanout tested only that the file existed, so a
# stale block kept skipping every brief forever while a plain run sailed past it.
H3="$T/h9"; mkdir -p "$H3"
printf '2020-01-01T00:00:00Z\nold block\n' > "$H3/.quota-block"
touch -t 202001010000 "$H3/.quota-block"
B2="$T/briefs2"; mkdir -p "$B2"; for nm in p q; do echo "GOAL $nm" > "$B2/$nm.md"; done
MK2="$T/dispatched2.log"; : > "$MK2"
out=$(STUB_MARKER="$MK2" CCX_HOME="$H3" GROK_BIN="$T/grok-ok" "$CCX" fanout --cwd "$ROOT" \
        --briefs "$B2" --read --concurrency 2 2>&1) && rc=0 || rc=$?
if grep -qi 'NOT dispatched' <<<"$out"; then
  no "an expired breaker must not make fanout skip briefs"
else ok "an expired breaker does not block fanout"; fi
started=$(ls "$H3"/runs 2>/dev/null | wc -l | tr -d ' ')
(( started >= 2 )) && ok "fanout dispatched past the expired breaker ($started runs)" \
  || no "fanout should have dispatched 2 briefs, started $started"

exit "$fail"
