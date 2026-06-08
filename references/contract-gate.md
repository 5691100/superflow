# Contract Gate (Phase 2)

The Contract Gate makes "done" a pre-agreed, checkable list instead of a fuzzy
request the reviewer interprets after the fact. It is Superflow's adaptation of
the Anthropic planner→agent→evaluator scheme (contract-first + evaluator).

Enforced by **Rule 3a** in `superflow-enforcement.md`. Template:
`templates/contract-template.yml`. Contracts live in
`docs/superflow/contracts/<date>-<feature>.contract.yml`.

## Where it sits in Phase 2
```
re-read phase docs → worktree + baseline tests → ┌─ CONTRACT GATE ─┐ → implement → Unified Review → PAR → ship
                                                  │ draft → agree   │      ▲                              │
                                                  └─────────────────┘      └── verifies the contract ─────┘
```
The contract is written **after** the worktree + baseline exist (so it reflects
reality) and **before** any feature code.

## The negotiation loop (implementer ↔ evaluator)
1. **Orchestrator** hands the implementer a sprint brief: goal, spec/charter refs, scope-out, invariants. It does NOT author criteria.
2. **Implementer** drafts the contract: concrete, checkable `criteria[]` covering product scenarios, edge cases, interface states, regression + the sprint's invariants. Each criterion gets `evidence:` (how it'll be proven) and `verify:` (the exact command / click-path / query).
3. **Evaluator** (a Unified-Review reviewer, same role that will grade it) reviews the contract for *sufficiency*: missing scenarios, edge cases, empty/error states, regression risk, owner directives. It replies with additions — not code feedback.
4. Iterate on the markdown/yml until criteria are sufficient, then set `gate.contract_agreed: true`. Implementation starts.
5. **Orchestrator** blocks the sprint if no agreed contract exists. It does not write criteria itself (Rule 11 tool budget still applies).

## What makes a good criterion
- **Checkable, not vague.** "card 146/2026 renders 5 physics tiles, no € anywhere" ✓ — "card looks good" ✗.
- **One assertion each**, with an id (`C01`…). A vague critique gives the implementer nothing to fix; a concrete one points at the exact problem.
- **Right altitude:** ~5–12 per sprint (Anthropic had 27 for a whole app). Not 200.
- **Typed** (`product|data|regression|security|ux`) and tagged with the evidence channel.

## Evidence channels
| `evidence:` | How the evaluator proves it | Who owns it |
|---|---|---|
| `test` | run the suite / a focused test | technical reviewer |
| `api` | curl / integration call, assert response + auth | technical reviewer |
| `browser` | **black-box browser pass** — Playwright/Chrome-MCP launches the app, clicks the criterion, screenshots, checks empty/loading/error states (Rule 3 item 9). App first; read code only to explain a failure. | product/browser evaluator (UI sprints) |
| `artifact` | run on golden fixtures, **open & reconcile every produced file** vs expected (Rule 3 item 10). Generalizes Steel QA Stage 1–3. | artifact evaluator (steel/workbook sprints) |
| `cli` | run the command, assert stdout/exit/side-effects | technical reviewer |

## How PAR consumes it
Unified Review returns a **PASS/FAIL line per `criteria.id`**, not one verdict.
`.par-evidence.json` carries `"criteria":{"C01":"PASS","C02":"FAIL",...}`. The push/PR
gate (Rule 3.7) stays blocked until every criterion is PASS (plus docs/review gates).

## Non-UI sprints
There is no "clicking" for a steel CLI — the artifact evaluator is the analogue:
execute on golden fixtures, open each produced workbook, reconcile sheets /
formulas / totals / quantities against an expected JSON. Treat the artifact as the
"user-facing surface" the evaluator inspects.

## Deliberately deferred (start simple)
Full Chrome-MCP, automated visual-diff, 27-criteria-per-sprint, hierarchical
evaluator teams. A simple contract + black-box evidence beats adding another
code-only reviewer.

## Reference pilot
`ClaudeClaw/workspace/starsmet/docs/superflow/contracts/2026-06-07-crm-sprint-8c-rfq-physics.contract.yml`
— Sprint 8c reverse-engineered into 8 criteria, all re-run → PASS. Note: its
`browser` criteria were verified by a render-extraction fallback, not a real
Playwright click — that gap is exactly what the browser-evaluator closes.
