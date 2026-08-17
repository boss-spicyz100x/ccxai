---
description: Delegate a read-only review to a Grok 4.6 worker (cannot write; kernel-enforced)
argument-hint: [what to review, e.g. "the auth middleware" or "the staged diff"]
allowed-tools: Bash, Read, Grep, Glob
---

Delegate a review of **$ARGUMENTS** to a Grok 4.6 worker.

1. Identify the exact files/diff in scope. Do NOT read their contents into your own
   context — the worker reads them itself. You only need the paths.
2. Write a brief to a temp file using the GOAL/FILES/CONSTRAINTS/ACCEPTANCE/DELIVERABLE
   format from the grok-delegation skill. In DELIVERABLE, ask for concrete findings with
   file:line and a severity, and explicitly ask it to skip style nits.
3. Dispatch:
   `${CLAUDE_PLUGIN_ROOT}/bin/ccx run --read --label review --task <brief>`
4. Triage the envelope: for each finding, verify it against the real code before
   repeating it to me. Report only findings that survive. Say plainly which ones you
   checked and which you could not confirm.
