# 10: Add repeatable stick navigation and scrolling

**What to build:** Add repeatable left-stick arrow navigation and right-stick scrolling to the supported app contexts using centralized initial tuning and the current Mac's natural-scrolling direction.

**Blocked by:** 08: Deliver the Slack command surface; 09: Deliver the Herdr command surface and Herdr layer.

**Status:** ready-for-agent

- [ ] Left-stick directions repeat the configured arrow-key actions after a 400 ms delay at an 80 ms interval outside a 0.25 dead zone.
- [ ] Right-stick movement produces repeatable scrolling that follows the current natural-scrolling setting.
- [ ] Herdr, ordinary Ghostty, and Slack receive the stick behavior specified for their app contexts.
- [ ] Repeat and scrolling stop on release, pause, disconnect, app-context transition, or entry into a higher-priority mode.
- [ ] Initial tuning values have one source of truth and persist through the versioned configuration.
- [ ] Automated checks cover dead-zone behavior, timing, direction, and cancellation.
