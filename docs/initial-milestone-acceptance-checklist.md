# Initial milestone physical acceptance record

This file belongs to one `acceptance.sh` evidence directory. Check an item only
after observing it on the target setup. Put supporting files beside this file
and link or name them under Notes.

## Run metadata

- Operator:
- UTC date and time:
- Git commit (copy from `environment.txt`):
- Evidence directory:
- Mac model and macOS:
- Controller name and Bluetooth identifiers:
- Herdr version:
- Ghostty version:
- Slack version:
- TypeWhisper version:

## Preconditions

- [ ] `result.txt` says `outcome=PASS`.
- [ ] The target Xbox Wireless Controller with Share is connected through
      Bluetooth Low Energy (`045E:0B13`) and its USB cable is disconnected.
- [ ] TypeWhisper toggles from the physical
      Command-Control-Option-Shift-backtick shortcut.
- [ ] I confirmed through Herdr's own configuration or status surface that
      Herdr's gamepad plugin is disabled.
- [ ] Vibestick did not change or attempt to manage the Herdr plugin.

USB `045E:0B12` is not qualified for Share and must not be used for this run.

Plugin confirmation method and evidence:

## Accessibility denied

Start with Vibestick absent from, or disabled in, System Settings > Privacy &
Security > Accessibility.

- [ ] First launch requests Accessibility permission.
- [ ] The menu reports that Accessibility is required.
- [ ] Share still opens and closes the bindings overlay.
- [ ] Long L3 still opens the app wheel; B cancels it.
- [ ] Keyboard shortcuts and scrolling are not emitted.
- [ ] The controller visualization remains live.

## Accessibility granted and system gestures

Grant Accessibility to this exact source-built `Vibestick.app`, then relaunch
it.

- [ ] The menu reports Accessibility granted and mapped output active.
- [ ] A short L3 press toggles TypeWhisper exactly once and does not open the
      app wheel.
- [ ] Holding L3 opens the app wheel and does not toggle TypeWhisper.
- [ ] Releasing L3 does not activate an app; A explicitly activates the
      selected app and B cancels.
- [ ] Share reliably toggles the bindings overlay.
- [ ] With the overlay visible, a normal mapped button still reaches the
      focused app and the visualization updates.
- [ ] Entering binding editing or capture suspends mapped output; ending it
      restores pass-through.

## Herdr surface

Focus a positively identified Herdr surface in Ghostty.

- [ ] A, B, and X emit Return, Space, and Escape.
- [ ] Y opens the Herdr session navigator.
- [ ] LT/RT select the previous/next agent.
- [ ] LB/RB select the previous/next tab.
- [ ] Start selects the next workspace.
- [ ] Every D-pad direction focuses the matching pane.
- [ ] Holding the left stick past the dead zone emits an immediate arrow,
      pauses, then repeats; returning to center stops it.
- [ ] The right stick scrolls repeatedly in both axes and agrees with the
      Mac's natural-scrolling setting.
- [ ] Holding Back with each mapped control executes the matching Herdr action:
      A zoom, B vertical split, Y horizontal split, X last pane, RB new tab,
      Start previous workspace, LB sidebar, RT help, and LT settings.
- [ ] Tapping Back arms one layer action for two seconds.
- [ ] Tapping Back again cancels the armed layer.
- [ ] Letting the armed layer time out emits no command.

## Ordinary Ghostty isolation

Focus an ordinary Ghostty terminal that is not positively identified as Herdr.

- [ ] A/B/X/Y emit Return, Space, Escape, and Tab.
- [ ] LB/RB switch Ghostty tabs and Start creates a new Ghostty tab.
- [ ] D-pad and sticks navigate and scroll as documented.
- [ ] LT, RT, R3, and Back emit nothing.
- [ ] No Herdr base or Back-layer command is emitted.
- [ ] No default control closes a terminal surface.

## Slack

Focus Slack and observe the result of every command.

- [ ] A starts, joins, leaves, or ends a huddle.
- [ ] B marks the conversation read or dismisses the current surface.
- [ ] X opens the quick conversation switcher; Y opens compose.
- [ ] LB/RB select the previous/next unread conversation.
- [ ] LT opens all unreads; RT opens search; R3 toggles huddle mute.
- [ ] D-pad up/down select the previous/next conversation.
- [ ] D-pad left/right move backward/forward in history.
- [ ] Back opens Home; Start opens Activity.
- [ ] Left-stick navigation and right-stick scrolling repeat and stop at center.
- [ ] Share and short/long L3 retain their system meanings.

## Unknown-app safety

Focus an app with no built-in preset or operator profile and place the caret in
an editable text field.

- [ ] Ordinary buttons, triggers, D-pad, and sticks emit no key or scroll
      output.
- [ ] Share and short/long L3 retain their configured system meanings.

## Lifecycle and app-context transitions

- [ ] Emergency pause immediately stops shortcuts, Herdr-layer actions,
      dictation, repeats, and scrolling.
- [ ] While paused, Share, the app wheel, menu controls, and live visualization
      remain available.
- [ ] Resuming re-enables mapped output; quitting while paused and relaunching
      starts active.
- [ ] Disconnecting while a control is held immediately releases output,
      closes the wheel, and cancels repeats and the Back layer.
- [ ] Reconnecting resumes active operation without another menu action.
- [ ] Changing from Herdr to ordinary Ghostty while a control is held releases
      old output and requires fresh input in the new context.
- [ ] Changing among Ghostty, Slack, and an unknown app updates the menu and
      overlay context without leaking the previous app's command.

## Configuration migration

Quit Vibestick. Back up the operator's existing
`~/Library/Application Support/Vibestick/config.json` outside that directory.
Use a disposable prototype configuration containing recognizable global and
app overrides, then launch the same source-built app.

- [ ] The app reports a one-time migration and the backup path.
- [ ] Recognizable global and app overrides remain effective.
- [ ] The migrated file uses the current versioned schema.
- [ ] The original prototype file remains at the reported backup path.
- [ ] Any skipped entry is reported with its configuration path and reason.
- [ ] A second launch loads the migrated schema without migrating again.
- [ ] I quit Vibestick, restored the operator's original configuration, and
      verified it loads.

## Completion

- [ ] Every failed check has precise reproduction evidence in Notes.
- [ ] Every item above passes, or the run is explicitly recorded as failed.
- [ ] Final physical outcome: **PASS** / **FAIL** (delete one)

## Notes and failure evidence
