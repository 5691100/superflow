# Superflow — Claude Instructions

## Project Overview
Superflow is a pure Markdown skill that orchestrates a 4-phase dev workflow: onboarding, product discovery with expert panel brainstorming, Product Vision alignment, and git workflow selection, autonomous execution with a selected branch/PR strategy, and merge. v5.5.0-pos (POS fork; selective hand-merge of upstream v5.7.0), MIT License. Supports both **Claude Code** and **Codex CLI** as primary orchestrator (auto-detected at startup via `$CLAUDE_CODE_SESSION_ID`). This fork keeps all agents on `model: opus` (no Sonnet/Haiku policy), has the event-telemetry stack removed (`.superflow-state.json` is the single source of truth), and adds the Rule 3a Contract Gate, Rule 2b state isolation, and `local_commit` git workflow mode.

## Key Rules
- All documentation output in English — user communication follows their language preference
- Dispatch subagents for all code/analysis — orchestrator reads, plans, reviews, dispatches
- Use `subagent_type: deep-doc-writer` for documentation agents — effort controlled via agent definition frontmatter, not prompt keywords
- Verify framework names by reading actual `import` statements, never guess from directory names
- Every claim in generated docs needs evidence (file path, count, command output)

## Architecture
```
SKILL.md (entry point, ~240 lines, auto-detects Claude/Codex runtime)
  ├── superflow-enforcement.md (durable rules → ~/.claude/rules/)
  ├── codex/
  │   ├── AGENTS.md (durable rules for Codex → ~/.codex/AGENTS.md)
  │   ├── agents/*.toml (12 Codex agent definitions → ~/.codex/agents/)
  │   ├── hooks.json (SessionStart + Stop hooks → ~/.codex/hooks.json)
  │   └── config-fragment.toml (reference config for ~/.codex/config.toml)
  ├── references/
  │   ├── codex/ (Codex dispatch overlays — one per phase)
  │   ├── codex-dispatch-patterns.md (complete Agent→spawn_agent mapping table)
  │   ├── codex-context-strategy.md (258K context budget guide)
  │   ├── git-workflow-modes.md (git workflow mode selection and branch base policy)
  │   ├── phase0-onboarding.md (router — detection, recovery matrix, stage loading)
  │   ├── phase0/
  │   │   ├── stage1-detect.md (parallel preflight, auto-detection, confirmation)
  │   │   ├── stage2-analysis.md (5 parallel agents, tiered model usage)
  │   │   ├── stage3-report.md (health report, informative summary, approval)
  │   │   ├── stage4-setup.md (3 concurrent branches, strict file ownership)
  │   │   ├── stage5-completion.md (markers, tech debt persistence, restart)
  │   │   └── greenfield.md (empty project path, G1-G6)
  │   ├── phase1-discovery.md (interactive, expert panel brainstorming, Product Vision alignment, governance mode selection, charter generation)
  │   ├── phase2-execution.md (legacy router — Sprint 2 reduced to ~39 lines pointing at phase2/)
  │   ├── phase2/ (Run 3 — DAG-driven Phase 2; integration in Run 3 Sprint 2)
  │   │   ├── workflow.json (DAG: 9-cell governance×complexity decision matrix + 7 stages + step_files map)
  │   │   ├── overview.md (Phase 2 high-level context, wave analysis, model selection)
  │   │   └── steps/ (10 step detail files: setup-reread, setup-worktree, impl-dispatch, review-unified, par-evidence, ship-pr, compaction-recovery, holistic-review, frontend-testing, completion-report)
  │   ├── phase3-merge.md (user-initiated merge, 3 stages)
  │   └── contract-gate.md (Rule 3a Contract Gate — contract-first criteria, browser/artifact evaluator lenses)
  ├── prompts/
  │   ├── implementer.md (TDD code agent)
  │   ├── expert-panel.md (expert persona prompt for brainstorming)
  │   ├── spec-reviewer.md (spec compliance)
  │   ├── code-quality-reviewer.md (correctness/security + charter compliance)
  │   ├── product-reviewer.md (user perspective + charter compliance)
  │   ├── llms-txt-writer.md (llms.txt generation)
  │   ├── claude-md-writer.md (CLAUDE.md generation)
  │   ├── testing-guidelines.md (TDD reference)
  │   ├── security-audit.md (Claude security fallback for Phase 0)
  │   └── codex/ (Codex-specific prompts: code-reviewer, product-reviewer, audit)
  ├── agents/ (12 agent definitions — deep/standard/fast tiers; all model: opus, differ by effort)
  ├── workflows/ (saved Claude workflows: superflow-review.js, superflow-wave.js → ~/.claude/workflows/)
  ├── tools/ (detect-test-env.sh, release-gate.sh, cleanup-testcontainers.sh, verify-phase2-dag.sh, measure-phase2-context.sh)
  ├── templates/
  │   ├── superflow-state-schema.json (state file JSON Schema — + use_workflows, local_commit)
  │   ├── contract-template.yml (sprint contract template — checkable criteria + evidence channel)
  │   ├── test-env.schema.json (schema for .superflow/test-env.json produced by detect-test-env.sh)
  │   ├── greenfield/ (stack scaffolding: nextjs.md, python.md, generic.md)
  │   └── ci/ (CI workflows: github-actions-node.yml, github-actions-python.yml)
```

