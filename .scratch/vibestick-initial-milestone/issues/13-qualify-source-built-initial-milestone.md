# 13: Qualify the source-built initial milestone

**What to build:** Provide and execute a repeatable source-build acceptance workflow for the complete initial milestone, including automated evidence and an operator-assisted physical workflow on the target controller. Correct failures discovered during qualification before declaring the milestone complete.

**Blocked by:** 07: Complete the explicit app wheel; 08: Deliver the Slack command surface; 09: Deliver the Herdr command surface and Herdr layer; 10: Add repeatable stick navigation and scrolling; 11: Make the bindings overlay a live pass-through trainer; 12: Complete bindings editing across every scope.

**Status:** ready-for-agent

- [ ] One documented workflow builds from source and runs all automated checks listed in the milestone specification.
- [ ] The physical workflow verifies Share, short and long L3, Herdr base and layer commands, navigation, scrolling, Ghostty isolation, Slack commands, and unknown-app safety.
- [ ] Manual checks cover Accessibility denied and granted, pause, disconnect and reconnect, app-context transitions, overlay pass-through, and configuration migration.
- [ ] The workflow confirms that Herdr's gamepad plugin is disabled without attempting to manage it.
- [ ] Failures discovered during qualification are fixed or recorded with precise reproducible evidence before completion.
