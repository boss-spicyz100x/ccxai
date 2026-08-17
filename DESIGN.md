# ccxai — Opus 5 orchestrator × Grok 4.6 worker

**Verdict:** delegate to the **Grok Build CLI in headless mode**, not to the xAI API,
and not by proxying Claude Code's own subagents onto Grok.

Two reasons, one of them decisive:

1. **Subscription.** `grok models` reports *"logged in with grok.com"* — an OAuth session,
   not an API key. Only the CLI can spend that subscription. Every API-based alternative
   (`zen-mcp-server`, `claude-code-router`, a hand-rolled MCP server) needs `XAI_API_KEY`
   and bills separately as pay-as-you-go. This alone eliminates three of the four options.
2. **A worker needs tools.** Grok Build is already a complete agent harness — tools,
   permissions, kernel sandbox, sessions, worktrees, MCP. An API call gives you a model
   with no file access, so the orchestrator must ship all the context, which is exactly
   what orchestrator-worker exists to avoid. Wrapping the CLI is ~300 lines; rebuilding
   it is months.

Status: **built and verified end-to-end** — see `plugins/ccx/`.

---

## 1. Verified on this machine (2026-08-17)

| Fact | Value | How verified |
|---|---|---|
| `grok` version | 0.2.93, `~/.grok/bin/grok`, authed via `auth.json` | `grok --version` |
| Default model / effort | `grok-4.6` / `xhigh` (already set in `~/.grok/config.toml`) | config read |
| Headless JSON envelope | `text, stopReason, sessionId, requestId, thought, usage, num_turns, total_cost_usd, modelUsage` | live call |
| Structured output | `--json-schema` returns validated `.structuredOutput` **and** still runs the tool loop | live call, 3 turns |
| Session resume | `--resume <uuid>` retains context across headless calls | planted + recalled a fact |
| Named session ids | **Rejected** — must be a valid UUID (bundled README is stale) | `Error: --session-id must be a valid UUID` |
| Worktree in headless | `-w/--worktree` is **ignored** under `-p` — orchestrator must create it | `grok --help` |
| Auth mode | **grok.com OAuth (subscription)** — no API key present | `grok models` |
| Sandbox | `--sandbox` is kernel-enforced (macOS Seatbelt). Blocks the file tool **and** the shell | canary write, both tools, blocked with `Operation not permitted` |
| Denied tools in headless | Return cleanly to the model ("Denied by permission policy") — no hang | live call |
| Cold-start overhead | ~9.8K input tokens of system prompt per fresh call (~5.2K cacheable) | live call |
| Measured: review | read-only worker, 4 turns, found 2 real defects: **$0.019 / 89s** | `ccx run --read` |
| Measured: fix | write worker in a worktree, correct 2-line diff, tests pass: **$0.012 / 21s** | `ccx run --worktree` |

### Version volatility — plan for it

The CLI **auto-updated 0.2.93 → 1.0.4 mid-session** (`auto_update = true`). `--check` and
`--best-of-n` were removed in that jump. `--json-schema`, `--sandbox`, `--reasoning-effort`,
`--resume`, `--rules`, `--permission-mode`, `--max-turns`, `--disallowed-tools` all survived.

Consequences baked into `ccx`: always pass `--no-auto-update`; implement self-verification
in the brief rather than via a flag; assert `--json-schema` support at dispatch time; record
the grok version in every run's `meta.json`.

### Sandbox profiles (the real safety story)

| Profile | FS read | FS write | Child network |
|---|---|---|---|
| `off` (default) | all | all | all |
| `workspace` | all | cwd + `/tmp` + `~/.grok/` | allowed |
| `read-only` | all | `~/.grok/` only | blocked |
| `strict` | cwd + system | cwd + `/tmp` | blocked |

Because the kernel is the boundary, a read-only worker can safely be given the *full*
toolset including shell — it simply cannot write. That is strictly better than trying to
express "read-only" as a list of tool-name and glob denials.

**Caveat: `/tmp` is writable under every profile.** A "read-only" worker whose cwd is
inside `/tmp` is not sandboxed in any meaningful sense. (This invalidated my first test.)

Correct tool IDs for `--tools` / `--disallowed-tools` (guessing these wrongly silently
strips the toolset and the worker answers blind):
`run_terminal_cmd, grep, read_file, search_replace, list_dir, web_search, web_fetch, todo_write, task`
plus `Agent` / `Agent(type)` to block nested subagent spawning.

---

## 2. Prior art — how people actually do this

