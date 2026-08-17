#!/usr/bin/env bash
# Both dispatch phases must carry IDENTICAL containment flags.
#
# Phase 2 exists only to format work phase 1 already did, which makes it easy to
# treat as harmless and hand-build. It was, and it silently dropped
# --permission-mode, --allow, 9 of 10 deny rules and --disallowed-tools, falling
# back to whatever ~/.grok/config.toml says -- the exact inheritance ccx exists to
# prevent. Nothing in the output revealed it; only capturing grok's argv did.
set -euo pipefail
CCX="$(cd "$(dirname "$0")/.." && pwd)/plugins/ccx/bin/ccx"
T=$(mktemp -d); LOG="$T/argv.log"; : > "$LOG"
cat > "$T/grok" <<STUB
#!/usr/bin/env bash
case "\$1" in
  --version) echo "grok 0.0.0 (stub)"; exit 0 ;;
  --help)    echo "--json-schema --sandbox --permission-mode --resume"; exit 0 ;;
esac
printf '%s\n' "=== INVOCATION ===" >> "$LOG"
for a in "\$@"; do printf '%s\n' "\$a" >> "$LOG"; done
echo '{"text":"{}","stopReason":"end_turn","sessionId":"11111111-2222-3333-4444-555555555555","num_turns":1,"total_cost_usd":0,"usage":{},"structuredOutput":{"status":"done","summary":"s","files_changed":[],"evidence":[],"open_questions":[]}}'
STUB
chmod +x "$T/grok"

fail=0
for profile in --read --write; do
  : > "$LOG"
  CCX_HOME="$T/home" GROK_BIN="$T/grok" "$CCX" run "$profile" --cwd "$PWD" \
    --deny 'Bash(canary-marker*)' --raw -- "parity probe" >/dev/null 2>&1 || true
  n=$(grep -c '=== INVOCATION ===' "$LOG" || echo 0)
  if [[ "$n" -ne 2 ]]; then echo "FAIL $profile: expected 2 phases, saw $n"; fail=1; continue; fi
  for f in --permission-mode --allow --deny --disallowed-tools --sandbox --disable-web-search; do
    p1=$(awk '/=== INVOCATION ===/{n++} n==1' "$LOG" | grep -cx -- "$f" || true)
    p2=$(awk '/=== INVOCATION ===/{n++} n==2' "$LOG" | grep -cx -- "$f" || true)
    if [[ "${p1:-0}" -ne "${p2:-0}" ]]; then
      echo "FAIL $profile: $f phase1=$p1 phase2=$p2"; fail=1
    fi
  done
  c1=$(awk '/=== INVOCATION ===/{n++} n==1' "$LOG" | grep -c 'canary-marker' || true)
  c2=$(awk '/=== INVOCATION ===/{n++} n==2' "$LOG" | grep -c 'canary-marker' || true)
  [[ "${c1:-0}" -eq "${c2:-0}" && "${c1:-0}" -gt 0 ]] || {
    echo "FAIL $profile: user --deny not carried to phase 2 (p1=$c1 p2=$c2)"; fail=1; }
  [[ "$fail" -eq 0 ]] && echo "PASS $profile: containment identical across both phases"
done
rm -rf "$T"
exit "$fail"
