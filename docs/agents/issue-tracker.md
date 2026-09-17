# Issue tracker: Local Markdown with GitHub intake

Internal issues and specs for this repo live as Markdown files in `.scratch/`.
Public-interest and potential OSS requests live as GitHub Issues in
`enkelm/vibestick`.

## Routing

Use local Markdown by default.

Create a GitHub issue only when:

- the user explicitly asks to publish the work publicly;
- the request represents public interest or potential OSS work; or
- the request originated from the public GitHub community.

Do not automatically mirror local issues to GitHub. If local work is promoted
to a public issue, add a link in both places when practical.

## Local conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at
  `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`; never
  use a single combined tickets file.
- Triage state is recorded as a `Status:` line near the top of each issue file.
  See `triage-labels.md` for the role strings.
- Comments and conversation history append to the bottom of the file under a
  `## Comments` heading.

## GitHub conventions

Use the `gh` CLI for GitHub operations. Infer the repository from
`git remote -v`; `gh` does this automatically when run inside the clone.

- Create: `gh issue create --title "..." --body "..."`
- Read: `gh issue view <number> --comments`
- List: `gh issue list --state open`
- Comment: `gh issue comment <number> --body "..."`
- Label: `gh issue edit <number> --add-label "..."`
- Close: `gh issue close <number> --comment "..."`

Use a heredoc for multiline issue bodies. Apply the mappings from
`triage-labels.md` when triaging GitHub issues.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## When a skill says "publish to the issue tracker"

Create a local Markdown issue unless the user explicitly identifies the work
as public-interest or OSS-facing. For public work, create a GitHub issue.

## When a skill says "fetch the relevant ticket"

- For a path under `.scratch/`, read that file.
- For a GitHub issue number or URL, run
  `gh issue view <number> --comments`.

## Wayfinding operations

Wayfinding uses local Markdown unless the user explicitly asks to run it
publicly.

- **Map:** `.scratch/<effort>/map.md`, containing Notes,
  Decisions-so-far, and Fog.
- **Child ticket:** `.scratch/<effort>/issues/NN-<slug>.md`, numbered from
  `01`, with the question in the body. A `Type:` line records the ticket type
  (`research`, `prototype`, `grilling`, or `task`); a `Status:` line records
  `claimed` or `resolved`.
- **Blocking:** a `Blocked by: NN, NN` line near the top. A ticket is unblocked
  when every file it lists is `resolved`.
- **Frontier:** scan `.scratch/<effort>/issues/` for files that are open,
  unblocked, and unclaimed; first by number wins.
- **Claim:** set `Status: claimed` and save before any work.
- **Resolve:** append the answer under an `## Answer` heading, set
  `Status: resolved`, then append a context pointer—gist plus link—to the
  map's Decisions-so-far in `map.md`.