| Approach | Example | Verdict |
|---|---|---|
| **CLI-delegation plugin** — subagent forwards a task to another vendor's CLI | `openai/codex-plugin-cc` (official), `zachdunn/grok-plugin-claude-code` (Grok reimpl) | **The pattern that won.** Both wrap the foreign CLI in headless JSON mode behind a Claude subagent + slash commands. |
| **Multi-model MCP server** — Claude calls out to Gemini/GPT/Grok for opinions | `zen-mcp-server` | Good for *consultation*, wrong for *delegation* — the model gets no tools, so the orchestrator must ship all context itself. |
| **Router / proxy** — Claude Code's own Task subagents run on Grok | `claude-code-router`, CCR `<CCR-SUBAGENT-MODEL>provider,model</...>` | Clever, fragile. Claude Code's system prompt and tool schemas are tuned for Claude; you also throw away Grok's own harness. Not the primary. |
| **Native subagent `model:` field** | Claude Code frontmatter | Anthropic models only. Dead end for xAI. |

The pattern reference for the orchestration itself is Anthropic's own multi-agent research
system: lead agent plans → spawns workers with **detailed self-contained briefs** → synthesizes.
Reported ~90% lift over single-agent, at ~15x tokens. The cost multiplier is the thing to
design against — which is exactly why the worker here is the cheap model.

---

## 3. Architecture

```
Opus 5 (max)  ── orchestrator: plans, writes briefs, verifies, integrates
     │
     │  brief (self-contained, ~40 lines)      envelope (JSON, ~30 lines)
     ▼                                          ▲
  bin/ccx  ── dispatcher: pins model/effort, safety profile, schema, worktree,
     │        writes full transcript to disk, prints ONLY the envelope
     ▼
grok -p (grok-4.6, xhigh) ── worker: own 500K context, own tool loop, own cwd
```

**The load-bearing idea: the orchestrator ships a brief, never context.**
The worker reads the files itself. That is the entire point — Opus's context stays
clean, and Grok's 500K window absorbs the grep/read churn.

### Three rules the dispatcher enforces

1. **Small return.** Full transcript → `.ccxai/runs/<id>/`; stdout is only the validated
   envelope + file paths. Without this, a chatty worker eats the orchestrator's context
   and you've inverted the whole benefit.
2. **Pinned safety.** Never inherit the global `yolo = true` / `permission_mode = "always-approve"`
   currently in `~/.grok/config.toml`. An autonomous orchestrator + auto-approved `rm` is the
   one genuinely dangerous combination here.
3. **Pinned model/effort.** `-m grok-4.6 --reasoning-effort xhigh` explicitly, so a config
   change never silently downgrades workers.

---

## 4. The contract

### 4a. Return envelope (`--json-schema`, verified working)

```json
{"type":"object","additionalProperties":false,
 "required":["status","summary","files_changed","evidence","open_questions"],
 "properties":{
  "status":{"enum":["done","partial","blocked"]},
  "summary":{"type":"string","description":"<=120 words, what changed and why"},
  "files_changed":{"type":"array","items":{"type":"object","additionalProperties":false,
    "required":["path","what"],
    "properties":{"path":{"type":"string"},"what":{"type":"string"}}}},
  "evidence":{"type":"array","items":{"type":"string"},
    "description":"commands run + their verdicts, e.g. 'pytest -q -> 41 passed'"},
  "open_questions":{"type":"array","items":{"type":"string"}},
  "next_steps":{"type":"array","items":{"type":"string"}}}}
```

`status: blocked` + `open_questions` is the escape hatch that stops a worker from
guessing when the brief is underspecified — cheaper than letting it invent an answer.

### 4b. Task brief (what Opus writes)

```
GOAL        one sentence, testable
FILES       exact paths + one line each on why they matter (paths, NOT contents)
CONSTRAINTS what not to touch; API/style invariants
ACCEPTANCE  the literal command that must pass
DELIVERABLE what to put in the envelope
```

Vague briefs are the documented failure mode of orchestrator-worker systems.
Budget real Opus effort here — the brief *is* the interface.

### 4c. Dispatcher (implemented: `plugins/ccx/bin/ccx`)

```bash
ccx run  --task brief.md [--write] [--cwd DIR] [--worktree NAME] [--timeout 900]
ccx cont --session <uuid> --task followup.md     # correction round, keeps worker context
ccx show --run <id>                              # full transcript on demand
```

Read profile — kernel makes it read-only, so permissions can be fully permissive:
```bash
grok --no-auto-update -p "$BRIEF" --cwd "$DIR" -m grok-4.6 --reasoning-effort xhigh \
  --sandbox read-only --permission-mode bypassPermissions \
  --disallowed-tools "Agent" --disable-web-search \
  --rules "$WORKER_RULES" --max-turns 30 --json-schema "$SCHEMA" --output-format json
```

