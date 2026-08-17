#!/usr/bin/env bash
# Read-only subcommands (show / ls / log / stats / doctor) must work against
# on-disk run state without dispatching a worker.
#
# Stats stdout is machine-readable JSON on its own; the human trailer belongs
# on stderr. show must still return an envelope when a kill between phases
# left only raw2.json. A record missing cost/label/status/profile/warnings
# must not crash stats.
#
# Point CCX at a copy of the dispatcher to prove a case actually fails.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCX="${CCX:-$ROOT/plugins/ccx/bin/ccx}"

FAIL=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAIL=1; }

if [[ ! -x "$CCX" ]]; then
  fail "setup: ccx not executable: $CCX"
  exit 1
fi
command -v jq >/dev/null 2>&1 || { fail "setup: jq is required"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

GROK="$T/grok"
cat > "$GROK" <<'STUB'
#!/usr/bin/env bash
# doctor calls --version and models. Anything else is an accidental dispatch.
case "$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume --tools"; exit 0 ;;
  models)    echo "logged in with grok.com (stub)"; exit 0 ;;
esac
echo "inspect.sh: stub grok invoked unexpectedly: $*" >&2
exit 1
STUB
chmod +x "$GROK"

# doctor greps ~/.grok/config.toml under pipefail; a 0-count grep -c aborts.
# Plant both patterns it looks for so this test does not depend on the real HOME.
FAKE_HOME="$T/home"
mkdir -p "$FAKE_HOME/.grok"
printf '%s\n' 'yolo = true' 'permission_mode = "always-approve"' '[mcp_servers.fake]' \
  > "$FAKE_HOME/.grok/config.toml"

run_ccx() {
  local home="$1"; shift
  HOME="$FAKE_HOME" CCX_HOME="$home" GROK_BIN="$GROK" "$CCX" "$@"
}

H_SHOW="$T/show";  mkdir -p "$H_SHOW/runs/run-alpha" "$H_SHOW/runs/run-kill" "$H_SHOW/runs/run-empty"
H_LS="$T/ls";      mkdir -p "$H_LS/runs/aaa-old" "$H_LS/runs/mmm-mid" "$H_LS/runs/zzz-new"
H_LOG="$T/log";    mkdir -p "$H_LOG"
H_STATS="$T/stats"; mkdir -p "$H_STATS"
H_SPARSE="$T/sparse"; mkdir -p "$H_SPARSE"
H_DOC="$T/doc";    mkdir -p "$H_DOC"

# ---------- fixtures ----------
cat > "$H_SHOW/runs/run-alpha/envelope.json" <<'EOF'
{"status":"done","summary":"UNIQUE-ENVELOPE-SUMMARY","files_changed":[],"evidence":[],"open_questions":[]}
EOF
cat > "$H_SHOW/runs/run-alpha/raw.json" <<'EOF'
{"thought":"UNIQUE-TRANSCRIPT-THOUGHT","text":"UNIQUE-TRANSCRIPT-TEXT"}
EOF
cat > "$H_SHOW/runs/run-alpha/meta.json" <<'EOF'
{"run":"run-alpha","status":"done","turns":3,"cost":0.01,"session":"11111111-2222-3333-4444-555555555555","profile":"read","label":"UNIQUE-META-LABEL"}
EOF
# kill-between-phases: raw.json / envelope.json absent, envelope lives in raw2
cat > "$H_SHOW/runs/run-kill/raw2.json" <<'EOF'
{"structuredOutput":{"status":"done","summary":"UNIQUE-RAW2-SUMMARY","files_changed":[],"evidence":[],"open_questions":[]},"text":"{}"}
EOF
cat > "$H_SHOW/runs/run-kill/meta.json" <<'EOF'
{"run":"run-kill","status":"done"}
EOF
cat > "$H_SHOW/runs/run-empty/meta.json" <<'EOF'
{"run":"run-empty","status":"done"}
EOF

for id in aaa-old mmm-mid zzz-new; do
  printf '%s\n' "{\"run\":\"$id\",\"status\":\"done\",\"turns\":1,\"cost\":0,\"session\":\"-\"}" \
    > "$H_LS/runs/$id/meta.json"
done
# set mtimes after the last write so ls -1t is deterministic
touch -t 200001010000 "$H_LS/runs/aaa-old"
touch -t 201006151200 "$H_LS/runs/mmm-mid"
touch -t 202608171200 "$H_LS/runs/zzz-new"

for i in 1 2 3 4 5; do
  jq -nc --arg r "L$i" '{run:$r}'
done > "$H_LOG/runs.jsonl"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  jq -nc --arg ts "$NOW" \
    '{ts:$ts,run:"new-keep",label:"keepme",status:"done",profile:"read",cost:0.5,seconds:20,warnings:[]}'
  jq -nc --arg ts "$NOW" \
    '{ts:$ts,run:"new-other",label:"other",status:"blocked",profile:"write",cost:0.25,seconds:5,warnings:["boom"]}'
  jq -nc \
    '{ts:"2000-01-01T00:00:00Z",run:"old-one",label:"ancient",status:"done",profile:"read",cost:99.0,seconds:10,warnings:[]}'
} > "$H_STATS/runs.jsonl"

{
  jq -nc --arg ts "$NOW" \
    '{ts:$ts,run:"complete",label:"ok",status:"done",profile:"read",cost:0.1,seconds:1,warnings:[]}'
  jq -nc --arg ts "$NOW" '{ts:$ts,run:"sparse"}'
} > "$H_SPARSE/runs.jsonl"

# ---------- show ----------
if out=$(run_ccx "$H_SHOW" show run-alpha 2>/dev/null); then
  if printf '%s\n' "$out" | jq -e '.summary=="UNIQUE-ENVELOPE-SUMMARY"' >/dev/null 2>&1; then
    pass "show-envelope"
  else
    fail "show-envelope: did not print envelope.json"
  fi
