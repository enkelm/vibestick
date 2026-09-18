# 01: Create a testable command-routing seam

**What to build:** Refactor the prototype into independently testable input, configuration, app-context, routing, output, and presentation boundaries without intentionally changing current behavior. Replace embedded self-checks with an XCTest target so later slices can add deterministic evidence while the source-built app remains usable.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Input, configuration, app-context, routing, output, and presentation responsibilities have explicit boundaries that can be exercised without launching the full app.
- [ ] Existing Xbox report decoding, profile resolution, persistence, and radial-selection self-checks run as XCTest cases.
- [ ] The app builds and its existing source-built workflows remain available after the refactor.
