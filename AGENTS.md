# Repository instructions

This repository contains the Swift Networking library. The normative 1.0 behavior is defined in docs/spec/networking-1.0.md.

Use [Documentation/AgentGuide.md](Documentation/AgentGuide.md) for the reading order,
authority rules, issue workflow, and verified repository commands. Use
[Documentation/Architecture.md](Documentation/Architecture.md) as the architecture map;
it links to the normative sections and decision records without replacing them.

Before changing public API, architecture, concurrency behavior, retries, authentication, transport behavior, TestSupport, or any documented invariant, read CONTEXT.md, the relevant specification sections, and applicable ADRs.

## Agent skills

### Issue tracker

Work is tracked in GitHub Issues for this repository. See docs/agents/issue-tracker.md.

### Triage labels

Use the canonical triage labels needs-triage, needs-info, ready-for-agent, ready-for-human, and wontfix. See docs/agents/triage-labels.md.

### Domain docs

This repository uses a single-context domain-document layout with root CONTEXT.md and ADRs under docs/adr/. See docs/agents/domain.md.
