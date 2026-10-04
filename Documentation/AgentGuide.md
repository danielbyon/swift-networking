# Agent guide

This guide explains how to make bounded, reviewable changes in the Swift Networking repository. The
root [`AGENTS.md`](../AGENTS.md) is the short entry point. The specification defines the normative
contract, and source shows the current implementation.

## Read in this order

1. Read the task or GitHub issue and root `AGENTS.md` for scope and repository instructions.
2. Read this guide for the workflow and command map.
3. Read [`CONTEXT.md`](../CONTEXT.md) for established terms and invariants.
4. Read the relevant sections of the normative
   [`Networking 1.0 specification`](../docs/spec/networking-1.0.md), then applicable records in
   [`docs/adr/`](../docs/adr/).
5. Use [`Architecture.md`](Architecture.md) as a navigation aid, then inspect current source and
   tests for implementation details.

The task and user instructions define the authorized work. `AGENTS.md` defines repository rules;
the normative specification defines 1.0 behavior; ADRs record accepted rationale within that
contract; `CONTEXT.md` supplies vocabulary and a compact invariant map. The architecture overview
and this guide are explanatory, not normative. If documents conflict, do not silently choose one:
identify the conflict and follow the task's authority and scope rules before changing behavior.

## Issue-driven change workflow

1. Confirm the repository remote and inspect the issue, comments, acceptance criteria, blockers, and
   labels. Use the repository's configured GitHub account and the `gh` workflow in
   [`docs/agents/issue-tracker.md`](../docs/agents/issue-tracker.md).
2. Use the five existing triage labels in
   [`docs/agents/triage-labels.md`](../docs/agents/triage-labels.md): `needs-triage`, `needs-info`,
   `ready-for-agent`, `ready-for-human`, and `wontfix`. An issue marked `ready-for-agent` should have
   a concrete scope and verifiable acceptance criteria. Pull requests are for implementation and
   review, not the feature-request queue.
3. Check the working tree before editing. Preserve unrelated user changes. Keep the patch within the
   issue and its authorized paths; surface a required scope extension instead of expanding it
   silently.
4. When behavior or an invariant changes, update the required source-of-truth documentation and
   relevant ADRs as authorized. The 1.0 specification is normative; if implementation work exposes a
   specification gap, raise it for resolution rather than silently rewriting the contract.
5. Run the applicable repository-owned validation after the final edits. For gpt-repo-local work,
   use its `repo_validate` profile `all` and retain the resulting evidence. Revalidate after any
   subsequent change; earlier results do not certify a later tree.
6. Review the diff and whitespace check, then report exactly what passed, failed, or could not run.
   Do not stage, commit, push, merge, or publish unless the task explicitly authorizes that phase.

## Verified repository commands

The Makefile defines the local commands. CI runs the aggregate quality gate and a separate compile
for each declared Apple platform.

| Purpose | Command | Behavior |
| --- | --- | --- |
| Apply formatting | `make format` | Runs the pinned SwiftFormat release with the shared baseline and repository overlay. |
| Lint | `make lint` | Runs `git diff --check` and pinned SwiftLint. |
| Host build | `make build` | Runs `swift build`. |
| Tests | `make test` | Runs `swift test`. |
| Aggregate quality gate | `make all` | Runs lint, build, and tests. This is the CI quality job. |
| Apple platform compile | `make platform-build PLATFORM=macOS` | Runs the package scheme with a generic platform destination. Replace `macOS` with `iOS`, `tvOS`, `watchOS`, or `visionOS` as needed. |
| Install local pre-commit hook | `make hooks-install` | Sets this checkout's `core.hooksPath` to `.githooks`. The tracked hook runs `make lint`. |

`make platform-build` also accepts an optional `DERIVED_DATA_PATH`; CI places derived data in the
runner's temporary directory. The CI platform matrix includes iOS, macOS, tvOS, watchOS, and
visionOS. `make hooks-install` changes local Git configuration for this checkout; it does not
install or alter tracked files. The formatter wrapper merges the shared baseline with `.swiftformat`
and passes a temporary effective config to SwiftFormat; its message that the on-disk config is
ignored is expected with that explicit config argument.

## Documentation synchronization

- Keep `CONTEXT.md` concise and use its established domain terms.
- Put architecture navigation in `Documentation/Architecture.md`, detailed agent workflow here, and
  durable decision rationale in `docs/adr/`.
- Treat `docs/spec/networking-1.0.md` as the normative behavior contract. Link to its sections instead
  of copying the full specification into the architecture map.
- Keep `AGENTS.md` short and operational. Add a pointer when detailed guidance belongs elsewhere.
- Keep code-level documentation aligned with public API and actual behavior. If the implementation
  and normative contract disagree, record the conflict and resolve the authority question before
  documenting one as the other.

## Recorded gpt-repo-local example

Issue [#26](https://github.com/danielbyon/swift-networking/issues/26) is a completed example of the
repository's coding-agent workflow. Its handoff record is
`2026-10-04T082146Z-document-the-complete-public-1-0-api`; the local run manifest says `mode: manual`,
and that run has a completed `RESULT.json`. The run validated its documentation changes,
including `make all`, before opening [PR #50](https://github.com/danielbyon/swift-networking/pull/50).

The local run directory contains `review-gate.json` but no `review.json`, so it does not document a
local `repo_codex_review` artifact or local review-driven rework. Separately, PR #50 was merged and
closed Issue #26; [GitHub CI](https://github.com/danielbyon/swift-networking/actions/runs/37216152423)
passed the quality gate and all five platform-build jobs, and GitHub's Codex Review Summary reports
a completed Codex review. These are distinct local-run and GitHub records.

For future runs, preserve the same evidence boundaries: identify manual versus runner-executed
mode, record the completed run result, run the repository validation profile, and describe any
`repo_codex_review` or corrective rework only when the local run artifacts show it. Then report PR,
CI, and issue completion from GitHub state. A GitHub review summary is not a local review artifact.
