#!/usr/bin/env bash
# shellcheck shell=bash
# codex-review.sh — transparent, observable wrapper around external Codex review (V2)
#
# WHY THIS EXISTS
#   The previous pattern was:  timeout 900 codex exec ... 2>&1 | tail -30
#   followed by PID recovery via `pgrep -f "codex exec.*"`. That hid the whole event
#   stream until the pipeline finished, and `pgrep` could match the parent shell, a
#   concurrent review, or the search command itself — which on 2026-06-16 produced a
#   real circular wait (`tail --pid=<parent-shell> -f /dev/null`) that hung for 26 days.
#
#   This wrapper NEVER pattern-matches a process. The child is launched as a job-controlled
#   background job, so bash makes it the leader of its own process group and `$!` IS the
#   PGID by construction. We store PID + PGID + /proc starttime at launch, wait on that exact
#   handle, and TERM/KILL that exact process group. No pgrep. No `tail --pid`. No `| tail -N`.
#
# WHAT IT GUARANTEES
#   - full raw JSONL event stream on disk and visible while the review runs   (AC01)
#   - exact PID/PGID captured at launch, never looked up by name              (AC02)
#   - unique run directory per review; concurrent reviews never collide       (AC03, AC10)
#   - atomic status.json (state, timestamps, deadline, pid/pgid, exit code)   (AC04)
#   - heartbeat with elapsed / last-event age / remaining deadline            (AC05)
#   - mechanical fenced-JSON verdict extraction + schema validation           (AC06, AC09)
#   - silence is reported as silence, never as confirmed progress             (AC07)
#   - hard deadline kills the whole process group — no orphans                (AC08)
#   - PID-reuse safe cleanup (PID + starttime tuple must match)               (AC11)
#   - prompt passed via file/stdin, never argv                                (AC12)
#
# USAGE
#   bash tools/codex-review.sh run --slug <slug> [options]
#   bash tools/codex-review.sh reconcile <run-dir>
#   bash tools/codex-review.sh cleanup   <run-dir> [--force]
#
#   run options:
#     --slug <s>          run namespace, e.g. sprint-3-technical   (default: review)
#     --root <dir>        repo root that holds .superflow/         (default: cwd)
#     --mode exec|review  `codex exec` or `codex exec review`      (default: review)
#     --base <branch>     base branch for review mode              (default: main)
#     --prompt-file <f>   prompt from a file      \
#     --prompt-text <s>   prompt from a string     |  exactly one; the prompt is ALWAYS
#     --prompt-stdin      prompt from stdin       /   handed to codex via a file on stdin
#     --model <m>         (default: $CODEX_REVIEW_MODEL or gpt-5.6-sol)
#     --effort <e>        model_reasoning_effort  (default: $CODEX_REVIEW_EFFORT or high)
#     --deadline-sec/--silent-sec/--stall-sec/--heartbeat-sec/--grace-sec
#     --no-heartbeat      suppress heartbeat lines on stdout
#     -- <args...>        extra args passed verbatim to codex
#
# EXIT CODES
#   0  VERDICT_PARSED, verdict is pass-class  (APPROVE | ACCEPTED | PASS)      -> gate OPEN
#   3  VERDICT_PARSED, verdict is fail-class  (REQUEST_CHANGES|NEEDS_FIXES|FAIL) -> gate CLOSED
#   1  no valid verdict: FAILED | TIMED_OUT | malformed/missing verdict        -> gate CLOSED
#   2  usage error
#   A missing or malformed verdict is NEVER a pass (AC09) — it exits 1, and .par-evidence.json
#   must be built only from a validated verdict.json.
#
# FEATURE FLAG
#   CODEX_REVIEW_WRAPPER_V2=1 (default) — this observable flow.
#   CODEX_REVIEW_WRAPPER_V2=0           — minimal fallback (§11): still exact $!, hard deadline,
#                                         separate stdout/stderr, recorded exit code. It does NOT
#                                         reintroduce pgrep or `tail --pid`.
#
# No secrets are read, printed, or persisted. The prompt is written to the run dir only.

set -uo pipefail

WRAPPER_VERSION="2.0.0"

# ---------------------------------------------------------------------------
# defaults (all thresholds configurable via env or flags — §5)
# ---------------------------------------------------------------------------
CODEX_BIN="${CODEX_BIN:-codex}"
DEADLINE_SEC="${CODEX_REVIEW_DEADLINE_SEC:-900}"   # hard timeout          -> TIMED_OUT
SILENT_SEC="${CODEX_REVIEW_SILENT_SEC:-150}"       # no event for N sec    -> SILENT
STALL_SEC="${CODEX_REVIEW_STALL_SEC:-300}"         # no event + no tool    -> STALLED_SUSPECTED
HEARTBEAT_SEC="${CODEX_REVIEW_HEARTBEAT_SEC:-30}"
GRACE_SEC="${CODEX_REVIEW_GRACE_SEC:-10}"          # TERM -> grace -> KILL
POLL_SEC="${CODEX_REVIEW_POLL_SEC:-1}"
WRAPPER_V2="${CODEX_REVIEW_WRAPPER_V2:-1}"
MODEL="${CODEX_REVIEW_MODEL:-gpt-5.6-sol}"
EFFORT="${CODEX_REVIEW_EFFORT:-high}"
# Reviewers must be able to run read commands (git diff, cat). `workspace-write` is the
# non-deprecated replacement for the old `--full-auto`.
SANDBOX="${CODEX_REVIEW_SANDBOX:-workspace-write}"

