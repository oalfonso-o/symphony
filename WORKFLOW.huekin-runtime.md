---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "huekin-symphony-runtime-7a59b42801e5"
  active_states:
    - Ready for Agent
    - In Progress
    - Integrating
  exclude_labels: []
  terminal_states:
    - Done
    - Canceled
polling:
  interval_ms: 10000
workspace:
  root: ~/pipprojects/symphony-runtime-workspaces
hooks:
  timeout_ms: 300000
  after_create: |
    git clone git@github.com:oalfonso-o/symphony.git .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_run: |
    git remote set-url origin git@github.com:oalfonso-o/symphony.git
    git fetch origin main --prune
agent:
  max_concurrent_agents: 1
  max_turns: 12
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  default_profile: default
  profiles:
    default:
      command: codex --config shell_environment_policy.inherit=all app-server
    spark:
      command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.3-codex-spark"' app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
runtime:
  state_root: ~/pipprojects/symphony-runtime-workspaces/.symphony_runtime
  summary_profile: spark
---

You are working on a Linear issue from the Huekin Symphony Runtime project.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}
Blocked by:
{% for blocker in issue.blocked_by %}
- {{ blocker.identifier }} ({{ blocker.state }})
{% endfor %}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Repository:
- Remote: git@github.com:oalfonso-o/symphony.git
- Base branch: main
- Local source-of-truth checkout: /Users/oalfonso/pipprojects/symphony

## Scope

This runtime owns work for the Huekin fork of Symphony: scheduler,
orchestrator, dashboard, workers, Linear adapter, Codex app-server integration,
model profiles, runtime logs, workflow files, and cross-project routing.

Do not modify /Users/oalfonso/code/symphony. Do not push to
upstream/openai/symphony. This workflow pushes only to
git@github.com:oalfonso-o/symphony.git.

## State Routing

Current Linear state: `{{ issue.state }}`

{% if issue.state == "Ready for Agent" %}
Selected phase: implementation.
{% elsif issue.state == "In Progress" %}
Selected phase: restart cleanup.
{% elsif issue.state == "Integrating" %}
Selected phase: integration.
{% else %}
Selected phase: none. Move the issue to `Human Review`; the current Linear
state is not routable by this workflow.
{% endif %}

## Shared Rules

1. Read `AGENTS.md` if present in the workspace, plus this workflow file, before
   making repository changes.
2. Preserve unrelated user or agent changes. Never use destructive git commands
   unless the issue explicitly requires them and the state is clear.
3. Use `rg` / `rg --files` for search and `apply_patch` for manual edits.
4. Agent-discovered out-of-scope work belongs in `Agent Follow-up` with exactly
   one inherited `epic:*` label.
5. `Agent Follow-up`, `Human Review`, `Human QA`, and automatic states require
   exactly one `epic:*` label. `Todo` and `Backlog` may remain unclassified.
6. Commits must start with the issue identifier and issue slug, for example:
   `HUE-83 codex-spark-routing: Add Spark routing for deterministic work`.
7. Do not create GitHub PRs for this workflow. Integration is local and direct.

## Implementation Phase

When the issue is in `Ready for Agent`:

1. Move the issue to `In Progress`.
2. Create or update one branch named `<issue-id>/<issue-slug>/WIP`.
   - The branch must start with the Linear identifier, such as `HUE-83`.
   - The slug is kebab-case and at most 20 characters.
   - Do not include `symphony`, `symphony-runtime`, or an `epic:*` label in the
     branch name.
3. Implement only the issue's described runtime change.
4. Run the full runtime validation:

   ```bash
   cd /Users/oalfonso/pipprojects/symphony
   make all
   git diff --check
   ```

5. Commit with the required `HUE-... slug:` prefix and push the WIP branch.
6. Move the issue to `Integrating` and leave a concise Linear comment with the
   branch, commit, validation commands, and any manual verification notes.

If validation fails because of your branch, fix it before moving the issue. If
the issue is underspecified, permissions are missing, or product judgment is
needed, move it to `Human Review` with a clear blocker comment.

## Restart Cleanup Phase

When a fresh worker receives `In Progress`, do not recover partial local
workspaces. Move the issue back to `Ready for Agent`, leave a brief comment that
the runtime restarted the phase, and stop.

## Integration Phase

When the issue is in `Integrating`:

1. Resolve the WIP branch from the issue branch metadata or from the
   `<issue-id>/<issue-slug>/WIP` convention. If the branch is missing or
   ambiguous, move the issue to `Human Review`.
2. Fetch `origin/main` and rebase the WIP branch onto it.
3. Run the full runtime validation on the branch:

   ```bash
   cd /Users/oalfonso/pipprojects/symphony
   make all
   git diff --check
   ```

4. Fast-forward local `main` to `origin/main`.
5. Squash merge the WIP branch into local `main`.
6. Create one final issue commit summarizing the complete outcome.
7. Run the full runtime validation again on `main`.
8. Push `origin main`.
9. Delete the remote and local WIP branch once the commit is present on `main`.
10. Move the issue to `Human QA` with baby-step verification instructions.

If rebase, squash, validation, attribution, or permissions become unclear before
`main` is pushed, move the issue to `Human Review`. If validation fails because
of branch code, return the issue to `Ready for Agent`. Keep `main` linear; do not
create merge commits.
