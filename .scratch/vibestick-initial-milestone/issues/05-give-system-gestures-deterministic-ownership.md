# 05: Give system gestures deterministic ownership

**What to build:** Route every controller input to exactly one owner while allowing the visible bindings overlay to observe pass-through input. Make short L3 invoke dictation, long L3 open the app wheel without also invoking dictation, and Share toggle the bindings overlay in every app context.

**Blocked by:** 04: Resolve app contexts and safe ordinary bindings.

**Status:** ready-for-agent

- [ ] Input ownership follows active capture, app wheel, pending system gesture, Herdr layer, then ordinary app binding.
- [ ] A short L3 emits the configured TypeWhisper keyboard shortcut exactly once.
- [ ] A long L3 opens the app wheel and does not emit the short-L3 action.
- [ ] Releasing L3 never activates an app.
- [ ] Share toggles the bindings overlay independently of the active app context.
- [ ] System bindings can be overridden or disabled without changing app profiles.
- [ ] Automated checks cover ownership precedence and short-versus-long L3 timing.