**Key v4.0 artifacts:**
- **Autonomy Charter** (`docs/superflow/specs/YYYY-MM-DD-<topic>-charter.md`): generated at end of Phase 1, injected into every sprint prompt and reviewer. Contains goal, non-negotiables, success criteria, governance mode, and git workflow mode.
- **completion-data.json** (`.superflow/completion-data.json`): structured completion data for Phase 3 merge context.
- **Heartbeat block** (optional field in `.superflow-state.json`): compaction-recovery snapshot written at sprint start and each stage transition. 9 fields: `updated_at`, `current_sprint`, `sprint_goal`, `merge_method`, `active_worktree`, `active_branch`, `must_reread`, `last_review_verdict`, `phase2_step`. Enforced by Rule 12; PreCompact hook surfaces it in the dump.

## Key Files
| File | Purpose |
|------|---------|
| `SKILL.md` | Entry point — startup checklist, provider detection, state management, phase routing |
| `superflow-enforcement.md` | 12 hard rules + Rule 3a (Contract Gate) + 2b (state isolation), specialized 2-agent reviews, rationalization prevention, phase gates |
| `references/contract-gate.md` | Contract Gate how-to — negotiation loop, criterion format, browser/artifact evidence channels, PAR consumption |
| `references/phase0-onboarding.md` | Router — detection, recovery matrix, stage loading |
| `references/phase0/stage1-detect.md` | Parallel preflight, auto-detection, confirmation |
| `references/phase0/stage2-analysis.md` | 5 parallel agents, tiered model usage |
| `references/phase0/stage3-report.md` | Health report, informative summary, approval |
| `references/phase0/stage4-setup.md` | 3 concurrent branches, strict file ownership |
| `references/phase0/stage5-completion.md` | Markers, tech debt persistence, restart |
| `references/phase0/greenfield.md` | Greenfield path G1-G6 |
| `references/git-workflow-modes.md` | Git workflow modes, selection heuristic, branch base policy |
| `references/phase1-discovery.md` | Expert panel brainstorming, Board Memo, Product Vision alignment, governance mode, charter generation |
| `references/phase2-execution.md` | Legacy router (~39 lines) — points at `references/phase2/workflow.json`, `overview.md`, and `steps/`; full prose preserved in git history (pre-Sprint-2) |
| `references/phase2/workflow.json` | Phase 2 lifecycle DAG with governance×complexity decision matrix |
| `references/phase3-merge.md` | 3 stages, sequential rebase merge with CI gate |
| `prompts/implementer.md` | Red-Green-Refactor TDD cycle for code agents |
| `prompts/expert-panel.md` | Expert persona prompt — proposals, challenge, recommendation |
| `prompts/llms-txt-writer.md` | llmstxt.org standard, no hard size limit |
| `prompts/claude-md-writer.md` | Verified paths/commands, <200 lines target |
| `tools/verify-phase2-dag.sh` | Static DAG verifier — validates all 9 governance×complexity cells, 7-stage sequence, step_files coverage, on-disk step file existence, and the `release_gate` phase gate; exits 0 on full pass |
| `tools/measure-phase2-context.sh` | Context savings quantifier — computes pre-Run-3 vs post-Run-3 per-turn token load using git history; outputs a one-line summary (Savings: 76.4%) |
| `tools/detect-test-env.sh` | Phase 0 test-infra probe — writes `.superflow/test-env.json` (project type, docker runtime, test runners, Playwright browsers, readiness verdict); read-only, installs nothing |
| `tools/release-gate.sh` | Post-sprint-loop release-gate verdict engine (bash+jq); PASS/SKIPPED/FAIL from journeys+results. Adapted to ADVISORY unless infra+`test_strategy`+test-suite all present (enforcement Rule 14) |
| `tools/cleanup-testcontainers.sh` | Label-based (`org.testcontainers=true`) leftover-container cleanup; the only docker-touching command the orchestrator may run |
| `workflows/superflow-review.js`, `workflows/superflow-wave.js` | Saved Claude multi-agent workflows (opt-in `context.use_workflows`) for review fan-out and parallel implementation waves → deployed to `~/.claude/workflows/` |