Write profile — worktree for logical isolation, `workspace` sandbox for physical isolation:
```bash
git worktree add "$WT" HEAD                # grok's -w does nothing under -p
grok --no-auto-update -p "$BRIEF" --cwd "$WT" -m grok-4.6 --reasoning-effort xhigh \
  --sandbox workspace --permission-mode acceptEdits --allow "Bash" \
  --deny "Bash(sudo*)" --deny "Bash(git push*)" --deny "Bash(gh*)" --deny "Write(**/.env*)" \
  --rules "$WORKER_RULES" --max-turns 60 --json-schema "$SCHEMA" --output-format json
```
The deny list is defence-in-depth for the things the sandbox *doesn't* stop — network-side
effects like `git push` and `gh`, which `workspace` permits.

### 4d. Loop

```
plan (Opus) → brief → ccx run → envelope
           → VERIFY INDEPENDENTLY (git diff + run the acceptance command yourself)
           → pass? integrate.  fail? ccx cont --session <uuid> with the failure output
```

Independent verification is non-negotiable: the envelope is the worker's *claim*.
Grok's `--check` flag adds worker self-verification — useful, not a substitute.
The `--resume` path is much better than a fresh brief for round 2: the worker keeps
its own reasoning context, and you skip the ~10K cold-start.

---

## 5. When to delegate

**Economic rule:** delegate when *cost(writing the brief) << cost(doing it yourself)*.
Below roughly one full file of work, the brief costs more than the task.

| Delegate | Keep in Opus |
|---|---|
| Wide mechanical work — migrations, codemods, test authoring across many files | Anything depending on accumulated conversation context |
| Exhaustive enumeration (edge cases, call sites) — Grok was strong at this in the smoke test | Architecture and API design calls |
| Large-context reads that would blow up Opus's window (500K available) | Small surgical edits |
| Independent second-opinion review of a diff | Final integration and the verification pass |
| Parallel exploration — N workers × N worktrees, or `--best-of-n` | Anything with irreversible side effects |

Cost anchor: Grok 4.6 is $2/$6 per M in/out, ~$0.02 minimum per fresh call from system-prompt
overhead alone. Batch into one substantial brief; don't dispatch micro-tasks.

---

## 6a. What dogfooding found

Pointing the tool at its own source turned up four defects in the design above. All were
verified against the real code or by canary before being accepted.

| Defect | Verified how | Fix |
|---|---|---|
| **`--json-schema` races the tool loop.** The worker can emit a schema-shaped answer on turn 1 *instead of* calling tools, then confidently report a fabricated result. | Controlled A/A below | Two-phase: phase 1 free-form, phase 2 `--resume` at low effort purely to format. `--schema-inline` keeps old behaviour |
| **MCP servers bypass the sandbox.** A `--read` session had `signoz_delete_alert`, `signoz_create_dashboard` etc. attached — separate processes outside Seatbelt, pointed at a live instance | grepped the session history; confirmed `--deny "MCPTool(*)"` blocks it | Deny MCP on every run; `--mcp` to opt in |
| **Network is not sandboxed on macOS.** Grok's "child network blocked" for `read-only` is Landlock/Linux only | `curl` canary inside a read-only worker returned HTTP 200 | Documentation corrected; no code fix possible |
| **Timeout destroyed the work.** 15 min of xhigh reasoning, `raw.json` 0 bytes, no session id, unrecoverable | the 900s timeout fired on a real review | Pre-generate the session UUID with `-s` so the session is addressable even when there is no output; timeout prints the resume command. Default raised to 1800s |

### The schema race, measured

Task: *"Read plugins/ccx/bin/ccx and report exactly how many lines it has."* Ground truth
413. Ten identical runs, five per mode, `--effort low`:

| Mode | Result | Failure |
|---|---|---|
| `--schema-inline` (single call) | 4/5 correct | run 2: **`turns=1`, `line_count=1`** — answered without ever opening the file |
| two-phase (default) | 4/5 correct | run 3: `turns=2`, `line_count=414` — *read* the file, counted `split("\n")` on a trailing newline |

Both modes missed once, but the failures are not comparable. The single-phase failure is a
fabrication: one turn, no tool call, a confident wrong number. The two-phase failure is a
convention disagreement by a worker that did the work. Only the first is dangerous, and it
cannot occur in two-phase by construction — phase 1 carries no schema, so there is nothing
to short-circuit the tool loop with.

Cost of the safety: **$0.0176 vs $0.0092 per run** (1.9x), and no wall-clock penalty
(10s vs 11s average). Five runs per arm is a small sample; the argument rests on the
mechanism, and the measurement is confirmation rather than proof.

