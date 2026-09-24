# Initial milestone acceptance

This workflow qualifies one source revision of Vibestick in two parts:

1. `acceptance.sh` performs a clean source build, runs the complete automated
   suite, and records reproducible evidence.
2. An operator runs the generated checklist on the target Mac and controller.

The milestone is qualified only when `result.txt` says `outcome=PASS` and every
applicable item in `manual-checklist.md` is checked. An automated pass alone is
not a physical qualification.

## Target setup

- macOS 14 or later.
- Microsoft Xbox Wireless Controller with Share connected through
  Bluetooth Low Energy (`045E:0B13`).
- TypeWhisper configured for Command-Control-Option-Shift-backtick.
- Herdr available in Ghostty.
- Slack available.
- Herdr's gamepad plugin disabled by the operator before Vibestick starts.

Disconnect the controller's USB cable before starting acceptance. USB
`045E:0B12` is not qualified for Share because macOS omits the controller's
Share extension from the USB input exposed to applications.

Vibestick and this workflow do not inspect, disable, enable, or otherwise
manage Herdr's plugin. The operator must confirm its state through Herdr's own
configuration or status surface and record that confirmation in the checklist.

## Run the automated workflow

From the repository root:

```sh
./acceptance.sh
```

The source worktree must be clean. The workflow refuses to qualify tracked,
staged, or untracked changes so that the recorded commit identifies the exact
source under test. Ignored build products and acceptance evidence do not affect
this check.

The command creates a unique run directory under `.scratch/acceptance/` and
prints its path. To choose an evidence directory instead:

```sh
./acceptance.sh /absolute/path/to/evidence
```

The destination must not already exist. A run produces:

- `environment.txt`: UTC time, exact Git commit and worktree state, macOS,
  architecture, and Swift version;
- `workflow.log`: the clean, test, and source-build transcript;
- `result.txt`: `PASS` or `FAIL` and the command's exit code;
- `manual-checklist.md`: the physical workflow to complete for that same run.

Do not reuse evidence from another commit. Preserve failed run directories;
they are the reproducible record of what failed.

## Automated evidence map

`swift test` covers the milestone specification at these public seams:

| Required evidence | Test coverage |
| --- | --- |
| Target identity and transport-specific unique backend ownership | `ControllerInputTests` |
| Gesture precedence and short/long L3 | `SystemGestureRoutingTests` |
| Back-layer hold, arm, cancellation, and timeout | `HerdrCommandRoutingTests` |
| App-context and profile resolution; unknown-app safety | `CommandRoutingTests` |
| App-wheel MRU ordering and explicit selection | `AppWheelTests` |
| Context transitions and held-output release | `OutputLifecycleTests` |
| Persistence and one-time migration | `ConfigurationPersistenceTests` |
| Overlay observation and pass-through | `BindingsOverlayTrainerTests` |
| Repeatable navigation and natural-direction scrolling | `StickRepeatTests` |
| Complete Slack preset | `SlackPresetTests` |
| Acceptance command success and failure evidence | `AcceptanceWorkflowTests` |

`build.sh` then compiles the release executable from source and assembles
`Vibestick.app`. It signs with the trusted local `Vibestick Local Code Signing`
identity when available (or an explicit `VIBESTICK_CODESIGN_IDENTITY`);
otherwise it falls back to ad-hoc signing, which requires a fresh Accessibility
grant after rebuilding.

## Run the physical workflow

Open the generated `manual-checklist.md`, fill in its run metadata, and work
from top to bottom. Use the app produced by the same run:

```sh
open ./Vibestick.app
```

The denied-Accessibility section must be performed before granting access.
Use System Settings to change permission; do not substitute another build
between the denied and granted checks.

The migration check changes
`~/Library/Application Support/Vibestick/config.json`. Perform it only after
quitting Vibestick and making the backup required by the checklist. Restore the
operator's original configuration at the end.

## Record a failure

For every failed checkbox, leave it unchecked and add:

- the exact checklist step;
- expected and actual behavior;
- UTC time and active app context;
- controller connection and Accessibility state;
- the shortest repeatable input sequence;
- relevant screenshots, console output, or files stored beside the checklist.

After a fix, create a new evidence directory and repeat the entire workflow.
Do not turn a failed run into a pass by editing `result.txt`.
