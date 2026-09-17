---
name: land
description: >-
  Land requested Vibestick changes on origin/main. Invoke only after the user
  explicitly requests landing, such as choosing Land Changes or asking to merge;
  do not invoke for review, preparation, verification, or skill installation alone.
metadata:
  delta-action: land
---

# Land Vibestick changes

The invocation is the landing request. Proceed without asking the user to confirm
the merge again. Stop only for a genuine blocker, unresolved scope, or an
ambiguous conflict.

## 1. Establish scope and destination

1. Work from the Vibestick repository root. Confirm the package is the macOS
   executable defined in [`Package.swift`](../../../Package.swift).
2. Inspect the branch, working tree, staged diff, unstaged diff, and every
   untracked path. Identify the files belonging to the requested change.
3. Preserve unrelated work. Stage explicit pathspecs rather than `git add .`;
   never stash, discard, overwrite, or include unrelated changes. If the requested
   files cannot be separated safely, ask one focused scope question.
4. Treat `origin` as the publication remote and `main` as the target only after
   verifying their current URLs/default branch. `local` is the user's checkout
   backlink, not a publication remote.
5. Fetch `origin/main` and inspect current GitHub branch rules and required checks
   before preparing the landing. If the destination now requires a pull request,
   review, or CI, follow that current policy when the available authentication
   permits it; otherwise report the unmet requirement as a blocker. Do not weaken
   or bypass new protections.

## 2. Prepare focused commits

1. Review the complete proposed diff for secrets, credentials, personal data,
   generated bundles, logs, screenshots, and machine-local paths. This repository
   is public.
2. Create the smallest coherent commit or sequence of commits for the requested
   work. Use concise imperative commit messages consistent with the repository's
   existing history.
3. Use non-interactive Git commands. Prefix any Git command that could open an
   editor with `GIT_EDITOR=true`.
4. If `origin/main` advanced, merge it into the prepared work without rewriting
   shared history.

### Conflicts

Resolve conflicts automatically when the intended combined result is clear,
preserving both the requested behavior and unrelated upstream work. Review every
resolved hunk before continuing.

Only pause when the competing outcomes are genuinely ambiguous or unsafe. Invoke
the `show-me` skill to present the alternatives visually, explain their effects,
and ask the user one focused decision question. Do not ask about routine conflicts.

## 3. Verify the final candidate

Run verification after incorporating the latest `origin/main`, so it exercises the
exact candidate that will be pushed.

For Swift source, package, app metadata, or build-script changes, run all of:

```sh
swift build
.build/debug/Vibestick --self-check
./build.sh
```

- `swift build` builds the executable target declared in
  [`Package.swift`](../../../Package.swift).
- `--self-check` is implemented by `VibestickMain.main` and `runSelfCheck` in
  [`Sources/Vibestick/main.swift`](../../../Sources/Vibestick/main.swift).
- `./build.sh` performs the release build, assembles `Vibestick.app`, and signs it
  as defined in [`build.sh`](../../../build.sh).

For a change limited to agent skills or Markdown, inspect every changed skill and
verify that its YAML frontmatter has a nonempty `name`, a block-scalar
`description`, and, for a Land skill, exactly:

```yaml
metadata:
  delta-action: land
```

Run additional focused checks when the changed code establishes them. A pending,
failing, missing, or unverifiable required check blocks landing. Fix failures when
the correction is clearly within scope, commit the correction, and rerun the full
applicable verification against the new commit.

## 4. Land and verify

1. Recheck that `origin/main` has not advanced since the verified candidate was
   prepared. If it has, incorporate it and repeat the applicable verification.
2. Push the verified commit with `git push origin HEAD:main`. The explicit landing
   request authorizes this normal push, not a force-push.
3. Read `refs/heads/main` back from `origin` and require its SHA to equal the local
   verified `HEAD`. Also verify the commit is reachable at
   `https://github.com/enkelm/vibestick/commit/<full-sha>`.
4. Report the landed commit, checks performed, and any intentionally preserved
   working-tree changes. A local commit, passing build, topic-branch push, or
   attempted push is not landing success.

## 5. Report the outcome

When running in a subthread and `report_subthread_status` is available, report the
final outcome to the parent. Otherwise report it in the current conversation.

- After remote verification, use `status: success`, title `Landed on main`, and a
  one-line description linking the short commit SHA to its verified GitHub commit
  URL. Include a verified required-CI link only when one exists.
- For a genuine blocker or failed attempt, use `status: failure`, a concise title
  naming the blocker, and one line stating that the change was not landed. Link a
  real failing check or commit when available.

Failure is recoverable: continue safe remediation allowed by this workflow and
report the updated verified outcome. Never report skill installation, commit
creation, or routine progress as landing success.
