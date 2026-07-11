# Git Workflow Modes

Superflow selects a git workflow in Phase 1 and stores it in `.superflow-state.json` under `context.git_workflow_mode`. Existing state files without this field default to `local_commit` when the repo has no GitHub remote with CI, else `sprint_pr_queue`.

## Modes

| Mode | Branching | PRs | Best for | Avoid when |
|------|-----------|-----|----------|------------|
| `solo_single_pr` | One feature branch for the whole run | 1 final PR | Solo/vibe coding, small-to-medium coherent work | Many independent workstreams need separate review |
| `sprint_pr_queue` | One branch per sprint from `main` | 1 PR per sprint | Team review, auditability, production-risk changes | Highly dependent sprints with noisy independent diffs |
| `stacked_prs` | Sprint N branches from Sprint N-1 | 1 PR per sprint, stacked bases | Dependent multi-sprint work where each step should be reviewable | Teams without stacked-PR discipline/tooling |
| `parallel_wave_prs` | Independent sprint branches from `main`, grouped by wave | 1 PR per sprint | Disjoint modules, team/agent parallelism | Sprints share files/state or require previous wave code before merge |
| `trunk_based` | Short-lived branches from `main`, optional feature flags | Small PRs as ready | Mature CI, team-owned products, release behind flags | Long autonomous runs without strong CI |
| `local_commit` | One branch/worktree per sprint from `main` | **No PRs** — local merge to `main` after the Rule 3 gate, then push to backup remote | Repos with no GitHub CI remote (backup-only remotes, e.g. `/root` POS) | Repo has CI — use a PR mode so CI gates merges |

Classic Git Flow (`develop`, `release`, `hotfix`) is intentionally not a default mode. Use it only when the project already has release trains or maintained release branches.

## Selection Heuristic

Choose by task shape, not by whether the user is solo or in a team:

- Coherent solo feature, <=3 sprints, one reviewer pass is enough -> `solo_single_pr`
- Team/critical work, compliance/audit needed, or user wants isolated review units -> `sprint_pr_queue`
- Sprint N directly builds on Sprint N-1 and independent PR diffs would be misleading -> `stacked_prs`
- Sprints touch clearly disjoint files and can be reviewed independently -> `parallel_wave_prs`
- Existing project practices require short-lived branches and feature flags -> `trunk_based`
- No GitHub remote with CI (backup-only or offline repo) -> `local_commit` — the PR/CI lane physically cannot run; the Rule 3 gate (dual review + PAR + docs) is the merge gate

## Branch Base Policy

- `solo_single_pr`: create or reuse `feat/<feature>` from `origin/main`; all sprints commit there; create one PR at the end.
- `sprint_pr_queue`: create `feat/<feature>-sprint-N` from `origin/main`; merge PRs sequentially in sprint order.
- `stacked_prs`: create Sprint 1 from `origin/main`; create Sprint N from `feat/<feature>-sprint-(N-1)`; PR base is previous sprint branch until Phase 3 restacks/retargets.
- `parallel_wave_prs`: create each sprint branch from `origin/main`; only sprints in the same wave with no file/state dependency may run concurrently.
- `trunk_based`: create short-lived branch names per deployable slice; keep changes behind flags when incomplete.
- `local_commit`: create `feat/<feature>-sprint-N` worktrees from `main`; after the Rule 3 gate passes — exit worktree, merge locally to `main`, push to the backup remote, remove the worktree. Record `"git_workflow_mode": "local_commit"` in state (not a prose mutation of another mode).

## Phase 2 Merge Boundary

Phase 2 creates PRs; it does not merge unless the user explicitly approved an auto-merge policy in Phase 1. If later work must see earlier merged code, choose `stacked_prs` or run the dependent sprints sequentially. Do not silently merge completed wave PRs during Phase 2.
