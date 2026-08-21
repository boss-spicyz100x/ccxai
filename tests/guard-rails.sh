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

ok(){ echo "PASS $1"; }
no(){ echo "FAIL $1"; fail=1; }

# --- --dry-run: exercise every guard without paying for it ---------------------
# The regression checks in CLAUDE.md pass a live brief (`-- x`), so a guard that
# stopped refusing used to dispatch a REAL worker. Two runs cost $0.047 asking
# what "x" meant before --dry-run existed. These assertions pin both halves: the
# guards still fire under --dry-run, and a run that passes them dispatches nothing.
: > "$LOG"
DRYHOME="$T/dryhome"
dry_out=$(CCX_HOME="$DRYHOME" "$CCX" run --read --cwd "$ROOT" --dry-run -- "probe" 2>&1); dry_rc=$?

if [[ "$dry_rc" -eq 0 ]]; then ok "dry-run exits 0 on a valid invocation"
else no "dry-run should exit 0 (got $dry_rc): $dry_out"; fi

if [[ -s "$LOG" ]]; then no "dry-run must not invoke grok (argv log is non-empty)"
else ok "dry-run does not invoke grok"; fi

if [[ -d "$DRYHOME/runs" ]]; then no "dry-run must not create a run directory"
else ok "dry-run leaves no run directory"; fi

# it is only useful as a containment check if it SHOWS the containment
for needle in "read-only" "MCPTool(*)" "bypassPermissions"; do
  if grep -qF -- "$needle" <<<"$dry_out"; then ok "dry-run shows $needle"
  else no "dry-run output omits $needle"; fi
done

# and the guards must still refuse when --dry-run is present
refuse "dry-run-still-refuses-conflict" \
  "--read and --worktree conflict" \
  run --read --worktree w --dry-run -- x
refuse "dry-run-still-refuses-traversal" \
  "must match" \
  run --worktree 'a/../../x' --dry-run -- x
refuse "dry-run-still-refuses-temp-cwd" \
  "every sandbox profile leaves writable" \
  run --read --cwd /tmp --dry-run -- x

# --dry-run must leave NOTHING behind, and that includes a git worktree. The
# short-circuit sits after argv assembly, which is after worktree creation, so
# `--dry-run --worktree` used to create a real worktree and branch.
WT_NAME="drynothing$$"
CCX_HOME="$T/wthome" "$CCX" run --write --worktree "$WT_NAME" --dry-run -- probe >/dev/null 2>&1 || true
if [[ -d "$T/wthome/worktrees" ]] && ls "$T/wthome/worktrees" 2>/dev/null | grep -q "$WT_NAME"; then
  no "dry-run must not create a git worktree"
else ok "dry-run creates no worktree"; fi
if git -C "$ROOT" worktree list 2>/dev/null | grep -q "$WT_NAME"; then
  no "dry-run must not register a worktree with git"
  git -C "$ROOT" worktree remove --force "$T/wthome/worktrees/$WT_NAME" 2>/dev/null || true
else ok "dry-run registers no worktree with git"; fi
if git -C "$ROOT" branch --list "ccx/$WT_NAME" 2>/dev/null | grep -q .; then
  no "dry-run must not create a branch"
  git -C "$ROOT" branch -D "ccx/$WT_NAME" >/dev/null 2>&1 || true
else ok "dry-run creates no branch"; fi

# fanout is a second entry point with its own dispatch path: DRY_RUN is parsed
# globally but only `run` short-circuits on it, so `fanout --dry-run` dispatched
# every brief for real.
FB="$T/drybriefs"; mkdir -p "$FB"; echo "GOAL a" > "$FB/a.md"; echo "GOAL b" > "$FB/b.md"
: > "$LOG"
CCX_HOME="$T/fdry" "$CCX" fanout --cwd "$ROOT" --briefs "$FB" --read --dry-run >/dev/null 2>&1 || true
if [[ -s "$LOG" ]]; then no "fanout --dry-run must not invoke grok"
else ok "fanout --dry-run does not invoke grok"; fi
if [[ -d "$T/fdry/runs" ]] && [[ -n "$(ls -A "$T/fdry/runs" 2>/dev/null)" ]]; then
  no "fanout --dry-run must not create run directories"
else ok "fanout --dry-run creates no run directories"; fi

# macOS puts TMPDIR under /var/folders. The pattern list matched that path only
# through the $TMPDIR pattern, so any context that does not export TMPDIR --
# cron, launchd, `env -u TMPDIR` -- accepted a --read cwd on a directory every
# sandbox profile leaves writable. /private/var/folders was listed; the
# unresolved /var/folders that TMPDIR actually names was not.
if [[ -d /var/folders ]]; then
  VARFOLDERS_CWD=$(TMPDIR=${TMPDIR:-/var/folders} mktemp -d 2>/dev/null || echo "")
  if [[ -n "$VARFOLDERS_CWD" && "$VARFOLDERS_CWD" == /var/folders/* ]]; then
    refuse "read-cwd-var-folders-no-tmpdir" \
      "every sandbox profile leaves writable" \
      env -u TMPDIR "$CCX" run --read --cwd "$VARFOLDERS_CWD" -- x
    rm -rf "$VARFOLDERS_CWD"
  fi
fi

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
