# Codex Dispatch Patterns — Complete Reference

Lookup table mapping every Agent() dispatch in Superflow to its Codex spawn_agent equivalent.

## Agent Dispatch Mapping

| Phase | Step | Agent Definition | Codex Dispatch |
|-------|------|------------------|----------------|
| P0 S2 | Architecture analysis | deep-analyst | spawn_agent("deep-analyst") |
| P0 S2 | Code quality analysis | deep-analyst | spawn_agent("deep-analyst") |
| P0 S2 | Security audit | deep-analyst | spawn_agent("deep-analyst") + `claude --model claude-opus-4-8 --effort xhigh -p` secondary |
| P0 S2 | DevOps analysis | fast-implementer | spawn_agent("fast-implementer") |
| P0 S2 | Documentation analysis | deep-analyst | spawn_agent("deep-analyst") |
| P0 S4 | Branch A (docs) | deep-doc-writer | spawn_agent("deep-doc-writer") |
| P0 S4 | Branch B (permissions) | fast-implementer | spawn_agent("fast-implementer") |
| P0 S4 | Branch C (scaffolding) | fast-implementer | spawn_agent("fast-implementer") |
| P0 GF | G3 scaffold | fast-implementer | spawn_agent("fast-implementer") |
| P0 GF | G4 docs | deep-doc-writer | spawn_agent("deep-doc-writer") |
| P0 GF | G5 env setup | fast-implementer | spawn_agent("fast-implementer") |
| P1 S3 | Domain research | deep-analyst | spawn_agent("deep-analyst") |
| P1 S3 | Product research | deep-analyst | `claude --model claude-opus-4-8 --effort xhigh -p` (secondary) or spawn_agent |
| P1 S5 | Expert: Product GM | deep-analyst | spawn_agent("deep-analyst") |
| P1 S5 | Expert: Staff Engineer | deep-analyst | spawn_agent("deep-analyst") |
| P1 S5 | Expert: UX/Workflow | deep-analyst | spawn_agent("deep-analyst") |
| P1 S5 | Expert: Domain | deep-analyst | `claude --model claude-opus-4-8 --effort xhigh -p` (secondary) or spawn_agent |
| P1 S9 | Spec review (product) | Claude (Opus 4.8) | `claude --model claude-opus-4-8 --effort xhigh -p` + prompts/claude/product-reviewer.md |
| P1 S9 | Spec review (tech) | deep-spec-reviewer | spawn_agent("deep-spec-reviewer") |
| P1 S11 | Plan review (product) | Claude (Opus 4.8) | `claude --model claude-opus-4-8 --effort xhigh -p` + prompts/claude/product-reviewer.md |
| P1 S11 | Plan review (tech) | standard-spec-reviewer | spawn_agent("standard-spec-reviewer") |
| P2 | Implementer (simple) | fast-implementer | spawn_agent("fast-implementer") |
| P2 | Implementer (medium) | standard-implementer | spawn_agent("standard-implementer") |
| P2 | Implementer (complex) | deep-implementer | spawn_agent("deep-implementer") |
| P2 | Sprint supervisor (parallel wave) | standard/deep implementer | spawn_agent("standard-implementer" or "deep-implementer") when `max_depth>=2` |
| P2 | Unified review (product) | Claude (Opus 4.8) | `claude --model claude-opus-4-8 --effort xhigh -p` + prompts/claude/product-reviewer.md |
| P2 | Unified review (tech) | standard-code-reviewer | spawn_agent("standard-code-reviewer") |
| P2 | Doc update | standard-doc-writer | spawn_agent("standard-doc-writer") |
| P2 | Doc review | standard-doc-writer | spawn_agent("standard-doc-writer") review-only |
| P2 | Holistic (product) | Claude (Opus 4.8) | `claude --model claude-opus-4-8 --effort xhigh -p` + prompts/claude/product-reviewer.md |
| P2 | Holistic (tech) | deep-code-reviewer | spawn_agent("deep-code-reviewer") |

## Codex Sprint-Level Parallelism

Recommended Codex config is `[agents] max_threads=6, max_depth=2`. With `max_depth>=2`, the parent orchestrator can spawn one sprint supervisor per independent sprint in a wave; each supervisor can then spawn implement/review/doc agents inside its sprint. If the user still has `max_depth=1`, use flat sequential sprints and report that the config must be updated to enable sprint-level parallelism.

## Secondary Provider Inversion

When Claude is the orchestrator, **every** Codex call goes through `tools/codex-review.sh` — never
raw `codex exec`, never piped into `tail -N`, never with an outer `timeout` (the wrapper owns its
deadline and its process group). See `references/codex-review-wrapper.md`.

| Context | Claude orchestrator (Codex secondary) | Codex orchestrator (Claude secondary) |
|---------|---------------------------------------|---------------------------------------|
| Security audit | `codex-review.sh run --mode exec --slug audit --effort xhigh --prompt-file prompts/codex/audit.md` | `claude --model claude-opus-4-8 --effort xhigh -p` + `prompts/claude/audit.md` |
| Code review | `codex-review.sh run --slug sprint-<N>-technical --base main --effort high --prompt-file <p>` | spawn_agent technical reviewer |
| Product review | `codex-review.sh run --mode exec --slug product --effort high --prompt-file prompts/codex/product-reviewer.md` | `claude --model claude-opus-4-8 --effort xhigh -p` + `prompts/claude/product-reviewer.md` |
| Spec review | `codex-review.sh run --mode exec --slug spec-review --effort high --prompt-file <p>` | Claude product + spawn_agent technical |
| Plan review | `codex-review.sh run --mode exec --slug plan-review --effort high --prompt-file <p>` | Claude product + spawn_agent technical |
| Contract gate | `codex-review.sh run --mode exec --slug contract-gate --effort high --prompt-file <contract.yml>` | spawn_agent technical reviewer |

Model defaults to `$CODEX_REVIEW_MODEL` (`gpt-5.6-sol`); override with `--model`. Read the verdict
from `<run-dir>/verdict.json` (exit 0 = pass-class, 3 = fail-class, 1 = **no valid verdict**, gate CLOSED).

## Split-Focus Fallback (no secondary provider)

| Context | Agent A (Product) | Agent B (Technical) |
|---------|-------------------|---------------------|
| Spec review | deep-product-reviewer | deep-spec-reviewer |
| Plan review | standard-product-reviewer | standard-spec-reviewer |
| Unified review | standard-product-reviewer | standard-code-reviewer |
| Holistic review | deep-product-reviewer | deep-code-reviewer |

Record `"provider": "split-focus"` in .par-evidence.json.

## Model Tier Mapping

| Claude Tier | Claude Model | Claude Effort | Codex Model | Codex Reasoning |
|-------------|-------------|---------------|-------------|-----------------|
| deep | claude-opus-4-8 | xhigh | gpt-5.6-sol | xhigh |
| standard | claude-opus-4-8 | xhigh | gpt-5.6-sol | high |
| fast | claude-opus-4-8 | low | gpt-5.6-sol | medium |
| implementer (deep) | claude-opus-4-8 | max | gpt-5.6-sol | xhigh |
| implementer (std) | claude-opus-4-8 | high | gpt-5.6-sol | high |
| implementer (fast) | claude-opus-4-8 | low | gpt-5.6-sol | medium |

> **Model note:** Fable access is blocked, so every Claude secondary (deep and standard product/review lens) runs on `claude-opus-4-8` at `xhigh` effort. There is no model-profile selection — depth is differentiated by effort.
