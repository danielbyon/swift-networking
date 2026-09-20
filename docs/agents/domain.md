# Domain documentation

This repository uses a single-context domain model.

## Canonical documents

- CONTEXT.md — shared project vocabulary, boundaries, invariants, and major concepts.
- docs/adr/ — architectural decision records.
- docs/spec/ — normative specifications.

## Consumer rules

Agents working in this repository should:

1. Read AGENTS.md.
2. Read CONTEXT.md before changing domain concepts or public API.
3. Read relevant ADRs before modifying an established architectural decision.
4. Treat docs/spec/networking-1.0.md as normative for Networking 1.0 implementation work.
5. Update domain documentation or add an ADR when implementation requires changing a documented invariant or consequential design decision.

Use the vocabulary defined in CONTEXT.md rather than inventing synonyms for established domain terms.

If proposed work contradicts an ADR or the normative specification, surface the conflict explicitly instead of silently overriding it.

Do not duplicate detailed architecture throughout AGENTS.md. Keep operational instructions there and link to deeper documentation.
