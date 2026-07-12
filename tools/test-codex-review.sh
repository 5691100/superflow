#!/usr/bin/env bash
# shellcheck shell=bash
# test-codex-review.sh — hermetic test harness for tools/codex-review.sh
#
# Covers the 9 mandatory tests from the transparent-Codex-review-wrapper handoff (§10):
#   1 normal  2 silent  3 timeout  4 malformed verdict  5 concurrent
#   6 no-wrong-PID  7 early CLI failure  8 tool activity  9 crash/recovery
#
# Hermetic: never invokes the real `codex` CLI or the network. All runs use
# tools/test-fixtures/fake-codex.sh, which replays the real 0.144.1 JSONL grammar.
#
# Discipline: tests run SEQUENTIALLY (one test process at a time) and every wrapper
# invocation is wrapped in `timeout`.
#
# Usage: bash tools/test-codex-review.sh [test-number ...]
# Exit 0 = all pass, 1 = any failure.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# state <run-dir>
state()  { jq -r '.state'   "$1/status.json" 2>/dev/null; }
jqf()    { jq -r "$2" "$1" 2>/dev/null; }

# newest run dir under <root>/.superflow/reviews/<slug>
rundir() { find "$1/.superflow/reviews/$2" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1; }

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

  CODEX_BIN="$FAKE" FAKE_MODE=normal FAKE_ARGV_OUT="$root/argv.txt" \
  timeout 60 bash "$WRAPPER" run --slug s1 --root "$root" --base main --prompt-text "review this diff" \
    --heartbeat-sec 1 >"$out" 2>&1
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
  if grep -qF "review this diff" "$root/argv.txt"; then bad "T1 prompt LEAKED into argv"; else ok "T1 prompt text never appears in argv (AC12)"; fi
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
  assert_contains "$out" "Codex review:" "T1 heartbeat printed to stdout"
  # AC01: raw event stream is visible, not swallowed by tail -N
  assert_contains "$rd/events.jsonl" '"type":"thread.started"' "T1 raw JSONL stream preserved (AC01)"
}

# count live processes in a process GROUP (numeric pgid — not a name pattern)
group_count() { ps -eo pgid=,stat= 2>/dev/null | awk -v g="$1" '$1==g && $2 !~ /^Z/ {n++} END{print n+0}'; }

# ---------------------------------------------------------------------------
# T2 — silent: alive but emitting nothing. Must surface SILENT then STALLED_SUSPECTED,
#      and must NEVER report progress_confirmed=true. (AC07)
# ---------------------------------------------------------------------------
t2() {
  head_ T2 "silent provider is reported as silence, not as progress"
  local root="$TMPROOT/t2"; mkdir -p "$root"
  local out="$root/stdout.txt"

  CODEX_BIN="$FAKE" FAKE_MODE=silent FAKE_SILENT_SEC=60 \
  timeout 40 bash "$WRAPPER" run --slug s2 --root "$root" --prompt-text "p" \
    --heartbeat-sec 1 --silent-sec 2 --stall-sec 5 --deadline-sec 9 >"$out" 2>&1
  local rc=$?

  local rd; rd="$(rundir "$root" s2)"
  assert_contains "$out" "Codex review: SILENT"            "T2 SILENT state surfaced"
  assert_contains "$out" "Codex review: STALLED_SUSPECTED" "T2 STALLED_SUSPECTED surfaced"
  assert_contains "$out" "progress confirmed no"           "T2 heartbeat says progress NOT confirmed"
  assert_eq "false" "$(jqf "$rd/status.json" .progress_confirmed)" "T2 progress_confirmed=false"
  assert_eq "0"     "$(jqf "$rd/status.json" .events_seen)"        "T2 zero events seen"
  assert_eq 1 "$rc" "T2 exit 1 (no verdict — gate closed)"
}

