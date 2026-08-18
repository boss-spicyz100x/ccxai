#!/usr/bin/env bash
# Paths where ccx must fail LOUDLY or degrade gracefully -- never abort silently.
#
# `set -euo pipefail` plus a command substitution whose pipeline starts with a
# command that legitimately exits non-zero (grep with no match, ls on an empty
# glob) kills the script mid-command with no message. Every assertion here was
# a live silent abort.
#
# Uses a stub GROK_BIN and a throwaway CCX_HOME -- no worker, no money.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCX="${CCX:-$ROOT/plugins/ccx/bin/ccx}"
[[ -x "$CCX" ]] || { echo "FAIL setup: ccx not executable at $CCX"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok(){ echo "PASS $1"; }
no(){ echo "FAIL $1"; fail=1; }

cat > "$T/grok" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume --tools"; exit 0 ;;
  models)    echo "stub-auth-ok"; exit 0 ;;
esac
echo '{"text":"{}","stopReason":"end_turn","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":2,"total_cost_usd":0,"usage":{},"structuredOutput":{"status":"done","summary":"s","files_changed":[],"evidence":[],"open_questions":[]}}'
STUB
chmod +x "$T/grok"

# --- 1. cont with a session ccx has no record of -------------------------------
# ccx has a deliberate graceful path for this (warn, assume --read, continue).
# It was unreachable: the `grep -l ... | tail -1` that looks for the parent run
# exits non-zero when nothing matches, and pipefail turned that into a bare
# `exit 2` with no output at all.
UNKNOWN=00000000-1111-2222-3333-444444444444
out=$(CCX_HOME="$T/h1" GROK_BIN="$T/grok" "$CCX" cont --session "$UNKNOWN" -- "hi" 2>&1) && rc=0 || rc=$?
if [[ -z "${out// }" ]]; then
  no "cont on an unknown session must say something (exited $rc with no output)"
elif grep -qi 'no local record of session' <<<"$out"; then
  ok "cont on an unknown session warns and continues"
elif grep -q '^ccx:' <<<"$out"; then
  ok "cont on an unknown session fails with a ccx: message"
else
  no "cont on an unknown session produced neither a warning nor a ccx: message"
fi

# --- 2. doctor against a grok config with no yolo/mcp lines --------------------
# `grep -c` exits 1 when the count is zero, so a clean config aborted doctor
# right before the two lines that report the config's safety posture.
H="$T/home"; mkdir -p "$H/.grok"
printf 'model = "grok-4"\n' > "$H/.grok/config.toml"
out=$(HOME="$H" CCX_HOME="$T/h2" GROK_BIN="$T/grok" "$CCX" doctor 2>&1) && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  no "doctor must exit 0 on a healthy setup with a clean grok config (exit $rc)"
else ok "doctor exits 0 with a clean grok config"; fi
# `defaults:` prints BEFORE the aborting greps, so asserting on it passes broken
# code. The discriminating check is that a clean config produces no safety note.
if grep -q 'yolo/permission_mode' <<<"$out"; then
  no "doctor must not warn about yolo when the config does not set it"
else ok "doctor emits no false yolo warning on a clean config"; fi

# --- 3. doctor still reports the safety posture when the config DOES set it ----
printf 'yolo = true\npermission_mode = "always-approve"\n[mcp_servers.exa]\n' > "$H/.grok/config.toml"
out=$(HOME="$H" CCX_HOME="$T/h3" GROK_BIN="$T/grok" "$CCX" doctor 2>&1) && rc=0 || rc=$?
if grep -q 'yolo/permission_mode' <<<"$out"; then
  ok "doctor warns when the grok config sets yolo/permission_mode"
else
  no "doctor must warn when the grok config sets yolo/permission_mode"
fi
if grep -q 'MCP server' <<<"$out"; then
  ok "doctor reports configured MCP servers"
else
  no "doctor must report configured MCP servers"
fi

# --- 4. worker-controlled cost must never reach a code evaluator ---------------
# COST and C2 come from the worker's own JSON (.total_cost_usd) and were
# interpolated raw into `python3 -c "print(round($COST + $C2, 8))"`. A worker
# that returns a string there executes arbitrary code in the orchestrator.
CANARY="$T/pwned"
sed "s#CANARYPATH#$CANARY#" > "$T/grok-inject" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume --tools"; exit 0 ;;
esac
cat <<'JSON'
{"text":"{}","stopReason":"end_turn","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":2,"total_cost_usd":"__import__('os').system('touch CANARYPATH') or 0.1","usage":{},"structuredOutput":{"status":"done","summary":"s","files_changed":[],"evidence":[],"open_questions":[]}}
JSON
STUB
chmod +x "$T/grok-inject"
CCX_HOME="$T/h4" GROK_BIN="$T/grok-inject" "$CCX" run --read --cwd "$ROOT" -- probe >/dev/null 2>&1 || true
if [[ -e "$CANARY" ]]; then
  no "worker-controlled cost must not be evaluated as code (canary was created)"
else ok "worker-controlled cost is not evaluated as code"; fi

exit "$fail"
