# Vibestick 0.1.0: mouse mode and Delta

## Purpose

Make the Xbox controller useful when an app has no adequate keyboard shortcut:
an explicitly entered mouse mode supplies pointer movement, scrolling, and
clicking without replacing the ordinary Herdr, Ghostty, and Slack controls.
Add a conservative Delta preset for navigation and inspection.

Version 0.1.0 is an app capability milestone that can be built and used locally.
Afterward, attempt a Homebrew tap distribution separately. Signing,
notarization, and a tap are not conditions for completing this feature
milestone; if they take longer, the first tap release may be 0.2.0 or later.
The operator will report bugs during use rather than require a formal
end-to-end physical acceptance run before feature work proceeds.

The initial milestone's target remains macOS 14 or later and the Xbox Wireless
Controller with Share over Bluetooth (`045E:0B13`). USB Share, other
controllers, and arbitrary app presets are not added to the qualified scope.

## Input ownership

Each normalized input still has exactly one owner. While mouse mode is active,
ownership resolves in this order:

1. active binding capture/editing (mapped output suspended);
2. an open app wheel (pointer and clicks suspended);
3. the L3+R3 mouse-mode chord and pending chord candidates;
4. system gestures, including short/long L3 and Share;
5. mouse-mode controls.

When mouse mode is inactive, the chord candidates precede the existing system
gestures, Herdr Back layer, and ordinary app bindings. An incomplete chord
falls back to the existing behavior. A merely visible bindings overlay
observes input without taking ownership, as it does today.

Mouse mode replaces ordinary app bindings and Herdr-layer output while active,
but does not eliminate the idea of app-specific *mouse-mode* bindings. Those
bindings are deferred: 0.1.0 ships one shared mouse layout, not a second
per-app editor or pointer-position macros.

## Entering and leaving mouse mode

- L3+R3 toggles mouse mode in any app context, including unknown apps. The
  clicks may arrive in either order, but the second must arrive while the
  first remains held and no more than 250 ms after the first press (the
  boundary is inclusive). Keep this timing in one place and adjust only with
  physical-use evidence. A lone L3 still opens the wheel 650 ms after its
  original press, not 650 ms after the chord window ends.
- The chord is fixed in 0.1.0. Show it in the bindings overlay, but do not
  present it as editable in the single-input binding editor. The menu bar
  provides an explicit **Exit Mouse Mode** recovery command.
- A completed chord consumes both presses and their releases. It cancels any
  pending short/long L3 or R3 action and the long-L3 wheel timer; entry and
  exit never also toggle dictation, open the wheel, or invoke a mapped R3
  command. Mouse output starts only after the chord buttons are released.
- R3 ordinary actions (notably Slack huddle mute) must wait just long enough
  to distinguish the chord. If R3 is released or the window expires without
  a chord, dispatch its ordinary press action exactly once when appropriate.
  A short L3 alone retains dictation; a long L3 alone retains the app wheel.
  An already-open wheel retains ownership and does not interpret its input as
  a mouse-mode chord.
- Mouse mode is session-only and starts off on every launch. It persists
  across focused-app changes, but ends on controller disconnect, emergency
  pause, loss of Accessibility, or shutdown. A new connection, permission
  grant, or resumption never silently re-enters it. Reject a chord attempting
  to enter mouse mode while Accessibility is unavailable; report the missing
  permission without emitting pointer or click events.
- Short L3, long L3, and Share retain their configured system bindings while
  mouse mode is active, with the completed chord taking precedence. The app
  wheel still uses its own stick, A, and B controls while open. Emergency
  pause and menu recovery remain available.

## Shared mouse layout

| Input | Mouse-mode behavior |
| --- | --- |
| Right stick | Continuous relative pointer motion in both axes; center stops |
| Left stick | Continuous horizontal and vertical scrolling, respecting the Mac's natural-scrolling setting |
| LB | Left mouse button down while held; release on LB up; hold and move to drag |
| RB | Right mouse button down while held; release on RB up |
| L3+R3 | Exit mouse mode |
| Short/long L3; Share | Existing system gestures, unless consumed by the chord |

Other ordinary buttons and triggers are unbound in mouse mode for 0.1.0.
Neither a pointer movement nor a scroll sample invokes the normal stick
mapping. Pointer velocity should follow stick displacement (with a dead zone),
not the keyboard-repeat cadence; keep initial speed/dead-zone parameters
centralized so they can be tuned after use. No cursor motion at rest, no
position-based click macros, and no pointer jump when entering the mode.

Maintain real button-down/button-up state rather than translating a held
bumper into repeated clicks. Repeated controller samples must not create
extra downs, ups, or clicks. On focus change, app-wheel entry, active binding
editing/capture, loss of Accessibility, emergency pause, disconnect, mode
exit, or shutdown, stop pointer/scroll output and release every synthesized
mouse button immediately. Mouse mode stays selected across focus changes,
wheel use, and editing, but output resumes only from fresh controls after
the interruption: each interrupted button must be released and pressed
again, and each interrupted stick must return to its dead zone before its
next movement or scroll output. Never carry a held drag or deflected stick
into another app or surface.