PASS_VERDICTS="APPROVE ACCEPTED PASS"
FAIL_VERDICTS="REQUEST_CHANGES NEEDS_FIXES FAIL"

die()  { printf 'codex-review: %s\n' "$1" >&2; exit "${2:-2}"; }
now()  { date -u +%s; }
iso()  { date -u -d "@${1:-$(now)}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }
mmss() { local s=${1:-0}; [ "$s" -lt 0 ] && s=0; printf '%02d:%02d' $((s/60)) $((s%60)); }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# --- /proc introspection BY PID (never by name). Field offsets account for the
#     "(comm)" field, which may itself contain spaces/parens: strip through the last ')'.
#     After stripping, field 3 = pgrp, field 20 = starttime (orig fields 5 and 22).
_procstat() { [ -r "/proc/$1/stat" ] && sed 's/.*) //' "/proc/$1/stat" 2>/dev/null; }
pgid_of() {
  local s; s="$(_procstat "$1")"
  if [ -n "$s" ]; then awk '{print $3}' <<<"$s"; else ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; fi
}
starttime_of() {
  local s; s="$(_procstat "$1")"
  if [ -n "$s" ]; then awk '{print $20}' <<<"$s"; else ps -o lstart= -p "$1" 2>/dev/null | tr -d ' '; fi
}
alive() { kill -0 "$1" 2>/dev/null; }

# Is ANY *live* (non-zombie) process still a member of process group <pgid>?
# Zombies must be excluded: our own child stays a zombie until we `wait` it, and a zombie is
# still signalable — using `kill -0 -PGID` here would report a fully-reaped group as alive.
group_alive() {
  ps -eo pgid=,stat= 2>/dev/null | awk -v g="$1" '$1==g && $2 !~ /^Z/ {f=1} END{exit !f}'
}

# ---------------------------------------------------------------------------
# atomic status.json  (tmp + rename on the same filesystem — AC04)
# ---------------------------------------------------------------------------
write_status() {
  local tmp="$RUN_DIR/.status.json.$$"
  jq -n \
    --arg run_id "$RUN_ID" --arg slug "$SLUG" --arg state "$STATE" \
    --arg started_at "$(iso "$STARTED")" \
    --arg last_event_at "$([ "$LAST_EVENT_TS" -gt 0 ] && iso "$LAST_EVENT_TS" || echo "")" \
    --arg deadline_at "$(iso "$DEADLINE_TS")" \
    --arg message "$MESSAGE" --arg thread_id "$THREAD_ID" \
    --arg wrapper_version "$WRAPPER_VERSION" \
    --argjson pid "${PID:-null}" --argjson pgid "${PGID:-null}" \
    --argjson start_ticks "${START_TICKS:-null}" \
    --argjson exit_code "${EXIT_CODE:-null}" \
    --argjson progress_confirmed "$PROGRESS_CONFIRMED" \
    --argjson events_seen "$EVENTS_SEEN" --argjson tools_active "$TOOLS_ACTIVE" \
    --argjson elapsed_sec "$(( $(now) - STARTED ))" \
    --arg cli_errors "$CLI_ERRORS" \
    '{run_id:$run_id, slug:$slug, state:$state, pid:$pid, pgid:$pgid,
      start_ticks:$start_ticks, started_at:$started_at,
      last_event_at:(if $last_event_at=="" then null else $last_event_at end),
      deadline_at:$deadline_at, exit_code:$exit_code,
      progress_confirmed:$progress_confirmed, events_seen:$events_seen,
      tools_active:$tools_active, thread_id:(if $thread_id=="" then null else $thread_id end),
      elapsed_sec:$elapsed_sec, message:$message,
      cli_errors:($cli_errors|split("\n")|map(select(.!=""))),
      wrapper_version:$wrapper_version}' > "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$RUN_DIR/status.json"
  rm -f "$tmp" 2>/dev/null
}

set_state() {
  local prev="${STATE:-}"
  STATE="$1"; MESSAGE="${2:-$MESSAGE}"
  write_status
  # Emit a line on every TRANSITION, not just on the heartbeat timer. Short-lived states
  # (SYNTHESIZING, a fast TOOL_ACTIVE) would otherwise never be sampled by a 30-60s
  # heartbeat, and the whole point of this wrapper is that the operator can see what the
  # review is doing at any moment. The periodic heartbeat still covers long silent waits.
  if [ "$STATE" != "$prev" ] && [ "${NO_HEARTBEAT:-0}" != "1" ]; then
    printf 'Codex review: %s | elapsed %s | %s | run %s\n' \
      "$STATE" "$(mmss $(( $(now) - STARTED )) )" "$MESSAGE" "$RUN_ID"
  fi
}

