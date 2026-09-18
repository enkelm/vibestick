# 04: Resolve app contexts and safe ordinary bindings

**What to build:** Resolve controller input through the active app context using operator override, preset, global fallback, then unbound. Positively distinguish a Herdr surface from ordinary Ghostty, fail closed to ordinary Ghostty, provide the conservative Ghostty preset, and keep ordinary controls inert in unknown apps.

**Blocked by:** 02: Recognize every target-controller input; 03: Migrate to the versioned sparse configuration.

**Status:** ready-for-agent

- [ ] App contexts distinguish Herdr, ordinary Ghostty, supported regular apps, and unknown apps without relying on bundle ID alone.
- [ ] Failure to positively identify a Herdr surface selects ordinary Ghostty.
- [ ] Binding resolution follows operator override, preset, global fallback, then unbound.
- [ ] The ordinary Ghostty preset matches the milestone specification and contains no destructive close-surface default.
- [ ] Unknown apps receive no ordinary default key or scroll output.
- [ ] Automated checks cover context classification, sparse overrides, reset behavior, and the complete Ghostty preset.
