---
description: Continue an existing Grok worker session with follow-up instructions
argument-hint: <session-uuid> <what to fix>
allowed-tools: Bash, Read, Grep, Glob
---

Continue the Grok worker session given in $ARGUMENTS.

Use `${CLAUDE_PLUGIN_ROOT}/bin/ccx cont --session <uuid> -- "<followup>"`.

Include the REAL failure output (actual command + actual stderr), not a paraphrase — the
worker still has its own context from the previous round, so it needs the delta, not a
restatement of the task. Then verify independently as usual.
