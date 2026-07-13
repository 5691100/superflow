#!/usr/bin/env bash
# shellcheck shell=bash
# test-codex-review.sh — hermetic test harness for tools/codex-review.sh
#
# Covers the 9 mandatory tests from the transparent-Codex-review-wrapper handoff (§10):
#   1 normal  2 silent  3 timeout  4 malformed verdict  5 concurrent
#   6 no-wrong-PID  7 early CLI failure  8 tool activity  9 crash/recovery
# …plus the regression suite for the Codex review r1 findings, which were all fail-OPEN defects
# that the happy-path tests could not see:
#   10 reconcile is fail-closed on a stored fail-class verdict            (F1, critical)
#   11 the prompt never reaches argv; artifacts are 0700/0600             (F6)
#   12 cleanup verifies the GROUP's identity before signalling it         (F4)
#   13 recovery preserves the event stream and the recorded evidence      (F5)
#   14 the rollback flag (CODEX_REVIEW_WRAPPER_V2=0) is still fail-closed (AC14)
# …plus the review r2 regressions — four faces of ONE bug: a PASS was being INFERRED from an answer
# that looks clean, instead of PROVEN from a run that demonstrably succeeded:
#   15 content after the verdict fence is not a verdict                    (r2 #1)
#   16 a nonzero provider exit can never yield a usable verdict            (r2 #2)
#   17 crash recovery demands proof of success, not absence of bad news    (r2 #3)
#   18 terminal state + provenance outrank a stored pass verdict           (r2 #4)
#
# Hermetic: never invokes the real `codex` CLI or the network. All runs use
# tools/test-fixtures/fake-codex.sh, which replays the real 0.144.1 JSONL grammar.
#
# Discipline: tests run SEQUENTIALLY (one test process at a time) and every wrapper
# invocation is wrapped in `timeout`. THIS FILE lives by the same banned-pattern rules as the
# wrapper (no pgrep, no `tail --pid`, no `| tail -N`) — T6 scans it to prove it.
#
# Usage: bash tools/test-codex-review.sh [test-number ...]
# Exit 0 = all pass, 1 = any failure.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${BASH_SOURCE[0]}"
WRAPPER="$HERE/codex-review.sh"
FAKE="$HERE/test-fixtures/fake-codex.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-tests.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
declare -a FAILED_TESTS=()

