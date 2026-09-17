# Vibestick initial milestone

## Purpose

Vibestick is a macOS command surface for Mac power users who use an Xbox
Wireless Controller during agentic development. The controller remains a
secondary input alongside keyboard, pointer, and voice input, while dictation
makes substantially keyboard-free operation possible.

The initial workflow is:

- Herdr inside Ghostty;
- ordinary Ghostty;
- Slack;
- system-level app switching, dictation, and binding visibility.

The existing implementation is a prototype. Its concepts are evidence, not a
behavioral contract.

## Target environment

- macOS 14 or later
- Microsoft Xbox Wireless Controller with Share, currently identified as
  `045E:0B12`
- TypeWhisper configured to toggle dictation with the physical backtick key
  plus Command, Control, Option, and Shift
- Herdr's gamepad plugin disabled while Vibestick owns controller input

The initial milestone is built locally from source. It does not include a
signed or notarized public release.

## Binding model

### Resolution

Each controller input has one owner. Resolve inputs in this order:

1. an active binding-capture edit;
2. the app wheel, when open;
3. a pending system gesture;
4. the Herdr Back layer, when active;
5. an ordinary app binding.

The visible bindings overlay is an exception: outside active editing, it
observes input while normal mappings continue to run.

Ordinary app bindings resolve through:

1. an operator override for the active app context;
2. the built-in preset for that context;
3. the operator's global fallback;
4. unbound.

App profiles are sparse. Resetting an override reveals the current preset or
global fallback rather than copying defaults into the profile.

Herdr and ordinary Ghostty are distinct app contexts even though they share a
bundle ID. If Vibestick cannot positively identify a focused Herdr surface, it
must select ordinary Ghostty rather than risk sending a Herdr command.

### System bindings

System bindings take precedence over app profiles but remain globally
rebindable or disableable.

| Gesture | Default |
| --- | --- |
| Short L3 | TypeWhisper toggle: Command-Control-Option-Shift-backtick |
| Long L3 | Open app wheel |
| Share | Toggle bindings overlay |

Dictation is represented as a plain keyboard shortcut, not a special provider
integration. TypeWhisper owns transcription models and providers.

The Share binding is a required capability for the target controller. The
current raw report parser does not expose it, so implementation must validate
Apple's `GCXboxGamepad.buttonShare` against the physical controller before
settling the input backend.

## Herdr

### Base bindings

Use the existing gamepad plugin's control grammar as the baseline, adjusted by
the system bindings above.

| Input | Action |
| --- | --- |
| A | Return |
| B | Space |
| X | Escape |
| Y | Herdr session navigator |
| LT / RT | Previous / next agent |
| LB / RB | Previous / next tab |
| Start | Next workspace |
| D-pad | Focus pane left, right, up, or down |
| Left stick | Repeatable arrow keys |
| Right stick | Repeatable scrolling |

The initial Herdr preset emits literal shortcuts matching the current Herdr
configuration. It does not call semantic Herdr actions or dynamically resolve
Herdr's configuration.

### Back layer

Back activates a second Herdr mapping through either:

- hold Back while pressing another control; or
- tap Back to arm the layer for two seconds, then press another control.

Tapping Back again cancels an armed layer. A timeout sends nothing. Vibestick
emits the complete configured shortcut only after a valid second input.

| Gesture | Herdr action |
| --- | --- |
| Back + A | Zoom |
| Back + B | Split vertically |
| Back + Y | Split horizontally |
| Back + X | Last pane |
| Back + RB | New tab |
| Back + Start | Previous workspace |
| Back + LB | Toggle sidebar |
| Back + RT | Help |
| Back + LT | Settings |

## Ordinary Ghostty

When Ghostty is focused without positive Herdr identification, use this
conservative terminal preset:

| Input | Action |
| --- | --- |
| A | Return |
| B | Space |
| X | Escape |
| Y | Tab |
| LB / RB | Previous / next Ghostty tab |
| Start | New Ghostty tab |
| D-pad | Arrow keys |
| Left stick | Repeatable arrow keys |
| Right stick | Repeatable scrolling |

LT, RT, R3, and Back are initially unbound. Do not include a destructive
close-surface default.

## Slack

| Input | Action | Literal shortcut |
| --- | --- | --- |
| A | Start, join, leave, or end huddle | Command-Shift-H |
| B | Mark current conversation read or dismiss | Escape |
| X | Quick conversation switcher | Command-K |
| Y | Compose a message | Command-N |
| LB / RB | Previous / next unread conversation | Option-Shift-Up / Down |
| LT | Open all unreads | Command-Shift-A |
| RT | Search | Command-G |
| R3 | Toggle huddle mute | Command-Shift-Space |
| D-pad up / down | Previous / next conversation | Option-Up / Down |
| D-pad left / right | Back / forward in history | Command-[ / ] |
| Left stick | Repeatable arrow keys | Arrow keys |
| Right stick | Repeatable scrolling | Scroll wheel |
| Back | Open Home | Control-1 |
| Start | Open Activity | Command-Shift-M |

