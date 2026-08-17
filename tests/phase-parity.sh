#!/usr/bin/env bash
# Both dispatch phases must carry IDENTICAL containment — flags AND their values.
#
# Phase 2 exists only to format work phase 1 already did, which makes it easy to
# treat as harmless and hand-build. It was, and it silently dropped
# --permission-mode, --allow, 9 of 10 deny rules and --disallowed-tools, falling
# back to whatever ~/.grok/config.toml says -- the exact inheritance ccx exists to
# prevent. Nothing in the output revealed it; only capturing grok's argv did.
#
# An earlier version of this test compared flag *counts* and passed two real
# regressions: dropping --tools from phase 2, and swapping the deny rules for
# no-op patterns of the same count. It compares full (flag, value) sets now --
# a count-based check looks like coverage and isn't.
set -euo pipefail
CCX="$(cd "$(dirname "$0")/.." && pwd)/plugins/ccx/bin/ccx"
T=$(mktemp -d); LOG="$T/argv.log"; : > "$LOG"
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

# Every flag that contains the worker. A value-taking flag is captured WITH its
# value, so a same-count content swap cannot pass.
VALUED="--sandbox --permission-mode --allow --deny --tools --disallowed-tools"
BARE="--disable-web-search"

containment() {   # $1 = phase number -> prints sorted "flag=value" lines
  awk -v n="$1" '/=== INVOCATION ===/{c++} c==n' "$LOG" | awk -v v="$VALUED" -v b="$BARE" '
    BEGIN{ split(v,V," "); for(i in V) val[V[i]]=1; split(b,B," "); for(i in B) bare[B[i]]=1 }
    { if ($0 in val) { getline nxt; print $0 "=" nxt } else if ($0 in bare) print $0 "=" }
  ' | sort
}

fail=0
for profile in --read --write; do
  : > "$LOG"
  CCX_HOME="$T/home" GROK_BIN="$T/grok" "$CCX" run "$profile" --cwd "$PWD" \
    --tools "read_file,grep" --allow 'Bash(canary-allow*)' --deny 'Bash(canary-deny*)' \
    --raw -- "parity probe" >/dev/null 2>&1 || true
  n=$(grep -c '=== INVOCATION ===' "$LOG" || echo 0)
  if [[ "$n" -ne 2 ]]; then echo "FAIL $profile: expected 2 phases, saw $n"; fail=1; continue; fi

  p1=$(containment 1); p2=$(containment 2)
  if [[ "$p1" != "$p2" ]]; then
    echo "FAIL $profile: containment differs between phases"
    diff <(printf '%s\n' "$p1") <(printf '%s\n' "$p2") | sed 's/^/    /' || true
    fail=1
  fi
  # the containment set must be non-trivial, or an empty-vs-empty compare "passes"
  for required in --sandbox --permission-mode --deny --tools; do
    grep -q "^$required=" <<<"$p1" || { echo "FAIL $profile: phase 1 missing $required"; fail=1; }
  done
  [[ "$fail" -eq 0 ]] && echo "PASS $profile: $(grep -c . <<<"$p1") containment args identical across both phases"
done
rm -rf "$T"
exit "$fail"