ok()   { printf '    ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '    FAIL %s\n' "$1"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }
head_() { printf '\n[%s] %s\n' "$1" "$2"; }

# assert_eq <expected> <actual> <label>
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3 ($2)"; else bad "$3 — expected '$1', got '$2'"; fi
}
# assert_contains <haystack-file> <needle> <label>
assert_contains() {
  if [ -f "$1" ] && grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 — '$2' not found in $1"; fi
}
assert_file() {
  if [ -s "$1" ]; then ok "$2"; else bad "$2 — missing/empty: $1"; fi
}
assert_absent() {  # <path> <label>
  if [ -e "$1" ]; then bad "$2 — $1 still exists"; else ok "$2"; fi
}
state()  { jq -r '.state'   "$1/status.json" 2>/dev/null; }
jqf()    { jq -r "$2" "$1" 2>/dev/null; }
md5()    { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# newest run dir under <root>/.superflow/reviews/<slug>. Glob order is chronological because a
# RUN_ID starts with a UTC timestamp. (No `| tail -1`: the banned-pattern scanner covers this file.)
rundir() {
  local d last=""
  for d in "$1/.superflow/reviews/$2"/*/; do [ -d "$d" ] && last="${d%/}"; done
  printf '%s\n' "$last"
}

# Write <text> to <dir>/prompt.in, echo the path. The tests NEVER pass prompt content in argv:
# --prompt-text is gone (F6/AC12) because a review prompt can carry unreleased code and security
# findings, and argv is world-readable through /proc/<pid>/cmdline.
pfile() {
  local d="$1"; mkdir -p "$d"
  printf '%s\n' "$2" > "$d/prompt.in"
  printf '%s\n' "$d/prompt.in"
}

# Live (non-zombie) members of a process GROUP — by numeric pgid, never by name pattern.
group_count() { ps -eo pgid=,stat= 2>/dev/null | awk -v g="$1" '$1==g && $2 !~ /^Z/ {n++} END{print n+0}'; }

# The command line of ONE process, looked up BY PID (the sanctioned lookup — see T6).
cmdline_of() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }

want() { # want <n> — should this test run?
  [ ${#SELECT[@]} -eq 0 ] && return 0
  local n; for n in "${SELECT[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1
}

SELECT=("$@")

# ---------------------------------------------------------------------------
# T1 — normal: events + final + valid verdict; reaches VERDICT_PARSED.
# ---------------------------------------------------------------------------
t1() {
  head_ T1 "normal review reaches VERDICT_PARSED"
  local root="$TMPROOT/t1"; mkdir -p "$root"
  local out="$root/stdout.txt"
  local sentinel="review this diff"

  CODEX_BIN="$FAKE" FAKE_MODE=normal FAKE_ARGV_OUT="$root/argv.txt" \
  timeout 60 bash "$WRAPPER" run --slug s1 --root "$root" --base main \
    --prompt-file "$(pfile "$root/p" "$sentinel")" --heartbeat-sec 1 >"$out" 2>&1
  local rc=$?

  local rd; rd="$(rundir "$root" s1)"

  # Regression guard (found by the first LIVE run): codex-cli 0.144.1 rejects
  # `exec review --base <B>` together with a [PROMPT] positional. Superflow's gate needs the
  # prompt (verdict contract), so review mode must scope via the PROMPT, not via `--base`.
  if grep -qE '(^| )review( |$)' "$root/argv.txt" && grep -qE '(^| )--base( |$)' "$root/argv.txt"; then
    bad "T1 argv must not combine 'review' + '--base' (CLI rejects it with a prompt)"
  else
    ok "T1 argv avoids the illegal 'review --base' + prompt combination"
  fi
  assert_contains "$root/argv.txt" "-o " "T1 prompt is NOT in argv — passed via stdin (AC12)"
  if grep -qF "$sentinel" "$root/argv.txt"; then bad "T1 prompt LEAKED into argv"; else ok "T1 prompt text never appears in argv (AC12)"; fi
  assert_contains "$rd/prompt.md" "git diff main...HEAD" "T1 review mode scopes the prompt to <base>...HEAD"
  assert_eq 0 "$rc" "T1 exit 0 (valid pass-class verdict)"
  assert_eq "VERDICT_PARSED" "$(state "$rd")" "T1 terminal state"
  assert_file "$rd/events.jsonl" "T1 events.jsonl written"
  assert_file "$rd/final.md"     "T1 final.md written"
  assert_file "$rd/status.json"  "T1 status.json written"
  assert_file "$rd/prompt.md"    "T1 prompt.md written"
  assert_file "$rd/pid"          "T1 pid written"
  assert_file "$rd/verdict.json" "T1 verdict.json written"
  # §7: LAST fenced block wins (fixture plants an earlier REQUEST_CHANGES decoy).
  assert_eq "APPROVE" "$(jqf "$rd/verdict.json" .verdict)" "T1 verdict = last fenced block"
  assert_eq "pass"    "$(jqf "$rd/verdict.json" .verdict_class)" "T1 verdict_class"
  assert_eq "open"    "$(jqf "$rd/verdict.json" .gate)" "T1 gate open"
  assert_eq "true"    "$(jqf "$rd/status.json" .progress_confirmed)" "T1 progress_confirmed"
  assert_eq "0"       "$(jqf "$rd/status.json" .exit_code)" "T1 exit_code recorded"
  # the run's identity fingerprint, used by cleanup to prove a live group is really ours (F4)
  assert_eq "$rd/final.md" "$(jqf "$rd/status.json" .cmdline_marker)" "T1 cmdline_marker recorded"
  assert_contains "$out" "Codex review:" "T1 heartbeat printed to stdout"
  # AC01: raw event stream is visible, not swallowed by tail -N
  assert_contains "$rd/events.jsonl" '"type":"thread.started"' "T1 raw JSONL stream preserved (AC01)"
}

# ---------------------------------------------------------------------------
# T2 — silent: alive but emitting nothing. Must surface SILENT then STALLED_SUSPECTED,
#      and must NEVER report progress_confirmed=true. (AC07)
# ---------------------------------------------------------------------------
t2() {
  head_ T2 "silent provider is reported as silence, not as progress"
  local root="$TMPROOT/t2"; mkdir -p "$root"
  local out="$root/stdout.txt"

  CODEX_BIN="$FAKE" FAKE_MODE=silent FAKE_SILENT_SEC=60 \
  timeout 40 bash "$WRAPPER" run --slug s2 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
    --heartbeat-sec 1 --silent-sec 2 --stall-sec 5 --deadline-sec 9 >"$out" 2>&1
  local rc=$?

  local rd; rd="$(rundir "$root" s2)"
  assert_contains "$out" "Codex review: SILENT"            "T2 SILENT state surfaced"
  assert_contains "$out" "Codex review: STALLED_SUSPECTED" "T2 STALLED_SUSPECTED surfaced"
  assert_contains "$out" "progress confirmed no"           "T2 heartbeat says progress NOT confirmed"
  # A live process that never speaks is the exact shape of the 26-day hang: the heartbeat must
  # say "alive" and "progress NOT confirmed" in the same breath, and must never claim otherwise.
  assert_contains "$out" "alive yes"                       "T2 heartbeat reports liveness separately from progress"
  assert_eq "false" "$(jqf "$rd/status.json" .progress_confirmed)" "T2 progress_confirmed=false"
  assert_eq "0"     "$(jqf "$rd/status.json" .events_seen)"        "T2 zero events seen"
  assert_eq "TIMED_OUT" "$(state "$rd")" "T2 terminal state (deadline, not a verdict)"
  if grep -q "VERDICT_PARSED" "$out"; then bad "T2 a silent run must never reach VERDICT_PARSED"; else ok "T2 never reaches VERDICT_PARSED"; fi
  assert_absent "$rd/verdict.json" "T2 no verdict.json from a silent run"
  assert_eq 1 "$rc" "T2 exit 1 (no verdict — gate closed)"
}

# ---------------------------------------------------------------------------
# T3 — timeout: hard deadline kills the WHOLE process group, no orphans. (AC08, F3)
# ---------------------------------------------------------------------------
t3() {
  head_ T3 "hard deadline -> TIMED_OUT, whole group reaped incl. a TERM-resistant descendant"
  local root="$TMPROOT/t3"; mkdir -p "$root"
  local out="$root/stdout.txt"

  CODEX_BIN="$FAKE" FAKE_MODE=hang FAKE_HANG_SEC=300 FAKE_GRANDCHILD_OUT="$root/gc.pid" \
  timeout 40 bash "$WRAPPER" run --slug s3 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
    --heartbeat-sec 1 --silent-sec 30 --stall-sec 60 --deadline-sec 3 --grace-sec 2 >"$out" 2>&1
  local rc=$?

  local rd; rd="$(rundir "$root" s3)"
  local pid pgid gc
  pid="$(jqf "$rd/status.json" .pid)"; pgid="$(jqf "$rd/status.json" .pgid)"
  gc="$(cat "$root/gc.pid" 2>/dev/null)"

  assert_eq "TIMED_OUT" "$(state "$rd")" "T3 state"
  assert_eq 1 "$rc" "T3 exit 1 (timed out — gate closed)"
  sleep 1
  # The grandchild IGNORES SIGTERM. Escalating only while the LEADER is alive would skip the
  # SIGKILL and leave it running forever — the orphan class this wrapper exists to prevent.
  if [ -n "$gc" ] && kill -0 "$gc" 2>/dev/null; then
    bad "T3 TERM-resistant descendant ($gc) SURVIVED — the group was not SIGKILLed"
  else
    ok "T3 TERM-resistant descendant was SIGKILLed with the group"
  fi
  assert_eq "0" "$(group_count "$pgid")" "T3 no orphans left in process group $pgid"
  if kill -0 "$pid" 2>/dev/null; then bad "T3 child still alive"; else ok "T3 child reaped"; fi
  assert_eq "0" "$(jqf "$rd/status.json" .orphans_left)" "T3 wrapper verified the group is empty"
  # partial evidence preserved
  assert_contains "$rd/events.jsonl" '"type":"turn.started"' "T3 partial events preserved"
  assert_file "$rd/status.json" "T3 status.json preserved"
  assert_absent "$rd/verdict.json" "T3 no verdict on timeout"
}

# ---------------------------------------------------------------------------
# T4 — malformed / unknown / prose-only / truncated verdict: gate stays CLOSED. (AC09, F2)
# ---------------------------------------------------------------------------
t4() {
  head_ T4 "every non-conforming final message fails the gate — no fallback to an earlier fence"
  local root="$TMPROOT/t4"; mkdir -p "$root"; local rd rc

  # (a) corrupt JSON inside the fence
  CODEX_BIN="$FAKE" FAKE_MODE=malformed \
    timeout 40 bash "$WRAPPER" run --slug m1 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
      --no-heartbeat >"$root/a.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m1)"
  assert_eq 1 "$rc" "T4a malformed JSON -> exit 1"
  assert_eq "FAILED" "$(state "$rd")" "T4a state FAILED"
  assert_file "$rd/final.md" "T4a final.md preserved for diagnosis"
  assert_absent "$rd/verdict.json" "T4a no verdict.json"
  assert_contains "$root/a.txt" "gate:       CLOSED" "T4a gate reported CLOSED"

  # (b) parseable JSON, unknown verdict value
  CODEX_BIN="$FAKE" FAKE_MODE=badverdict \
    timeout 40 bash "$WRAPPER" run --slug m2 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
      --no-heartbeat >"$root/b.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m2)"
  assert_eq 1 "$rc" "T4b unknown verdict 'LGTM' -> exit 1"
  assert_eq "FAILED" "$(state "$rd")" "T4b state FAILED"

  # (c) prose only, and the prose literally says "APPROVE" — must NOT become a pass
  CODEX_BIN="$FAKE" FAKE_MODE=noverdict \
    timeout 40 bash "$WRAPPER" run --slug m3 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
      --no-heartbeat >"$root/c.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m3)"
  assert_eq 1 "$rc" "T4c prose saying APPROVE -> exit 1 (prose is never parsed)"
  assert_absent "$rd/verdict.json" "T4c no false PASS from prose"

  # (d) valid APPROVE fence followed by a LATER corrupt fence. Scanning backwards for "the last
  #     block that happens to parse" would return the APPROVE and open the gate. (F2)
  CODEX_BIN="$FAKE" FAKE_MODE=trailingbad \
    timeout 40 bash "$WRAPPER" run --slug m4 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
      --no-heartbeat >"$root/d.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m4)"
  assert_eq 1 "$rc" "T4d corrupt LAST fence -> exit 1 (no fallback to an earlier valid fence)"
  assert_absent "$rd/verdict.json" "T4d the earlier APPROVE fence is NOT used"

  # (e) verdict present but `findings`/`summary` missing — the contract requires all three.
  CODEX_BIN="$FAKE" FAKE_MODE=partial \
    timeout 40 bash "$WRAPPER" run --slug m5 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
      --no-heartbeat >"$root/e.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m5)"
  assert_eq 1 "$rc" "T4e incomplete verdict object -> exit 1 (findings+summary are mandatory)"
  assert_absent "$rd/verdict.json" "T4e no verdict.json for an incomplete schema"

  # (f) valid APPROVE fence followed by a TRUNCATED one (opened, never closed) — a killed or
  #     rate-limited model. A closed-fence-only regex cannot SEE the truncated block, so it
  #     silently returns the earlier APPROVE: the same fail-open, one step subtler. (F2 residual)
  CODEX_BIN="$FAKE" FAKE_MODE=truncated \
    timeout 40 bash "$WRAPPER" run --slug m6 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
      --no-heartbeat >"$root/f.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m6)"
  assert_eq 1 "$rc" "T4f UNTERMINATED last fence -> exit 1 (a truncated answer is not a verdict)"
  assert_eq "FAILED" "$(state "$rd")" "T4f state FAILED"
  assert_absent "$rd/verdict.json" "T4f the earlier APPROVE fence is NOT used for a truncated tail"
}

# ---------------------------------------------------------------------------
# T5 — concurrent reviews: separate dirs / pids / pgids, results never cross, and a concurrent
#      reader never sees a torn status.json. (AC03, AC04, AC10)
# ---------------------------------------------------------------------------
t5() {
  head_ T5 "two concurrent reviews on the same slug do not collide"
  local root="$TMPROOT/t5"; mkdir -p "$root"

  local rcA rcB
  ( CODEX_BIN="$FAKE" FAKE_MODE=normal FAKE_TOOL_SEC=2 \
      timeout 40 bash "$WRAPPER" run --slug same --root "$root" --prompt-file "$(pfile "$root/pa" "A")" \
        --no-heartbeat >"$root/A.txt" 2>&1; echo $? >"$root/rcA" ) &
  local pA=$!
  ( CODEX_BIN="$FAKE" FAKE_MODE=normal FAKE_TOOL_SEC=2 \
      FAKE_FINAL_TEXT='done

```json
{"verdict":"REQUEST_CHANGES","findings":[{"id":"F1"}],"summary":"B findings"}
```' \
      timeout 40 bash "$WRAPPER" run --slug same --root "$root" --prompt-file "$(pfile "$root/pb" "B")" \
        --no-heartbeat >"$root/B.txt" 2>&1; echo $? >"$root/rcB" ) &
  local pB=$!

  # AC04: status.json is replaced by an atomic tmp+rename. Hammer both files while the runs are in
  # flight — every single read must parse. A torn read is what makes an orchestrator act on a
  # half-written state.
  local torn=0 reads=0 f stop=$(( $(date +%s) + 6 ))
  while [ "$(date +%s)" -lt "$stop" ]; do
    for f in "$root"/.superflow/reviews/same/*/status.json; do
      [ -f "$f" ] || continue
      reads=$((reads+1))
      jq -e . "$f" >/dev/null 2>&1 || torn=$((torn+1))
    done
  done
  wait "$pA" "$pB"
  rcA="$(cat "$root/rcA")"; rcB="$(cat "$root/rcB")"

  if [ "$reads" -gt 100 ]; then ok "T5 status.json was sampled $reads times under concurrency"
  else bad "T5 too few concurrent reads ($reads) — the torn-read check would be vacuous"; fi
  assert_eq 0 "$torn" "T5 zero torn/partial status.json reads (atomic rename)"

  local dirs; dirs="$(find "$root/.superflow/reviews/same" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  assert_eq 2 "$dirs" "T5 two distinct run directories"

  # map each run dir to its prompt so we can check results did not cross
  local dA dB d
  for d in "$root"/.superflow/reviews/same/*/; do
    if grep -qx "A" "$d/prompt.md" 2>/dev/null; then dA="${d%/}"; fi
    if grep -qx "B" "$d/prompt.md" 2>/dev/null; then dB="${d%/}"; fi
  done

  assert_eq "APPROVE"         "$(jqf "$dA/verdict.json" .verdict)" "T5 run A keeps its own verdict"
  assert_eq "REQUEST_CHANGES" "$(jqf "$dB/verdict.json" .verdict)" "T5 run B keeps its own verdict"
  assert_eq 0 "$rcA" "T5 run A exit 0 (pass-class)"
  assert_eq 3 "$rcB" "T5 run B exit 3 (fail-class verdict, gate closed)"

  local pidA pidB pgA pgB
  pidA="$(jqf "$dA/status.json" .pid)"; pidB="$(jqf "$dB/status.json" .pid)"
  pgA="$(jqf "$dA/status.json" .pgid)"; pgB="$(jqf "$dB/status.json" .pgid)"
  if [ "$pidA" != "$pidB" ]; then ok "T5 distinct PIDs ($pidA vs $pidB)"; else bad "T5 PIDs collided"; fi
  if [ "$pgA" != "$pgB" ]; then ok "T5 distinct PGIDs ($pgA vs $pgB)"; else bad "T5 PGIDs collided"; fi
  assert_eq "1" "$(jqf "$dB/verdict.json" .findings_count)" "T5 run B findings not mixed with A"
}

# ---------------------------------------------------------------------------
# T6 — no wrong PID: a decoy whose cmdline looks exactly like a codex review must be
#      untouched, even when the wrapper TERMs its own process group. (AC02, AC11, F7)
# ---------------------------------------------------------------------------
t6() {
  head_ T6 "decoy 'codex exec' process is never matched, waited on, or killed"
  local root="$TMPROOT/t6"; mkdir -p "$root"

  # decoy: argv[0] IS a codex review command line -> the old `pgrep -f "codex exec"` would match it
  bash -c 'exec -a "codex exec review --base main -m gpt-5.6-sol -c model_reasoning_effort=high" sleep 60' &
  local decoy=$!
  sleep 0.5

  # Prove the trap is real WITHOUT searching for a process by name: read the decoy's own cmdline
  # BY PID — the only sanctioned lookup — and confirm it carries the string the old recovery
  # pattern would have matched. (The test suite must not use pgrep either. F7.)
  case "$(cmdline_of "$decoy")" in
    *"codex exec review"*) ok "T6 decoy's cmdline is what the old pattern-matching recovery would have grabbed" ;;
    *)                     bad "T6 decoy did not register — test would be vacuous" ;;
  esac

  # a hanging run that will hit its deadline and TERM/KILL its own group
  CODEX_BIN="$FAKE" FAKE_MODE=hang FAKE_HANG_SEC=120 \
  timeout 40 bash "$WRAPPER" run --slug s6 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
    --no-heartbeat --deadline-sec 3 --grace-sec 2 >"$root/out.txt" 2>&1
  local rd; rd="$(rundir "$root" s6)"
  local pid pgid; pid="$(jqf "$rd/status.json" .pid)"; pgid="$(jqf "$rd/status.json" .pgid)"

  if [ "$pid" != "$decoy" ]; then ok "T6 wrapper tracked its own child ($pid), not the decoy ($decoy)"
  else bad "T6 wrapper latched onto the decoy PID"; fi
  # the decoy must not even share the group we SIGKILLed
  local dpgid; dpgid="$(ps -o pgid= -p "$decoy" 2>/dev/null | tr -d ' ')"
  if [ "$dpgid" != "$pgid" ]; then ok "T6 decoy is not in the run's process group"; else bad "T6 decoy shares the killed group"; fi
  sleep 1
  if kill -0 "$decoy" 2>/dev/null; then ok "T6 decoy SURVIVED the group kill"; else bad "T6 decoy was killed"; fi

  kill -KILL "$decoy" 2>/dev/null; wait "$decoy" 2>/dev/null

  # Static guarantee: the banned patterns appear nowhere in EXECUTABLE code — in the wrapper OR in
  # this test file. (r1 finding F7: the suite itself was calling pgrep while asserting nobody does.)
  # `^[^#]*` anchors the match before the first '#', so comments that NAME these patterns in order
  # to explain why they are forbidden do not trip the check.
  local f n
  for f in "$WRAPPER" "$SELF"; do
    n="$(basename "$f")"
    if grep -qE '^[^#]*\bpgrep\b' "$f"; then bad "T6 $n CODE contains pgrep"; else ok "T6 $n code contains no pgrep (AC02)"; fi
    if grep -qE '^[^#]*tail[[:space:]]+--pid' "$f"; then bad "T6 $n CODE contains 'tail --pid'"; else ok "T6 $n code has no 'tail --pid'"; fi
    if grep -qE '^[^#]*\|[[:space:]]*tail[[:space:]]+-' "$f"; then bad "T6 $n CODE pipes into tail -N"; else ok "T6 $n code never pipes into 'tail -N' (AC01)"; fi
  done
}

# ---------------------------------------------------------------------------
# T7 — early CLI failure (bad flag / model): FAILED, stderr + exit code preserved.
# ---------------------------------------------------------------------------
t7() {
  head_ T7 "early CLI failure -> FAILED with stderr and exit code preserved"
  local root="$TMPROOT/t7"; mkdir -p "$root"

  CODEX_BIN="$FAKE" FAKE_MODE=failfast \
  timeout 40 bash "$WRAPPER" run --slug s7 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
    --no-heartbeat >"$root/out.txt" 2>&1
  local rc=$?
  local rd; rd="$(rundir "$root" s7)"

  assert_eq 1 "$rc" "T7 exit 1 (gate closed)"
  assert_eq "FAILED" "$(state "$rd")" "T7 state FAILED"
  assert_eq "2" "$(jqf "$rd/status.json" .exit_code)" "T7 CLI exit code recorded"
  assert_file "$rd/stderr.log" "T7 stderr.log preserved"
  assert_contains "$rd/stderr.log" "not available" "T7 CLI error text captured"
  assert_absent "$rd/verdict.json" "T7 no verdict on failure"
}

# ---------------------------------------------------------------------------
# T8 — tool activity: item.started(tool) -> TOOL_ACTIVE, then SYNTHESIZING -> COMPLETED.
# ---------------------------------------------------------------------------
t8() {
  head_ T8 "tool call drives TOOL_ACTIVE -> SYNTHESIZING -> VERDICT_PARSED"
  local root="$TMPROOT/t8"; mkdir -p "$root"
  local out="$root/stdout.txt"

  CODEX_BIN="$FAKE" FAKE_MODE=tools FAKE_TOOL_SEC=3 \
  timeout 40 bash "$WRAPPER" run --slug s8 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
    --heartbeat-sec 1 --deadline-sec 25 >"$out" 2>&1
  local rc=$?
  local rd; rd="$(rundir "$root" s8)"

  assert_contains "$out" "Codex review: TOOL_ACTIVE"  "T8 TOOL_ACTIVE observed during tool call"
  assert_contains "$out" "Codex review: SYNTHESIZING" "T8 SYNTHESIZING observed after tool call"
  assert_eq "VERDICT_PARSED" "$(state "$rd")" "T8 terminal state"
  assert_eq 0 "$rc" "T8 exit 0"
  assert_eq "true" "$(jqf "$rd/status.json" .progress_confirmed)" "T8 progress confirmed by tool activity"
  # a benign `error` item (config deprecation) must NOT fail an otherwise good run
  assert_eq "1" "$(jqf "$rd/status.json" '.cli_errors|length')" "T8 benign error item recorded, not fatal"
}

# ---------------------------------------------------------------------------
# T9 — crash / recovery: reconcile must not mistake a live-but-unsupervised process for
#      progress, and must refuse to act on a REUSED pid. (AC11)
# ---------------------------------------------------------------------------
t9() {
  head_ T9 "reconcile after wrapper crash; stale liveness is not progress"
  local root="$TMPROOT/t9"; mkdir -p "$root"

  # start a run, then hard-kill the WRAPPER (child keeps running, orphaned)
  CODEX_BIN="$FAKE" FAKE_MODE=hang FAKE_HANG_SEC=120 \
    bash "$WRAPPER" run --slug s9 --root "$root" --prompt-file "$(pfile "$root/p" "p")" \
      --no-heartbeat --deadline-sec 60 >"$root/out.txt" 2>&1 &
  local wpid=$!
  sleep 3
  kill -KILL "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null

  local rd; rd="$(rundir "$root" s9)"
  local pid pgid; pid="$(jqf "$rd/status.json" .pid)"; pgid="$(jqf "$rd/status.json" .pgid)"
  if kill -0 "$pid" 2>/dev/null; then ok "T9 child outlived the crashed wrapper (orphan to recover)"; else bad "T9 setup: child already gone"; fi

  # (a) reconcile: alive + ours, but liveness must NOT be sold as progress
  timeout 30 bash "$WRAPPER" reconcile "$rd" >"$root/rec.txt" 2>&1
  local rc=$?
  assert_eq 1 "$rc" "T9a reconcile exit 1 (not a pass)"
  assert_contains "$root/rec.txt" "is-our-process: yes" "T9a identity confirmed (pid+starttime+pgid+cmdline)"
  assert_contains "$root/rec.txt" "liveness is not progress" "T9a stale liveness not counted as progress"
  assert_eq "false" "$(jqf "$rd/status.json" .progress_confirmed)" "T9a progress_confirmed still false"

  # (b) cleanup --force: terminate the verified stale group, leave nothing behind
  timeout 30 bash "$WRAPPER" cleanup "$rd" --force >"$root/cln.txt" 2>&1
  assert_contains "$root/cln.txt" "terminated pid" "T9b cleanup terminated the verified group"
  sleep 1
  assert_eq "0" "$(group_count "$pgid")" "T9b no orphans after cleanup"

  # (c) PID reuse: an innocent live process now holds the recorded PID (its starttime differs).
  #     Neither reconcile nor cleanup may touch it. Two fixtures, because reconcile rewrites state.
  bash -c 'exec sleep 60' & local victim=$!
  sleep 0.3

  mk_reuse_fixture() {   # <dir> — records the victim's PID but a bogus starttime
    mkdir -p "$1"
    jq -n --argjson pid "$victim" '{run_id:"reused",slug:"s9",state:"MODEL_WAIT",pid:$pid,pgid:$pid,
        start_ticks:999999999,cmdline_marker:"/nonexistent/final.md",
        started_at:"2026-01-01T00:00:00Z",deadline_at:"2026-01-01T00:15:00Z",
        exit_code:null,progress_confirmed:false,events_seen:0,tools_active:0,thread_id:null,
        elapsed_sec:0,message:"",cli_errors:[],wrapper_version:"2.0.0"}' > "$1/status.json"
  }

  mk_reuse_fixture "$root/reuse-a"
  timeout 30 bash "$WRAPPER" reconcile "$root/reuse-a" >"$root/reuse.txt" 2>&1
  assert_contains "$root/reuse.txt" "REUSED" "T9c reconcile detects reused PID via starttime mismatch"

  mk_reuse_fixture "$root/reuse-b"
  timeout 30 bash "$WRAPPER" cleanup "$root/reuse-b" --force >"$root/reuse-cln.txt" 2>&1
  local crc=$?
  assert_eq 1 "$crc" "T9c cleanup refuses to kill a reused PID"
  assert_contains "$root/reuse-cln.txt" "REFUSING" "T9c refusal is explicit"

  if kill -0 "$victim" 2>/dev/null; then ok "T9c innocent PID-reuse victim ($victim) untouched"
  else bad "T9c the innocent process holding the reused PID was killed"; fi
  kill -KILL "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
}

# ---------------------------------------------------------------------------
# T10 — F1 (critical): a stored fail-class verdict must NEVER reconcile to success.
#       The run itself returned 3; an orchestrator that later re-checks the same run dir with
#       `reconcile` would have received 0 — turning REQUEST_CHANGES into a green gate.
# ---------------------------------------------------------------------------
t10() {
  head_ T10 "reconcile is fail-closed: a stored fail-class verdict never reports success (F1)"
  local root="$TMPROOT/t10"; mkdir -p "$root"; local rd

  # (a) REQUEST_CHANGES: the run exits 3 …
  CODEX_BIN="$FAKE" FAKE_MODE=normal \
    FAKE_FINAL_TEXT='Findings below.

```json
{"verdict":"REQUEST_CHANGES","findings":[{"id":"F1","severity":"critical"}],"summary":"must not pass"}
```' \
    timeout 40 bash "$WRAPPER" run --slug r1 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p1" "p")" --no-heartbeat >"$root/a.txt" 2>&1
  local rc=$?
  rd="$(rundir "$root" r1)"
  assert_eq 3 "$rc" "T10a run exits 3 on a fail-class verdict"
  assert_eq "fail" "$(jqf "$rd/verdict.json" .verdict_class)" "T10a verdict stored as fail-class"

  # … and reconcile on the SAME run dir must be non-zero too.
  timeout 30 bash "$WRAPPER" reconcile "$rd" >"$root/rec1.txt" 2>&1
  assert_eq 3 "$?" "T10a reconcile exits 3 on a stored REQUEST_CHANGES (never 0)"
  assert_contains "$root/rec1.txt" "gate CLOSED" "T10a reconcile says the gate is CLOSED"

  # (b) pass-class still reconciles to 0 — the gate is fail-CLOSED, not fail-ALWAYS.
  CODEX_BIN="$FAKE" FAKE_MODE=normal \
    timeout 40 bash "$WRAPPER" run --slug r2 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p2" "p")" --no-heartbeat >"$root/b.txt" 2>&1
  rd="$(rundir "$root" r2)"
  timeout 30 bash "$WRAPPER" reconcile "$rd" >"$root/rec2.txt" 2>&1
  assert_eq 0 "$?" "T10b reconcile exits 0 on a stored APPROVE"

  # (c) a run that never produced a valid verdict must reconcile to 1.
  CODEX_BIN="$FAKE" FAKE_MODE=malformed \
    timeout 40 bash "$WRAPPER" run --slug r3 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p3" "p")" --no-heartbeat >"$root/c.txt" 2>&1
  rd="$(rundir "$root" r3)"
  timeout 30 bash "$WRAPPER" reconcile "$rd" >"$root/rec3.txt" 2>&1
  assert_eq 1 "$?" "T10c reconcile exits 1 on a run with no valid verdict"

  # (d) TAMPERED/incomplete evidence: state says VERDICT_PARSED but verdict.json no longer
  #     satisfies the contract, and final.md is gone so nothing can be re-derived. Trusting the
  #     recorded state alone would open the gate on a file that nobody ever validated.
  rd="$(rundir "$root" r2)"
  printf '{"verdict":"APPROVE"}\n' > "$rd/verdict.json"
  rm -f "$rd/final.md"
  timeout 30 bash "$WRAPPER" reconcile "$rd" >"$root/rec4.txt" 2>&1
  assert_eq 1 "$?" "T10d reconcile exits 1 when the stored verdict.json fails the contract"
  assert_absent "$rd/verdict.json" "T10d the invalid verdict.json is removed, not left to be misread"
}

# ---------------------------------------------------------------------------
# T11 — F6: the prompt never reaches argv, and run artifacts are not world-readable.
# ---------------------------------------------------------------------------
t11() {
  head_ T11 "prompt never lands in argv; run dir 0700 and artifacts 0600 (F6/AC12)"
  local root="$TMPROOT/t11"; mkdir -p "$root"
  local sentinel="SENTINEL-e7f1c0-unreleased-review-text"

  # (a) --prompt-text is GONE: it put the entire prompt into the wrapper's own argv, where any
  #     user on the box can read it out of /proc/<pid>/cmdline.
  timeout 20 bash "$WRAPPER" run --slug p1 --root "$root" --prompt-text "$sentinel" >"$root/pt.txt" 2>&1
  assert_eq 2 "$?" "T11a --prompt-text is rejected as a usage error"
  assert_contains "$root/pt.txt" "--prompt-file" "T11a the error points at the safe alternative"

  # (b) run a review whose prompt holds the sentinel and, WHILE IT IS IN FLIGHT, read the real
  #     /proc cmdline of both the wrapper and the codex child. Neither may carry the prompt.
  local pf; pf="$(pfile "$root/p2" "$sentinel")"
  CODEX_BIN="$FAKE" FAKE_MODE=hang FAKE_HANG_SEC=30 \
    bash "$WRAPPER" run --slug p2 --root "$root" --mode exec --prompt-file "$pf" \
      --no-heartbeat --deadline-sec 4 --grace-sec 1 >"$root/out.txt" 2>&1 &
  local wpid=$!
  local rd="" i=0
  while [ "$i" -lt 80 ] && [ -z "$rd" ]; do sleep 0.1; rd="$(rundir "$root" p2)"; i=$((i+1)); done
  i=0; while [ "$i" -lt 80 ] && [ ! -s "$rd/pid" ]; do sleep 0.1; i=$((i+1)); done
  local child; child="$(cat "$rd/pid" 2>/dev/null)"

  case "$(cmdline_of "$wpid")" in
    *"$sentinel"*) bad "T11b the prompt LEAKED into the wrapper's own argv" ;;
    *)             ok  "T11b prompt absent from /proc/<wrapper>/cmdline" ;;
  esac
  case "$(cmdline_of "$child")" in
    *"$sentinel"*) bad "T11b the prompt LEAKED into the codex child's argv" ;;
    *)             ok  "T11b prompt absent from /proc/<codex-child>/cmdline" ;;
  esac
  wait "$wpid" 2>/dev/null

  # (c) permissions — a review dir holds the prompt, the full transcript and the findings.
  assert_eq "700" "$(stat -c %a "$rd")"              "T11c run dir is 0700"
  assert_eq "600" "$(stat -c %a "$rd/prompt.md")"    "T11c prompt.md is 0600"
  assert_eq "600" "$(stat -c %a "$rd/status.json")"  "T11c status.json is 0600"
  assert_eq "600" "$(stat -c %a "$rd/events.jsonl")" "T11c events.jsonl is 0600"

  # (d) the artifacts codex itself writes inherit the same umask
  CODEX_BIN="$FAKE" FAKE_MODE=normal \
    timeout 40 bash "$WRAPPER" run --slug p3 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p3" "p")" --no-heartbeat >"$root/n.txt" 2>&1
  rd="$(rundir "$root" p3)"
  assert_eq "600" "$(stat -c %a "$rd/final.md")"    "T11d final.md (the whole review) is 0600"
  assert_eq "600" "$(stat -c %a "$rd/verdict.json")" "T11d verdict.json is 0600"
}

# ---------------------------------------------------------------------------
# T12 — F4: cleanup must verify that the recorded GROUP really is this run's before it SIGKILLs
#       the group. (pid, starttime) only says "a process with this pid started at this instant".
# ---------------------------------------------------------------------------
t12() {
  head_ T12 "cleanup refuses to signal a process group it cannot tie to the run (F4)"
  local root="$TMPROOT/t12"; mkdir -p "$root"

  # A live process leading its OWN group, whose cmdline even LOOKS like a codex run — but points
  # at a different run dir. `set -m` gives it its own pgid, exactly like the wrapper's child, so a
  # wrong group-kill hits only this victim and not the test harness.
  set -m
  bash -c 'exec -a "codex exec --json -o /somewhere/else/final.md -m gpt-5.6-sol -" sleep 60' &
  local victim=$!
  set +m
  sleep 0.3

  local vstart vpgid
  vstart="$(awk '{sub(/.*\) /,""); print $20}' "/proc/$victim/stat" 2>/dev/null)"
  vpgid="$(awk '{sub(/.*\) /,""); print $3}'  "/proc/$victim/stat" 2>/dev/null)"
  if [ "$vpgid" = "$victim" ]; then ok "T12 victim leads its own group (fixture mirrors a real run)"
  else bad "T12 fixture broken: victim is not a group leader ($vpgid != $victim)"; fi

  # pid, starttime AND pgid all genuinely match the live victim. The ONLY thing that does not is
  # the run's identity — this run's unique output path is nowhere in that process's argv.
  mk_fixture() {   # <dir>
    mkdir -p "$1"
    jq -n --argjson pid "$victim" --argjson pgid "$vpgid" --argjson st "$vstart" --arg m "$1/final.md" \
      '{run_id:"foreign",slug:"t12",state:"MODEL_WAIT",pid:$pid,pgid:$pgid,start_ticks:$st,
        cmdline_marker:$m,started_at:"2026-01-01T00:00:00Z",deadline_at:"2026-01-01T00:15:00Z",
        exit_code:null,progress_confirmed:false,events_seen:0,tools_active:0,thread_id:null,
        elapsed_sec:0,message:"",cli_errors:[],orphans_left:0,wrapper_version:"2.0.0"}' > "$1/status.json"
  }

  mk_fixture "$root/foreign"
  timeout 30 bash "$WRAPPER" cleanup "$root/foreign" --force >"$root/f.txt" 2>&1
  assert_eq 1 "$?" "T12 cleanup refuses a group it cannot tie to this run"
  assert_contains "$root/f.txt" "REFUSING" "T12 the refusal is explicit"
  sleep 0.5
  if kill -0 "$victim" 2>/dev/null; then ok "T12 the unverified process group was NOT signalled"
  else bad "T12 cleanup SIGKILLed a whole process group it never verified"; fi

  # a recorded pgid that does not match the live process's real pgid is also disqualifying
  mk_fixture "$root/badpgid"
  jq '.pgid = (.pgid + 1)' "$root/badpgid/status.json" > "$root/badpgid/s.tmp" \
    && mv "$root/badpgid/s.tmp" "$root/badpgid/status.json"
  timeout 30 bash "$WRAPPER" cleanup "$root/badpgid" --force >"$root/g.txt" 2>&1
  assert_eq 1 "$?" "T12 cleanup refuses when the recorded pgid != the process's real pgid"
  if kill -0 "$victim" 2>/dev/null; then ok "T12 victim still untouched after the pgid-mismatch refusal"
  else bad "T12 victim killed on a pgid mismatch"; fi

  kill -KILL "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
}

# ---------------------------------------------------------------------------
# T13 — F5: recovery is not allowed to destroy the evidence it is recovering from.
# ---------------------------------------------------------------------------
t13() {
  head_ T13 "reconcile/cleanup preserve events.jsonl and the recorded evidence (F5)"
  local root="$TMPROOT/t13"; mkdir -p "$root"

  CODEX_BIN="$FAKE" FAKE_MODE=hang FAKE_HANG_SEC=120 \
    bash "$WRAPPER" run --slug s13 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p" "p")" --no-heartbeat --deadline-sec 60 >"$root/out.txt" 2>&1 &
  local wpid=$!
  sleep 3
  kill -KILL "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null   # wrapper dies; child lives on

  local rd; rd="$(rundir "$root" s13)"
  local md5_before ev_before thread_before pgid
  md5_before="$(md5 "$rd/events.jsonl")"
  ev_before="$(jqf "$rd/status.json" .events_seen)"
  thread_before="$(jqf "$rd/status.json" .thread_id)"
  pgid="$(jqf "$rd/status.json" .pgid)"
  assert_eq "3" "$ev_before" "T13 baseline: 3 events were recorded before the crash"

  timeout 30 bash "$WRAPPER" reconcile "$rd" >"$root/rec.txt" 2>&1
  assert_eq "$md5_before" "$(md5 "$rd/events.jsonl")" "T13 reconcile leaves events.jsonl byte-identical (append-only evidence)"
  assert_eq "$ev_before"     "$(jqf "$rd/status.json" .events_seen)" "T13 reconcile keeps events_seen"
  assert_eq "$thread_before" "$(jqf "$rd/status.json" .thread_id)"   "T13 reconcile keeps thread_id"
  if [ "$(jqf "$rd/status.json" .last_event_at)" = "null" ]; then
    bad "T13 reconcile erased last_event_at — the status no longer describes the real stream"
  else
    ok "T13 reconcile keeps last_event_at"
  fi

  timeout 30 bash "$WRAPPER" cleanup "$rd" --force >"$root/cln.txt" 2>&1
  assert_eq "$md5_before" "$(md5 "$rd/events.jsonl")" "T13 cleanup leaves events.jsonl byte-identical"
  assert_eq "$ev_before"     "$(jqf "$rd/status.json" .events_seen)" "T13 cleanup keeps events_seen"
  assert_eq "$thread_before" "$(jqf "$rd/status.json" .thread_id)"   "T13 cleanup keeps thread_id"
  # `wait` on a process that is NOT our child returns 127. Recording that as the review's exit
  # code invents a CLI failure that never happened.
  assert_eq "null" "$(jqf "$rd/status.json" .exit_code)" "T13 cleanup does not invent an exit code (no 127)"
  assert_file "$rd/recovery.log" "T13 recovery actions are appended to recovery.log, not into the event stream"
  sleep 1
  assert_eq "0" "$(group_count "$pgid")" "T13 cleanup still reaped the whole group"
}

# ---------------------------------------------------------------------------
# T14 — AC14: the rollback flag drops the state machine, never the fail-closed gate.
# ---------------------------------------------------------------------------
t14() {
  head_ T14 "rollback flag CODEX_REVIEW_WRAPPER_V2=0 is still fail-closed (AC14)"
  local root="$TMPROOT/t14"; mkdir -p "$root"; local rd

  CODEX_REVIEW_WRAPPER_V2=0 CODEX_BIN="$FAKE" FAKE_MODE=normal \
    timeout 40 bash "$WRAPPER" run --slug f1 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p1" "p")" >"$root/a.txt" 2>&1
  assert_eq 0 "$?" "T14 fallback: pass-class verdict -> exit 0"
  rd="$(rundir "$root" f1)"
  assert_eq "APPROVE" "$(jqf "$rd/verdict.json" .verdict)" "T14 fallback still takes the LAST fence"

  CODEX_REVIEW_WRAPPER_V2=0 CODEX_BIN="$FAKE" FAKE_MODE=normal \
    FAKE_FINAL_TEXT='x

```json
{"verdict":"REQUEST_CHANGES","findings":[],"summary":"no"}
```' \
    timeout 40 bash "$WRAPPER" run --slug f2 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p2" "p")" >"$root/b.txt" 2>&1
  assert_eq 3 "$?" "T14 fallback: fail-class verdict -> exit 3"

  CODEX_REVIEW_WRAPPER_V2=0 CODEX_BIN="$FAKE" FAKE_MODE=truncated \
    timeout 40 bash "$WRAPPER" run --slug f3 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p3" "p")" >"$root/c.txt" 2>&1
  assert_eq 1 "$?" "T14 fallback: truncated final fence -> exit 1 (no fallback to an earlier fence)"
  rd="$(rundir "$root" f3)"
  assert_absent "$rd/verdict.json" "T14 fallback writes no verdict.json for a bad final message"
}

# ---------------------------------------------------------------------------
# Review-r2 regressions (T15–T18). All four are the SAME bug wearing four hats: a PASS was being
# INFERRED (from an answer that looks clean) instead of PROVEN (from a run that demonstrably
# succeeded). Each test therefore asserts the same thing — in this situation, a pass must be
# UNPROVABLE — and each one passed against the previous commit only because nobody asked.
#
# `mk_evidence_fixture <dir> <state> <exit_code-json>` builds a run dir by hand: this is INJECTED /
# CRASH-DAMAGED evidence, the kind a live fake-codex run cannot produce, and it is exactly what a
# recovery path must survive. pid is null, so the run reads as "process gone" and reconcile goes
# straight to judging the artifacts. started_at is old, so a freshly written final.md is NEWER than
# the run (isolating the checks under test from the mtime check).
# ---------------------------------------------------------------------------
GOOD_FENCE='Review done.

```json
{"verdict":"APPROVE","findings":[],"summary":"looks good"}
```'

mk_evidence_fixture() {   # <dir> <state> <exit_code-json>
  mkdir -p "$1"
  jq -n --arg id "inj-$(basename "$1")" --arg st "$2" --argjson ec "$3" \
    '{run_id:$id, slug:"r2", state:$st, pid:null, pgid:null, start_ticks:null,
      cmdline_marker:null, started_at:"2026-01-01T00:00:00Z", deadline_at:"2026-01-01T00:15:00Z",
      exit_code:$ec, progress_confirmed:true, events_seen:3, tools_active:0,
      thread_id:"thr_inj", orphans_left:0, elapsed_sec:12, message:"", cli_errors:[],
      wrapper_version:"2.0.0"}' > "$1/status.json"
  printf '%s\n' '{"type":"thread.started","thread_id":"thr_inj"}' \
                '{"type":"turn.started"}' \
                '{"type":"turn.completed","usage":{}}' > "$1/events.jsonl"
  printf '%s\n' "$GOOD_FENCE" > "$1/final.md"
}

# ---------------------------------------------------------------------------
# T15 — r2 #1: content after the verdict fence. The reviewer said APPROVE and then kept talking:
#       it contradicted itself, or it was cut off mid-correction. Either way the message is not a
#       verdict, and honouring the fence while ignoring the tail infers a pass from an unfinished
#       answer. Only whitespace may follow the closing fence.
# ---------------------------------------------------------------------------
t15() {
  head_ T15 "trailing content after the verdict fence -> gate CLOSED (r2 #1)"
  local root="$TMPROOT/t15"; mkdir -p "$root"; local rd

  CODEX_BIN="$FAKE" FAKE_MODE=trailingprose \
    timeout 40 bash "$WRAPPER" run --slug g1 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p" "p")" --no-heartbeat >"$root/a.txt" 2>&1
  assert_eq 1 "$?" "T15a APPROVE fence + trailing prose -> exit 1"
  rd="$(rundir "$root" g1)"
  assert_eq "FAILED" "$(state "$rd")" "T15a state FAILED"
  assert_absent "$rd/verdict.json" "T15a the valid-but-not-final APPROVE fence is NOT used"
  assert_contains "$root/a.txt" "gate:       CLOSED" "T15a gate reported CLOSED"
  assert_file "$rd/final.md" "T15a final.md preserved for diagnosis"

  # Whitespace after the fence is FINE — the gate is fail-closed, not fail-paranoid. A model that
  # ends with a trailing blank line or two has still delivered its verdict last.
  CODEX_BIN="$FAKE" FAKE_MODE=normal FAKE_FINAL_TEXT='ok

```json
{"verdict":"APPROVE","findings":[],"summary":"trailing whitespace only"}
```

   ' \
    timeout 40 bash "$WRAPPER" run --slug g2 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p2" "p")" --no-heartbeat >"$root/b.txt" 2>&1
  assert_eq 0 "$?" "T15b trailing WHITESPACE after the fence is still a valid verdict (exit 0)"
}

# ---------------------------------------------------------------------------
# T16 — r2 #2: a nonzero provider exit with a flawless APPROVE in final.md. Codex reproduced this
#       exactly: provider exit 2, `run` exit 1 — and then `reconcile` mined the APPROVE, returned 0
#       and set VERDICT_PARSED. The answer is not the run.
# ---------------------------------------------------------------------------
t16() {
  head_ T16 "nonzero provider exit can never yield a usable verdict (r2 #2)"
  local root="$TMPROOT/t16"; mkdir -p "$root"; local rd

  # (a) a real run: the provider writes a valid APPROVE final.md and THEN exits 2.
  CODEX_BIN="$FAKE" FAKE_MODE=failafter \
    timeout 40 bash "$WRAPPER" run --slug x1 --root "$root" --mode exec \
      --prompt-file "$(pfile "$root/p" "p")" --no-heartbeat >"$root/a.txt" 2>&1
  assert_eq 1 "$?" "T16a run exits 1 despite a valid APPROVE in final.md"
  rd="$(rundir "$root" x1)"
  assert_eq "FAILED" "$(state "$rd")" "T16a state FAILED"
  assert_eq "2" "$(jqf "$rd/status.json" .exit_code)" "T16a provider exit 2 recorded"
  assert_contains "$rd/final.md" '"verdict":"APPROVE"' "T16a final.md really does hold a clean APPROVE"
  assert_absent "$rd/verdict.json" "T16a run refuses to extract a verdict from a failed run"

  # (b) …and re-checking the same run dir must be no more optimistic. THIS is what returned 0.
  timeout 30 bash "$WRAPPER" reconcile "$rd" >"$root/rec.txt" 2>&1
  assert_eq 1 "$?" "T16b reconcile exits 1 on the same run (never mines the APPROVE)"
  assert_absent "$rd/verdict.json" "T16b reconcile produced no verdict.json"
  assert_contains "$root/rec.txt" "gate CLOSED" "T16b reconcile says gate CLOSED"

  # (c) the exit code alone must be disqualifying — isolated from the state check. A crash-damaged
  #     status.json claiming COMPLETED, with exit_code 2 and a clean APPROVE sitting in final.md.
  mk_evidence_fixture "$root/exit2" COMPLETED 2
  timeout 30 bash "$WRAPPER" reconcile "$root/exit2" >"$root/c.txt" 2>&1
  assert_eq 1 "$?" "T16c COMPLETED + exit_code 2 + valid APPROVE -> exit 1"
  assert_absent "$root/exit2/verdict.json" "T16c no verdict mined from a nonzero-exit run"
  assert_contains "$root/c.txt" "provider exited with code 2" "T16c the refusal names the exit code"
}

# ---------------------------------------------------------------------------
# T17 — r2 #3: crash recovery without durable proof of success. `load_run_metadata` resets the live
#       TURN_FAILED flag and a killed wrapper never wrote its exit code, so an interrupted FAILURE
#       could be recovered as a pass. Recovery must demand proof, not the absence of bad news.
# ---------------------------------------------------------------------------
t17() {
  head_ T17 "crash recovery refuses to mine final.md without proof the run succeeded (r2 #3)"
  local root="$TMPROOT/t17"; mkdir -p "$root"

  # (a) no exit code was ever recorded: the wrapper was killed before it saw the child exit. The
  #     absence of a recorded failure is NOT proof of success.
  mk_evidence_fixture "$root/noexit" MODEL_WAIT null
  timeout 30 bash "$WRAPPER" reconcile "$root/noexit" >"$root/a.txt" 2>&1
  assert_eq 1 "$?" "T17a exit_code null + valid APPROVE -> exit 1 (unproven run)"
  assert_absent "$root/noexit/verdict.json" "T17a nothing mined without a recorded exit code"
  assert_contains "$root/a.txt" "no provider exit code" "T17a the refusal names the missing proof"

  # (b) the append-only event stream records turn.failed, but the crashed wrapper never got to
  #     write that into status.json. Recovery must REPLAY the stream, not trust the status field.
  mk_evidence_fixture "$root/turnfail" COMPLETED 0
  printf '%s\n' '{"type":"turn.failed","error":{"message":"provider error"}}' >> "$root/turnfail/events.jsonl"
  timeout 30 bash "$WRAPPER" reconcile "$root/turnfail" >"$root/b.txt" 2>&1
  assert_eq 1 "$?" "T17b turn.failed in events.jsonl -> exit 1 even with exit_code 0"
  assert_absent "$root/turnfail/verdict.json" "T17b no verdict mined from a failed turn"
  assert_contains "$root/b.txt" "failed turn" "T17b the refusal names the failed turn"

  # (c) final.md predates the run: a leftover or injected answer from somewhere else. Size and
  #     mtime must be consistent with a run that actually produced it.
  mk_evidence_fixture "$root/stale" COMPLETED 0
  touch -d '2020-01-01T00:00:00Z' "$root/stale/final.md"
  timeout 30 bash "$WRAPPER" reconcile "$root/stale" >"$root/c.txt" 2>&1
  assert_eq 1 "$?" "T17c final.md older than the run -> exit 1 (not this run's answer)"
  assert_absent "$root/stale/verdict.json" "T17c no verdict mined from a stale final.md"

  # (d) the control: identical evidence, all proofs present -> the gate DOES open. Without this the
  #     three refusals above could be passing for the wrong reason.
  mk_evidence_fixture "$root/good" COMPLETED 0
  timeout 30 bash "$WRAPPER" reconcile "$root/good" >"$root/d.txt" 2>&1
  assert_eq 0 "$?" "T17d control: a provably successful run still recovers its APPROVE (exit 0)"
  assert_eq "APPROVE" "$(jqf "$root/good/verdict.json" .verdict)" "T17d control: verdict recovered"
}

# ---------------------------------------------------------------------------
# T18 — r2 #4: a stored pass-class verdict.json was accepted BEFORE the run's state and provenance
#       were checked, so stale or injected evidence could make a failed run return 0. Terminal
#       failure outranks any verdict, and a verdict from another run is not this run's answer.
# ---------------------------------------------------------------------------
t18() {
  head_ T18 "terminal state and provenance outrank a stored pass verdict (r2 #4)"
  local root="$TMPROOT/t18"; mkdir -p "$root"

  # a complete, contract-perfect, pass-class verdict.json — the strongest possible fake
  mk_pass_verdict() {   # <dir>
    jq -n --arg id "inj-$(basename "$1")" \
      '{run_id:$id, verdict:"APPROVE", verdict_class:"pass", gate:"open", findings:[],
        findings_count:0, summary:"stored pass", source:"final.md",
        extracted_at:"2026-01-01T00:10:00Z"}' > "$1/verdict.json"
  }

  # (a) TIMED_OUT run holding a perfect APPROVE. The kill is the truth; the verdict is not.
  mk_evidence_fixture "$root/timedout" TIMED_OUT 124
  mk_pass_verdict "$root/timedout"
  timeout 30 bash "$WRAPPER" reconcile "$root/timedout" >"$root/a.txt" 2>&1
  assert_eq 1 "$?" "T18a TIMED_OUT + stored APPROVE -> exit 1 (never 0)"
  assert_absent "$root/timedout/verdict.json" "T18a the stored pass verdict is no longer usable"
  assert_file "$root/timedout/verdict.rejected.json" "T18a …but it is quarantined, not destroyed (F5)"
  assert_contains "$root/a.txt" "terminal failure outranks" "T18a the refusal explains the precedence"

  # (b) same, for a FAILED run that even records a clean exit 0.
  mk_evidence_fixture "$root/failed" FAILED 0
  mk_pass_verdict "$root/failed"
  timeout 30 bash "$WRAPPER" reconcile "$root/failed" >"$root/b.txt" 2>&1
  assert_eq 1 "$?" "T18b FAILED + stored APPROVE -> exit 1"
  assert_absent "$root/failed/verdict.json" "T18b the stored pass verdict is no longer usable"

  # (c) a contract-perfect APPROVE that belongs to a DIFFERENT run (copied/injected verdict.json).
  #     final.md carries no verdict, so once the foreign one is rejected nothing can be re-derived:
  #     if the run_id were not checked, this would return 0.
  mk_evidence_fixture "$root/foreign" VERDICT_PARSED 0
  printf 'Prose only. I approve. APPROVE.\n' > "$root/foreign/final.md"
  mk_pass_verdict "$root/foreign"
  jq '.run_id = "some-other-run"' "$root/foreign/verdict.json" > "$root/foreign/v.tmp" \
    && mv "$root/foreign/v.tmp" "$root/foreign/verdict.json"
  timeout 30 bash "$WRAPPER" reconcile "$root/foreign" >"$root/c.txt" 2>&1
  assert_eq 1 "$?" "T18c a pass verdict from ANOTHER run is not this run's answer -> exit 1"
  assert_absent "$root/foreign/verdict.json" "T18c the foreign verdict is quarantined"
}

# ---------------------------------------------------------------------------
run_all() {
  local t
  for t in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    if want "$t" && declare -F "t$t" >/dev/null; then "t$t"; fi
  done
}

printf '=== codex-review.sh test suite ===\n'
printf 'wrapper: %s\n' "$WRAPPER"
run_all

printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed assertions:\n'
  for f in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
