# 07: Complete the explicit app wheel

**What to build:** Let the operator explicitly select and activate one of up to eight other recently used running regular apps with the left stick and A, or cancel with B, while suppressing ordinary mappings for the entire wheel interaction.

**Blocked by:** 06: Make output lifecycle-safe and pausable.

**Status:** ready-for-agent

- [ ] Candidates exclude Vibestick and the current app, are deduplicated, and are limited to eight.
- [ ] Candidate order uses most recent use with alphabetical fallback.
- [ ] The wheel opens with no selection and retains its last selection when the stick returns to the dead zone.
- [ ] A explicitly activates the selected app and B cancels.
- [ ] L3 release does not activate an app.
- [ ] All ordinary mappings remain suppressed until the wheel interaction is complete.
- [ ] Automated checks cover ordering, selection, dead-zone retention, activation, cancellation, and suppression.
