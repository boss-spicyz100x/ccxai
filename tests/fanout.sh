#!/usr/bin/env bash
# ccx fanout: orchestration over `ccx run`. Uses a stub GROK_BIN and a throwaway
# CCX_HOME -- no real worker is dispatched and no money is spent.
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
esac
echo '{"text":"{}","stopReason":"end_turn","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":2,"total_cost_usd":0,"usage":{},"structuredOutput":{"status":"done","summary":"s","files_changed":[],"evidence":[],"open_questions":[]}}'
STUB
chmod +x "$T/grok"
B="$T/briefs"; mkdir -p "$B"
for n in alpha beta; do echo "GOAL $n" > "$B/$n.md"; done
echo "GOAL collide" > "$B/alpha.txt"          # same slug as alpha.md
echo "GOAL odd"     > "$B/weird name!.md"     # must be sanitised
run(){ CCX_HOME="$1" GROK_BIN="$T/grok" "$CCX" fanout --cwd "$ROOT" "${@:2}"; }

# --- argument guards: each must refuse before dispatching anything ---
# A guard must REFUSE -- exit non-zero with a ccx: message, promptly. Accepting any
# non-zero exit would let a hang (killed by timeout, exit 124) masquerade as a refusal,
# which is how a guard test starts passing broken code.
g(){ local d out rc; d="$T/g$RANDOM"
     out=$(timeout 30 env CCX_HOME="$d" GROK_BIN="$T/grok" "$CCX" fanout --cwd "$ROOT" \
             "${@:3}" 2>&1) && rc=0 || rc=$?
     if   [[ "$rc" -eq 0   ]]; then no "$1 (was accepted)"
     elif [[ "$rc" -eq 124 ]]; then no "$1 (hung, not refused)"
     elif ! grep -q '^ccx:' <<<"$out"; then no "$1 (failed without a ccx: message)"
     else ok "$1"; fi; }
g "no --briefs refused"            x
g "missing briefs dir refused"     x --briefs "$T/nope"
g "--concurrency 0 refused"        x --briefs "$B" --concurrency 0
g "--concurrency abc refused"      x --briefs "$B" --concurrency abc
mkdir -p "$T/empty"
g "empty briefs dir refused"       x --briefs "$T/empty"

# --- read profile: dispatches every brief, creates no worktrees ---
H="$T/h1"
out=$(run "$H" --briefs "$B" --read --concurrency 2 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && ok "read fanout exits 0" || no "read fanout exits 0 (got $rc)"
n=$(ls "$H"/fanout/*/*.json 2>/dev/null | wc -l | tr -d ' ')
[[ "$n" -eq 4 ]] && ok "one result file per brief (4)" || no "expected 4 result files, got $n"
[[ ! -d "$H/worktrees" ]] && ok "read profile creates no worktrees" \
  || no "read profile created worktrees"
grep -q '^alpha ' <<<"$out"   && ok "slug from brief name"        || no "slug from brief name"
grep -q '^alpha-2 ' <<<"$out" && ok "duplicate slug deduped"      || no "duplicate slug deduped"
grep -q '^weird-name ' <<<"$out" && ok "slug sanitised"           || no "slug sanitised"
grep -q 'done' <<<"$out"      && ok "summary reports status"      || no "summary reports status"

# --- write profile: one worktree per brief ---
H2="$T/h2"
run "$H2" --briefs "$B" --write --concurrency 4 >/dev/null 2>&1 || true
w=$(ls -1 "$H2/worktrees" 2>/dev/null | wc -l | tr -d ' ')
[[ "$w" -eq 4 ]] && ok "write profile: one worktree per brief" \
  || no "write profile worktrees: expected 4, got $w"
for slug in alpha alpha-2 beta weird-name; do
  git -C "$ROOT" worktree remove --force "$H2/worktrees/$(basename "$ROOT")-$slug" 2>/dev/null || true
  git -C "$ROOT" branch -D "ccx/$slug" 2>/dev/null || true
done >/dev/null 2>&1
git -C "$ROOT" worktree prune 2>/dev/null || true

# --- a failing worker must make fanout exit non-zero, not silently pass ---
cat > "$T/grok-bad" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume"; exit 0 ;;
esac
echo '{"text":"","stopReason":"cancelled","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":1,"total_cost_usd":0,"usage":{}}'
STUB
chmod +x "$T/grok-bad"
if CCX_HOME="$T/h3" GROK_BIN="$T/grok-bad" "$CCX" fanout --cwd "$ROOT" \
     --briefs "$B" --read --concurrency 4 >/dev/null 2>&1; then
  no "failing workers must make fanout exit non-zero"
else ok "failing workers make fanout exit non-zero"; fi

# --- a worker that never created a run dir must not inherit an older run's
# --- numbers. fanout located each worker's run by globbing runs/*-<slug>-*
# --- across ALL history, so a stale run with the same brief name was reported
# --- as this run's turns/cost/seconds and folded into the fanout total.
H4="$T/h4"; mkdir -p "$H4/runs/20260101-000000-alpha-9999"
cat > "$H4/runs/20260101-000000-alpha-9999/meta.json" <<'STALE'
{"run":"20260101-000000-alpha-9999","session":"deadbeef-0000-0000-0000-000000000000",
 "status":"done","turns":42,"cost":99.99,"seconds":4242,"profile":"read"}
STALE
# GROK_BIN missing makes each child die at the `grok CLI not found` check, which
# runs BEFORE the run directory is created -- so this fanout produces no run of
# its own and the only alpha-* run on disk is the stale one seeded above.
AOUT=$(CCX_HOME="$H4" GROK_BIN="$T/nonexistent-grok" "$CCX" fanout --cwd "$ROOT" \
         --briefs "$B" --read --concurrency 2 2>&1 || true)
if grep -qE '(^|[^0-9])42($|[^0-9])' <<<"$AOUT" || grep -q '99\.99' <<<"$AOUT"; then
  no "stale run must not be attributed to a worker that never ran"
  printf '     reported: %s\n' "$(grep -E '^alpha' <<<"$AOUT" | head -1)"
else ok "stale run must not be attributed to a worker that never ran"; fi

# The total line must be PRESENT and must not contain the stale cost. Asserting
# only "99.99 is absent" is a false pass: fanout used to die at the run-dir glob
# (pipefail + set -e) so the total never printed at all, and absence looked green.
if ! grep -qE '^total \$' <<<"$AOUT"; then
  no "fanout must still print a total when a worker has no run dir"
elif grep -qE '^total \$(99\.99|199\.98)' <<<"$AOUT"; then
  no "stale cost must not enter the fanout total"
else ok "fanout totals exclude the stale run"; fi

# Every brief must get a summary row; a worker with no run dir used to abort the
# whole loop, so later briefs silently vanished from the table.
missing=""
for want in alpha beta; do grep -qE "^$want " <<<"$AOUT" || missing="$missing $want"; done
if [[ -n "$missing" ]]; then no "every brief must appear in the summary (missing:$missing)"
else ok "every brief appears in the summary"; fi

exit "$fail"
