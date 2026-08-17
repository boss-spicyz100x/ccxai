#!/usr/bin/env bash
# Refusal cases must fail BEFORE any worker is dispatched.
#
# A check that only asks "nonzero + some ccx: line + no grok argv" is not
# coverage. Several of these guards sit in front of a later die() that would
# still look like a pass if the *specific* guard were deleted -- the same
# class of hole that let tests/phase-parity.sh ship while dropping real
# containment. Each case therefore matches the distinctive die() text of
# the guard it claims to cover.
#
# Point CCX at a copy to prove a broken guard actually FAILs this file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCX="${CCX:-$ROOT/plugins/ccx/bin/ccx}"

T=$(mktemp -d)
TMPCWD=$(mktemp -d /tmp/ccx-guard-XXXXXX)
cleanup() { rm -rf "$T" "$TMPCWD"; }
trap cleanup EXIT

LOG="$T/argv.log"
: > "$LOG"
mkdir -p "$T/home" "$T/repo"
git -C "$T/repo" init -q
git -C "$T/repo" config user.email "guard@test"
git -C "$T/repo" config user.name "guard"
git -C "$T/repo" commit --allow-empty -q -m init

# Same stub pattern as tests/phase-parity.sh: --version/--help are probes,
# anything else is a dispatch. Never on PATH ahead of this stub -- an empty
# GROK_BIN used to fall through to the real grok.
cat > "$T/grok" <<STUB
#!/usr/bin/env bash
case "\$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume --tools"; exit 0 ;;
esac
printf '%s\n' "=== INVOCATION ===" >> "$LOG"
for a in "\$@"; do printf '%s\n' "\$a" >> "$LOG"; done
echo '{"text":"{}","stopReason":"end_turn","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":1,"total_cost_usd":0,"usage":{},"structuredOutput":{"status":"done","summary":"s","files_changed":[],"evidence":[],"open_questions":[]}}'
STUB
chmod +x "$T/grok"

# Isolate every lookup that could reach a real worker or a real ~/.ccxai.
unset CCX_TIMEOUT CCX_MODEL CCX_EFFORT CCX_MAX_OUT
export PATH="$T:$PATH"
export HOME="$T/home"
export CCX_HOME="$T/home"
export GROK_BIN="$T/grok"

[[ -x "$CCX" ]] || { echo "FAIL setup: $CCX is not executable"; exit 1; }

fail=0

# $1 name  $2 distinctive needle from the guard's die()  $3... command
refuse() {
  local name="$1" needle="$2" rc=0 out
  shift 2
  : > "$LOG"
  out=$( "$@" 2>&1 ) || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL $name: expected non-zero exit, got 0"
    fail=1
    return
  fi
  if [[ "$out" != ccx:* ]]; then
    echo "FAIL $name: message not ccx:-prefixed: ${out:-<empty>}"
    fail=1
    return
  fi
  if [[ "$out" != *"$needle"* ]]; then
    echo "FAIL $name: missing '$needle': $out"
    fail=1
    return
  fi
  if [[ -s "$LOG" ]]; then
    echo "FAIL $name: dispatched worker"
    fail=1
    return
  fi
  echo "PASS $name"
}

run() { "$CCX" run "$@"; }

refuse "read+worktree" \
  "--read and --worktree conflict" \
  run --read --worktree w --cwd "$T/repo" -- x

refuse "worktree-slash" \
  "--worktree name must match" \
  run --worktree 'a/../../x' --cwd "$T/repo" -- x

refuse "worktree-dotdot" \
  "--worktree name must match" \
  run --worktree '..' --cwd "$T/repo" -- x

refuse "read-cwd-tmp" \
  "every sandbox profile leaves writable" \
  run --read --cwd /tmp -- x

if [[ -d /private/tmp ]]; then
  refuse "read-cwd-private-tmp" \
    "every sandbox profile leaves writable" \
    run --read --cwd /private/tmp -- x
fi

refuse "read-cwd-under-tmp" \
  "every sandbox profile leaves writable" \
  run --read --cwd "$TMPCWD" -- x

refuse "run-with-session" \
  "--session resumes an existing worker" \
  run --session 11111111-2222-3333-4444-555555555555 -- x

refuse "cont-no-session" \
  "ccx cont requires --session" \
  "$CCX" cont -- "followup"

refuse "show-dotdot" \
  "run id must match" \
  "$CCX" show '..'

refuse "show-slash" \
  "run id must match" \
  "$CCX" show 'foo/bar'

refuse "show-multiword" \
  "run id must match" \
  "$CCX" show 'foo bar'

refuse "timeout-zero" \
  "--timeout must be greater than 0" \
  run --timeout 0 -- x

refuse "timeout-negative" \
  "--timeout must be a positive integer" \
  run --timeout -5 -- x

refuse "timeout-non-number" \
  "--timeout must be a positive integer" \
  run --timeout abc -- x

refuse "n-non-numeric" \
  "-n must be a positive integer" \
  "$CCX" ls -n abc

refuse "days-non-numeric" \
  "--days must be a positive integer" \
  "$CCX" stats --days abc

refuse "empty-GROK_BIN" \
  "GROK_BIN is set but empty" \
  env GROK_BIN= "$CCX" run -- x

refuse "whitespace-brief" \
  "empty brief" \
  run --read --cwd "$PWD" -- $'   \t\n  '

exit $(( fail > 0 ? 1 : 0 ))