## Conventions
- Pure Markdown skill (no Python, no pip dependencies)
- File references use relative paths from project root
- Phase docs are re-read at every phase/sprint boundary (compaction erases skill content)
- Markers: `<!-- updated-by-superflow:YYYY-MM-DD -->` appended to generated files
- Both `<!-- updated-by-superflow:` and `<!-- superflow:onboarded` are valid markers (backwards compat)
- Breakage scenario required for every review finding — no scenario = not a finding
- All phases use stage/todo structure with TaskCreate for progress tracking
- `.superflow-state.json` persists phase/stage for crash recovery (gitignored); extended with `brief_file`, `charter_file`, `completion_data_file`, `governance_mode`, `git_workflow_mode`, and optional `heartbeat` block for compaction drift defense
- **Governance modes** (light/standard/critical): auto-suggested at Phase 1 start, stored in state and charter. Controls review depth, holistic review threshold, and plan complexity
- **Git workflow modes** (`solo_single_pr`, `sprint_pr_queue`, `stacked_prs`, `parallel_wave_prs`, `trunk_based`, `local_commit`): selected in Phase 1, stored in state and charter, and controls branch base, PR count, sprint parallelism, and merge order
- **Product Vision alignment**: Phase 1 uses a single recommendation-led decision brief with options, tradeoffs, reversibility, safe defaults, and support for "do what you recommend", one-message, or audio-transcript answers. It replaces the old design-tree grilling pattern.
- **Autonomy Charter**: durable intent artifact generated at end of Phase 1. Injected into sprint prompts and reviewers as single source of truth for autonomous execution boundaries
- **Model policy (all-opus)**: every Superflow agent runs on plain `model: opus` (owner directive 2026-06-06 — no Sonnet/Haiku policy anywhere); depth is differentiated by effort (deep = max, standard = high, fast = low) via agent-definition frontmatter. Codex subagents and Claude-runtime `codex exec` secondary calls use `gpt-5.5` (deep = `xhigh`, standard = `high`, fast = `medium`). Codex-runtime Claude product/research secondary calls use exact model `claude-opus-4-8` with `--effort xhigh` (Fable access is blocked).
- **Testing system (adaptive Release Gate)**: Phase 0 `detect-test-env.sh` writes `.superflow/test-env.json`; Phase 1 Step 13a builds a charter `test_strategy` (journeys keyed by stable `spec_tag`, each with an `owning_sprint`); the post-sprint-loop Release Gate (`tools/release-gate.sh`) computes `.superflow/release-gate/verdict.json`. **The gate is ADVISORY by default on this POS** — it BLOCKS Phase 3 only when infra is ready AND the charter defines `test_strategy` journeys AND a test suite exists (enforcement Rule 14); otherwise the sprint contract's browser/artifact evaluator pass remains the binding gate.
- **Saved workflows (opt-in)**: `context.use_workflows` (Claude runtime) enables `/superflow-review` (review fan-out) and `/superflow-wave` (parallel implementation-only waves). Single authority: `references/workflow-orchestration.md`. Fallback to manual Agent dispatch when disabled/unavailable.
- **Verdict contract**: every reviewer ends its message with a fenced JSON `{verdict, findings, summary}` block; the orchestrator extracts it mechanically (awk/sed → jq) and assembles `.par-evidence.json` — no prose parsing. Reviewer dispatch fills the `<spec_or_plan>`/`<autonomy_charter>`/`<original_spec>`/`<product_brief>` context slots verbatim.
- **Per-PR docs gate**: every PR must run documentation update and separate documentation review before `gh pr create`. In per-sprint PR modes this happens every sprint; in `solo_single_pr` it happens before the final PR. `.par-evidence.json` must include `docs_update` (`UPDATED` or `UNCHANGED`) and `docs_review: PASS`; `llms.txt` is explicitly audited for every PR.
- **Contract Gate (Rule 3a)**: each Phase 2 sprint opens with an agreed `docs/superflow/contracts/<date>-<feature>.contract.yml` (checkable criteria) BEFORE code; the evaluator confirms sufficiency, then Unified Review verifies it criterion-by-criterion (`.par-evidence.json` gains a `criteria` PASS/FAIL table). UI sprints add a Playwright browser pass; artifact sprints (steel/workbook) open & reconcile every produced file. Template `templates/contract-template.yml`, how-to `references/contract-gate.md`. Adapts the planner→agent→evaluator / contract-first scheme.

