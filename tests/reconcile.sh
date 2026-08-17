#!/usr/bin/env bash
# _reconcile must repair status="running" leftovers from a killed dispatcher.
#
# An earlier version logged a failed merge on every ls/stats/log call (the run
# stayed "running", so the next pass appended again). Counting jsonl lines once
# is not enough — we re-invoke ls/stats/log and require the count not to grow.
# A non-object raw.json (the literal 42) is valid JSON, so it enters the recover
# branch; the merge must fail closed: no garbage line, no recovered status.
set -euo pipefail

CCX="${CCX:-$(cd "$(dirname "$0")/.." && pwd)/plugins/ccx/bin/ccx}"
[[ -f "$CCX" && -x "$CCX" ]] || { echo "FAIL setup: ccx not executable at $CCX" >&2; exit 1; }

T=$(mktemp -d)
trap 'chmod -R u+rwx "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
HOME_DIR="$T/home"
mkdir -p "$HOME_DIR/runs" "$T/cwd"

cat > "$T/grok" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume --tools"; exit 0 ;;
esac
echo "ccx-reconcile-test: stub grok invoked unexpectedly: $*" >&2
exit 99
STUB
chmod +x "$T/grok"
export CCX_HOME="$HOME_DIR" GROK_BIN="$T/grok"

plant() {  # $1=id $2=status $3=timeout_s
  local dir="$HOME_DIR/runs/$1"
  mkdir -p "$dir"
  jq -n --arg r "$1" --arg st "$2" --argjson to "$3" \
    '{run:$r,session:"11111111-2222-3333-4444-555555555555",
      cwd:"'"$T/cwd"'",profile:"read",model:"grok-4.6",effort:"xhigh",
      timeout_s:$to,max_turns:30,label:"reconcile-test",sub:"run",status:$st}' \
    > "$dir/meta.json"
}

# Worker-shaped object. A number or empty file is not this.
raw_object='{"text":"ok","stopReason":"end_turn","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":4,"total_cost_usd":0.02}'

plant stale-recoverable running 1
printf '%s\n' "$raw_object" > "$HOME_DIR/runs/stale-recoverable/raw.json"

plant stale-notobject running 1
printf '42\n' > "$HOME_DIR/runs/stale-notobject/raw.json"

plant stale-abandoned running 1
# no raw*.json — nothing to recover

plant fresh-inflight running 1800
printf '%s\n' "$raw_object" > "$HOME_DIR/runs/fresh-inflight/raw.json"

plant aaa-unreadable running 1
printf '%s\n' "$raw_object" > "$HOME_DIR/runs/aaa-unreadable/raw.json"

# Stale = older than timeout_s+600. 2020 is safely past a 1s budget.
touch -t 202001010000.00 \
  "$HOME_DIR/runs/stale-recoverable/meta.json" \
  "$HOME_DIR/runs/stale-notobject/meta.json" \
  "$HOME_DIR/runs/stale-abandoned/meta.json" \
  "$HOME_DIR/runs/aaa-unreadable/meta.json"
# In-flight must look freshly written and inside its 1800s budget.
touch "$HOME_DIR/runs/fresh-inflight/meta.json"
# Newest mtime so `ccx ls` (ls -1t) hits the unreadable meta first.
touch "$HOME_DIR/runs/aaa-unreadable/meta.json"
chmod 000 "$HOME_DIR/runs/aaa-unreadable/meta.json"

run_ccx() { "$CCX" "$@"; }

status_of() { jq -r '.status // ""' "$HOME_DIR/runs/$1/meta.json" 2>/dev/null || echo ""; }

# Count jsonl records for a run id, skipping unparseable lines (e.g. a dumped 42).
lines_for() {
  local id="$1" f="$HOME_DIR/runs.jsonl"
  [[ -f "$f" ]] || { echo 0; return 0; }
  local n=0 line
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -z "$line" ]] && continue
    printf '%s\n' "$line" | jq -e --arg r "$id" 'type=="object" and .run==$r' >/dev/null 2>&1 \
      && n=$((n+1))
  done < "$f"
  echo "$n"
}

bad_lines() {
  local f="$HOME_DIR/runs.jsonl"
  [[ -f "$f" ]] || { echo 0; return 0; }
  local n=0 line
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -z "$line" ]] && continue
    printf '%s\n' "$line" | jq -e 'type=="object"' >/dev/null 2>&1 || n=$((n+1))
  done < "$f"
  echo "$n"
}

fail=0

ls_rc=0
run_ccx ls >"$T/ls1.out" 2>"$T/ls1.err" || ls_rc=$?

# The growth check is the point: one snapshot can hide "append on every call".
for _i in 1 2 3; do
  run_ccx ls >/dev/null 2>&1 || true
  run_ccx stats >/dev/null 2>&1 || true
  run_ccx log >/dev/null 2>&1 || true
done

st=$(status_of stale-recoverable)
n1=$(lines_for stale-recoverable)
cost=$(jq -r '.cost // empty' "$HOME_DIR/runs/stale-recoverable/meta.json" 2>/dev/null || echo "")
turns=$(jq -r '.turns // empty' "$HOME_DIR/runs/stale-recoverable/meta.json" 2>/dev/null || echo "")
if [[ "$st" == "recovered" && "$n1" -eq 1 && "$cost" == "0.02" && "$turns" == "4" ]]; then
  echo "PASS recoverable: status=recovered, merged worker result, logged exactly once"
else
  echo "FAIL recoverable: status=$st jsonl=$n1 cost=$cost turns=$turns (want recovered/1/0.02/4)"
  fail=1
fi

st=$(status_of stale-notobject)
n1=$(lines_for stale-notobject)
nb=$(bad_lines)
if [[ "$st" == "running" && "$n1" -eq 0 && "$nb" -eq 0 ]]; then
  echo "PASS not-object: merge failed closed, no garbage jsonl line, no growth"
else
  echo "FAIL not-object: status=$st jsonl=$n1 bad_lines=$nb (want running/0/0)"
  fail=1
fi

st=$(status_of stale-abandoned)
n1=$(lines_for stale-abandoned)
if [[ "$st" == "abandoned" && "$n1" -eq 1 ]]; then
  echo "PASS abandoned: status=abandoned and reaches runs.jsonl"
else
  echo "FAIL abandoned: status=$st jsonl=$n1 (want abandoned/1)"
  fail=1
fi

st=$(status_of fresh-inflight)
n1=$(lines_for fresh-inflight)
if [[ "$st" == "running" && "$n1" -eq 0 ]]; then
  echo "PASS inflight: fresh mtime inside budget left untouched"
else
  echo "FAIL inflight: status=$st jsonl=$n1 (want running/0)"
  fail=1
fi

if [[ "$ls_rc" -eq 0 ]] \
   && grep -q 'stale-recoverable' "$T/ls1.out" \
   && grep -q 'aaa-unreadable' "$T/ls1.out"; then
  echo "PASS unreadable: chmod 000 meta does not abort ls listing"
else
  echo "FAIL unreadable: ls_rc=$ls_rc out=$(tr '\n' '|' <"$T/ls1.out") err=$(tr '\n' '|' <"$T/ls1.err")"
  fail=1
fi

exit "$fail"