# ---------------------------------------------------------------------------
# heartbeat (§6) — derived from EVENTS and files, never from `kill -0` alone (AC05)
# ---------------------------------------------------------------------------
heartbeat() {
  [ "$NO_HEARTBEAT" = "1" ] && return 0
  local t; t="$(now)"
  local elapsed=$(( t - STARTED ))
  local remain=$(( DEADLINE_TS - t ))
  local age_str="never"
  [ "$LAST_EVENT_TS" -gt 0 ] && age_str="$(mmss $(( t - LAST_EVENT_TS )) ) ago"
  local alive_str="no"; alive "$PID" && alive_str="yes"
  local prog="no"; [ "$PROGRESS_CONFIRMED" = "true" ] && prog="yes"
  printf 'Codex review: %s | elapsed %s | last event %s | deadline %s remaining | alive %s | progress confirmed %s | events %d | run %s\n' \
    "$STATE" "$(mmss "$elapsed")" "$age_str" "$(mmss "$remain")" "$alive_str" "$prog" "$EVENTS_SEEN" "$RUN_ID"
}

# ---------------------------------------------------------------------------
# event handling — grammar verified live against codex-cli 0.144.1 (2026-07-12):
#   thread.started | turn.started | turn.completed | turn.failed
#   item.started / item.completed with item.type in:
#     command_execution | agent_message | reasoning | mcp_tool_call | file_change |
#     web_search | patch_apply | todo_list | error
#
#   NOTE: an `error` ITEM is NOT a failure. The real CLI emits one on fully successful
#   (exit 0) runs — e.g. a config deprecation notice. Only a nonzero exit code, turn.failed,
#   or a missing/invalid final message may fail the review.
#
#   progress_confirmed becomes true only once the model actually emits item.* / turn.completed.
#   thread.started + turn.started mean "request sent, waiting on provider/broker" — which is
#   exactly the WAITING_PROVIDER_OR_BROKER snapshot from the handoff (§2.1): alive, but NOT proof
#   of work. Process liveness alone must never be reported as progress (AC07).
# ---------------------------------------------------------------------------
handle_event() {
  local line="$1" etype itype
  [ -z "$line" ] && return 0
  etype="$(jq -r 'try .type catch "?"' <<<"$line" 2>/dev/null)"
  [ -z "$etype" ] || [ "$etype" = "?" ] || [ "$etype" = "null" ] && { [ "$etype" = "?" ] && return 0; }

  EVENTS_SEEN=$((EVENTS_SEEN+1))
  LAST_EVENT_TS="$(now)"

  case "$etype" in
    thread.started)
      THREAD_ID="$(jq -r 'try (.thread_id // "") catch ""' <<<"$line")"
      set_state SESSION_CREATED "session created; sending request"
      ;;
    turn.started)
      set_state MODEL_WAIT "request sent; waiting for model/provider"
      ;;
    item.started|item.completed)
      itype="$(jq -r 'try (.item.type // "") catch ""' <<<"$line")"
      case "$itype" in
        error)
          # diagnostic only — recorded, never fatal (see note above)
          local msg; msg="$(jq -r 'try (.item.message // "") catch ""' <<<"$line" | tr -d '\n' | cut -c1-200)"
          CLI_ERRORS="${CLI_ERRORS}${msg}"$'\n'
          write_status
          ;;
        agent_message)
          PROGRESS_CONFIRMED=true
          set_state SYNTHESIZING "model is producing its answer"
          ;;
        "")
          write_status
          ;;
        *)
          # any tool-ish item: command_execution, mcp_tool_call, file_change, reasoning,
          # web_search, patch_apply, todo_list, and anything the CLI adds later.
          PROGRESS_CONFIRMED=true
          if [ "$etype" = "item.started" ]; then
            TOOLS_ACTIVE=$((TOOLS_ACTIVE+1))
          else
            [ "$TOOLS_ACTIVE" -gt 0 ] && TOOLS_ACTIVE=$((TOOLS_ACTIVE-1))
          fi
          if [ "$TOOLS_ACTIVE" -gt 0 ]; then
            set_state TOOL_ACTIVE "tool running: $itype"
          else
            set_state SYNTHESIZING "tool finished ($itype); waiting for final answer"
          fi
          ;;
      esac
      ;;
    turn.completed)
      PROGRESS_CONFIRMED=true
      set_state SYNTHESIZING "turn completed; finalizing"
      ;;
    turn.failed)
      local emsg; emsg="$(jq -r 'try ((.error.message // .message) // "") catch ""' <<<"$line" | tr -d '\n' | cut -c1-200)"
      CLI_ERRORS="${CLI_ERRORS}turn.failed: ${emsg}"$'\n'
      TURN_FAILED=1
      set_state FAILED "codex reported turn.failed"
      ;;
    *)
      write_status
      ;;
  esac
}

# incremental, complete-line-safe drain of events.jsonl via a persistent fd.
# A partial trailing line (writer mid-write) is carried over to the next drain.
drain_events() {
  local line
  while IFS= read -r line <&3; do
    handle_event "${CARRY}${line}"
    CARRY=""
  done
  # read returned nonzero: if it produced data, that was an incomplete final line
  if [ -n "${line:-}" ]; then CARRY="${CARRY}${line}"; fi
}

