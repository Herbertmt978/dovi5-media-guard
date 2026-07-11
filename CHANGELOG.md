# Changelog

All notable changes to this project are documented here.

## [1.1.1] - 2026-07-11

### Fixed

- Bounded the Matroska header probe and rejected zero-valued probe timeouts, which GNU `timeout` otherwise treats as having no deadline.

## [1.1.0] - 2026-07-11

### Added

- One retained retry followed by bounded FFprobe/FFmpeg validation for structurally invalid or reproducibly undecodable media.
- Durable Sonarr/Radarr recovery with failed-grab correlation, rescan, replacement search, and retryable SQLite jobs.
- Safe installer upgrades that wait for an active scan, validate the host toolchain, and preserve an existing environment file.
- Public release documentation, MIT licensing, security reporting guidance, and privacy disclosures.

### Changed

- Renamed the public project to **DoVi5 Media Guard** while retaining legacy runtime filenames and systemd unit names for upgrade compatibility.
- Profile 5 remains an immediate permanent-deletion policy; validation-derived deletions use an all-or-nothing circuit breaker.
- New runtime state, locks, and backups use owner-only defaults; environment permissions are repaired with safer atomic replacement. Existing log/state permissions should be audited after upgrade.
- Servarr API helpers reject redirects and unsafe URL forms so credentials are not forwarded unexpectedly.

### Security

- Added clean-history publication, secret scanning, pinned CI actions, static analysis, and hardened credential/backup handling.

## [1.0.0] - 2026-07-10

- Initial private deployment of the Profile 5 delete-and-recover scanner.

[1.1.1]: https://github.com/Herbertmt978/dovi5-media-guard/releases/tag/v1.1.1
[1.1.0]: https://github.com/Herbertmt978/dovi5-media-guard/releases/tag/v1.1.0
