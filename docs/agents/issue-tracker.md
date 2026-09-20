# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the gh CLI for all operations.

## Conventions

- Create an issue with gh issue create --title "..." --body "...". Use a heredoc for multi-line bodies.
- Read an issue with gh issue view <number> --comments, fetching labels and filtering comments as needed.
- List issues with gh issue list --state open --json number,title,body,labels,comments and appropriate label/state filters.
- Comment with gh issue comment <number> --body "...".
- Apply/remove labels with gh issue edit <number> --add-label "..." or --remove-label "...".
- Close with gh issue close <number> --comment "...".

Infer the repository from git remote configuration when operating inside the clone.

## Pull requests as a triage surface

PRs as a request surface: no.

External pull requests are not treated as the feature-request/triage queue.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Read the corresponding GitHub issue and its comments.

## Implementation conventions

When creating implementation work:

- Prefer small tracer-bullet issues with explicit dependencies.
- Preserve links back to the governing specification or ADR.
- Make acceptance criteria concrete enough for an implementation agent to verify.
- Record blocking relationships explicitly.