# ---------------------------------------------------------------------------
# terminate the child's PROCESS GROUP: TERM -> grace -> KILL (AC08, no orphans)
# ---------------------------------------------------------------------------
kill_group() {
  local reason="$1"
  [ -z "${PGID:-}" ] && PGID="$PID"

  kill -TERM "-$PGID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null

  # Escalate on the GROUP, not on the leader. The leader may exit promptly on TERM while a
  # descendant (a node/codex child that traps or ignores TERM) lingers — waiting only on the
  # leader would declare success and leave those descendants orphaned.
  local waited=0
  while [ "$waited" -lt "$GRACE_SEC" ] && group_alive "$PGID"; do sleep 1; waited=$((waited+1)); done

  if group_alive "$PGID"; then
    kill -KILL "-$PGID" 2>/dev/null || kill -KILL "$PID" 2>/dev/null
    local k=0
    while [ "$k" -lt 5 ] && group_alive "$PGID"; do sleep 1; k=$((k+1)); done
  fi

  if group_alive "$PGID"; then
    printf 'codex-review: WARNING — process group %s still has live members after SIGKILL (%s)\n' \
      "$PGID" "$reason" >&2
  else
    printf 'codex-review: terminated process group %s (%s)\n' "$PGID" "$reason" >&2
  fi
}

# ---------------------------------------------------------------------------
# mechanical verdict extraction (§7) — LAST fenced JSON block in final.md.
# Prose is NEVER interpreted. Missing/malformed/unknown verdict => gate stays CLOSED.
# ---------------------------------------------------------------------------
extract_verdict() {
  FINAL_FILE="$RUN_DIR/final.md"
  [ -s "$FINAL_FILE" ] || { VERDICT_ERROR="final.md missing or empty"; return 1; }

  RUN_ID="$RUN_ID" PASS_V="$PASS_VERDICTS" FAIL_V="$FAIL_VERDICTS" \
  python3 - "$FINAL_FILE" "$RUN_DIR/verdict.json" <<'PY'
import json, os, re, sys, datetime

final_path, out_path = sys.argv[1], sys.argv[2]
text = open(final_path, encoding="utf-8", errors="replace").read()
PASS = os.environ["PASS_V"].split()
FAIL = os.environ["FAIL_V"].split()

# Every fenced block, ```lang optional.
blocks = re.findall(r"^[ \t]*```[^\n`]*\n(.*?)^[ \t]*```", text, re.S | re.M)
if not blocks:
    print("no fenced block in final.md", file=sys.stderr); sys.exit(1)

# The LAST fenced block MUST be the verdict. The reviewer contract states that nothing may follow
# the closing fence, so we do NOT scan backwards for "the most recent block that happens to parse":
# if the final block is truncated or garbled, falling back to an earlier valid fence would let a
# broken response through as a clean PASS. A bad last block is a failed review — fail closed.
chosen = json.loads(blocks[-1])   # JSONDecodeError -> non-zero exit -> FAILED, gate CLOSED
if not isinstance(chosen, dict):
    print("last fenced block is not a JSON object", file=sys.stderr); sys.exit(1)

# All three contract fields are MANDATORY — an incomplete verdict object is not a verdict.
missing = [k for k in ("verdict", "findings", "summary") if k not in chosen]
if missing:
    print("verdict block is missing required field(s): %s" % ", ".join(missing), file=sys.stderr)
    sys.exit(1)

verdict = chosen["verdict"]
if not isinstance(verdict, str) or verdict.upper() not in PASS + FAIL:
    print("unknown verdict value: %r" % (verdict,), file=sys.stderr); sys.exit(1)
verdict = verdict.upper()

findings = chosen["findings"]
if not isinstance(findings, list):
    print("'findings' must be an array", file=sys.stderr); sys.exit(1)
summary = chosen["summary"]
if not isinstance(summary, str):
    print("'summary' must be a string", file=sys.stderr); sys.exit(1)

vclass = "pass" if verdict in PASS else "fail"
out = {
    "run_id": os.environ.get("RUN_ID", ""),
    "verdict": verdict,
    "verdict_class": vclass,
    "gate": "open" if vclass == "pass" else "closed",
    "findings": findings,
    "findings_count": len(findings),
    "summary": summary,
    "source": "final.md",
    "extracted_at": datetime.datetime.now(datetime.timezone.utc)
                      .strftime("%Y-%m-%dT%H:%M:%SZ"),
}
tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2)
os.replace(tmp, out_path)
print(verdict)
PY
}