Short and long L3 and Share retain their system meanings.

## Unknown apps

Ship ordinary controls unbound for app contexts with neither a preset nor an
operator profile. System bindings remain available. Auto-enabled output must
not cause arbitrary key entry in unsupported apps.

## App wheel

Long L3 opens the app wheel. The wheel:

- shows up to eight other running regular apps;
- excludes Vibestick and the current app;
- deduplicates apps;
- orders candidates by most recent use, with alphabetical fallback;
- starts with no selection;
- retains the last selection when the stick returns to its dead zone;
- uses A for explicit activation and B for cancellation;
- suppresses all ordinary mappings while open.

Releasing L3 does not activate an app.

## Bindings overlay

Share toggles a translucent training overlay. While the overlay is merely
visible:

- Share is the only controller input it consumes;
- all other controller mappings continue to operate;
- it follows the current app context;
- the controller visualization updates live;
- the underlying app remains visible.

The overlay becomes more opaque for pointer interaction or active editing.
Editing remains keyboard-and-mouse operated in the initial milestone.

The editor exposes:

- system bindings;
- global defaults;
- focused-app base bindings;
- the focused Herdr context's Back layer;
- stick and scroll behavior.

Each binding shows whether it comes from a preset, global fallback, or operator
override. The operator can clear or override a binding and reset one binding
or the whole app profile.

When active editing or key capture begins:

- pin the app context being edited;
- suspend mapped controller output;
- continue updating the live controller visualization;
- resume pass-through after editing ends.

The menu-bar command remains the recovery path if Share is cleared or
misconfigured.

## Lifecycle and safety

- Output becomes active automatically whenever Vibestick runs.
- There is no Launch at Login support in the initial milestone.
- First run automatically requests Accessibility permission.
- Without Accessibility, keyboard and scroll output remain unavailable while
  the app wheel, overlay, and status UI continue to work.
- The menu bar reports controller, Accessibility, output, and app-context
  status.
- A session-only emergency pause disables app shortcuts, Herdr-layer actions,
  dictation, repeats, and scrolling.
- While paused, Share, the app wheel, menu controls, and live visualization
  remain available.
- Pause resets to active on the next launch.
- Disconnect immediately releases active output, closes the app wheel, clears
  held controls, and cancels the Herdr layer.
- Reconnect resumes active operation without another menu action.
- An app-context change releases old output, stops repeats and scrolling,
  clears held controls, and cancels transient modes before accepting a fresh
  input in the new context.
- The Herdr gamepad plugin must remain disabled. Vibestick does not manage it.

Initial stick tuning:

- dead zone: `0.25`;
- repeat delay: `400 ms`;
- repeat interval: `80 ms`;
- scrolling follows the current Mac's natural-scrolling direction.

These values remain centralized but do not require initial tuning UI.

## Persistence

Introduce one versioned configuration schema for:

- system bindings;
- global fallback bindings;
- app profiles;
- Herdr-layer overrides;
- stick mappings.

Perform a one-time migration from the prototype configuration. Preserve
recognizable global and app overrides. If an entry cannot be migrated, retain
the old file as a backup and report what was skipped. Do not maintain both
schemas at runtime.

## Non-goals

- controllers other than the target Xbox Wireless Controller;
- Teams, Zed, Delta, or additional app presets;
- Launch at Login;
- semantic Herdr API actions;
- dynamic Herdr-config synchronization;
- direct speech-model or transcription-provider integration;
- controller-only bindings editing;
- automatic Herdr-plugin management;
- ordinary key output in unknown apps;
- app-wheel favorites, paging, or multiple rings;
- signed or notarized binary distribution.

## Acceptance criteria

### Automated evidence

Checks cover:

- Xbox input decoding;
- gesture precedence;
- short-L3 versus long-L3 behavior;
- Back-layer hold, arm, cancellation, and timeout;
- app-context and profile resolution;
- app-wheel MRU ordering and selection;
- context transitions and held-output release;
- persistence and one-time migration.

### Physical workflow

On the target controller:

- Share reliably toggles the training overlay through the selected input
  backend;
- short L3 toggles TypeWhisper;
- long L3 opens the app wheel;
- Back hold and tap-to-arm execute real Herdr commands;
- sticks navigate and scroll Herdr;
- ordinary Ghostty receives only its terminal preset;
- Slack huddle, unread, navigation, search, and compose bindings work;
- unknown apps receive no ordinary default output.

Manual checks cover Accessibility denied and granted states, output pause,
disconnect and reconnect, app-context transitions, overlay pass-through, and
configuration migration.

## Deferred implementation questions

These require engineering evidence rather than more product decisions:

- whether Game Controller can be the sole input backend for the target
  controller while preserving all required controls;
- if not, how to combine Share support with raw Xbox reports without duplicate
  events;
- how to positively correlate a focused Ghostty surface with Herdr without
  failing open.
