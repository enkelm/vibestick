# 12: Complete bindings editing across every scope

**What to build:** Let the operator edit system bindings, global fallbacks, the pinned focused-app profile, the focused Herdr context's Herdr layer, and stick and scroll behavior with keyboard and pointer input while mapped controller output is safely suspended.

**Blocked by:** 03: Migrate to the versioned sparse configuration; 09: Deliver the Herdr command surface and Herdr layer; 10: Add repeatable stick navigation and scrolling; 11: Make the bindings overlay a live pass-through trainer.

**Status:** ready-for-agent

- [ ] The editor exposes every configurable scope in the milestone.
- [ ] Each binding identifies whether it comes from a preset, global fallback, or operator override.
- [ ] The operator can clear or override a binding and reset one binding or an entire app profile.
- [ ] Resetting a sparse override reveals the current preset or global fallback.
- [ ] Starting editing or key capture pins the edited app context and suspends mapped controller output.
- [ ] Live controller visualization continues during editing and pass-through resumes after editing ends.
- [ ] Saved edits survive relaunch through the versioned configuration.
