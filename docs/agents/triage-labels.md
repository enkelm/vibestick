# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those
roles to the status strings used in local Markdown and the labels used on
GitHub.

| Canonical role    | Local status / GitHub label | Meaning                                  |
| ----------------- | --------------------------- | ---------------------------------------- |
| `needs-triage`    | `needs-triage`              | Maintainer needs to evaluate this issue  |
| `needs-info`      | `needs-info`                | Waiting on reporter for more information |
| `ready-for-agent` | `ready-for-agent`           | Fully specified, ready for an AFK agent  |
| `ready-for-human` | `ready-for-human`           | Requires human implementation            |
| `wontfix`         | `wontfix`                   | Will not be actioned                     |

When a skill mentions a role, use the corresponding value from this table as
the local issue's `Status:` or as the GitHub issue label.

Edit the middle column if this repository adopts different vocabulary.
