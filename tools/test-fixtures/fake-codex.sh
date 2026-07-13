#!/usr/bin/env bash
# shellcheck shell=bash
# fake-codex.sh — hermetic stand-in for the real `codex` CLI, used by tools/test-codex-review.sh.
#
# It reproduces the ACTUAL JSONL grammar emitted by codex-cli 0.144.1 (`codex exec --json`),
# observed live on 2026-07-12:
#
#   {"type":"thread.started","thread_id":"..."}
#   {"type":"turn.started"}
#   {"type":"item.started","item":{"type":"command_execution","status":"in_progress",...}}
#   {"type":"item.completed","item":{"type":"command_execution","status":"completed","exit_code":0,...}}
#   {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
#   {"type":"item.completed","item":{"type":"error","message":"..."}}   <-- benign; fires on exit 0 too
#   {"type":"turn.completed","usage":{...}}
#
# Behaviour is selected via FAKE_MODE. The stub reads the prompt from stdin (never argv),
# and honours `-o/--output-last-message <FILE>` exactly like the real CLI.
#
# Modes:
#   normal | tools | silent | hang | failfast                    — process/stream behaviour
#   malformed | badverdict | noverdict                           — bad final message
#   trailingbad | truncated | partial | trailingprose            — fail-OPEN traps for the extractor
#   failafter                                                    — valid APPROVE, then a FAILED run
#
# The traps all hand back something that LOOKS like a pass. `trailingbad`/`truncated`/`partial`
# plant an earlier, perfectly valid APPROVE fence and then ruin the final one; `trailingprose` gets
# the fence right and then keeps talking; `failafter` writes a flawless APPROVE and exits nonzero.
# An extractor that scans backwards for "the last block that parses", that defaults away a missing
# schema key, that ignores what follows the fence, or that mines a final.md without proving the RUN
# succeeded, will open the gate on all of them. Every one must be rejected.

set -u

OUT=""
prev=""
IS_REVIEW=0
HAS_BASE=0
HAS_PROMPT_ARG=0
for arg in "$@"; do
  case "$prev" in
    -o|--output-last-message) OUT="$arg" ;;
  esac
  case "$arg" in
    review) IS_REVIEW=1 ;;
    --base) HAS_BASE=1 ;;
    -)      HAS_PROMPT_ARG=1 ;;   # `-` is the [PROMPT] positional meaning "read from stdin"
  esac
  prev="$arg"
done

# Faithfully reproduce a REAL constraint of codex-cli 0.144.1 that bit us on the first live run:
# `codex exec review --base <BRANCH>` REFUSES to accept a [PROMPT] positional (including `-`).
# Superflow's gate *requires* a custom prompt (verdict contract + criteria rubric), so the wrapper
# must never emit this combination.
if [ "$IS_REVIEW" = "1" ] && [ "$HAS_BASE" = "1" ] && [ "$HAS_PROMPT_ARG" = "1" ]; then
  echo "error: the argument '--base <BRANCH>' cannot be used with '[PROMPT]'" >&2
  echo "Usage: codex exec review --base <BRANCH> [PROMPT]" >&2
  exit 2
fi

# Record argv so tests can assert exactly what the wrapper passed to the CLI.
[ -n "${FAKE_ARGV_OUT:-}" ] && printf '%s\n' "$*" > "$FAKE_ARGV_OUT"

# Consume stdin (the prompt) exactly like the real CLI does. Never echo it.
PROMPT="$(cat || true)"
: "${PROMPT:=}"

emit() { printf '%s\n' "$1"; }

FAKE_MODE="${FAKE_MODE:-normal}"

# --- failfast: early CLI failure (bad flag / bad model). No events, stderr + nonzero exit. ---
if [ "$FAKE_MODE" = "failfast" ]; then
  echo "ERROR: unexpected argument '--nope' found" >&2
  echo "error: model 'gpt-nonexistent' is not available" >&2
  exit 2
fi

# --- silent: process is alive but never emits a single event (provider/broker black hole). ---
if [ "$FAKE_MODE" = "silent" ]; then
  sleep "${FAKE_SILENT_SEC:-600}"
  exit 0
fi

emit '{"type":"thread.started","thread_id":"thr_fake_'"$$"'"}'
# Benign deprecation notice — the real CLI emits this as an `error` item on SUCCESSFUL runs.
emit '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"`[features].codex_hooks` is deprecated."}}'
emit '{"type":"turn.started"}'