# ---------------------------------------------------------------------------
# cmd_run
# ---------------------------------------------------------------------------
cmd_run() {
  local SLUG="review" ROOT="$PWD" MODE="review" BASE="main"
  local PROMPT_FILE="" PROMPT_TEXT="" PROMPT_STDIN=0
  NO_HEARTBEAT=0
  local -a EXTRA=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --slug)          SLUG="${2:?}"; shift 2 ;;
      --root)          ROOT="${2:?}"; shift 2 ;;
      --mode)          MODE="${2:?}"; shift 2 ;;
      --base)          BASE="${2:?}"; shift 2 ;;
      --prompt-file)   PROMPT_FILE="${2:?}"; shift 2 ;;
      --prompt-text)   PROMPT_TEXT="${2:?}"; shift 2 ;;
      --prompt-stdin)  PROMPT_STDIN=1; shift ;;
      --model)         MODEL="${2:?}"; shift 2 ;;
      --effort)        EFFORT="${2:?}"; shift 2 ;;
      --sandbox)       SANDBOX="${2:?}"; shift 2 ;;
      --deadline-sec)  DEADLINE_SEC="${2:?}"; shift 2 ;;
      --silent-sec)    SILENT_SEC="${2:?}"; shift 2 ;;
      --stall-sec)     STALL_SEC="${2:?}"; shift 2 ;;
      --heartbeat-sec) HEARTBEAT_SEC="${2:?}"; shift 2 ;;
      --grace-sec)     GRACE_SEC="${2:?}"; shift 2 ;;
      --no-heartbeat)  NO_HEARTBEAT=1; shift ;;
      --)              shift; EXTRA=("$@"); break ;;
      -h|--help)       sed -n '1,60p' "$0"; exit 0 ;;
      *)               die "unknown flag: $1" ;;
    esac
  done

  case "$MODE" in exec|review) ;; *) die "--mode must be exec or review" ;; esac

  # ---- unique run directory (AC03/AC10): timestamp + wrapper pid + randomness ----
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N2 -tu2 </dev/urandom 2>/dev/null | tr -d ' ' || echo $RANDOM)"
  RUN_DIR="$ROOT/.superflow/reviews/$SLUG/$RUN_ID"
  mkdir -p "$RUN_DIR" || die "cannot create run dir: $RUN_DIR"

  # ---- prompt to a FILE, never argv (AC12) ----
  if [ -n "$PROMPT_FILE" ]; then
    [ -r "$PROMPT_FILE" ] || die "prompt file not readable: $PROMPT_FILE"
    cp "$PROMPT_FILE" "$RUN_DIR/prompt.md"
  elif [ -n "$PROMPT_TEXT" ]; then
    printf '%s\n' "$PROMPT_TEXT" > "$RUN_DIR/prompt.md"
  elif [ "$PROMPT_STDIN" = "1" ]; then
    cat > "$RUN_DIR/prompt.md"
  else
    die "one of --prompt-file / --prompt-text / --prompt-stdin is required"
  fi

  # --- review mode: scope the prompt to <base>...HEAD ---------------------------------
  # codex-cli 0.144.1 REFUSES `exec review --base <BRANCH>` together with a [PROMPT] positional
  # ("the argument '--base <BRANCH>' cannot be used with '[PROMPT]'"), and `-` (read prompt from
  # stdin) counts as that positional. Superflow's gate REQUIRES the custom prompt — it carries the
  # verdict contract and the contract-gate criteria rubric — so we cannot drop it. We therefore run
  # review as a plain `codex exec` and put the base scope INTO the prompt; the reviewer runs the
  # diff itself. Verdict semantics are unchanged (AC13).
  if [ "$MODE" = "review" ]; then
    local scoped="$RUN_DIR/.prompt.scoped"
    {
      printf '# Review scope\n\n'
      printf 'Review ONLY the changes on the current branch against base `%s`.\n' "$BASE"
      printf 'Obtain the diff yourself by running:\n\n    git diff %s...HEAD\n\n' "$BASE"
      printf 'Do not review pre-existing code outside that diff.\n\n---\n\n'
      cat "$RUN_DIR/prompt.md"
    } > "$scoped"
    mv -f "$scoped" "$RUN_DIR/prompt.md"
  fi

  : > "$RUN_DIR/events.jsonl"
  : > "$RUN_DIR/stderr.log"

  STARTED="$(now)"
  DEADLINE_TS=$(( STARTED + DEADLINE_SEC ))
  STATE="STARTING"; MESSAGE="run dir created; launching codex"
  LAST_EVENT_TS=0; EVENTS_SEEN=0; TOOLS_ACTIVE=0; PROGRESS_CONFIRMED=false
  THREAD_ID=""; EXIT_CODE=null; CLI_ERRORS=""; CARRY=""; TURN_FAILED=0
  VERDICT_ERROR=""
  PID=null; PGID=null; START_TICKS=null
  write_status

  # ---- assemble argv (the prompt is NOT here — it arrives on stdin; AC12) ----
  # Both modes use plain `codex exec`; see the review-scope note above for why review mode does
  # NOT use the `exec review --base` subcommand.
  local -a ARGV=(exec --json -o "$RUN_DIR/final.md" -m "$MODEL"
                 -c "model_reasoning_effort=$EFFORT" --sandbox "$SANDBOX")
  [ ${#EXTRA[@]} -gt 0 ] && ARGV+=("${EXTRA[@]}")
  ARGV+=(-)   # `-` = read the prompt from stdin

  # ---- FALLBACK PATH (feature flag off, §11) ----
  if [ "$WRAPPER_V2" != "1" ]; then
    printf 'codex-review: CODEX_REVIEW_WRAPPER_V2=0 — minimal fallback (no heartbeat/state machine).\n' >&2
    set -m
    "$CODEX_BIN" "${ARGV[@]}" < "$RUN_DIR/prompt.md" > "$RUN_DIR/events.jsonl" 2> "$RUN_DIR/stderr.log" &
    PID=$!            # exact child handle — still no pgrep, still no `tail --pid`
    set +m
    PGID="$(pgid_of "$PID")"; PGID="${PGID:-$PID}"
    printf '%s\n' "$PID" > "$RUN_DIR/pid"
    local waited=0
    while alive "$PID" && [ "$waited" -lt "$DEADLINE_SEC" ]; do sleep 1; waited=$((waited+1)); done
    if alive "$PID"; then kill_group "fallback hard deadline"; STATE="TIMED_OUT"; fi
    wait "$PID" 2>/dev/null; EXIT_CODE=$?
    [ "$STATE" != "TIMED_OUT" ] && STATE="COMPLETED"
    write_status
    if [ "$STATE" = "COMPLETED" ] && [ "$EXIT_CODE" = "0" ] && extract_verdict >/dev/null 2>&1; then
      set_state VERDICT_PARSED "verdict extracted (fallback)"
      [ "$(jq -r .verdict_class "$RUN_DIR/verdict.json")" = "pass" ] && return 0 || return 3
    fi
    return 1
  fi

  # ---- V2 LAUNCH ----------------------------------------------------------
  # `set -m` (job control) makes bash put the background job in its OWN process group,
  # with PGID == $!. That is how we get an authoritative PGID *by construction* rather
  # than by looking a process up by name. `set +m` right after keeps job-control chatter
  # off our stdout; the group is already established at fork time and persists.
  set -m
  "$CODEX_BIN" "${ARGV[@]}" < "$RUN_DIR/prompt.md" > "$RUN_DIR/events.jsonl" 2> "$RUN_DIR/stderr.log" &
  PID=$!
  set +m

  printf '%s\n' "$PID" > "$RUN_DIR/pid"
  PGID="$(pgid_of "$PID")"; PGID="${PGID:-$PID}"
  START_TICKS="$(starttime_of "$PID")"; START_TICKS="${START_TICKS:-null}"
  set_state STARTING "codex launched (pid $PID, pgid $PGID)"

  printf 'codex-review: run %s | pid %s | pgid %s | deadline %ss | dir %s\n' \
    "$RUN_ID" "$PID" "$PGID" "$DEADLINE_SEC" "$RUN_DIR"

  exec 3< "$RUN_DIR/events.jsonl"     # persistent fd: incremental reads, no `tail`
  local last_hb=$STARTED

  while :; do
    drain_events

    local t; t="$(now)"

    # --- hard deadline (AC08) ---
    if [ "$t" -ge "$DEADLINE_TS" ] && alive "$PID"; then
      set_state TIMED_OUT "hard deadline of ${DEADLINE_SEC}s reached"
      heartbeat
      kill_group "hard deadline"
      break
    fi

    # --- silence overlays (AC07): diagnostic, never proof of hanging, and never
    #     applied while a tool is legitimately running or after we've finished. ---
    if [ "$TOOLS_ACTIVE" -eq 0 ]; then
      local ref=$LAST_EVENT_TS; [ "$ref" -eq 0 ] && ref=$STARTED
      local age=$(( t - ref ))
      case "$STATE" in
        STARTING|SESSION_CREATED|MODEL_WAIT|SYNTHESIZING|SILENT|STALLED_SUSPECTED)
          if [ "$age" -ge "$STALL_SEC" ]; then
            [ "$STATE" != "STALLED_SUSPECTED" ] && \
              set_state STALLED_SUSPECTED "no events for ${age}s and no active tool — stall suspected (not proven)"
          elif [ "$age" -ge "$SILENT_SEC" ]; then
            [ "$STATE" != "SILENT" ] && \
              set_state SILENT "no events for ${age}s — process alive, progress NOT confirmed"
          fi
          ;;
      esac
    fi

    # --- child finished? ---
    if ! alive "$PID"; then
      drain_events                      # flush anything written just before exit
      wait "$PID" 2>/dev/null; EXIT_CODE=$?
      break
    fi

    if [ $(( t - last_hb )) -ge "$HEARTBEAT_SEC" ]; then heartbeat; last_hb=$t; fi
    sleep "$POLL_SEC"
  done

  exec 3<&-

  # ---- terminal classification ----
  if [ "$STATE" = "TIMED_OUT" ]; then
    wait "$PID" 2>/dev/null; EXIT_CODE=$?
    write_status
    heartbeat
    finish_report
    return 1
  fi

  if [ "${EXIT_CODE:-1}" != "0" ] || [ "$TURN_FAILED" = "1" ]; then
    set_state FAILED "codex exited with code ${EXIT_CODE} (see stderr.log)"
    heartbeat; finish_report; return 1
  fi

  set_state COMPLETED "codex exited 0; final message received"

  local v
  if v="$(extract_verdict 2>"$RUN_DIR/.verdict.err")"; then
    set_state VERDICT_PARSED "verdict extracted and validated: $v"
    heartbeat; finish_report
    [ "$(jq -r .verdict_class "$RUN_DIR/verdict.json" 2>/dev/null)" = "pass" ] && return 0 || return 3
  else
    VERDICT_ERROR="$(cat "$RUN_DIR/.verdict.err" 2>/dev/null | tr -d '\n' | cut -c1-300)"
    # final.md is deliberately preserved for diagnosis (§7.5)
    set_state FAILED "review produced no valid verdict: ${VERDICT_ERROR}"
    heartbeat; finish_report; return 1
  fi
}

