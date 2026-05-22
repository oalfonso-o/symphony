# Symphony Repository

Project guidance for agentic workers in this repository.

## Source Of Truth

- Elixir runtime implementation guidance lives in `elixir/AGENTS.md`.
- Workflow/runtime contract details live in `elixir/WORKFLOW.md`.
- Keep repository-level git and workspace rules here so interactive Codex
  sessions follow the same mainline discipline regardless of their starting
  directory.

## Local Codex Workflow

These rules apply to interactive Codex sessions in
`/Users/oalfonso/pipprojects/symphony`. Symphony-dispatched workers follow
`elixir/WORKFLOW.md` in their own isolated workspaces instead.

- Treat `/Users/oalfonso/pipprojects/symphony` as the primary mainline
  checkout. Before local Codex edits, inspect `git status --short --branch`,
  run `git fetch origin --prune`, and confirm the checkout is on `main` with
  `main` fast-forwarded to `origin/main`.
- Use `origin` (`git@github.com:oalfonso-o/symphony.git`) as the writable fork
  for this project. Do not push to `upstream/openai/symphony` from local Codex
  sessions.
- If the primary checkout is not on `main`, has uncommitted changes, has local
  commits not already based on current `origin/main`, or cannot fast-forward
  cleanly, stop before editing and report the exact git state. Do not continue
  feature work on a local branch in the primary checkout unless the human
  explicitly asks for that branch.
- Local interactive Codex work should commit directly on `main` after
  verification when the human asks for a durable local change. Keep `main`
  linear and based on current `origin/main`; rebase local commits onto
  `origin/main` before considering the work finished.
- Local interactive Codex sessions must not use local feature branches in the
  primary checkout for parallel or experimental work. If isolation is needed,
  create a separate git worktree from current `origin/main`, use a temporary
  `codex/<short-purpose>` branch only inside that worktree, then integrate the
  finished commits back onto `main`.
- After isolated work is integrated, remove the temporary worktree and delete
  its temporary branch. Do not leave stale `codex/*` branches or worktrees once
  their commits are present on `main`.
- End local Codex sessions with the primary checkout on `main`. The worktree
  should be clean unless the final response explicitly lists remaining
  uncommitted files and why they were left uncommitted.

## Validation

- For Elixir runtime changes, run the validation in `elixir/AGENTS.md`.
- For documentation-only changes, at minimum run `git diff --check`.
