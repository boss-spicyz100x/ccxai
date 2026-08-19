---
description: Delegate an implementation task to a Grok 4.6 worker in an isolated git worktree
argument-hint: [what to implement/fix]
allowed-tools: Bash, Read, Grep, Glob, Edit
---

Delegate implementation of **$ARGUMENTS** to a Grok 4.6 worker.

1. Work out the acceptance command first (the test/build/lint that must pass). If there
   isn't one, say so and propose one — a task with no acceptance criterion should not be
   delegated.
2. Write the brief (GOAL/FILES/CONSTRAINTS/DECIDED/AMBIGUITY/ACCEPTANCE/DELIVERABLE).
   Paths, not contents. DECIDED and AMBIGUITY are not optional: 24% of runs came back
   asking a question the brief could have answered, and each one costs a `ccx cont` round.
   State explicitly what must NOT be touched — especially the test files.
3. Dispatch into an isolated worktree:
   `${CLAUDE_PLUGIN_ROOT}/bin/ccx run --worktree <short-name> --label <short-name> --task <brief> --check`
4. **Verify independently** — this is not optional:
   - `git -C <worktree> diff` and read the real change
   - run the acceptance command yourself
   - confirm the constraints held
5. If it failed, `ccx cont --session <uuid>` with the real failure output. Max 2 rounds,
   then rewrite the brief.
6. Report: what changed, what you verified, and how to merge the worktree.
