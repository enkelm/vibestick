# 02: Recognize every target-controller input

**What to build:** Make the target controller produce one normalized event stream for every required button, trigger, stick, connection event, and Share. Validate Apple's Share-button support on the physical controller, select the simplest complete input backend, and prevent duplicate events if more than one framework is required.

**Blocked by:** 01: Create a testable command-routing seam.

**Status:** ready-for-agent

- [ ] Automated checks cover decoding and normalization for all required controls that can be represented without physical hardware.
- [ ] A diagnostic workflow demonstrates whether Game Controller alone exposes every required control, including Share, on target controller `045E:0B12`.
- [ ] If multiple input sources are required, one physical gesture produces exactly one normalized event.
- [ ] Connect and disconnect events are exposed to the rest of the app.
