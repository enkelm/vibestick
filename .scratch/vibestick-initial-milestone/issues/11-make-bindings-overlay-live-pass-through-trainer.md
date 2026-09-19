# 11: Make the bindings overlay a live pass-through trainer

**What to build:** Make the bindings overlay a translucent training surface that follows the active app context, shows resolved bindings and live controller state, and allows normal controller behavior to continue while the overlay is merely visible.

**Blocked by:** 07: Complete the explicit app wheel; 10: Add repeatable stick navigation and scrolling.

**Status:** claimed

- [ ] Share toggles the overlay and is the only controller input consumed by a merely visible overlay.
- [ ] Buttons, sticks, scrolling, and the app wheel continue to work while the training overlay is visible.
- [ ] The overlay follows app-context changes and displays the currently resolved bindings.
- [ ] The controller visualization updates live even when mapped output is unavailable or paused.
- [ ] The underlying app remains visible and the overlay becomes more opaque for pointer interaction.
- [ ] The menu-bar command can open the overlay when Share is cleared or misconfigured.
