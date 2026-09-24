# 04: Resolve app contexts and safe ordinary bindings

**What to build:** Resolve controller input through the active app context using operator override, preset, global fallback, then unbound. Positively distinguish a Herdr surface from ordinary Ghostty, fail closed to ordinary Ghostty, provide the conservative Ghostty preset, and keep ordinary controls inert in unknown apps.

**Blocked by:** 02: Recognize every target-controller input; 03: Migrate to the versioned sparse configuration.

**Status:** wontfix

- [x] App contexts distinguish Herdr, ordinary Ghostty, supported regular apps, and unknown apps without relying on bundle ID alone.
- [x] Failure to positively identify a Herdr surface selects ordinary Ghostty.
- [x] Binding resolution follows operator override, preset, global fallback, then unbound.
- [x] The ordinary Ghostty preset matches the milestone specification and contains no destructive close-surface default.
- [x] Unknown apps receive no ordinary default key or scroll output.
- [x] Automated checks cover context classification, sparse overrides, reset behavior, and the complete Ghostty preset.

## Comments

Closed as implemented at the operator's request. `CommandRoutingTests` covers
classification, positive Herdr evidence, fail-closed ordinary Ghostty,
resolution precedence, sparse overrides, reset, unknown-app defaults, and the
complete Ghostty preset. The paired session confirmed Herdr recognition inside
agent panes and ordinary Ghostty isolation. Unknown-app behavior was tested
automatically but not physically qualified in the unfinished milestone run;
ticket 13 retains that distinction.
