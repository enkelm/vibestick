# Vibestick

Vibestick is a macOS command surface for using an Xbox controller as a secondary input during agentic development and adjacent communication workflows.

## Language

**Agentic development**:
A software-development workflow in which a person directs and collaborates with coding agents, initially through Herdr.

**Secondary input**:
A controller input that complements keyboard, pointer, and voice input rather than replacing them.
_Avoid_: Primary input, keyboard replacement

**Emergency pause**:
A session-only safety state that suspends mapped output while preserving system-level recovery surfaces and live controller visualization; a new launch starts active.
_Avoid_: Output disabled, observe-only mode

**Target controller**:
The Xbox Wireless Controller with Share used to validate Vibestick's initial behavior; support for other controllers is outside the initial product boundary.
_Avoid_: Generic gamepad, every Xbox controller

**Dictation**:
Speech-to-text input that an external dictation app delivers to the currently focused text field.
_Avoid_: Text-to-speech, voice output

**Herdr surface**:
A focused, Herdr-managed development environment presented inside Ghostty; it is distinct from an ordinary Ghostty shell and is Vibestick's initial and primary command context.
_Avoid_: Herder, Ghostty profile

**App context**:
The focused app or distinguishable surface used to choose an app profile and preset; Herdr and ordinary Ghostty are separate app contexts.
_Avoid_: Window title, bundle ID

**System binding**:
A globally configured controller gesture that remains available in every app context and takes precedence over app-specific commands.
_Avoid_: App binding, preset

**App wheel**:
A system-level radial selector for explicitly activating one of the eight most recently used running apps other than the current app.
_Avoid_: App profile, automatic app switcher

**Bindings overlay**:
The translucent training view and keyboard-and-mouse editor for observing and overriding mappings by system, global, focused-app, and Herdr-layer scope; while merely visible, it consumes only Share and lets other controller input pass through.
_Avoid_: App wheel, preset

**App profile**:
An operator's sparse set of button overrides for one app context, layered over that context's preset and the global defaults.
_Avoid_: Complete keymap, preset

**Preset**:
Vibestick's built-in default bindings for a supported app context; untouched preset bindings can evolve without replacing operator overrides.
_Avoid_: App profile, hard-coded profile

**Herdr layer**:
The alternate Herdr button map armed by holding Back or by tapping Back before the next controller input.
_Avoid_: Overlay, app profile
