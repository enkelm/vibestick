# 09: Deliver the Herdr command surface and Herdr layer

**What to build:** Provide the complete Herdr base preset and alternate Herdr layer on positively identified Herdr surfaces. Support both holding Back with another control and tapping Back to arm the next control for two seconds, without emitting partial shortcuts.

**Blocked by:** 06: Make output lifecycle-safe and pausable.

**Status:** ready-for-agent

- [ ] Every Herdr base input emits the literal shortcut specified for the initial milestone.
- [ ] Holding Back while pressing another configured control executes the corresponding Herdr-layer action.
- [ ] Tapping Back arms the Herdr layer for two seconds; a valid second input executes once.
- [ ] Tapping Back again cancels an armed layer, and timeout emits nothing.
- [ ] Vibestick emits the complete configured shortcut only after a valid second input.
- [ ] Ordinary Ghostty never receives Herdr base or layer commands.
- [ ] Automated checks cover hold, arm, cancellation, timeout, and context isolation.
