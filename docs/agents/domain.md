# Domain Docs

How the engineering skills should consume this repo's domain documentation
when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root.
- **`CONTEXT-MAP.md`** at the repo root if it exists; it points at one
  `CONTEXT.md` per context. Read each one relevant to the topic.
- **`docs/adr/`**: read ADRs that touch the area you are about to work in.

If any of these files do not exist, proceed silently. Do not flag their
absence or suggest creating them upfront. The domain-modeling workflows create
them lazily when terms or decisions are resolved.

## File structure

This repository uses a single-context layout:

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-example-decision.md
│   └── 0002-another-decision.md
├── App/
└── Sources/
```

## Use the glossary's vocabulary

When output names a domain concept—in an issue title, refactor proposal,
hypothesis, or test name—use the term defined in `CONTEXT.md`. Do not drift to
synonyms that the glossary explicitly avoids.

If the needed concept is absent, either reconsider whether the term belongs to
the project or note the gap for the domain-modeling workflow.

## Flag ADR conflicts

If output contradicts an existing ADR, surface it explicitly rather than
silently overriding it:

> Contradicts ADR-0007, but worth reopening because…
