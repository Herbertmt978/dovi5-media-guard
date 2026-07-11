# DoVi5 Media Guard

[![Verification](https://github.com/Herbertmt978/dovi5-media-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/Herbertmt978/dovi5-media-guard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Herbertmt978/dovi5-media-guard)](https://github.com/Herbertmt978/dovi5-media-guard/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Permanently remove Dolby Vision Profile 5 media that is unsuitable for your playback setup, then ask Sonarr or Radarr to find a replacement.

> [!CAUTION]
> This service **permanently deletes media files**. It has no quarantine, undo, recycle bin, or scanner preview mode. `SERVARR_DRY_RUN=1` aborts the scanner; it is not a simulation. Once configuration validation succeeds, the installer enables a timer that may become due immediately. Verify your backups, permissions, library mappings, and Servarr recovery flow before enabling it.

## Why this exists

In the maintainer's setup, Dolby Vision Profile 5 files do not play on an Apple TV 4K (3rd generation), and show broken pink/green colour on an NVIDIA Shield Pro. DoVi5 Media Guard turns that local playback policy into an automated delete-and-recover workflow.

That is a site-specific decision, not a claim that Profile 5 fails on every Apple TV, Shield, Plex client, television, or HDMI chain. The [pink/green Shield discussion that illustrates the symptom](https://www.reddit.com/r/nvidiashield/comments/qtmlyv/help_with_pinkgreen_hue_on_shield_pro/) also shows that display mode, player behaviour, cables, receivers, and source files can all matter. Diagnose your own chain before adopting this policy.

The project detects only `dvhe.05*`. It does not reject every Dolby Vision profile and it does not transcode media. See [Dolby's profile and level reference](https://professionalsupport.dolby.com/s/article/What-is-Dolby-Vision-Profile) for the format background.

## Install

The installer targets a Linux systemd host. Clone the repository on that host, then run:

```bash
git clone https://github.com/Herbertmt978/dovi5-media-guard.git
cd dovi5-media-guard
chmod +x install.sh move_dovi5_to_quarantine.sh
sudo ./install.sh
```

A fresh install creates `/home/frigate/dovi5-frigate-ops.env` with mode `0600` and leaves the timer disabled because the example has blank API keys. Edit it, verify every path and endpoint, then rerun the installer:

```bash
sudoedit /home/frigate/dovi5-frigate-ops.env
sudo ./install.sh
```

The old `dovi5-frigate-ops` filenames and systemd unit names are deliberately retained so existing installations can upgrade without a state migration.

### Trust and permission surface

| Concern | Behaviour |
| --- | --- |
| Media changes | Deletes only the selected source file; it does not remove sidecars or directories. |
| Installed files | Installs the scanner, recovery CLI, Python package, owner-only environment file, and two systemd units. |
| State | Writes a TSV cache, SQLite recovery outbox, logs, and optional Servarr backups. The service uses `UMask=0077` for new files. systemd sets `/var/lib/dovi5-frigate-ops` to mode `0700` and the configured service identity; existing log/state file modes elsewhere are not repaired, so audit upgrades. |
| Network | Contacts only the configured Sonarr/Radarr APIs. The installer may use `apt-get` when MediaInfo or FFmpeg is missing. There is no telemetry. |
| Servarr changes | Recovery can mark a correlated grab failed/blocklisted and submit rescan/search commands. The optional `--apply` helper creates or updates a custom format and rewrites matching quality profiles. |
| Privileges | Installation requires root. The scanner runs as the target user with group `media`, and therefore needs traversal and delete access to all four library roots. |
| Disable | `sudo systemctl disable --now move-dovi5-to-quarantine.timer` prevents new scheduled scans. Never stop an active scanner midway through a run. |
| Uninstall | After any active scan finishes, remove the installed scripts/package and systemd units shown below. Keep the environment, state, logs, and backups until you have decided whether they are still needed. |

<details>
<summary><b>Uninstall commands</b></summary>

```bash
sudo systemctl disable --now move-dovi5-to-quarantine.timer
systemctl is-active move-dovi5-to-quarantine.service
# Continue only after the service reports inactive.
sudo rm -f /etc/systemd/system/move-dovi5-to-quarantine.service
sudo rm -f /etc/systemd/system/move-dovi5-to-quarantine.timer
sudo rm -f /home/frigate/move_dovi5_to_quarantine.sh
sudo rm -f /home/frigate/servarr_outbox.py
sudo rm -rf /home/frigate/dovi5_ops
sudo systemctl daemon-reload
```

If you installed for another account, replace `/home/frigate` with that account's home. The commands intentionally do not remove `/home/<user>/dovi5-frigate-ops.env`, `/var/lib/dovi5-frigate-ops`, or your configured log/backup directory.

</details>

## Requirements

- Linux with systemd, GNU userland tools (`find`, `head`, `timeout`, `realpath`, `getent`), and util-linux tools (`flock`, `mountpoint`, `runuser`). A non-root installer invocation also needs `sudo`.
- Python 3.10 or newer.
- MediaInfo plus a matched FFmpeg/FFprobe pair with H.264 and HEVC decoders and Matroska and MP4 demuxers. The installer can add distro packages with `apt-get` when they are missing.
- An existing target account (default `frigate`) with `/home/<TARGET_USER>` and an existing `media` group.
- One mounted media filesystem and exactly four distinct, non-overlapping library directories beneath it. The fixed configuration labels can point at paths of your choice.
- Four Sonarr/Radarr mappings whose library paths exactly match roots configured in those applications. Multiple mappings may use the same Servarr instance.
- Reliable backups and filesystem permissions that allow the service account to traverse and delete media.
- Write/create access for the service account to `LOG_DIR`. Its legacy default, `/mnt/media/_orphaned_quarantine`, holds logs and TSV state (and is the helper's default backup directory); media is never moved there.

Use another service account when needed:

```bash
sudo TARGET_USER=mediaops ./install.sh
```

To use a trusted service-only FFmpeg build without replacing host tools, install a matched pair beneath a root-owned path and select it during installation:

```bash
sudo VALIDATOR_FFPROBE_BIN=/opt/dovi5-frigate-ops/toolchain/ffprobe \
  VALIDATOR_FFMPEG_BIN=/opt/dovi5-frigate-ops/toolchain/ffmpeg \
  ./install.sh
```

The installer canonicalizes and validates those executables, writes them only to the root-owned unit, and preserves the selected pair on later upgrades unless you explicitly replace it.

## Configure

The deployed environment file is the source of truth. Start with paths and endpoints like these:

```bash
MEDIA_MOUNTPOINT=/mnt/media
PLEX_TV_DIR=/mnt/media/PlexTV
PLEX_TVHD_DIR=/mnt/media/PlexTVHD
PLEX_FILMS_DIR=/mnt/media/PlexFilms
PLEX_FILMSHD_DIR=/mnt/media/PlexFilmsHD

SONARR_TV_URL=http://sonarr.example.invalid:8989
SONARR_TV_API_KEY=
SONARR_TVHD_URL=http://sonarr-hd.example.invalid:8989
SONARR_TVHD_API_KEY=
RADARR_FILMS_URL=http://radarr.example.invalid:7878
RADARR_FILMS_API_KEY=
RADARR_FILMSHD_URL=http://radarr-hd.example.invalid:7878
RADARR_FILMSHD_API_KEY=
```

Keep API keys only in the deployed mode-`0600` file, never in Git or issue reports. Defaults for timeouts, minimum file age, state compaction, and the validation-deletion circuit breaker are documented in [`dovi5-frigate-ops.env.example`](dovi5-frigate-ops.env.example). Every scanner timeout must be greater than zero; GNU `timeout` treats zero as having no deadline, so the scanner rejects it.

Check configuration and API access without printing keys:

```bash
sudo -u frigate python3 /home/frigate/servarr_outbox.py \
  --env-file /home/frigate/dovi5-frigate-ops.env check-config --verify-api
```

## What happens during a scan

The scanner walks `.mkv`, `.mp4`, and `.m4v` files once. Files ending in `.sdr.mkv` or `.sdr.tmp.mkv` are always ignored.

| Result | Action |
| --- | --- |
| File is younger than `MIN_FILE_AGE_SECONDS`, is changing, or has an inconclusive I/O/tool error | Retain it. |
| Unchanged file is durably cached as not Profile 5 | Skip the expensive probes. |
| First stable MediaInfo failure or no primary video stream | Record the complete fingerprint and retain it for one retry. |
| Same unchanged file fails again | Validate the container/video stream with FFprobe and software-decode one frame with FFmpeg. |
| MediaInfo or FFprobe positively identifies `dvhe.05*` | Durably enqueue recovery, recheck the fingerprint, then permanently delete it. Profile 5 deletion intentionally bypasses the validation-deletion cap. |
| Retry confirms an invalid header, no real video stream, or a recognised decode corruption | Make it a validation-derived deletion candidate. |
| Validation candidates exceed `MAX_VALIDATION_DELETIONS_PER_RUN` | Delete none of those candidates and exit non-zero. |
| Timeout, out-of-memory/signal exit, permission/NFS I/O failure, unsupported decoder, missing/changing file, or unknown validator result | Retain it. |
| Recovery enqueue fails or the final fingerprint changes | Retain it. |
| `rm` fails | If the original fingerprint is still present, cancel recovery and retain the source. If that fingerprint cannot be confirmed because the path is missing or replaced, keep recovery queued. |
| Servarr becomes unavailable after enqueue | The file may already be deleted; retain the durable recovery job and exit non-zero. |

Only the source path is deleted. Sidecars and now-empty directories are left alone.

<details>
<summary><b>Validation limits</b></summary>

The validator proves only that the local container and primary video stream can be inspected and that the installed FFmpeg can software-decode one sampled frame. It does not perform full playback, test every frame, inspect audio/subtitle compatibility, or emulate Plex/Infuse routing, licensed Dolby Vision rendering, Apple TV or Shield hardware decoders, HDMI, an AVR, or a display.

Having the right codecs on the Linux host therefore does **not** prove Apple TV or Shield compatibility. Profile 5 remains a separate deletion policy based on your observed playback. A narrow race remains between the final fingerprint check and filesystem deletion; changing media in place while a scan runs is unsupported. A userspace deadline also cannot terminate Linux I/O stuck in an uninterruptible kernel state, so network mounts still need suitable client and server timeouts.

Tabs and newlines in filenames are handled by null-delimited enumeration and an independent re-probe before deletion.

</details>

## Sonarr, Radarr, and Plex

Sonarr or Radarr is the recovery owner for every configured library. Before deletion, the scanner commits an at-least-once recovery job to SQLite. The worker then:

1. Maps the exact deleted path to a series/episode or movie.
2. Searches the newest 250 history records for the exact import path and download ID, then correlates it with the matching grabbed event.
3. Marks a correlated grab as failed/blocklisted so the same release is less likely to be selected again.
4. Requests a rescan and waits for a successful result.
5. Requests an episode/season/series or movie search.
6. Retains the job until the replacement search succeeds.

Older or manually imported files may have no usable import-to-grab correlation. They still receive the rescan/search flow, but cannot be blocklisted reliably. At-least-once delivery means a retry can repeat a safe Servarr command.

Plex is only a consumer of the same filesystem. This project does not use the Plex API, refresh a Plex library, empty Plex trash, or test Plex playback. The `PLEX_*` setting names are retained for compatibility and can point at any four libraries backed by Sonarr/Radarr.

See the [Servarr wiki](https://wiki.servarr.com/) for Sonarr/Radarr administration and [Plex's Dolby Vision support pages](https://support.plex.tv/tag/dolby-vision/) for current Plex guidance.

## Prevent future grabs (optional)

`tools/configure_servarr_dovi_filter.py` can create a `DV (w/o HDR fallback)` custom format and assign score `-10000` to quality profiles that contain an allowed 2160p/UHD quality.

```bash
# Read-only preview of the proposed custom-format/profile changes
sudo -u frigate -- python3 "$PWD/tools/configure_servarr_dovi_filter.py" \
  --env-file /home/frigate/dovi5-frigate-ops.env

# Apply only after reviewing the preview and backup location
sudo -u frigate -- python3 "$PWD/tools/configure_servarr_dovi_filter.py" \
  --env-file /home/frigate/dovi5-frigate-ops.env \
  --apply
```

Run these commands from a trusted checkout that the target account can read, and ensure the backup directory is writable by that account. This helper is preventive, not authoritative Profile 5 detection. It uses a TRaSH-style release-title/source heuristic, does not inspect downloaded media, does not set a quality profile's minimum custom-format score, and is not transactional across instances. Review the dry run, score, targeted profiles, and generated owner-only JSON backup first. By default it targets the primary Sonarr and Radarr mappings; `--include-hd-instances` includes the other two.

For broader custom-format design, see the TRaSH Guides collections for [Sonarr](https://trash-guides.info/Sonarr/sonarr-collection-of-custom-formats/) and [Radarr](https://trash-guides.info/Radarr/Radarr-collection-of-custom-formats/).

## Operate and recover

```bash
systemctl status move-dovi5-to-quarantine.timer
systemctl status move-dovi5-to-quarantine.service
journalctl -u move-dovi5-to-quarantine.service
sudo -u frigate python3 /home/frigate/servarr_outbox.py count
```

The first run after upgrading from the legacy state format deliberately revalidates every media file because an earlier probe failure could otherwise be cached as safe. On a large NFS library this can take hours. Later runs still perform a full metadata walk, but unchanged files avoid MediaInfo and the independent validator.

The timer runs 10 minutes after boot, 15 minutes after activation, and 15 minutes after each completed scan. During an upgrade, the installer stops the timer and waits as long as 12 hours for an active scan to finish; it does not kill the scanner.

## Privacy and security

- The project has no telemetry. Runtime network requests go only to configured Sonarr/Radarr endpoints.
- Logs and the systemd journal include the hostname, complete media paths, validation results, and deletion events.
- The TSV cache and SQLite outbox store canonical media paths and fingerprints. Optional JSON backups contain Servarr custom-format and quality-profile configuration.
- Protect the service account's home, `/var/lib/dovi5-frigate-ops`, the configured log/backup directory, and exported support logs. Redact hostnames, paths, and API keys before sharing diagnostics.
- API redirects are rejected to avoid forwarding a key to another destination.

Report vulnerabilities through [GitHub's private vulnerability reporting](https://github.com/Herbertmt978/dovi5-media-guard/security/advisories/new), following [`SECURITY.md`](SECURITY.md). Do not open a public issue containing an API key, media path, hostname, or private network address.

## Development

```bash
bash tests/test_move_dovi5_to_quarantine.sh
bash tests/test_timer_cadence.sh
bash tests/test_install.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
ruff check .
ruff format --check .
bandit -q -r dovi5_ops servarr_outbox.py tools
```

CI also runs Bash syntax checks, ShellCheck, Python compilation, `systemd-analyze verify`, and pinned static-analysis tools.

### Repository layout

- `move_dovi5_to_quarantine.sh` — scanner and destructive safety boundary
- `servarr_outbox.py` — recovery-queue CLI
- `dovi5_ops/` — configuration, Servarr transport, schema, and durable outbox
- `dovi5-frigate-ops.env.example` — deployment configuration template
- `systemd/` — service and timer units
- `install.sh` — guarded install and upgrade lifecycle
- `tools/configure_servarr_dovi_filter.py` — optional preventive custom-format helper
- `tests/` — scanner, outbox, installer, timer, and helper regression tests

## License

Released under the [MIT License](LICENSE).
