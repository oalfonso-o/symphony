# Epic-Aware Scheduling

This document defines the Linear dispatch contract for workflows that use
`epic:*` labels as work-grouping metadata.

## Runnable Candidate Set

Epic priority is computed only after the scheduler removes work that is not
runnable:

- Issues excluded by `tracker.exclude_labels`, such as `human-action`.
- Terminal issues.
- Non-terminal issues with non-terminal Linear blockers.
- Issues that are not routable to the current worker assignment.
- Issue ids already claimed by the scheduler.
- Issue ids already running in an active agent session.

The contract applies to every state in `tracker.active_states`. If a workflow
configures `Ready for Agent`, `In Progress`, `In Review`, or any other state as
active, candidates from that state participate in the same epic-aware ordering.

## Epic Buckets

An issue with exactly one `epic:*` label belongs to that valid epic bucket.

An issue with no `epic:*` label, or with more than one `epic:*` label, is
malformed for scheduling. Malformed candidates are placed after all valid epic
buckets, sorted by the normal deterministic per-issue order. The scheduler must
not automatically mark malformed issues `human-action`; workflow agents remain
responsible for enforcing issue metadata when they claim or work a specific
issue.

## Bucket Priority

Epics that already have running active work remain preferred while they still
have runnable candidates. Only non-terminal issues in configured active states
count as active epic work. Terminal audit, source, canceled, duplicate, closed,
or completed issues do not keep an epic focused.

When there is no runnable candidate in a running-active epic bucket, priority
falls back to valid epic buckets ordered by each bucket's best runnable issue.
The best runnable issue uses the existing per-issue dispatch sort: Linear
priority, creation date, then identifier.

## Spillover

Epic focus is a strong preference, not a strict single-epic lock. The scheduler
fills available agent slots from the preferred epic first. If the preferred epic
cannot consume all available capacity because it has too few runnable
candidates, per-state capacity is exhausted, or worker assignment prevents more
dispatches, the scheduler spills over to later epic buckets. Malformed fallback
candidates are considered only after valid epic buckets.
