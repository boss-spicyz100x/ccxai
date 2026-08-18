#!/usr/bin/env bash
# Mutation harness: does the suite actually FAIL when ccx is broken?
#
# The rule in CLAUDE.md -- "a test is only finished when it fails on the bug it
# guards" -- was enforced by hand, one bug at a time. That is how the first
# phase-parity.sh shipped green against two genuinely broken variants, and how a
# fanout assertion later passed only because fanout crashed before printing the
# line it asserted on.
#
# Each mutation below breaks one invariant in a COPY of ccx and names the test
# file that is supposed to notice. A mutation that survives is a hole in the
# suite, not a fixed bug. Nothing here touches the real ccx.
#
# Usage: tests/mutate.sh [name-substring]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL="$ROOT/plugins/ccx/bin/ccx"
FILTER="${1:-}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
survived=0; killed=0

# name | guardian test | literal to find | replacement
MUTATIONS=(
"mcp-deny-dropped" "dispatch.sh"
'[[ "$MCP" -eq 0 ]] && SAFE+=(--deny "MCPTool(*)")'
':'

"write-permission-mode-weakened" "dispatch.sh"
'SAFE+=(--sandbox "$SANDBOX" --permission-mode bypassPermissions --allow "Bash")'
'SAFE+=(--sandbox "$SANDBOX" --permission-mode acceptEdits --allow "Bash")'

"read-write-conflict-guard-dropped" "guard-rails.sh"
'die "--read and --worktree conflict (a worktree is for writes). Choose one."'
':'

"temp-cwd-guard-dropped" "guard-rails.sh"
'/tmp/*|/private/tmp/*|/var/tmp/*|/var/folders/*|/private/var/folders/*|"${TMPDIR:-/nonexistent-tmpdir}"*)'
'/nonexistent-path-that-never-matches/*)'

"var-folders-guard-dropped" "guard-rails.sh"
'/tmp/*|/private/tmp/*|/var/tmp/*|/var/folders/*|/private/var/folders/*|"${TMPDIR:-/nonexistent-tmpdir}"*)'
'/tmp/*|/private/tmp/*|/var/tmp/*|/private/var/folders/*|"${TMPDIR:-/nonexistent-tmpdir}"*)'

"fanout-attribution-reverted-to-glob" "fanout.sh"
'    md=""; [[ -n "$rid" && -f "$CCX_HOME/runs/$rid/meta.json" ]] && md="$CCX_HOME/runs/$rid"'
'    md=$(ls -dt "$CCX_HOME"/runs/*-"$slug"-* 2>/dev/null | head -1 || true)'

"doctor-pipefail-guard-dropped" "failure-paths.sh"
'  gy=$(grep -cE '"'"'^(yolo|permission_mode)'"'"' ~/.grok/config.toml 2>/dev/null || true); gy="${gy:-0}"'
'  gy=$(grep -cE '"'"'^(yolo|permission_mode)'"'"' ~/.grok/config.toml 2>/dev/null | head -1); gy="${gy:-0}"'

"cont-pipefail-guard-dropped" "failure-paths.sh"
'  PARENT="$(grep -l -- "$SESSION" "$CCX_HOME"/runs/*/meta.json 2>/dev/null | tail -1 || true)"'
'  PARENT="$(grep -l -- "$SESSION" "$CCX_HOME"/runs/*/meta.json 2>/dev/null | tail -1)"'

"cost-arithmetic-back-to-eval" "failure-paths.sh"
'  COST=$(awk -v a="$COST" -v b="$C2" '"'"'BEGIN{printf "%.8f", (a+0)+(b+0)}'"'"' 2>/dev/null || echo "$COST")'
'  COST=$(python3 -c "print(round($COST + $C2, 8))" 2>/dev/null || echo "$COST")'

"terminal-runs-not-logged" "recovery.sh"
'  _log_run "$D/meta.json"
}'
'  :
}'

"stale-reconcile-lock-not-broken" "recovery.sh"
'    (( lockage > 900 )) || return 0'
'    return 0'

"dispatch-signal-handling-deferred" "recovery.sh"
'  --output-format json "${ARGS[@]}" >"$D/raw.json" 2>"$D/stderr.log" &
WORKER_PID=$!
wait "$WORKER_PID"
RC=$?'
'  --output-format json "${ARGS[@]}" >"$D/raw.json" 2>"$D/stderr.log"
RC=$?'

"fanout-signal-cascade-dropped" "recovery.sh"
"  trap '_fanout_signal TERM' TERM"
'  :'

"quota-classified-as-parse-error" "quota.sh"
'  if _looks_like_quota "$D/stderr.log"; then'
'  if false; then'

"quota-breaker-not-checked-before-dispatch" "quota.sh"
'command -v timeout >/dev/null 2>&1 || die "timeout(1) not found -- install coreutils (brew install coreutils) or provide gtimeout"
_breaker_check'
'command -v timeout >/dev/null 2>&1 || die "timeout(1) not found -- install coreutils (brew install coreutils) or provide gtimeout"'

"fanout-ignores-quota-breaker" "quota.sh"
'    if [[ -f "$(_breaker_file)" ]]; then
      SKIPPED+=("$slug")
      continue
    fi'
'    :'
)

printf '%-38s %-18s %s\n' MUTATION GUARDIAN RESULT
printf '%s\n' "----------------------------------------------------------------------------"

for (( i=0; i<${#MUTATIONS[@]}; i+=4 )); do
  name="${MUTATIONS[i]}"; guard="${MUTATIONS[i+1]}"
  find="${MUTATIONS[i+2]}"; repl="${MUTATIONS[i+3]}"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue

  copy="$T/ccx-$name"
  if ! FIND="$find" REPL="$repl" python3 - "$REAL" "$copy" <<'PY'
import os, sys, pathlib
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
s = src.read_text(); find = os.environ["FIND"]; repl = os.environ["REPL"]
if find not in s:
    sys.stderr.write("anchor missing\n"); sys.exit(3)
dst.write_text(s.replace(find, repl, 1))
PY
  then
    printf '%-38s %-18s %s\n' "$name" "$guard" "SKIP (anchor no longer present)"
    survived=$((survived+1)); continue
  fi
  chmod +x "$copy"

  if ! bash -n "$copy" 2>/dev/null; then
    printf '%-38s %-18s %s\n' "$name" "$guard" "killed (syntax)"
    killed=$((killed+1)); continue
  fi

  if CCX="$copy" bash "$ROOT/tests/$guard" >/dev/null 2>&1; then
    printf '%-38s %-18s %s\n' "$name" "$guard" "SURVIVED  <-- coverage hole"
    survived=$((survived+1))
  else
    printf '%-38s %-18s %s\n' "$name" "$guard" "killed"
    killed=$((killed+1))
  fi
done

echo
echo "killed $killed, survived $survived"
(( survived == 0 )) || {
  echo "a surviving mutation means the suite does not actually guard that invariant" >&2
  exit 1
}
