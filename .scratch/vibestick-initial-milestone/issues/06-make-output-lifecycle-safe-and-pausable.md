# 06: Make output lifecycle-safe and pausable

**What to build:** Start mapped output automatically while keeping it safe across missing Accessibility permission, emergency pause, controller disconnect and reconnect, app-context changes, and application shutdown. Preserve system-level recovery surfaces whenever ordinary output is unavailable.

**Blocked by:** 05: Give system gestures deterministic ownership.

**Status:** ready-for-agent

- [ ] Output is active on launch and pause resets to active on the next launch.
- [ ] First run requests Accessibility permission, while denied permission leaves the app wheel, bindings overlay, and status UI usable.
- [ ] Emergency pause disables app shortcuts, Herdr-layer actions, dictation, repeats, and scrolling while preserving Share, the app wheel, menu controls, and live visualization.
- [ ] Disconnect and app-context transitions release active output, clear held controls, stop continuous output, and cancel transient modes.
- [ ] Reconnect resumes active operation without another menu action.
- [ ] The menu bar reports controller, Accessibility, output, and app-context status.
- [ ] Automated checks cover pause, disconnect, reconnect, and app-context transition state.