# ---------------------------------------------------------------------------
# T3 — timeout: hard deadline kills the WHOLE process group, no orphans. (AC08)
# ---------------------------------------------------------------------------
t3() {
  head_ T3 "hard deadline -> TIMED_OUT, whole group reaped, partial logs kept"
  local root="$TMPROOT/t3"; mkdir -p "$root"
  local out="$root/stdout.txt"

  CODEX_BIN="$FAKE" FAKE_MODE=hang FAKE_HANG_SEC=300 \
  timeout 40 bash "$WRAPPER" run --slug s3 --root "$root" --prompt-text "p" \
    --heartbeat-sec 1 --silent-sec 30 --stall-sec 60 --deadline-sec 3 --grace-sec 2 >"$out" 2>&1
  local rc=$?

  local rd; rd="$(rundir "$root" s3)"
  local pid pgid
  pid="$(jqf "$rd/status.json" .pid)"; pgid="$(jqf "$rd/status.json" .pgid)"

  assert_eq "TIMED_OUT" "$(state "$rd")" "T3 state"
  assert_eq 1 "$rc" "T3 exit 1 (timed out — gate closed)"
  # the fixture spawned a grandchild in the same group; both must be gone
  sleep 1
  assert_eq "0" "$(group_count "$pgid")" "T3 no orphans left in process group $pgid"
  if kill -0 "$pid" 2>/dev/null; then bad "T3 child still alive"; else ok "T3 child reaped"; fi
  # partial evidence preserved
  assert_contains "$rd/events.jsonl" '"type":"turn.started"' "T3 partial events preserved"
  assert_file "$rd/status.json" "T3 status.json preserved"
  assert_eq "null" "$(jqf "$rd/verdict.json" .verdict 2>/dev/null || echo null)" "T3 no verdict on timeout"
}

# ---------------------------------------------------------------------------
# T4 — malformed / unknown / prose-only verdict: gate stays CLOSED. (AC09)
# ---------------------------------------------------------------------------
t4() {
  head_ T4 "malformed, unknown and prose-only verdicts all fail the gate"
  local root="$TMPROOT/t4"; mkdir -p "$root"; local rd rc

  # (a) corrupt JSON inside the fence
  CODEX_BIN="$FAKE" FAKE_MODE=malformed \
    timeout 40 bash "$WRAPPER" run --slug m1 --root "$root" --prompt-text "p" \
      --no-heartbeat >"$root/a.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m1)"
  assert_eq 1 "$rc" "T4a malformed JSON -> exit 1"
  assert_eq "FAILED" "$(state "$rd")" "T4a state FAILED"
  assert_file "$rd/final.md" "T4a final.md preserved for diagnosis"
  if [ -f "$rd/verdict.json" ]; then bad "T4a verdict.json must NOT exist"; else ok "T4a no verdict.json"; fi
  assert_contains "$root/a.txt" "gate:       CLOSED" "T4a gate reported CLOSED"

  # (b) parseable JSON, unknown verdict value
  CODEX_BIN="$FAKE" FAKE_MODE=badverdict \
    timeout 40 bash "$WRAPPER" run --slug m2 --root "$root" --prompt-text "p" \
      --no-heartbeat >"$root/b.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m2)"
  assert_eq 1 "$rc" "T4b unknown verdict 'LGTM' -> exit 1"
  assert_eq "FAILED" "$(state "$rd")" "T4b state FAILED"

  # (c) prose only, and the prose literally says "APPROVE" — must NOT become a pass
  CODEX_BIN="$FAKE" FAKE_MODE=noverdict \
    timeout 40 bash "$WRAPPER" run --slug m3 --root "$root" --prompt-text "p" \
      --no-heartbeat >"$root/c.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m3)"
  assert_eq 1 "$rc" "T4c prose saying APPROVE -> exit 1 (prose is never parsed)"
  if [ -f "$rd/verdict.json" ]; then bad "T4c verdict.json must NOT exist"; else ok "T4c no false PASS from prose"; fi

  # (d) valid verdict fence followed by a LATER corrupt fence. Falling back to the earlier valid
  #     block would let a truncated/garbled response pass as a clean APPROVE. (Codex finding #2)
  CODEX_BIN="$FAKE" FAKE_MODE=trailingbad \
    timeout 40 bash "$WRAPPER" run --slug m4 --root "$root" --prompt-text "p" \
      --no-heartbeat >"$root/d.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m4)"
  assert_eq 1 "$rc" "T4d corrupt LAST fence -> exit 1 (no fallback to an earlier valid fence)"
  if [ -f "$rd/verdict.json" ]; then bad "T4d must NOT accept the earlier APPROVE fence"; else ok "T4d no verdict.json (fail-closed)"; fi

  # (e) verdict present but `findings`/`summary` missing — the contract requires all three.
  CODEX_BIN="$FAKE" FAKE_MODE=partial \
    timeout 40 bash "$WRAPPER" run --slug m5 --root "$root" --prompt-text "p" \
      --no-heartbeat >"$root/e.txt" 2>&1
  rc=$?; rd="$(rundir "$root" m5)"
  assert_eq 1 "$rc" "T4e incomplete verdict object -> exit 1 (findings+summary are mandatory)"
  if [ -f "$rd/verdict.json" ]; then bad "T4e must NOT accept a verdict missing findings/summary"; else ok "T4e no verdict.json (fail-closed)"; fi
}