## Known Issues & Tech Debt
- Permissions JSON: single-sourced in `references/phase0/stage4-setup.md` (Branch B); `README.md` has a short example with a link to the canonical source
- Greenfield templates (nextjs.md, python.md) provide config files but not source file contents — LLM generates those
- **Phase 3 post-compaction merge regression**: context compaction during Phase 3 merge loop can cause agent to fall back to local `git merge` instead of `gh pr merge --rebase --delete-branch`, leaving GitHub PRs open and creating non-linear history. Mitigated by: (1) merge method rule in `superflow-enforcement.md` (survives compaction); (2) heartbeat `must_reread` includes `references/phase3-merge.md` starting at Sprint 1 end — compaction-triggered rehydration pulls the exact Phase 3 merge procedure into context automatically. Full fix: re-read `phase3-merge.md` before each PR merge (already in must_reread via Phase 2 heartbeat).
- **Codex sprint-level parallelism**: recommended config is `[agents] max_threads=6, max_depth=2`. This allows sprint supervisors to spawn per-sprint implement/review/doc agents, enabling sprint-level parallel waves in Codex when `git_workflow_mode` permits. Old `max_depth=1` configs fall back to sequential sprints.
- **Codex no PreCompact/PostCompact**: compaction recovery relies on Stop hook dumps + SessionStart re-injection + self-referential rule in AGENTS.md. Less reliable than Claude's hook-based recovery.
- **Codex context ~258K**: 4x smaller than Claude's 1M. Long Phase 2 runs (4+ sprints) require session-per-wave/session-per-sprint strategy or aggressive /compact usage.
<!-- updated-by-superflow:2026-06-08 -->