Lesser defects, all confirmed by inspection and fixed: `--worktree` silently overrode
`--read` (last-wins) so a read request could get a write worker; `ccx cont` did not
restore the parent run's profile/cwd, so resuming a worktree run wrote to the main
checkout; `--read` did not reject a cwd on temp paths where the guarantee cannot hold;
run ids collided for parallel same-label workers within one second; `--worktree` names
were unsanitized (`foo/../../../.ssh/pwned` escaped the worktree root); a pre-existing
directory was reused as a worktree without checking it was one; `show --transcript`
advertised a full transcript but printed only `.text`.

One reported defect was **not** real: a `line 258: command not found` error came from my
editing `ccx` while an instance was running — bash reads scripts lazily by byte offset,
so the running process resumed at a stale offset into rewritten content. Worth knowing
as an operational hazard when iterating on a script that is currently dispatching.

## 6b. Gotchas found while testing

- `--json-schema` **plus a misspelled `--tools` list** = the worker answers on turn 1 with
  `status: blocked` having touched nothing. Looks like a schema bug; it is a toolset bug —
  invalid tool IDs are dropped silently, leaving the worker with no tools.
- `/tmp` is writable under every sandbox profile; don't test or run "read-only" workers there.
- The CLI auto-updates and drops flags across majors. Pin `--no-auto-update`, record the version.
- Named session ids are gone in 0.2.93 — generate a UUID (`uuidgen`) or capture the returned one.
- `-w/--worktree` silently does nothing under `-p`. Create the worktree yourself.
- `--tools`, `--disallowed-tools`, `--max-turns` are headless-only; ignored with a warning in the TUI.
- Resuming replays history — later rounds get more expensive. Cap correction rounds at ~2, then re-brief fresh.
- The bundled `~/.grok/README.md` (Jul 9) is older than the binary (Aug 17). `grok --help` wins.
- `git rev-parse --git-common-dir` returns a **relative** `.git` from a main checkout and
  an absolute path from a worktree. Comparing the two with `-ef` resolves the relative one
  against the caller's cwd, so a legitimate worktree reads as foreign. Use
  `--path-format=absolute`. (This shipped as a guard rail and broke every worktree reuse
  on the first real write task — found by using it, not by reading it.)
- Editing the dispatcher while it is running corrupts that run: bash reads scripts lazily.
- A run can die in two different ways and only one of them is yours. `ccx`'s own
  `timeout` fires and can report; an **external** SIGTERM (harness limit, ctrl-c, sleep)
  kills the dispatcher before it reports anything. Recording the session id only on the
  self-timeout path still loses the work. Write it to `meta.json` *before* dispatching.
- Long reviews must be started in the background. A real 2708-line subsystem review
  exceeded a 10-minute foreground limit while still working normally.
- `grep -c` with zero matches prints `0` *and* exits 1, so `$(grep -c … || echo 0)` yields
  a two-line `0\n0` that breaks numeric comparison.

---

## 6c. First real write task

Target: the `n <= 45` ceiling this tool's own review had confirmed in a production
Cloudflare Worker pipeline. Baseline established first (deps installed in the worktree,
typecheck 0, suite `ALL PASS`) so any failure would be attributable.

Worker: 15 turns, 154s, $0.10. One-line diff, `test/` untouched, both acceptance commands
green. The envelope's `evidence[]` was accurate and volunteered its own caveats.

Two things only independent verification caught:

1. **The green suite proved less than it appeared.** `slot-coverage.test.ts` `SKIP`s
   without `char1/char2.pkg` and exits 0, and no test references `extractCharDerived`.
   The change is verified by inspection and typecheck, not by an executed test. Trusting
   `evidence[]` at face value would have recorded this as test-verified.
2. **A design decision was hiding in a one-line diff.** The worker gated on
   `charSources.has(n)` and rebuilt the path, preserving the original 8MB read window.
   Reusing `charSources.get(n)` instead also inherits the 64KB window the author chose
   for those same packages — better on Worker memory, worse on subrequest count. That is
   a production tradeoff for the repo owner, not something a worker or an orchestrator
   should silently pick.

The second is the more interesting one: the worker did the job correctly and still left a
judgement call on the table. Reviewing the diff is not just defect-hunting.

## 7. What was built

```
plugins/ccx/
├── bin/ccx                          dispatcher: profiles, schema, worktree, run dir,
│                                    envelope-only stdout, session continuation
├── skills/grok-delegation/SKILL.md  when to delegate, brief format, verify discipline
├── commands/{review,implement,cont}.md
└── agents/grok-worker.md            optional wrapper for parallel fan-out
```

Install: `/plugin marketplace add ~/Documents/personal/research/ccxai` then
`/plugin install ccx@ccxai`. Or symlink `bin/ccx` onto `PATH`.

Not built (deliberately): an MCP server (can't use the subscription), a router
(fragile, discards Grok's harness), background job control (`ccx` runs are short;
add it only if long-running workers become common).
