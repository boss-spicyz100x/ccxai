---
name: grok-delegation
description: Delegate engineering work to a Grok 4.6 worker via the ccx dispatcher. Use BY DEFAULT, deciding before starting rather than after struggling, for: any mechanical change across 3 or more files (migrations, codemods, renames, adding tests across modules); needing to read 5 or more files to answer something; reviewing any diff or subsystem over roughly 200 lines; exhaustively enumerating edge cases, call sites, or failure modes; a second opinion on work just done here; and anything you would otherwise call slow or large. Not for edits under about one file of work, architecture and API decisions, irreversible or outward-facing actions, or work depending on this conversation's accumulated context.
---

# Delegating to a Grok 4.6 worker

You are the orchestrator. `ccx` dispatches a **Grok 4.6 worker** (xhigh reasoning,
500K context, its own tool loop) and returns a small validated JSON envelope.

## The one rule that matters

**Ship a brief, never context.** The worker reads the files itself. Do not paste file
contents into the brief — you are paying your own context for something the worker can
read for free in its own window. Pasting context defeats the entire purpose.

## When to delegate

Delegate when *writing the brief costs less than doing the work*. Below roughly one
full file of work, the brief costs more than the task — just do it yourself.

| Delegate | Keep |
|---|---|
| Wide mechanical work across many files | Anything needing this conversation's context |
| Exhaustive enumeration (edge cases, call sites) | Architecture and API design decisions |
| Large-context reads that would flood your window | Small surgical edits |
| Independent review of a diff | Final integration + the verification pass |
| Parallel exploration (N worktrees, N workers) | Anything irreversible |

## Brief format

```
GOAL        one sentence, testable
FILES       exact paths + one line each on why they matter (paths, NOT contents)
CONSTRAINTS what not to touch; invariants to preserve
ACCEPTANCE  the literal command that must pass
DELIVERABLE what to put in the envelope
```

A vague brief is the documented failure mode of orchestrator-worker systems. Spend real
effort here — the brief *is* the interface.

## Commands

```bash
# review / analysis — kernel-enforced read-only, worker cannot write anything
ccx run --read --label review --task brief.md

# implementation — isolated git worktree, writes confined to it
ccx run --worktree fix-auth --label fix-auth --task brief.md --check

# correction round — keeps the worker's own context, skips the ~10K cold start
ccx cont --session <uuid> -- "test_foo still fails: <paste real failure>"

ccx show <run-id> --transcript    # full reasoning, on demand only
ccx ls                            # recent runs
```

## Verification is your job

The envelope is the worker's **claim**, not a fact. Before integrating anything:

1. `git -C <worktree> diff` — read the actual change.
2. Run the acceptance command yourself. Do not accept `evidence[]` as proof.
3. Check the constraints held (it didn't edit the test file to make tests pass).

`status: "blocked"` with `open_questions` means the brief was underspecified. Answer the
questions and use `ccx cont` — do not re-dispatch a fresh worker.

Cap correction rounds at ~2. Resuming replays history, so cost grows; after two failed
rounds the brief itself is wrong. Rewrite it and start fresh.

## Cost

Grok 4.6 is far cheaper than Opus, but each fresh call carries ~10K tokens of system
prompt (~$0.02) before any work. Batch into one substantial brief rather than dispatching
micro-tasks. A real fix-a-bug-in-a-worktree round trip measured ~$0.01 / 21s.