if [ "$FAKE_MODE" = "hang" ]; then
  # Deliberately outlive the deadline, AND spawn grandchildren in the same process group so the
  # test can prove the wrapper reaps the whole GROUP (no orphans), not just the direct child.
  sleep "${FAKE_HANG_SEC:-600}" &
  # A TERM-RESISTANT descendant: `trap "" TERM` sets SIGTERM to SIG_IGN, which SURVIVES execve —
  # so this process ignores the TERM that kills its parent. An escalation that sends SIGKILL only
  # while the LEADER is still alive skips it entirely and leaves a real orphan behind. Its pid is
  # published so the test can assert it actually died. (Real-world analogue: a node/codex child
  # that traps TERM and lingers.)
  bash -c 'trap "" TERM; sleep '"${FAKE_HANG_SEC:-600}" &
  [ -n "${FAKE_GRANDCHILD_OUT:-}" ] && printf '%s\n' "$!" > "$FAKE_GRANDCHILD_OUT"
  sleep "${FAKE_HANG_SEC:-600}"
  exit 0
fi

if [ "$FAKE_MODE" = "tools" ] || [ "$FAKE_MODE" = "normal" ]; then
  emit '{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/bash -lc '"'"'ls tools/'"'"'","status":"in_progress","exit_code":null,"aggregated_output":""}}'
  sleep "${FAKE_TOOL_SEC:-0}"
  emit '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/bash -lc '"'"'ls tools/'"'"'","status":"completed","exit_code":0,"aggregated_output":"release-gate.sh"}}'
fi

emit '{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Reviewed the diff."}}'
emit '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0}}'

# --- final message (-o) ---
case "$FAKE_MODE" in
  malformed)
    # Fenced block present but the JSON inside is corrupt.
    FINAL='Review done.

```json
{"verdict": "APPROVE", "findings": [ , "summary":
```'
    ;;
  badverdict)
    # Parses as JSON, but the verdict value is not in the allowed enum.
    FINAL='Review done.

```json
{"verdict":"LGTM","findings":[],"summary":"looks fine to me"}
```'
    ;;
  noverdict)
    # Prose only — no fenced JSON block at all. Must NOT be interpreted.
    FINAL='I approve this change. It looks good and I see no blocking issues. APPROVE.'
    ;;
  trailingbad)
    # A VALID verdict fence followed by a LATER corrupt fence. The contract says nothing may
    # follow the verdict fence, so the LAST fence must be the verdict — silently falling back to
    # the earlier valid one would let a truncated/garbled tail pass as a clean APPROVE.
    FINAL='Review done.

```json
{"verdict":"APPROVE","findings":[],"summary":"earlier valid block"}
```

```json
{"verdict": "APPROVE", "findings": [ ,
```'
    ;;
  truncated)
    # A VALID verdict fence followed by a TRUNCATED one: the final fence is OPENED and never
    # closed — exactly what a killed, rate-limited or context-exhausted model leaves behind.
    # A regex that only matches complete ```…``` PAIRS cannot see this block at all, so it hands
    # back the previous (APPROVE) fence and opens the gate on an answer that was never finished.
    FINAL='Review done.

```json
{"verdict":"APPROVE","findings":[],"summary":"earlier valid block"}
```

Final verdict:

```json
{"verdict":"REQUEST_CHANGES","findings":[{"id":"F1"}],"summary":"cut off mid-'
    ;;
  partial)
    # Parses, verdict is in the enum, but `findings` and `summary` are MISSING.
    FINAL='Review done.

```json
{"verdict":"APPROVE"}
```'
    ;;
  trailingprose)
    # A PERFECTLY VALID APPROVE fence — and then the model kept talking. It either contradicted
    # itself or was cut off mid-correction. The contract says the verdict fence is the LAST thing in
    # the message, so this is not a verdict: honouring the fence and ignoring the tail INFERS a pass
    # from an unfinished answer. (r2 finding 1.)
    FINAL='Review done.

```json
{"verdict":"APPROVE","findings":[],"summary":"looks good"}
```

Wait — on reflection the auth check at line 42 is still broken, so this should be'
    ;;
  *)
    # Two fenced blocks on purpose: the extractor must take the LAST one (§7),
    # never the earlier decoy, and never the surrounding prose.
    FINAL='Reviewed the sprint diff against the contract.

```json
{"verdict":"REQUEST_CHANGES","findings":[{"id":"F1","severity":"high","detail":"decoy earlier block"}],"summary":"ignore me: not the last block"}
```

After the fixes were applied, the final assessment is:

```json
{"verdict":"APPROVE","findings":[],"summary":"contract criteria satisfied"}
```'
    [ -n "${FAKE_FINAL_TEXT:-}" ] && FINAL="$FAKE_FINAL_TEXT"
    ;;
esac

if [ -n "$OUT" ]; then
  printf '%s\n' "$FINAL" > "$OUT"
fi

# --- failafter: the provider wrote a clean, perfectly valid APPROVE final message and THEN DIED —
#     rate limit, broker drop, panic on shutdown. The event stream even shows turn.completed. The
#     ANSWER looks like a pass; the RUN failed. Anything that mines that final.md is inferring a
#     pass from a run that never succeeded, which is the whole class of bug in review r2.
if [ "$FAKE_MODE" = "failafter" ]; then
  echo "error: stream disconnected before completion" >&2
  exit 2
fi

exit 0
