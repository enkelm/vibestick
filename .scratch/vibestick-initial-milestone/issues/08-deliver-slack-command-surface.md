# 08: Deliver the Slack command surface

**What to build:** Provide the complete Slack preset for huddles, unread conversations, navigation, search, composition, Home, and Activity while retaining system-gesture precedence and sparse operator overrides.

**Blocked by:** 06: Make output lifecycle-safe and pausable.

**Status:** ready-for-agent

- [ ] Every Slack controller input emits the literal shortcut specified for the initial milestone.
- [ ] Short and long L3 and Share retain their system meanings in Slack.
- [ ] Operator overrides affect only the overridden Slack inputs and reset reveals the current preset or global fallback.
- [ ] Automated checks cover the complete Slack preset and precedence over global fallbacks.