# ---------------------------------------------------------------------------
# T5 — concurrent reviews: separate dirs / pids / pgids, results never cross. (AC03, AC10)
# ---------------------------------------------------------------------------
t5() {
  head_ T5 "two concurrent reviews on the same slug do not collide"
  local root="$TMPROOT/t5"; mkdir -p "$root"

  local rcA rcB
  ( CODEX_BIN="$FAKE" FAKE_MODE=normal FAKE_TOOL_SEC=2 \
      timeout 40 bash "$WRAPPER" run --slug same --root "$root" --prompt-text "A" \
        --no-heartbeat >"$root/A.txt" 2>&1; echo $? >"$root/rcA" ) &
  local pA=$!
  ( CODEX_BIN="$FAKE" FAKE_MODE=normal FAKE_TOOL_SEC=2 \
      FAKE_FINAL_TEXT='done

```json
{"verdict":"REQUEST_CHANGES","findings":[{"id":"F1"}],"summary":"B findings"}
```' \
      timeout 40 bash "$WRAPPER" run --slug same --root "$root" --prompt-text "B" \
        --no-heartbeat >"$root/B.txt" 2>&1; echo $? >"$root/rcB" ) &
  local pB=$!
  wait "$pA" "$pB"
  rcA="$(cat "$root/rcA")"; rcB="$(cat "$root/rcB")"

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
#      untouched, even when the wrapper TERMs its own process group. (AC02, AC11)
# ---------------------------------------------------------------------------
t6() {
  head_ T6 "decoy 'codex exec' process is never matched, waited on, or killed"
  local root="$TMPROOT/t6"; mkdir -p "$root"

  # decoy: argv[0] is literally a codex review command line -> `pgrep -f "codex exec"` WOULD match it
  bash -c 'exec -a "codex exec review --base main -m gpt-5.6-sol -c model_reasoning_effort=high" sleep 60' &
  local decoy=$!
  sleep 0.5

  if pgrep -f "codex exec review" >/dev/null 2>&1; then
    ok "T6 decoy is matchable by the OLD pgrep pattern (so the trap is real)"
  else
    bad "T6 decoy did not register — test would be vacuous"
  fi

  # a hanging run that will hit its deadline and TERM its own group
  CODEX_BIN="$FAKE" FAKE_MODE=hang FAKE_HANG_SEC=120 \
  timeout 40 bash "$WRAPPER" run --slug s6 --root "$root" --prompt-text "p" \
    --no-heartbeat --deadline-sec 3 --grace-sec 2 >"$root/out.txt" 2>&1
  local rd; rd="$(rundir "$root" s6)"
  local pid; pid="$(jqf "$rd/status.json" .pid)"

  if [ "$pid" != "$decoy" ]; then ok "T6 wrapper tracked its own child ($pid), not the decoy ($decoy)"
  else bad "T6 wrapper latched onto the decoy PID"; fi
  sleep 1
  if kill -0 "$decoy" 2>/dev/null; then ok "T6 decoy SURVIVED the group kill"; else bad "T6 decoy was killed"; fi

  kill -KILL "$decoy" 2>/dev/null; wait "$decoy" 2>/dev/null

  # Static guarantee: the banned patterns appear nowhere in EXECUTABLE code.
  # `^[^#]*` anchors the match before the first '#', so the header comments that *name*
  # these patterns (in order to explain why they are forbidden) do not trip the check.
  if grep -qE '^[^#]*\bpgrep\b' "$WRAPPER"; then bad "T6 wrapper CODE contains pgrep"; else ok "T6 wrapper code contains no pgrep (AC02)"; fi
  if grep -qE '^[^#]*tail[[:space:]]+--pid' "$WRAPPER"; then bad "T6 wrapper CODE contains 'tail --pid'"; else ok "T6 wrapper code has no 'tail --pid'"; fi
  if grep -qE '^[^#]*\|[[:space:]]*tail[[:space:]]+-' "$WRAPPER"; then bad "T6 wrapper CODE pipes into tail -N"; else ok "T6 wrapper code never pipes into 'tail -N' (AC01)"; fi
}

# ---------------------------------------------------------------------------
# T7 — early CLI failure (bad flag / model): FAILED, stderr + exit code preserved.
# ---------------------------------------------------------------------------
t7() {
  head_ T7 "early CLI failure -> FAILED with stderr and exit code preserved"
  local root="$TMPROOT/t7"; mkdir -p "$root"

  CODEX_BIN="$FAKE" FAKE_MODE=failfast \
  timeout 40 bash "$WRAPPER" run --slug s7 --root "$root" --prompt-text "p" \
    --no-heartbeat >"$root/out.txt" 2>&1
  local rc=$?
  local rd; rd="$(rundir "$root" s7)"

  assert_eq 1 "$rc" "T7 exit 1 (gate closed)"
  assert_eq "FAILED" "$(state "$rd")" "T7 state FAILED"
  assert_eq "2" "$(jqf "$rd/status.json" .exit_code)" "T7 CLI exit code recorded"
  assert_file "$rd/stderr.log" "T7 stderr.log preserved"
  assert_contains "$rd/stderr.log" "not available" "T7 CLI error text captured"
  if [ -f "$rd/verdict.json" ]; then bad "T7 verdict.json must NOT exist"; else ok "T7 no verdict on failure"; fi
}

# ---------------------------------------------------------------------------
# T8 — tool activity: item.started(tool) -> TOOL_ACTIVE, then SYNTHESIZING -> COMPLETED.
# ---------------------------------------------------------------------------
t8() {
  head_ T8 "tool call drives TOOL_ACTIVE -> SYNTHESIZING -> VERDICT_PARSED"
  local root="$TMPROOT/t8"; mkdir -p "$root"
  local out="$root/stdout.txt"

  CODEX_BIN="$FAKE" FAKE_MODE=tools FAKE_TOOL_SEC=3 \
  timeout 40 bash "$WRAPPER" run --slug s8 --root "$root" --prompt-text "p" \
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
    bash "$WRAPPER" run --slug s9 --root "$root" --prompt-text "p" \
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
  assert_contains "$root/rec.txt" "is-our-process: yes" "T9a identity confirmed via pid+starttime"
  assert_contains "$root/rec.txt" "liveness is not progress" "T9a stale liveness not counted as progress"
  assert_eq "false" "$(jqf "$rd/status.json" .progress_confirmed)" "T9a progress_confirmed still false"

  # (b) cleanup --force: terminate the verified stale group, leave nothing behind
  timeout 30 bash "$WRAPPER" cleanup "$rd" --force >"$root/cln.txt" 2>&1
  assert_contains "$root/cln.txt" "terminated pid" "T9b cleanup terminated the verified group"
  sleep 1
  assert_eq "0" "$(group_count "$pgid")" "T9b no orphans after cleanup"

  # (c) PID reuse: an innocent live process now holds the recorded PID (its starttime differs).
  #     Neither reconcile nor cleanup may touch it. Two fixtures, because reconcile rewrites state.
  local victim_cmd='sleep 60'
  bash -c "exec $victim_cmd" & local victim=$!
  sleep 0.3

  mk_reuse_fixture() {   # <dir> — records the victim's PID but a bogus starttime
    mkdir -p "$1"
    jq -n --argjson pid "$victim" '{run_id:"reused",slug:"s9",state:"MODEL_WAIT",pid:$pid,pgid:$pid,
        start_ticks:999999999,started_at:"2026-01-01T00:00:00Z",deadline_at:"2026-01-01T00:15:00Z",
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
  assert_contains "$root/reuse-cln.txt" "REFUSING to kill" "T9c refusal is explicit"

  if kill -0 "$victim" 2>/dev/null; then ok "T9c innocent PID-reuse victim ($victim) untouched"
  else bad "T9c the innocent process holding the reused PID was killed"; fi
  kill -KILL "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
}

# ---------------------------------------------------------------------------
run_all() {
  local t
  for t in 1 2 3 4 5 6 7 8 9; do
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
