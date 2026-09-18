# 03: Migrate to the versioned sparse configuration

**What to build:** Persist system bindings, global fallback bindings, app profiles, Herdr-layer overrides, and stick mappings in one versioned sparse configuration. Upgrade prototype configurations once, preserve recognizable overrides, and make skipped entries recoverable and visible to the operator.

**Blocked by:** 01: Create a testable command-routing seam.

**Status:** ready-for-agent

- [ ] The persisted configuration has an explicit schema version and represents every configurable scope in the milestone.
- [ ] App profiles and Herdr-layer overrides remain sparse rather than copying presets into operator configuration.
- [ ] A one-time migration preserves recognizable prototype global and app overrides.
- [ ] An incomplete migration retains a backup of the old configuration and reports skipped entries.
- [ ] Automated checks cover clean load, save and reload, successful migration, partial migration, and unsupported future versions.
- [ ] Runtime behavior reads only the new schema after migration.