else
  fail "show-envelope: ccx exited non-zero"
fi

if out=$(run_ccx "$H_SHOW" show run-alpha --transcript 2>/dev/null); then
  if grep -q 'UNIQUE-TRANSCRIPT-THOUGHT' <<<"$out" \
     && grep -q 'UNIQUE-TRANSCRIPT-TEXT' <<<"$out" \
     && ! grep -q 'UNIQUE-ENVELOPE-SUMMARY' <<<"$out"; then
    pass "show-transcript"
  else
    fail "show-transcript: did not select transcript content"
  fi
else
  fail "show-transcript: ccx exited non-zero"
fi

if out=$(run_ccx "$H_SHOW" show run-alpha --meta 2>/dev/null); then
  if printf '%s\n' "$out" | jq -e '.label=="UNIQUE-META-LABEL"' >/dev/null 2>&1; then
    pass "show-meta"
  else
    fail "show-meta: did not print meta.json"
  fi
else
  fail "show-meta: ccx exited non-zero"
fi

if out=$(run_ccx "$H_SHOW" show run-kill 2>/dev/null); then
  if printf '%s\n' "$out" | jq -e '.summary=="UNIQUE-RAW2-SUMMARY"' >/dev/null 2>&1; then
    pass "show-raw2-fallback"
  else
    fail "show-raw2-fallback: expected structuredOutput from raw2.json"
  fi
else
  fail "show-raw2-fallback: ccx exited non-zero (kill-between-phases should still show)"
fi

if run_ccx "$H_SHOW" show run-empty >"$T/empty.out" 2>"$T/empty.err"; then
  fail "show-unreadable: expected non-zero when no result files exist"
else
  if grep -q 'no readable result' "$T/empty.err"; then
    pass "show-unreadable"
  else
    fail "show-unreadable: missing 'no readable result' on stderr"
  fi
fi

# ---------- stats ----------
# stdout must be standalone JSON: pipe it through jq and throw stderr away.
if run_ccx "$H_STATS" stats 2>/dev/null | jq -e 'type=="object" and has("runs")' >/dev/null 2>&1; then
  err=$(run_ccx "$H_STATS" stats 2>&1 >/dev/null || true)
  if grep -q 'recent failures' <<<"$err"; then
    pass "stats-stdout-json"
  else
    fail "stats-stdout-json: human trailer not on stderr"
  fi
else
  fail "stats-stdout-json: stdout is not valid JSON on its own"
fi

if out=$(run_ccx "$H_SPARSE" stats 2>/dev/null); then
  if printf '%s\n' "$out" | jq -e 'type=="object" and .incomplete_records>=1' >/dev/null 2>&1; then
    pass "stats-missing-fields"
  else
    fail "stats-missing-fields: expected valid JSON with incomplete_records>=1"
  fi
else
  fail "stats-missing-fields: crashed on a record missing cost/label/status/profile/warnings"
fi

if out=$(run_ccx "$H_STATS" stats --label keepme 2>/dev/null); then
  if printf '%s\n' "$out" | jq -e '
      type=="object"
      and .runs==1
      and (.spend_by_label|has("keepme"))
      and (.spend_by_label|has("ancient")|not)
      and (.spend_by_label|has("other")|not)' >/dev/null 2>&1; then
    pass "stats-label"
  else
    fail "stats-label: --label did not filter to keepme only"
  fi
else
  fail "stats-label: ccx exited non-zero"
fi

if unf=$(run_ccx "$H_STATS" stats 2>/dev/null) \
   && filt=$(run_ccx "$H_STATS" stats --days 1 2>/dev/null); then
  if printf '%s\n' "$unf" | jq -e 'type=="object" and (.spend_by_label|has("ancient"))' >/dev/null 2>&1 \
     && printf '%s\n' "$filt" | jq -e '
          type=="object"
          and (.spend_by_label|has("ancient")|not)
          and (.spend_by_label|has("keepme"))' >/dev/null 2>&1; then
    pass "stats-days"
  else
    fail "stats-days: --days did not drop the 2000-01-01 record"
  fi
else
  fail "stats-days: ccx exited non-zero"
fi

# ---------- ls / log / doctor ----------
if out=$(run_ccx "$H_LS" ls 2>/dev/null); then
  got=$(printf '%s\n' "$out" | awk '{print $1}')
  exp=$(printf '%s\n' zzz-new mmm-mid aaa-old)
  if [[ "$got" == "$exp" ]]; then
    pass "ls-newest-first"
  else
    fail "ls-newest-first: expected zzz-new mmm-mid aaa-old, got: $(printf '%s' "$got" | tr '\n' ' ')"
  fi
else
  fail "ls-newest-first: ccx exited non-zero"
fi

if out=$(run_ccx "$H_LOG" log -n 2 2>/dev/null); then
  ids=$(printf '%s\n' "$out" | jq -r '.run' 2>/dev/null || true)
  n=$(printf '%s\n' "$out" | grep -c . || true)
  if [[ "$n" -eq 2 && "$ids" == $'L4\nL5' ]]; then
    pass "log-n"
  else
    fail "log-n: expected last 2 lines L4 L5 (n=$n ids=$(printf '%s' "$ids" | tr '\n' ' '))"
  fi
else
  fail "log-n: ccx exited non-zero"
fi

if out=$(run_ccx "$H_DOC" doctor 2>/dev/null); then
  if grep -q '^ccx ' <<<"$out"; then
    pass "doctor"
  else
    fail "doctor: exited 0 but did not print a ccx header"
  fi
else
  fail "doctor: expected exit 0"
fi

exit "$FAIL"
