# Codex Review Wrapper (V2) — `tools/codex-review.sh`

Single source of truth for launching and observing an external Codex review.
Every Superflow path that used to shell out to `codex exec` goes through this wrapper.

## Why

The old pattern hid the work and tracked the wrong process:

```bash
timeout 900 codex exec ... 2>&1 | tail -30     # nothing visible until the pipeline ends
PID=$(pgrep -f "codex exec.*Facade" | head -1) # matched the parent SHELL, not codex
tail --pid=$PID -f /dev/null                   # shell waits on tail, tail waits on shell
```

On 2026-06-16 that produced a circular wait that hung for 26 days (bash `2773246` ↔ `tail 2773269`),
and it let the orchestrator report "the process exists" as if it meant "Codex is working".
**Process liveness is not progress.** Codex CLI was never at fault — it has supported `--json` and
`--output-last-message` all along.

## Guarantees

| | |
|---|---|
| AC01 | Full raw JSONL event stream on disk, visible during the run. No `\| tail -N`. |
| AC02 | PID/PGID captured at launch from `$!`. **No `pgrep`, ever.** |
| AC03 / AC10 | Unique run dir per review; concurrent reviews never collide. |
| AC04 | `status.json` written atomically (tmp + rename). |
| AC05 | Heartbeat: elapsed, last-event age, remaining deadline, progress-confirmed. |
| AC06 | Normal run reaches `VERDICT_PARSED` with all artifacts. |
| AC07 | Silence is reported as `SILENT` / `STALLED_SUSPECTED`, never as confirmed progress. |
| AC08 | Hard deadline TERMs → KILLs the whole **process group**. Escalation is driven by *group* liveness (zombies excluded), not by the leader — a descendant that ignores SIGTERM still gets SIGKILLed. No orphans. |
| AC09 | Missing/malformed verdict ⇒ gate CLOSED. Never a false PASS. |
| AC11 | Cleanup verifies the `(pid, starttime)` tuple — a reused PID is never killed. |
| AC12 | Prompt goes via file/stdin, never argv (not in the process list, no argv limit). |

The child is launched as a **job-controlled background job** (`set -m`), so bash makes it the leader
of its own process group and `$!` *is* the PGID by construction — no lookup, no name matching. The
deadline is enforced in-loop rather than by an outer `timeout`, because nesting `timeout` around the
wrapper re-creates exactly the "which PID is the real one" confusion this exists to eliminate.

## Usage

```bash
# technical code review against a base branch (default --mode review)
bash tools/codex-review.sh run --slug sprint-3-technical --base main --effort high \
  --prompt-file /tmp/review-prompt.md

# plain `codex exec` (spec review, audit, contract gate…)
bash tools/codex-review.sh run --slug contract-gate --mode exec --effort high \
  --prompt-file docs/superflow/contracts/2026-07-12-x.contract.yml

bash tools/codex-review.sh reconcile <run-dir>      # after a wrapper crash
bash tools/codex-review.sh cleanup   <run-dir> [--force]
```

**Never** wrap it in an outer `timeout`. **Never** pipe it into `tail`. (Tailing the *log file* —
`tail -f <run>/events.jsonl` — is fine and encouraged; piping the *review* into `tail -N` is not.)

## Run directory

`.superflow/reviews/<slug>/<run-id>/` (gitignored via `.superflow/`):

| Artifact | Content |
|---|---|
| `events.jsonl` | full `codex exec --json` stream, append-only |
| `final.md` | last agent message (`--output-last-message`) |
| `stderr.log` | CLI / broker / wrapper errors |
| `status.json` | state, timestamps, deadline, pid/pgid/starttime, exit code, progress_confirmed |
| `pid` | exact PID, written immediately at launch |
| `prompt.md` | the prompt (kept out of argv) |
| `verdict.json` | mechanically extracted + schema-validated verdict |

## States

`STARTING → SESSION_CREATED → MODEL_WAIT → TOOL_ACTIVE → SYNTHESIZING → COMPLETED → VERDICT_PARSED`
plus `SILENT`, `STALLED_SUSPECTED`, `TIMED_OUT`, `FAILED`.

Derived from the real event grammar of codex-cli 0.144.1 (verified live 2026-07-12):

