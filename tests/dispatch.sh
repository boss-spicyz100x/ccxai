#!/usr/bin/env bash
# What ccx actually sends to grok, and what it records in meta.json.
#
# A count of flags is not coverage: an earlier cousin of this (phase-parity) passed
# two real regressions that swapped deny contents for same-count no-ops. Every
# assertion below checks a concrete value (sandbox mode, deny pattern, exit code),
# never "some --deny exists" or "cmd is present".
#
# Never dispatches a real worker. Override the script under test with CCX=.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCX="${CCX:-$ROOT/plugins/ccx/bin/ccx}"
# --read refuses a cwd on a temp path (every sandbox leaves /tmp writable).
SAFE_CWD="$ROOT"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
GROK="$T/grok"
failures=0

if [[ ! -x "$CCX" ]]; then
  echo "FAIL setup: ccx not executable: $CCX"
  exit 1
fi

# Freeze only the run-id clock so two same-label runs collide without $$;
# every other date format (epoch, ISO ts) still goes to the real date.
REAL_DATE="$(command -v date)"
mkdir -p "$T/bin"
cat > "$T/bin/date" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "+%Y%m%d-%H%M%S" ]]; then
  echo "20260101-120000"
  exit 0
fi
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$T/bin/date"
export PATH="$T/bin:$PATH"

cat > "$GROK" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume --tools"; exit 0 ;;
esac
if [[ -n "${STUB_LOG:-}" ]]; then
  {
    printf '%s\n' "=== INVOCATION ==="
    for a in "$@"; do printf '%s\n' "$a"; done
  } >> "$STUB_LOG"
fi
if [[ -n "${STUB_JSON:-}" ]]; then
  printf '%s\n' "$STUB_JSON"
else
  printf '%s\n' '{"text":"ok","stopReason":"end_turn","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":3,"total_cost_usd":0,"usage":{},"structuredOutput":{"status":"done","summary":"s","files_changed":[],"evidence":[],"open_questions":[]}}'
fi
STUB
chmod +x "$GROK"
export GROK_BIN="$GROK"

BLOCKED_JSON='{"text":"blocked","stopReason":"end_turn","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":3,"total_cost_usd":0,"usage":{},"structuredOutput":{"status":"blocked","summary":"cannot proceed","files_changed":[],"evidence":[],"open_questions":["need more"]}}'
# Valid grok JSON that yields an empty envelope: no text, no structuredOutput.
EMPTY_JSON='{"stopReason":"end_turn","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":3,"total_cost_usd":0,"usage":{}}'

# Phase-N argv, one flag/value per line (same shape as phase-parity.sh).
invoc() {
  awk -v n="$2" '/^=== INVOCATION ===$/{c++; next} c==n{print} c>n{exit}' "$1"
}

# Exact (flag, value) pair in phase 1 — not a regex, not a count.
has_pair() {
  invoc "$1" 1 | awk -v f="$2" -v v="$3" '
    $0==f { getline nxt; if (nxt==v) found=1 }
    END { exit found ? 0 : 1 }
  '
}

has_bare() {
  invoc "$1" 1 | grep -qxF -- "$2"
}

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failures=1; }

# $1=home $2=log then ccx args after `run`. Always hits the stub, never PATH grok.
run_ccx() {
  local home="$1" log="$2"
  shift 2
  mkdir -p "$home"
  : > "$log"
  set +e
  STUB_LOG="$log" STUB_JSON="${STUB_JSON:-}" \
    CCX_HOME="$home" GROK_BIN="$GROK" \
    "$CCX" run --cwd "$SAFE_CWD" --raw "$@" >/dev/null 2>&1
  last_rc=$?
  set -e
}

expect_invoked() {
  local case="$1" log="$2" want_rc="${3:-0}"
  if [[ "$last_rc" -ne "$want_rc" ]]; then
    fail "$case: ccx exited $last_rc (want $want_rc)"
    return 1
  fi
  if ! grep -q '^=== INVOCATION ===$' "$log" 2>/dev/null; then
    fail "$case: stub grok was not invoked (refusing to treat that as a pass)"
    return 1
  fi
  return 0
}

