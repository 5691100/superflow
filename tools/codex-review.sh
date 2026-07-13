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
#   - hard deadline KILLs the whole process group — no orphans                (AC08)
#   - cleanup verifies the group is really ours before signalling it          (AC11)
#   - prompt passed via file/stdin, never argv; artifacts are 0700/0600       (AC12)
#
# FAIL-CLOSED, EVERYWHERE. Every defect this wrapper has ever had was the same defect: something
# that was NOT a pass got reported as one. So:
#   - the verdict is the LITERAL LAST fenced block of final.md. Not "the last block that happens
#     to parse" — an earlier valid APPROVE followed by a garbled or TRUNCATED final block is a
#     failed review, not an approval.
#   - all three contract fields (verdict, findings, summary) are mandatory. Nothing is defaulted.
#   - `reconcile` re-validates the stored verdict against that same contract and exits non-zero
#     for every fail-class verdict and every state that is not VERDICT_PARSED. A REQUEST_CHANGES
#     run must look like a failure to EVERY caller, including a later re-check.
#   - `cleanup` refuses to signal a process group it cannot tie to this run.
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
#     --prompt-file <f>   prompt from a file    \  exactly one. The prompt is ALWAYS materialised
#     --prompt-stdin      prompt from stdin     /  to prompt.md and handed to codex on stdin.
#                         (--prompt-text was REMOVED: prompt content in argv is world-readable
#                          via /proc/<pid>/cmdline — AC12.)
#     --model <m>         (default: $CODEX_REVIEW_MODEL or gpt-5.6-sol)
#     --effort <e>        model_reasoning_effort  (default: $CODEX_REVIEW_EFFORT or high)
#     --deadline-sec/--silent-sec/--stall-sec/--heartbeat-sec/--grace-sec
#     --no-heartbeat      suppress heartbeat lines on stdout
#     -- <args...>        extra args passed verbatim to codex
#
# EXIT CODES  (identical for `run` and `reconcile` — a re-check can never be more optimistic)
#   0  VERDICT_PARSED, verdict is pass-class  (APPROVE | ACCEPTED | PASS)        -> gate OPEN
#   3  VERDICT_PARSED, verdict is fail-class  (REQUEST_CHANGES|NEEDS_FIXES|FAIL) -> gate CLOSED
#   1  no valid verdict: FAILED | TIMED_OUT | SILENT | malformed/missing verdict -> gate CLOSED
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

# A run dir holds the prompt (unreleased code), the full transcript and the findings. None of it
# is anyone else's business: 0700 dirs, 0600 files — including the artifacts the codex child
# writes itself, which inherit this umask across the fork (AC12).
umask 077

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

# The full command line of a process, BY PID. Used to prove that a live process really is the
# codex run we recorded — never to FIND a process (that is what pgrep did, and it is banned).
cmdline_of() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }

# Live (non-zombie) members of process group <pgid>, read straight from /proc. Selection is by
# NUMERIC pgid, never by name. Zombies are excluded: our own child stays a zombie until we `wait`
# it, and a zombie is still signalable, so counting it would report a fully-reaped group as alive.
# Fork-free: one `read` builtin per /proc entry, no `ps`/`awk` per process.
group_members() {
  local pgid="${1:-}" f pid line rest
  case "$pgid" in ''|null|0) return 0 ;; esac
  for f in /proc/[0-9]*/stat; do
    [ -r "$f" ] || continue
    IFS= read -r line < "$f" 2>/dev/null || continue
    rest="${line##*) }"   # drop "pid (comm) " — comm itself may hold spaces and parens
    # shellcheck disable=SC2086  # deliberate split: $1=state $2=ppid $3=pgrp … $20=starttime
    set -- $rest
    [ "${1:-}" = "Z" ] && continue
    if [ "${3:-}" = "$pgid" ]; then
      pid="${f#/proc/}"; pid="${pid%/stat}"
      printf '%s\n' "$pid"
    fi
  done
  return 0
}
group_alive() { local m; m="$(group_members "$1")"; [ -n "$m" ]; }