| Event | Meaning |
|---|---|
| `thread.started` | → `SESSION_CREATED` (carries `thread_id`) |
| `turn.started` | → `MODEL_WAIT` — request sent, waiting on provider/broker. **Not** progress. |
| `item.started` / `item.completed` with `item.type` = `command_execution`, `collab_tool_call`, `mcp_tool_call`, `file_change`, `reasoning`, `web_search`, `patch_apply`, … | → `TOOL_ACTIVE` (progress confirmed). Any *unknown* item type is classified as tool activity, so a new CLI item type degrades safely instead of being ignored (`collab_tool_call` was first seen on a live run and needed no code change). |
| `item.completed` with `item.type` = `agent_message` | → `SYNTHESIZING` |
| `item.*` with `item.type` = `error` | recorded in `cli_errors[]` — **diagnostic only**. The real CLI emits these on fully successful (exit 0) runs, e.g. config-deprecation notices. Never fails a review on its own. |
| `turn.completed` | model finished the turn (carries `usage`) |
| `turn.failed` | → `FAILED` |

`progress_confirmed` flips to `true` only when the model actually emits items — a live process that
has sent the request and heard nothing back stays `progress_confirmed=false`.

Thresholds (env or flags): `CODEX_REVIEW_DEADLINE_SEC` (900), `CODEX_REVIEW_SILENT_SEC` (150),
`CODEX_REVIEW_STALL_SEC` (300), `CODEX_REVIEW_HEARTBEAT_SEC` (30), `CODEX_REVIEW_GRACE_SEC` (10).

## Review mode does not use `codex exec review`

codex-cli 0.144.1 **refuses** `exec review --base <BRANCH>` together with a `[PROMPT]` positional
(`-` counts as one):

```
error: the argument '--base <BRANCH>' cannot be used with '[PROMPT]'
```

Superflow's gate *requires* the custom prompt — it carries the verdict contract and the
contract-gate criteria rubric — so we cannot drop it. `--mode review` therefore runs a plain
`codex exec` and puts the scope **into the prompt** ("review `git diff <base>...HEAD`"); the
reviewer runs the diff itself. Verdict semantics are unchanged (AC13). The old documented command
(`codex exec review --base main … - < prompt`) was already broken against this CLI — the wrapper's
first live run surfaced it, and `tools/test-fixtures/fake-codex.sh` now reproduces the constraint so
the suite catches any regression.

## Verdict

The reviewer ends its message with a fenced JSON block. The wrapper takes the **last** fenced block
in `final.md` — which the reviewer contract says must be the verdict, with nothing after it —
validates it, and writes `verdict.json`. It deliberately does **not** scan backwards for "the most
recent block that happens to parse": if the final block is truncated or garbled, falling back to an
earlier valid fence would let a broken response through as a clean PASS. All three contract fields
(`verdict`, `findings`, `summary`) are **mandatory** — an incomplete object is not a verdict.

```json
{"verdict":"APPROVE","verdict_class":"pass","gate":"open","findings":[],"findings_count":0,"summary":"…"}
```

Verdict strings are unchanged from Rule 3.9 (AC13) — pass: `APPROVE` `ACCEPTED` `PASS`;
fail: `REQUEST_CHANGES` `NEEDS_FIXES` `FAIL`.

Prose is **never** interpreted. A final message that merely says "I approve this" produces no
verdict, exits 1, and leaves the gate closed. `.par-evidence.json` is assembled only from a
validated `verdict.json`.

**Exit codes:** `0` pass-class · `3` fail-class · `1` no valid verdict (FAILED/TIMED_OUT/malformed → gate CLOSED) · `2` usage error.

## Feature flag & rollback

`CODEX_REVIEW_WRAPPER_V2=1` (default, ON). Rollback: `CODEX_REVIEW_WRAPPER_V2=0` — drops the state
machine, heartbeat and event parsing, but still keeps the exact `$!`, the hard deadline with a
process-group kill, separate stdout/stderr, and a recorded exit code. It does **not** reintroduce
`pgrep` or `tail --pid`, and it preserves existing run directories for postmortem.

## Tests

`bash tools/test-codex-review.sh [n…]` — 9 hermetic tests (normal, silent, timeout, malformed
verdict, concurrent, no-wrong-PID, early CLI failure, tool activity, crash/recovery) driven by
`tools/test-fixtures/fake-codex.sh`, which replays the real JSONL grammar. No network, no real
`codex` invocation. The no-wrong-PID test spawns a decoy whose command line *would* be matched by
the old `pgrep -f "codex exec"` and asserts the wrapper never touches it.