finish_report() {
  local t; t="$(now)"
  printf '\n--- codex review finished ---\n'
  printf 'state:      %s\n' "$STATE"
  printf 'elapsed:    %s\n' "$(mmss $(( t - STARTED )) )"
  printf 'exit code:  %s\n' "${EXIT_CODE:-n/a}"
  printf 'events:     %s (progress confirmed: %s)\n' "$EVENTS_SEEN" "$PROGRESS_CONFIRMED"
  if [ -s "$RUN_DIR/verdict.json" ] && [ "$STATE" = "VERDICT_PARSED" ]; then
    printf 'verdict:    %s (%s, gate %s)\n' \
      "$(jq -r .verdict "$RUN_DIR/verdict.json")" \
      "$(jq -r .verdict_class "$RUN_DIR/verdict.json")" \
      "$(jq -r .gate "$RUN_DIR/verdict.json")"
  else
    printf 'verdict:    NOT PARSED — %s\n' "${VERDICT_ERROR:-review did not complete}"
    printf 'gate:       CLOSED (a missing/malformed verdict is never a pass)\n'
  fi
  printf 'final:      %s\n' "$RUN_DIR/final.md"
  printf 'events:     %s\n' "$RUN_DIR/events.jsonl"
  printf 'stderr:     %s\n' "$RUN_DIR/stderr.log"
  printf 'status:     %s\n' "$RUN_DIR/status.json"
}