# ---------------------------------------------------------------------------
# verdict.json contract check (AC09). The file is EVIDENCE, so it is re-validated on every read
# rather than trusted because some status.json says VERDICT_PARSED. Echoes pass|fail; a file that
# does not satisfy the full contract produces NO output and a non-zero exit — never a class.
#
# The optional second argument pins the verdict to a RUN: a verdict.json whose run_id belongs to
# some other run is not this run's answer, no matter how well-formed it is (r2 F11).
# ---------------------------------------------------------------------------
verdict_class_of() {
  local f="${1:-}" want_run="${2:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 1
  jq -er --arg want "$want_run" '
    def passes: ["APPROVE","ACCEPTED","PASS"];
    def fails:  ["REQUEST_CHANGES","NEEDS_FIXES","FAIL"];
    if (type == "object")
       and ((.verdict?  | type) == "string")
       and ((.findings? | type) == "array")
       and ((.summary?  | type) == "string")
       and ($want == "" or ((.run_id? // "") == $want))
    then ((.verdict | ascii_upcase) as $v |
          if   (passes | index($v)) and (.verdict_class == "pass") and (.gate == "open")
          then "pass"
          elif (fails  | index($v)) and (.verdict_class == "fail") and (.gate == "closed")
          then "fail"
          else empty end)
    else empty end' "$f" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Terminal failure, replayed from the APPEND-ONLY event stream rather than from a status field that
# a wrapper killed mid-drain never got to write (r2 F10).
#
# An `error` ITEM ({"type":"item.completed","item":{"type":"error"}}) is deliberately NOT a failure:
# the real CLI emits one (a config deprecation notice) on fully successful exit-0 runs, and T8 pins
# that. Only a TOP-LEVEL error event or a turn.failed says the turn itself did not succeed — the
# anchor is what keeps the two apart. Over-matching here would only ever CLOSE the gate.
# ---------------------------------------------------------------------------
events_show_failure() {
  local f="$RUN_DIR/events.jsonl"
  [ -s "$f" ] || return 1
  grep -qE '"type"[[:space:]]*:[[:space:]]*"turn\.failed"' "$f" && return 0
  grep -qE '^[[:space:]]*\{[[:space:]]*"type"[[:space:]]*:[[:space:]]*"error"' "$f" && return 0
  return 1
}

# ---------------------------------------------------------------------------
# RUN PROVENANCE (r2 F9/F10/F11) — a PASS must be PROVEN, not inferred.
#
# A verdict is only usable if the run that produced it is provably a SUCCESSFUL run. Until now the
# verdict was treated as self-standing evidence: a final.md containing "APPROVE" could be mined out
# of a run whose provider had exited 2, whose turn had failed, or which had timed out — the answer
# looked clean, so the gate opened. The answer is not the run. Every clause below is read off a
# durable artifact; nothing is inferred from a state field alone:
#
#   1. the recorded state is not a terminal FAILURE (FAILED / TIMED_OUT). A terminal failure
#      OUTRANKS any stored verdict, so it is checked BEFORE the verdict is even looked at (F11).
#   2. the provider's exit code was actually RECORDED, and it is 0. `null` means nobody ever saw
#      the process exit — that is the ABSENCE of proof, not proof of success (F9/F10).
#   3. the event stream shows no failed turn — replayed from events.jsonl, not from status.json,
#      because a crashed wrapper never wrote it there (F10).
#   4. final.md exists, is non-empty, and was not written BEFORE the run started — a leftover or
#      injected final message from another run is not this run's answer (F10).
#
# Sets PROVENANCE_ERROR and returns 1 at the first missing proof.
# ---------------------------------------------------------------------------
verify_provenance() {
  PROVENANCE_ERROR=""
  case "${STATE:-}" in
    FAILED|TIMED_OUT)
      PROVENANCE_ERROR="recorded state is $STATE — a terminal failure outranks any stored verdict"
      return 1 ;;
  esac
  if [ -z "${EXIT_CODE:-}" ] || [ "$EXIT_CODE" = "null" ]; then
    PROVENANCE_ERROR="no provider exit code was ever recorded — the run's success is unproven"
    return 1
  fi
  if [ "$EXIT_CODE" != "0" ]; then
    PROVENANCE_ERROR="provider exited with code $EXIT_CODE — a failed run cannot yield a usable verdict"
    return 1
  fi
  if events_show_failure; then
    PROVENANCE_ERROR="events.jsonl records a failed turn — the review turn did not succeed"
    return 1
  fi
  if [ ! -s "$RUN_DIR/final.md" ]; then
    PROVENANCE_ERROR="final.md is missing or empty — there is no final message to trust"
    return 1
  fi
  local mt; mt="$(stat -c %Y "$RUN_DIR/final.md" 2>/dev/null || echo 0)"
  if [ "${mt:-0}" -lt "${STARTED:-0}" ] 2>/dev/null; then
    PROVENANCE_ERROR="final.md predates the run (mtime $mt < start $STARTED) — leftover or injected, not this run's answer"
    return 1
  fi
  return 0
}

# A verdict we refuse to honour must stop being a USABLE verdict — .par-evidence.json is built from
# verdict.json, so leaving an unusable one on disk is exactly how a rejected run opens a gate. It is
# still evidence, though (F5), so it is MOVED aside for forensics, never deleted.
quarantine_verdict() {
  [ -e "$RUN_DIR/verdict.json" ] || return 0
  mv -f "$RUN_DIR/verdict.json" "$RUN_DIR/verdict.rejected.json" 2>/dev/null
  recovery_note "verdict.json REJECTED, quarantined to verdict.rejected.json — $1"
  printf '  -> stored verdict.json is NOT usable (%s) — quarantined to verdict.rejected.json\n' "$1"
}

# ---------------------------------------------------------------------------
# Process identity (AC11). A stale record says "pid P, started at tick T, group G". After a crash
# the kernel may well have handed pid P to somebody else, so (pid, starttime) alone is NOT an
# identity — it only says "a process with this pid started at this instant". Before we SIGKILL a
# whole process GROUP we additionally require:
#   - the live process is still the LEADER of the recorded group (pgid == pid, the `set -m`
#     invariant), and its real pgid matches what we recorded;
#   - its argv still carries this run's unique output path. A PID-reuse victim cannot forge that,
#     and we know the marker by construction (we passed `-o <RUN_DIR>/final.md`), so there is no
#     launch-time race in capturing it.
# On failure VERIFY_ERROR explains exactly which check failed, and the caller REFUSES to signal.
# ---------------------------------------------------------------------------
verify_leader() {
  VERIFY_ERROR=""
  [ -n "${PID:-}" ] && [ "$PID" != "null" ] || { VERIFY_ERROR="no pid recorded"; return 1; }
  alive "$PID" || { VERIFY_ERROR="pid $PID is not running"; return 1; }

  local cur_start cur_pgid cur_cmd
  cur_start="$(starttime_of "$PID")"
  cur_pgid="$(pgid_of "$PID")"
  cur_cmd="$(cmdline_of "$PID")"

  if [ -z "${START_TICKS:-}" ] || [ "$START_TICKS" = "null" ] || [ "$cur_start" != "$START_TICKS" ]; then
    VERIFY_ERROR="starttime ${cur_start:-?} != recorded ${START_TICKS:-?} — pid $PID was REUSED by another process"
    return 1
  fi
  if [ -z "${PGID:-}" ] || [ "$PGID" = "null" ] || [ "$cur_pgid" != "$PGID" ]; then
    VERIFY_ERROR="live pgid ${cur_pgid:-?} != recorded pgid ${PGID:-?}"
    return 1
  fi
  if [ "$PGID" != "$PID" ]; then
    VERIFY_ERROR="recorded pgid $PGID is not the recorded pid $PID — the process does not lead the group"
    return 1
  fi
  if [ -z "${CMDLINE_MARKER:-}" ]; then
    VERIFY_ERROR="no cmdline marker on record — this run's identity cannot be proven"
    return 1
  fi
  case "$cur_cmd" in
    *"$CMDLINE_MARKER"*) : ;;
    *) VERIFY_ERROR="argv of pid $PID does not carry this run's marker ($CMDLINE_MARKER) — different process"
       return 1 ;;
  esac
  return 0
}

# Every OTHER member of the group must be a plausible descendant of the verified leader: same
# group, and started no earlier than the leader (starttime is monotonic since boot, so a process
# older than the leader cannot descend from it). Anything else means the group is not exclusively
# ours, and we refuse to SIGKILL it.
verify_group() {
  VERIFY_ERROR=""
  local m st
  for m in $(group_members "$PGID"); do
    [ "$m" = "$PID" ] && continue
    st="$(starttime_of "$m")"
    if [ -z "$st" ] || [ "$st" -lt "$START_TICKS" ] 2>/dev/null; then
      VERIFY_ERROR="pid $m in group $PGID predates the leader (starttime ${st:-?} < $START_TICKS) — not our descendant"
      return 1
    fi
  done
  return 0
}

# Append-only audit trail for recovery actions. events.jsonl belongs to the CLI and is NEVER
# rewritten, truncated or appended to by recovery (AC04/AC05) — wrapper-side facts go here.
recovery_note() {
  [ -n "${RUN_DIR:-}" ] || return 0
  printf '%s %s\n' "$(iso)" "$1" >> "$RUN_DIR/recovery.log" 2>/dev/null || true
  chmod 600 "$RUN_DIR/recovery.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# atomic status.json  (tmp + rename on the same filesystem — AC04)
# ---------------------------------------------------------------------------
write_status() {
  local tmp="$RUN_DIR/.status.json.$$"
  # elapsed_sec is FROZEN once the run is over. A finished run whose clock keeps ticking every
  # time somebody reconciles it is not a record of what happened.
  local elapsed="${ELAPSED_FROZEN:-}"
  [ -n "$elapsed" ] || elapsed=$(( $(now) - STARTED ))
  jq -n \
    --arg run_id "$RUN_ID" --arg slug "$SLUG" --arg state "$STATE" \
    --arg started_at "$(iso "$STARTED")" \
    --arg last_event_at "$([ "$LAST_EVENT_TS" -gt 0 ] && iso "$LAST_EVENT_TS" || echo "")" \
    --arg deadline_at "$(iso "$DEADLINE_TS")" \
    --arg message "$MESSAGE" --arg thread_id "$THREAD_ID" \
    --arg cmdline_marker "${CMDLINE_MARKER:-}" \
    --arg wrapper_version "$WRAPPER_VERSION" \
    --argjson pid "${PID:-null}" --argjson pgid "${PGID:-null}" \
    --argjson start_ticks "${START_TICKS:-null}" \
    --argjson exit_code "${EXIT_CODE:-null}" \
    --argjson progress_confirmed "$PROGRESS_CONFIRMED" \
    --argjson events_seen "$EVENTS_SEEN" --argjson tools_active "$TOOLS_ACTIVE" \
    --argjson orphans_left "${ORPHANS_LEFT:-0}" \
    --argjson elapsed_sec "$elapsed" \
    --arg cli_errors "$CLI_ERRORS" \
    '{run_id:$run_id, slug:$slug, state:$state, pid:$pid, pgid:$pgid,
      start_ticks:$start_ticks, started_at:$started_at,
      last_event_at:(if $last_event_at=="" then null else $last_event_at end),
      deadline_at:$deadline_at, exit_code:$exit_code,
      progress_confirmed:$progress_confirmed, events_seen:$events_seen,
      tools_active:$tools_active, thread_id:(if $thread_id=="" then null else $thread_id end),
      cmdline_marker:(if $cmdline_marker=="" then null else $cmdline_marker end),
      orphans_left:$orphans_left,
      elapsed_sec:$elapsed_sec, message:$message,
      cli_errors:($cli_errors|split("\n")|map(select(.!=""))),
      wrapper_version:$wrapper_version}' > "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$RUN_DIR/status.json"
  rm -f "$tmp" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Load a run's metadata for reconcile/cleanup WITHOUT destroying it (AC04/AC05).
# Recovery used to zero last_event_at / tools_active / events_seen / thread_id and to overwrite
# exit_code with 127 (the shell's "not my child" answer from `wait`) — so the recovered status no
# longer described the run that actually happened. events.jsonl is append-only evidence: we only
# ever READ it, and we re-derive the counters from it so recovery makes the record MORE accurate,
# never less.
# ---------------------------------------------------------------------------
load_run_metadata() {
  local s="$RUN_DIR/status.json"
  RUN_ID="$(jq -r '.run_id // ""' "$s")"
  SLUG="$(jq -r '.slug // ""' "$s")"
  STATE="$(jq -r '.state // "UNKNOWN"' "$s")"
  PID="$(jq -r '.pid // empty' "$s")"
  PGID="$(jq -r '.pgid // empty' "$s")"
  START_TICKS="$(jq -r '.start_ticks // empty' "$s")"
  CMDLINE_MARKER="$(jq -r '.cmdline_marker // ""' "$s")"
  THREAD_ID="$(jq -r '.thread_id // ""' "$s")"
  EXIT_CODE="$(jq -r 'if .exit_code == null then "null" else (.exit_code|tostring) end' "$s")"
  PROGRESS_CONFIRMED="$(jq -r '.progress_confirmed // false' "$s")"
  TOOLS_ACTIVE="$(jq -r '.tools_active // 0' "$s")"
  ORPHANS_LEFT="$(jq -r '.orphans_left // 0' "$s")"
  CLI_ERRORS="$(jq -r '(.cli_errors // []) | join("\n")' "$s")"
  MESSAGE="$(jq -r '.message // ""' "$s")"
  STARTED="$(date -u -d "$(jq -r '.started_at' "$s")" +%s 2>/dev/null || now)"
  DEADLINE_TS="$(date -u -d "$(jq -r '.deadline_at' "$s")" +%s 2>/dev/null || now)"
  ELAPSED_FROZEN="$(jq -r '.elapsed_sec // 0' "$s")"

  LAST_EVENT_TS=0
  local rec_last; rec_last="$(jq -r '.last_event_at // ""' "$s")"
  [ -n "$rec_last" ] && LAST_EVENT_TS="$(date -u -d "$rec_last" +%s 2>/dev/null || echo 0)"

  EVENTS_SEEN="$(jq -r '.events_seen // 0' "$s")"
  if [ -s "$RUN_DIR/events.jsonl" ]; then
    # the raw stream is the authority: a wrapper that died mid-drain under-counted
    local stream_seen mt
    stream_seen="$(grep -c . "$RUN_DIR/events.jsonl" 2>/dev/null || echo 0)"
    [ "$stream_seen" -gt "$EVENTS_SEEN" ] 2>/dev/null && EVENTS_SEEN="$stream_seen"
    mt="$(stat -c %Y "$RUN_DIR/events.jsonl" 2>/dev/null || echo 0)"
    [ "$mt" -gt "$LAST_EVENT_TS" ] 2>/dev/null && LAST_EVENT_TS="$mt"
  fi

  CARRY=""; TURN_FAILED=0; VERDICT_ERROR=""; NO_HEARTBEAT=1
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

  # Suicide guard: only ever signal a group that is NOT our own. If job control failed to give the
  # child its own group, group-signalling would kill this wrapper (and its whole session). In that
  # degraded case we fall back to signalling the single recorded pid.
  local self_pgid group_ok=1
  self_pgid="$(pgid_of $$)"
  if [ -z "$PGID" ] || [ "$PGID" = "null" ] || [ "$PGID" = "$self_pgid" ]; then group_ok=0; fi

  if [ "$group_ok" = "1" ]; then kill -TERM "-$PGID" 2>/dev/null; else kill -TERM "$PID" 2>/dev/null; fi

  # Grace is measured on the GROUP, not on the leader.
  local waited=0
  while [ "$waited" -lt "$GRACE_SEC" ]; do
    if [ "$group_ok" = "1" ]; then group_alive "$PGID" || break; else alive "$PID" || break; fi
    sleep 1; waited=$((waited+1))
  done

  # UNCONDITIONAL escalation. Do NOT make this depend on the leader (or even the group) still
  # looking alive: a descendant that inherited SIG_IGN for SIGTERM survives the TERM that kills its
  # parent, and any liveness probe is a race anyway. SIGKILL on an already-empty group is a no-op
  # (ESRCH), so there is nothing to lose and an orphan to prevent.
  if [ "$group_ok" = "1" ]; then kill -KILL "-$PGID" 2>/dev/null; else kill -KILL "$PID" 2>/dev/null; fi
  sleep 1

  # Verify, don't assume: read the group's membership back out of /proc and report survivors.
  ORPHANS_LEFT=0
  if [ "$group_ok" = "1" ]; then
    local left; left="$(group_members "$PGID" | tr '\n' ' ')"
    left="${left% }"
    if [ -n "$left" ]; then
      ORPHANS_LEFT="$(printf '%s\n' $left | grep -c .)"
      printf 'codex-review: WARNING — %s process(es) SURVIVED SIGKILL in group %s (%s): %s\n' \
        "$ORPHANS_LEFT" "$PGID" "$reason" "$left" >&2
      recovery_note "kill_group: $ORPHANS_LEFT process(es) survived SIGKILL in pgid $PGID ($left)"
      return 1
    fi
  fi
  printf 'codex-review: terminated process group %s (%s)\n' "$PGID" "$reason" >&2
  return 0
}

# ---------------------------------------------------------------------------
# mechanical verdict extraction (§7) — LAST fenced JSON block in final.md.
# Prose is NEVER interpreted. Missing/malformed/unknown verdict => gate stays CLOSED.
# ---------------------------------------------------------------------------
extract_verdict() {
  FINAL_FILE="$RUN_DIR/final.md"
  # A failed extraction must leave NO usable verdict.json behind — not even a stale one from an
  # earlier attempt. The gate reads this file; an orphaned pass would reopen it.
  rm -f "$RUN_DIR/verdict.json" 2>/dev/null
  [ -s "$FINAL_FILE" ] || { VERDICT_ERROR="final.md missing or empty"; return 1; }

  RUN_ID="$RUN_ID" PASS_V="$PASS_VERDICTS" FAIL_V="$FAIL_VERDICTS" \
  python3 - "$FINAL_FILE" "$RUN_DIR/verdict.json" <<'PY'
import json, os, re, sys, datetime

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)

final_path, out_path = sys.argv[1], sys.argv[2]
text = open(final_path, encoding="utf-8", errors="replace").read()
PASS = os.environ["PASS_V"].split()
FAIL = os.environ["FAIL_V"].split()

# Find every FENCE LINE and pair them up, rather than regex-matching complete ```…``` PAIRS.
# A pair-matching regex is blind to an UNTERMINATED final fence — it simply does not see the block,
# hands back the previous one, and a model that was killed/rate-limited/context-exhausted mid-answer
# gets its earlier draft APPROVE promoted to the real verdict. That is the fail-open this whole
# wrapper exists to prevent, so the fences are counted, not pattern-matched.
lines = text.split("\n")
fences = [i for i, ln in enumerate(lines) if re.match(r"^[ \t]*```", ln)]
if not fences:
    fail("no fenced block in final.md")
if len(fences) % 2:
    # odd number of fence lines => the last one was opened and never closed
    fail("the final fenced block is UNTERMINATED (truncated response) — not a verdict")

# The LAST closed fence MUST be the verdict. The reviewer contract says nothing may follow the
# verdict fence, so we do NOT scan backwards for "the most recent block that happens to parse":
# a garbled or truncated last block is a FAILED review, never a fallback to an earlier APPROVE.
#
# And "nothing may follow" is enforced literally: a model that emits a clean APPROVE fence and then
# keeps talking ("Wait — actually the auth check is still broken…") has NOT delivered a verdict. It
# contradicted itself, or it was cut off mid-correction. Either way the message is not a verdict,
# and treating the earlier fence as one INFERS a pass instead of proving it. Only whitespace may
# follow the closing fence.
trailing = "\n".join(lines[fences[-1] + 1:])
if trailing.strip():
    fail("non-whitespace content follows the verdict fence — the verdict must be the LAST thing "
         "in final.md (got %r…)" % trailing.strip()[:60])

block = "\n".join(lines[fences[-2] + 1: fences[-1]])
try:
    chosen = json.loads(block)
except json.JSONDecodeError as e:
    fail("the last fenced block is not valid JSON (%s) — not a verdict" % e.msg)
if not isinstance(chosen, dict):
    fail("last fenced block is not a JSON object")

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
  local PROMPT_FILE="" PROMPT_STDIN=0
  NO_HEARTBEAT=0
  local -a EXTRA=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --slug)          SLUG="${2:?}"; shift 2 ;;
      --root)          ROOT="${2:?}"; shift 2 ;;
      --mode)          MODE="${2:?}"; shift 2 ;;
      --base)          BASE="${2:?}"; shift 2 ;;
      --prompt-file)   PROMPT_FILE="${2:?}"; shift 2 ;;
      --prompt-stdin)  PROMPT_STDIN=1; shift ;;
      # REMOVED (AC12). It put the whole review prompt into this process's argv, where every user
      # on the box can read it out of /proc/<pid>/cmdline. Fail loudly and name the replacement —
      # a silent "unknown flag" would tempt a caller to shell-quote the prompt somewhere worse.
      --prompt-text)   die "--prompt-text was REMOVED: a prompt in argv is world-readable via /proc/<pid>/cmdline (AC12). Use --prompt-file <f> or --prompt-stdin." ;;
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
  chmod 700 "$RUN_DIR" 2>/dev/null   # explicit, even though umask 077 already gives us this

  # This run's identity fingerprint (F4/AC11). We hand codex `-o <RUN_DIR>/final.md`, so this exact
  # string is in the child's argv BY CONSTRUCTION — no launch-time race in capturing it, and a
  # PID-reuse victim cannot forge it. cleanup/reconcile require it before signalling anything.
  CMDLINE_MARKER="$RUN_DIR/final.md"

  # ---- prompt to a FILE, never argv (AC12) ----
  if [ -n "$PROMPT_FILE" ]; then
    [ -r "$PROMPT_FILE" ] || die "prompt file not readable: $PROMPT_FILE"
    cp "$PROMPT_FILE" "$RUN_DIR/prompt.md"
  elif [ "$PROMPT_STDIN" = "1" ]; then
    cat > "$RUN_DIR/prompt.md"
  else
    die "one of --prompt-file / --prompt-stdin is required"
  fi
  chmod 600 "$RUN_DIR/prompt.md" 2>/dev/null

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
    # Same provenance gate as the V2 path: the rollback flag drops the state machine, never the
    # requirement that a pass be PROVEN (AC14).
    if [ "$STATE" = "COMPLETED" ] && verify_provenance && extract_verdict >/dev/null 2>&1; then
      set_state VERDICT_PARSED "verdict extracted (fallback)"
      [ "$(verdict_class_of "$RUN_DIR/verdict.json" "$RUN_ID")" = "pass" ] && return 0 || return 3
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

  # One gate, both paths: `run` proves the run succeeded before it will extract a verdict from it,
  # exactly as `reconcile` does. A re-check can then never be more OPTIMISTIC than the original run,
  # and the original run can never be more optimistic than the evidence (r2 F9/F10).
  if ! verify_provenance; then
    set_state FAILED "run provenance not proven: $PROVENANCE_ERROR"
    VERDICT_ERROR="$PROVENANCE_ERROR"
    heartbeat; finish_report; return 1
  fi

  local v
  if v="$(extract_verdict 2>"$RUN_DIR/.verdict.err")"; then
    set_state VERDICT_PARSED "verdict extracted and validated: $v"
    heartbeat; finish_report
    case "$(verdict_class_of "$RUN_DIR/verdict.json" "$RUN_ID")" in
      pass) return 0 ;;
      fail) return 3 ;;
      *)    return 1 ;;   # written but not re-validatable — fail closed
    esac
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
# cmd_reconcile — crash recovery (§10 test 9), FAIL-CLOSED.
#
# The exit code is the whole point: a review that did not pass must look like a failure to EVERY
# caller, including one that re-checks the run dir later. reconcile therefore returns exactly what
# `run` would have returned — 0 only for a re-validated pass-class verdict, 3 for a fail-class one,
# 1 for everything else (still running, crashed, timed out, no/!valid verdict). It never trusts a
# stale `state` field on its own, and it never trusts liveness as progress.
#
# It is also READ-ONLY with respect to evidence (F5): events.jsonl is append-only and is only ever
# read; the recorded counters (events_seen / thread_id / last_event_at / progress_confirmed) and the
# real exit_code survive recovery untouched. Recovery actions go to recovery.log.
# ---------------------------------------------------------------------------
cmd_reconcile() {
  RUN_DIR="${1:?usage: codex-review.sh reconcile <run-dir>}"
  [ -s "$RUN_DIR/status.json" ] || die "no status.json in $RUN_DIR"
  load_run_metadata

  local live="no" ours="no"
  if [ -n "${PID:-}" ] && [ "$PID" != "null" ] && alive "$PID"; then
    live="yes"
    # Full identity, not just (pid, starttime): pgid + leadership + this run's argv marker (F4).
    if verify_leader; then ours="yes"; fi
  fi

  printf 'reconcile %s\n  recorded state: %s\n  pid %s live: %s | is-our-process: %s\n' \
    "$RUN_DIR" "$STATE" "${PID:-n/a}" "$live" "$ours"

  if [ "$live" = "yes" ] && [ "$ours" = "yes" ]; then
    # Unsupervised and still breathing. Whatever it is doing, it is NOT a verdict — exit non-zero.
    if [ "$(now)" -ge "$DEADLINE_TS" ]; then
      set_state STALLED_SUSPECTED "reconcile: still running past its deadline; wrapper is gone"
      printf '  -> %s (deadline expired; run `cleanup` to terminate the group)\n' "$STATE"
    else
      # Alive is NOT progress. Say exactly that.
      set_state SILENT "reconcile: process alive but unsupervised — liveness is not progress"
      printf '  -> %s: %s (progress_confirmed=%s)\n' "$STATE" "$MESSAGE" "$PROGRESS_CONFIRMED"
    fi
    recovery_note "reconcile: pid $PID alive and verified ours; state -> $STATE (gate CLOSED)"
    printf '  -> gate CLOSED (an unfinished review is not a pass)\n'
    return 1
  fi

  if [ "$live" = "yes" ] && [ "$ours" = "no" ]; then
    # The recorded PID is now a DIFFERENT process. Say so loudly, keep the pid on record for
    # forensics, touch nothing — and go on to judge the run by its ARTIFACTS, which are the only
    # trustworthy evidence left.
    printf '  -> pid %s is live but NOT ours: %s\n' "$PID" "$VERIFY_ERROR"
    printf '  -> treating the recorded PID as REUSED by an unrelated process; it will not be touched.\n'
    recovery_note "reconcile: recorded pid $PID is not ours ($VERIFY_ERROR); not signalled"
  fi

  # ---- the process is gone (or was never ours): judge the run by its ARTIFACTS ----
  #
  # ORDER MATTERS (r2 F11). The run's STATE and PROVENANCE are established FIRST; only a run that is
  # proven to have succeeded may have a verdict honoured or mined out of it. Reading the stored
  # verdict first — as this used to — means a TIMED_OUT or exit-2 run that happens to hold an
  # APPROVE returns 0. The verdict is not the run.
  if ! verify_provenance; then
    printf '  -> run is NOT usable: %s\n' "$PROVENANCE_ERROR"
    quarantine_verdict "$PROVENANCE_ERROR"
    case "$STATE" in
      FAILED|TIMED_OUT) : ;;   # already terminal — keep the accurate label, rewrite nothing
      *) set_state FAILED "reconcile: unusable run — $PROVENANCE_ERROR" ;;
    esac
    recovery_note "reconcile: gate CLOSED — $PROVENANCE_ERROR"
    printf '  -> FAILED (gate CLOSED — a PASS must be proven, not inferred)\n'
    return 1
  fi

  # Provenance is proven: the provider exited 0, no turn failed, and final.md belongs to this run.
  # Only NOW may a verdict be honoured — and it is still re-validated against the full contract and
  # PINNED to this run_id, because a well-formed verdict from another run is not this run's answer.
  local cls=""
  if [ -e "$RUN_DIR/verdict.json" ]; then
    cls="$(verdict_class_of "$RUN_DIR/verdict.json" "$RUN_ID")"
    [ -z "$cls" ] && quarantine_verdict "fails the verdict contract, or belongs to a different run"
  fi

  # Nothing usable on record: re-derive it from this run's own final.md (the crash-recovery path).
  if [ -z "$cls" ]; then
    if extract_verdict >/dev/null 2>"$RUN_DIR/.verdict.err"; then
      cls="$(verdict_class_of "$RUN_DIR/verdict.json" "$RUN_ID")"
      recovery_note "reconcile: verdict re-derived from final.md of a provably successful run ($cls)"
    else
      VERDICT_ERROR="$(tr -d '\n' < "$RUN_DIR/.verdict.err" 2>/dev/null | cut -c1-300)"
    fi
  fi

  if [ "$cls" = "pass" ]; then
    set_state VERDICT_PARSED "reconcile: verdict re-validated: $(jq -r .verdict "$RUN_DIR/verdict.json")"
    printf '  -> verdict %s (pass-class) — gate OPEN\n' "$(jq -r .verdict "$RUN_DIR/verdict.json")"
    return 0
  fi
  if [ "$cls" = "fail" ]; then
    # THE critical case (F1): a stored REQUEST_CHANGES/NEEDS_FIXES/FAIL used to reconcile to 0,
    # which silently turned a rejected review into a green gate on every re-check.
    set_state VERDICT_PARSED "reconcile: verdict re-validated: $(jq -r .verdict "$RUN_DIR/verdict.json")"
    printf '  -> verdict %s (fail-class) — gate CLOSED\n' "$(jq -r .verdict "$RUN_DIR/verdict.json")"
    return 3
  fi

  set_state FAILED "reconcile: no valid verdict — review did not complete${VERDICT_ERROR:+: $VERDICT_ERROR}"
  recovery_note "reconcile: no valid verdict (gate CLOSED)${VERDICT_ERROR:+ — $VERDICT_ERROR}"
  printf '  -> FAILED (no valid verdict; gate CLOSED)\n'
  return 1
}