meta_of() {
  local home="$1" matches=()
  shopt -s nullglob
  matches=("$home"/runs/*/meta.json)
  shopt -u nullglob
  if [[ ${#matches[@]} -eq 0 ]]; then
    return 1
  fi
  printf '%s' "${matches[0]}"
}

# ---------- default --read containment (one invocation, several value checks)
H="$T/h-read"; L="$T/l-read"
unset STUB_JSON
run_ccx "$H" "$L" --read --no-schema -- "dispatch probe"
if expect_invoked "read-defaults" "$L"; then
  if has_pair "$L" --sandbox read-only; then
    pass "read-sandbox: --sandbox read-only"
  else
    got=$(invoc "$L" 1 | awk '$0=="--sandbox"{getline; print; exit}')
    fail "read-sandbox: want --sandbox read-only, got '${got:-<missing>}'"
  fi

  if has_pair "$L" --deny "MCPTool(*)"; then
    pass "mcp-denied-by-default: --deny MCPTool(*)"
  else
    fail "mcp-denied-by-default: argv has no --deny MCPTool(*)"
  fi

  if has_bare "$L" --disable-web-search; then
    pass "web-off: --disable-web-search"
  else
    fail "web-off: missing --disable-web-search when --web was not passed"
  fi
fi

# ---------- --write sandbox value
H="$T/h-write"; L="$T/l-write"
run_ccx "$H" "$L" --write --no-schema -- "dispatch probe"
if expect_invoked "write-sandbox" "$L"; then
  if has_pair "$L" --sandbox workspace; then
    pass "write-sandbox: --sandbox workspace"
  else
    got=$(invoc "$L" 1 | awk '$0=="--sandbox"{getline; print; exit}')
    fail "write-sandbox: want --sandbox workspace, got '${got:-<missing>}'"
  fi
fi

# ---------- --mcp drops the MCP deny (absence of that exact pattern)
H="$T/h-mcp"; L="$T/l-mcp"
run_ccx "$H" "$L" --read --mcp --no-schema -- "dispatch probe"
if expect_invoked "mcp-flag" "$L"; then
  if has_pair "$L" --deny "MCPTool(*)"; then
    fail "mcp-flag: --mcp still sent --deny MCPTool(*)"
  else
    pass "mcp-flag: --mcp omits --deny MCPTool(*)"
  fi
fi

# ---------- --web drops --disable-web-search
H="$T/h-web"; L="$T/l-web"
run_ccx "$H" "$L" --read --web --no-schema -- "dispatch probe"
if expect_invoked "web-on" "$L"; then
  if has_bare "$L" --disable-web-search; then
    fail "web-on: --web still sent --disable-web-search"
  else
    pass "web-on: --web omits --disable-web-search"
  fi
fi

# ---------- user --allow/--deny reach grok verbatim (exact strings, not just counts)
H="$T/h-xd"; L="$T/l-xd"
ALLOW_RULE='Bash(canary-allow*)'
DENY_RULE='Bash(canary-deny*)'
run_ccx "$H" "$L" --read --allow "$ALLOW_RULE" --deny "$DENY_RULE" --no-schema -- "dispatch probe"
if expect_invoked "allow-deny-verbatim" "$L"; then
  ok_a=0; ok_d=0
  has_pair "$L" --allow "$ALLOW_RULE" && ok_a=1
  has_pair "$L" --deny "$DENY_RULE" && ok_d=1
  if [[ "$ok_a" -eq 1 && "$ok_d" -eq 1 ]]; then
    pass "allow-deny-verbatim: --allow/--deny values reach grok unchanged"
  else
    fail "allow-deny-verbatim: missing exact --allow $ALLOW_RULE (ok=$ok_a) or --deny $DENY_RULE (ok=$ok_d)"
  fi
fi

# ---------- meta.json fields + non-empty cmd that actually recorded the invocation
H="$T/h-meta"; L="$T/l-meta"
run_ccx "$H" "$L" --read --no-schema \
  --max-turns 17 --label meta-rec --model grok-test-model --effort medium -- "dispatch probe"
if expect_invoked "meta-json-record" "$L"; then
  meta="$(meta_of "$H" || true)"
  badf=()
  if [[ -z "$meta" || ! -f "$meta" ]]; then
    fail "meta-json-record: no meta.json written"
  else
    [[ "$(jq -r '.max_turns' "$meta")" == "17" ]] || badf+=("max_turns=$(jq -r '.max_turns' "$meta")")
    [[ "$(jq -r '.label' "$meta")" == "meta-rec" ]] || badf+=("label=$(jq -r '.label' "$meta")")
    [[ "$(jq -r '.sub' "$meta")" == "run" ]] || badf+=("sub=$(jq -r '.sub' "$meta")")
    [[ "$(jq -r '.profile' "$meta")" == "read" ]] || badf+=("profile=$(jq -r '.profile' "$meta")")
    [[ "$(jq -r '.model' "$meta")" == "grok-test-model" ]] || badf+=("model=$(jq -r '.model' "$meta")")
    [[ "$(jq -r '.effort' "$meta")" == "medium" ]] || badf+=("effort=$(jq -r '.effort' "$meta")")
    if ! jq -e '.cmd | type=="array" and length>0 and (index("--sandbox") != null)' "$meta" >/dev/null; then
      badf+=("cmd=$(jq -c '.cmd' "$meta")")
    fi
    if [[ ${#badf[@]} -eq 0 ]]; then
      pass "meta-json-record: max_turns,label,sub,profile,model,effort,cmd"
    else
      fail "meta-json-record: $(IFS=','; echo "${badf[*]}")"
    fi
  fi
fi

# ---------- run id includes pid: frozen clock + same label => two dirs iff $$ is in the id
H="$T/h-pid"
run_ccx "$H" "$T/l-pid1" --read --no-schema --label sametime -- "first"
r1=$last_rc
run_ccx "$H" "$T/l-pid2" --read --no-schema --label sametime -- "second"
r2=$last_rc
ids=()
shopt -s nullglob
for d in "$H"/runs/*; do
  [[ -d "$d" ]] && ids+=("$(basename "$d")")
done
shopt -u nullglob
if [[ "$r1" -ne 0 || "$r2" -ne 0 ]]; then
  fail "run-id-includes-pid: ccx exited $r1 / $r2"
elif [[ ${#ids[@]} -ne 2 ]]; then
  fail "run-id-includes-pid: want 2 run dirs in the same second, got ${#ids[@]} (${ids[*]:-none})"
else
  pids_ok=1
  pid_a=${ids[0]##*-}
  pid_b=${ids[1]##*-}
  for id in "${ids[@]}"; do
    case "$id" in
      20260101-120000-sametime-[0-9]*) ;;
      *) pids_ok=0 ;;
    esac
  done
  if [[ "$pids_ok" -eq 1 && "$pid_a" != "$pid_b" ]]; then
    pass "run-id-includes-pid: ${ids[0]} vs ${ids[1]}"
  else
    fail "run-id-includes-pid: ids not timestamp-slug-pid or pids collide (${ids[*]})"
  fi
fi

# ---------- blocked envelope => exit 3
H="$T/h-block"; L="$T/l-block"
STUB_JSON="$BLOCKED_JSON" run_ccx "$H" "$L" --read -- "blocked probe"
if [[ "$last_rc" -eq 3 ]]; then
  pass "blocked-exit-3: worker status=blocked -> exit 3"
else
  fail "blocked-exit-3: want exit 3, got $last_rc"
fi

# ---------- neither text nor structuredOutput => exit 5, not 0 with empty stdout
H="$T/h-empty"; L="$T/l-empty"
STUB_JSON="$EMPTY_JSON" run_ccx "$H" "$L" --read -- "empty probe"
if [[ "$last_rc" -eq 5 ]]; then
  pass "empty-envelope-exit-5: no text/structuredOutput -> exit 5"
elif [[ "$last_rc" -eq 0 ]]; then
  fail "empty-envelope-exit-5: exited 0 with an empty worker result"
else
  fail "empty-envelope-exit-5: want exit 5, got $last_rc"
fi

exit "$failures"