# ---------------------------------------------------------------------------
# cmd_reconcile — crash recovery (§10 test 9).
# Reads run metadata from disk and decides the truth WITHOUT trusting a stale
# "process_alive". A recorded PID that now belongs to a DIFFERENT process (PID reuse)
# must never be reported as our review still running (AC11).
# ---------------------------------------------------------------------------
cmd_reconcile() {
  RUN_DIR="${1:?usage: codex-review.sh reconcile <run-dir>}"
  [ -s "$RUN_DIR/status.json" ] || die "no status.json in $RUN_DIR"

  RUN_ID="$(jq -r '.run_id // ""' "$RUN_DIR/status.json")"
  SLUG="$(jq -r '.slug // ""' "$RUN_DIR/status.json")"
  STATE="$(jq -r '.state // "UNKNOWN"' "$RUN_DIR/status.json")"
  PID="$(jq -r '.pid // empty' "$RUN_DIR/status.json")"
  PGID="$(jq -r '.pgid // empty' "$RUN_DIR/status.json")"
  START_TICKS="$(jq -r '.start_ticks // empty' "$RUN_DIR/status.json")"
  STARTED="$(date -u -d "$(jq -r '.started_at' "$RUN_DIR/status.json")" +%s 2>/dev/null || now)"
  DEADLINE_TS="$(date -u -d "$(jq -r '.deadline_at' "$RUN_DIR/status.json")" +%s 2>/dev/null || now)"
  LAST_EVENT_TS=0; EVENTS_SEEN="$(jq -r '.events_seen // 0' "$RUN_DIR/status.json")"
  TOOLS_ACTIVE=0; THREAD_ID="$(jq -r '.thread_id // ""' "$RUN_DIR/status.json")"
  PROGRESS_CONFIRMED="$(jq -r '.progress_confirmed // false' "$RUN_DIR/status.json")"
  EXIT_CODE="$(jq -r '.exit_code // "null"' "$RUN_DIR/status.json")"
  CLI_ERRORS=""; MESSAGE=""; NO_HEARTBEAT=1; VERDICT_ERROR=""

  local ours="no" live="no"
  if [ -n "$PID" ] && alive "$PID"; then
    live="yes"
    local cur; cur="$(starttime_of "$PID")"
    # identity = (pid, starttime). Same PID with a different starttime = a DIFFERENT process.
    if [ -n "$START_TICKS" ] && [ "$START_TICKS" != "null" ] && [ "$cur" = "$START_TICKS" ]; then
      ours="yes"
    fi
  fi

  printf 'reconcile %s\n  recorded state: %s\n  pid %s live: %s | is-our-process: %s\n' \
    "$RUN_DIR" "$STATE" "${PID:-n/a}" "$live" "$ours"

  if [ "$live" = "yes" ] && [ "$ours" = "yes" ]; then
    if [ "$(now)" -ge "$DEADLINE_TS" ]; then
      set_state STALLED_SUSPECTED "reconcile: still running past its deadline; wrapper is gone"
      printf '  -> %s (deadline expired; run `cleanup` to terminate the group)\n' "$STATE"
    else
      # Alive is NOT progress. Say exactly that.
      set_state SILENT "reconcile: process alive but unsupervised — liveness is not progress"
      printf '  -> %s: %s (progress_confirmed=%s)\n' "$STATE" "$MESSAGE" "$PROGRESS_CONFIRMED"
    fi
    return 1
  fi

  if [ "$live" = "yes" ] && [ "$ours" = "no" ]; then
    # The recorded PID is now a DIFFERENT process (PID reuse). Keep the pid on record for
    # forensics — cleanup's own (pid, starttime) guard is what prevents anyone acting on it.
    printf '  -> PID was REUSED by an unrelated process; not ours, will not be touched.\n'
    set_state FAILED "reconcile: wrapper died; recorded pid now belongs to a different process (PID reuse)"
    return 1
  fi

  # process is gone — decide from artifacts alone
  if [ "$STATE" = "VERDICT_PARSED" ] && [ -s "$RUN_DIR/verdict.json" ]; then
    printf '  -> already complete; verdict %s\n' "$(jq -r .verdict "$RUN_DIR/verdict.json")"
    return 0
  fi
  if [ -s "$RUN_DIR/final.md" ] && extract_verdict >/dev/null 2>&1; then
    set_state VERDICT_PARSED "reconcile: recovered verdict from final.md after wrapper crash"
    printf '  -> recovered verdict %s\n' "$(jq -r .verdict "$RUN_DIR/verdict.json")"
    [ "$(jq -r .verdict_class "$RUN_DIR/verdict.json")" = "pass" ] && return 0 || return 3
  fi
  set_state FAILED "reconcile: process gone, no valid verdict — review did not complete"
  printf '  -> FAILED (no valid verdict; gate CLOSED)\n'
  return 1
}