# ---------------------------------------------------------------------------
# cmd_cleanup — verified stale-process termination (§8, AC11, F4).
#
# This function SIGKILLs an entire process group, so the bar for proving that the group is ours is
# absolute. (pid, starttime) is NOT enough: it only says "a process with this pid started at this
# instant" — it says nothing about the group we are about to wipe out. Before signalling we require
# ALL of:
#   - pid alive, and its starttime equals the recorded one          (not a reused pid)
#   - its real pgid equals the recorded pgid, and it LEADS that group (the `set -m` invariant)
#   - its argv still carries this run's unique output path           (not a lookalike)
#   - every other member of the group started no earlier than the leader (a genuine descendant)
# Any doubt at all -> REFUSE and exit 1. The handoff is explicit: a diagnostic snapshot is not a
# licence to kill a PID.
# ---------------------------------------------------------------------------
cmd_cleanup() {
  RUN_DIR="${1:?usage: codex-review.sh cleanup <run-dir> [--force]}"; shift || true
  local FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
  [ -s "$RUN_DIR/status.json" ] || die "no status.json in $RUN_DIR"
  load_run_metadata     # evidence-preserving: keeps events_seen / thread_id / exit_code (F5)

  if [ -z "${PID:-}" ] || [ "$PID" = "null" ] || ! alive "$PID"; then
    printf 'cleanup: pid %s not running — nothing to kill.\n' "${PID:-n/a}"; return 0
  fi

  if ! verify_leader; then
    printf 'cleanup: REFUSING to signal pid %s / pgid %s — %s\n' "$PID" "${PGID:-?}" "$VERIFY_ERROR" >&2
    recovery_note "cleanup: REFUSED to signal pid $PID — $VERIFY_ERROR"
    return 1
  fi
  if ! verify_group; then
    printf 'cleanup: REFUSING to signal process group %s — %s\n' "$PGID" "$VERIFY_ERROR" >&2
    recovery_note "cleanup: REFUSED to signal pgid $PGID — $VERIFY_ERROR"
    return 1
  fi
  if [ "$FORCE" != "1" ] && [ "$(now)" -lt "$DEADLINE_TS" ]; then
    printf 'cleanup: pid %s is our process but its deadline has not expired. Use --force to override.\n' "$PID" >&2
    return 1
  fi

  recovery_note "cleanup: verified pid $PID / pgid $PGID as this run's group; terminating (force=$FORCE)"
  kill_group "cleanup of stale run $RUN_ID"
  local krc=$?

  # Deliberately NO `wait` here: this process is NOT our child (the wrapper that forked it is gone),
  # so `wait` would return 127 — "no such job" — and recording that as the review's exit code would
  # invent a CLI failure that never happened and overwrite real evidence (F5). The exit code loaded
  # from status.json stands as it is.
  set_state FAILED "cleanup: stale process group terminated by operator"
  printf 'cleanup: terminated pid %s / pgid %s (run %s).\n' "$PID" "$PGID" "$RUN_ID"
  [ "$krc" -ne 0 ] && printf 'cleanup: WARNING — %s process(es) survived; see recovery.log\n' "$ORPHANS_LEFT" >&2
  return "$krc"
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