An unobtrusive, non-focus-stealing on-screen indication identifies mouse
mode while active. The menu bar reports the state and offers the exit
command. The bindings overlay shows the active mouse layout as well as the
fixed entry chord; its ordinary visible/training state remains pass-through
except for Share.

## Delta app context and preset

Before implementing the preset, read the installed Delta.app's
`CFBundleIdentifier`, record the observed value in the preset and tests, and
recognize it by exact bundle-ID match as the existing Slack and Ghostty
presets do. Do not guess from the display name or match unrelated windows;
if the identity cannot be confirmed, treat Delta as an unknown app rather
than shipping a name-only matcher. Delta gets a distinct app context and
built-in preset; its operator profile remains sparse, keyed by the app's
bundle ID, so existing overrides for that ID continue to win. Unknown apps
have no built-in preset, but their explicit app overrides and global
fallbacks continue to apply outside mouse mode.

The initial Delta base preset uses the documented macOS shortcuts in
[Delta's keybinding reference](https://delta.dev/docs/configuration/keybindings):

| Input | Action | Shortcut |
| --- | --- | --- |
| A | Find a thread | Command-T |
| X | Open Review Changes | Option-Shift-D |
| LB / RB | Previous / next file tab | Command-Option-Left / Right |
| Back | Focus the parent conversation from a subthread | Command-1 |
| Start | Open the command palette | Command-Shift-P |
| D-pad | Arrow keys for navigation in the focused view | Arrow keys |

B, Y, LT, RT, and R3 have no Delta base action. Escape is deliberately
not bound: in a focused Delta subagent conversation it can stop the agent.
Command-K is deliberately not bound: when a terminal is focused it goes
to the terminal instead of reliably searching commands and threads. The
existing global left-stick arrow navigation and right-stick scrolling
become available when Delta is recognized; they are not part of the
per-app button preset and retain their global operator tuning and
overrides. The system L3 and Share gestures remain global; mouse mode
replaces the base preset while selected. Preserve the current
profile/override and stick-mapping rules, and display the Delta preset
in the bindings overlay/editor with binding source information.

These are literal shortcuts, not a Delta API integration. Delta documents
that its command shortcuts may depend on focused view and settings, so
verify the selected shortcuts in the installed version's live keymap
(Command-/) and in the target workflow. In particular, do not default any
button to send a message, archive a thread, accept a change, or invoke an
action whose focus-dependent meaning could have those effects. The operator
may still explicitly override a binding.

## Validation

Automated checks cover:

- chord recognition in both orders, deadline and release edges, duplicate
  input, inclusive 250 ms chord boundary, incomplete chords falling back
  exactly once without delaying the 650 ms long-L3 deadline, and no L3
  wheel or Slack R3 mute action on a completed chord;
- single-owner routing across capture, wheel, system gestures, Herdr layer,
  ordinary bindings, mouse mode, and merely visible overlay;
- pointer dead zone and direction, analog motion distinct from repeatable
  arrows, natural-direction scrolling, and no ordinary binding leakage;
- mouse down/up and drag behavior, with button release and zero stale output
  at every interruption listed above; each held button and deflected stick
  requires an up/neutral edge before it can resume output;
- mode persistence across app changes, exit on pause/disconnect/shutdown,
  loss of Accessibility, permission-denied entry, indicator and menu
  recovery;
- exact Delta bundle-ID identification, shortcut table, sparse-override
  precedence, global stick mappings, unknown-app override/fallback safety,
  and no Escape or Command-K default; verify both the focused-subagent
  and focused-terminal cases.

Physical smoke checks on the target Bluetooth controller cover both chord
orders, an ordinary short L3, long L3, Slack R3, moving and clicking in
Herdr and Delta, dragging across a focus change, the overlay and wheel while
mouse mode is active, disconnect/reconnect, pause/resume, and Accessibility
denied/granted. Confirm the on-screen indicator and menu exit in active
mode, and that the indicator disappears on exit. Check that the actual
Delta install is positively identified and its mapped shortcuts do what
their labels say, including with a subagent or terminal focused. Bugs found
during use are tracked and fixed as they arise; this list is not the earlier
milestone's formal acceptance gate.

## Not in 0.1.0

- Editable entry chords or app-specific mouse-mode bindings.
- Precision-speed controls, cursor snapping, coordinate macros, or
  accessibility-based named-UI-target actions.
- Dynamic Herdr configuration synchronization or semantic Herdr actions.
- A signed/notarized public artifact, Homebrew tap, or other distribution
  promise. These belong to a separate follow-on effort after the 0.1.0 app
  capability work; a later tap release may use a later app version.