# ---------------------------------------------------------------------------
# cmd_cleanup — verified stale-process termination (§8, AC11).
# Refuses to kill unless (pid, starttime) still matches the run metadata.
# ---------------------------------------------------------------------------
cmd_cleanup() {
  RUN_DIR="${1:?usage: codex-review.sh cleanup <run-dir> [--force]}"; shift || true
  local FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
  [ -s "$RUN_DIR/status.json" ] || die "no status.json in $RUN_DIR"

  RUN_ID="$(jq -r '.run_id // ""' "$RUN_DIR/status.json")"
  SLUG="$(jq -r '.slug // ""' "$RUN_DIR/status.json")"
  STATE="$(jq -r '.state // "UNKNOWN"' "$RUN_DIR/status.json")"
  PID="$(jq -r '.pid // empty' "$RUN_DIR/status.json")"
  PGID="$(jq -r '.pgid // empty' "$RUN_DIR/status.json")"
  START_TICKS="$(jq -r '.start_ticks // empty' "$RUN_DIR/status.json")"
  STARTED="$(date -u -d "$(jq -r '.started_at' "$RUN_DIR/status.json")" +%s 2>/dev/null || now)"
  DEADLINE_TS="$(date -u -d "$(jq -r '.deadline_at' "$RUN_DIR/status.json")" +%s 2>/dev/null || now)"
  LAST_EVENT_TS=0; EVENTS_SEEN=0; TOOLS_ACTIVE=0; THREAD_ID=""
  PROGRESS_CONFIRMED=false; EXIT_CODE=null; CLI_ERRORS=""; MESSAGE=""; NO_HEARTBEAT=1

  if [ -z "$PID" ] || ! alive "$PID"; then
    printf 'cleanup: pid %s not running — nothing to kill.\n' "${PID:-n/a}"; return 0
  fi
  local cur; cur="$(starttime_of "$PID")"
  if [ -z "$START_TICKS" ] || [ "$START_TICKS" = "null" ] || [ "$cur" != "$START_TICKS" ]; then
    printf 'cleanup: REFUSING to kill pid %s — starttime %s != recorded %s (PID reuse; not our process).\n' \
      "$PID" "${cur:-?}" "${START_TICKS:-?}" >&2
    return 1
  fi
  if [ "$FORCE" != "1" ] && [ "$(now)" -lt "$DEADLINE_TS" ]; then
    printf 'cleanup: pid %s is our process but its deadline has not expired. Use --force to override.\n' "$PID" >&2
    return 1
  fi
  kill_group "cleanup of stale run $RUN_ID"
  wait "$PID" 2>/dev/null
  EXIT_CODE=$?
  set_state FAILED "cleanup: stale process group terminated by operator"
  printf 'cleanup: terminated pid %s / pgid %s (run %s).\n' "$PID" "$PGID" "$RUN_ID"
  return 0
}

# ---------------------------------------------------------------------------
main() {
  need jq; need python3
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    run)       cmd_run "$@" ;;
    reconcile) cmd_reconcile "$@" ;;
    cleanup)   cmd_cleanup "$@" ;;
    version)   printf 'codex-review.sh %s\n' "$WRAPPER_VERSION" ;;
    help|-h|--help) sed -n '1,60p' "$0" ;;
    *)         die "unknown command: $cmd (run|reconcile|cleanup|version|help)" ;;
  esac
}
main "$@"
