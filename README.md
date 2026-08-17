# ccxai

**Claude Opus 5 (max) orchestrates. Grok 4.6 (xhigh) does the work.**

`ccx` dispatches scoped engineering tasks from Claude Code to a Grok 4.6 worker running
under the Grok Build CLI, and returns a small schema-validated JSON envelope.

Uses your **grok.com subscription** through the CLI's OAuth session. No `XAI_API_KEY`,
no pay-as-you-go billing.

## Why the CLI and not the API

Grok Build is already a complete agent harness — tools, permissions, kernel sandbox,
sessions, worktrees, MCP. A worker needs to *read the codebase itself*; that is the whole
point of orchestrator-worker. An API call gives you a model with no tools, so the
orchestrator has to ship all the context — which is the thing you were trying to avoid.

And decisively: **only the CLI can use a grok.com subscription.** Every API-based
alternative (`zen-mcp-server`, `claude-code-router`, a custom MCP server) needs an API
key and bills separately.

## Install

```bash
# in Claude Code
/plugin marketplace add ~/Documents/personal/research/ccxai
/plugin install ccx@ccxai

# or just put the dispatcher on PATH
ln -s ~/Documents/personal/research/ccxai/plugins/ccx/bin/ccx ~/.local/bin/ccx
ccx doctor
```

## Use

```bash
ccx run --read --label review --task brief.md          # read-only worker
ccx run --worktree fix-auth --task brief.md --check    # writes, confined to a worktree
ccx cont --session <uuid> -- "test_x still fails: ..." # correction round
ccx show <run-id> --transcript                         # full reasoning, on demand
ccx ls
```

In Claude Code: `/ccx:review`, `/ccx:implement`, `/ccx:cont`, or the `grok-worker`
subagent for parallel fan-out. The `grok-delegation` skill teaches Claude when to
delegate and when not to.

## The two things that make it work

**Ship a brief, never context.** The worker reads files itself in its own 500K window.
Pasting file contents into the brief spends the orchestrator's context on something the
worker gets for free.

**Verify independently.** The envelope is the worker's *claim*. Read the diff, run the
acceptance command yourself. `ccx` gives the worker an isolated worktree precisely so
that verification can happen before anything merges.

## Safety

Profiles are enforced by the OS kernel (macOS Seatbelt / Linux Landlock), not by prompt:

| Profile | Reads | Writes to disk | Network |
|---|---|---|---|
| `--read` (default) | anywhere | **nothing** | **not blocked on macOS** |
| `--write` | anywhere | run cwd + `/tmp` only | not blocked |

Two limits worth knowing, both found by testing rather than reading docs:

- **Network is not sandboxed on macOS.** Grok documents `read-only` as blocking child
  network, but that is Landlock (Linux); Seatbelt no-ops it. A `curl` from inside a
  read-only worker returns HTTP 200. A read-only worker cannot write to your disk, but it
  can still reach the network.
- **MCP servers run outside the sandbox.** They are separate processes, so a "read-only"
  worker could perform remote writes through them. `ccx` therefore passes
  `--deny "MCPTool(*)"` on every run; use `--mcp` to opt back in.

`ccx` pins these per invocation and never inherits `~/.grok/config.toml` — which on this
machine sets `yolo = true` / `permission_mode = "always-approve"`. That's fine when you
are driving interactively; it is not fine for an autonomously dispatched worker.

`/tmp` is writable under every profile, so `ccx` refuses to start a `--read` worker whose
cwd is on a temp path rather than let the guarantee quietly not apply.

## Operating notes

Learned from real use, not from the docs:

- **Start long reviews in the background.** A 2708-line subsystem review runs past ten
  minutes while working perfectly normally. Foreground limits will kill it.
- **A fresh worktree has no dependencies.** `git worktree add` gives you a clean checkout
  with no `node_modules`, so the acceptance command cannot run in it. Install deps and
  confirm the suite is green *before* delegating — otherwise you cannot tell the worker's
  breakage from a broken baseline.
- **Never edit `ccx` while a run is in flight.** Bash reads scripts lazily by byte offset;
  the running process will resume into rewritten content and corrupt that run.
- **Pin the CLI if you want stability.** `grok` auto-updates and has dropped flags across
  a major (`--check`, `--best-of-n` went away in 1.0). `ccx` asserts what it needs and
  records the version per run, but `auto_update = false` in `~/.grok/config.toml` is the
  real fix.

## Status

| Path | Evidence |
|---|---|
| `--read` review | **Proven.** Found 6 real defects in a 2708-line production subsystem; all 6 verified against source. Under $0.30. |
| `--write` in a worktree | **Works, lightly used.** Isolation verified (writes confined, main checkout clean, `cont` resumes in the worktree). Read every diff. |
| `grok-worker` agent | **Untested.** Ships, never run. |

See `DESIGN.md` for the full rationale, prior art, and measurements.
