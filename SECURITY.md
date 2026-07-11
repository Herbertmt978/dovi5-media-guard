# Security policy

## Supported versions

Security fixes are provided for the latest published release.

| Version | Supported |
| --- | --- |
| 1.1.x | Yes |
| Earlier | No |

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/Herbertmt978/dovi5-media-guard/security/advisories/new). Please do not open a public issue for a suspected vulnerability.

Include the affected version, a minimal reproduction, impact, and any suggested mitigation. Remove API keys, credentials, media titles and paths, hostnames, private network addresses, and unrelated log content before submitting evidence.

You should receive an acknowledgement within seven days. A fix and disclosure timeline will depend on severity and reproducibility. Please allow a reasonable period for investigation and remediation before public disclosure.

## Operational secrets

The deployed environment file contains Sonarr/Radarr API keys and must remain mode `0600`. Logs, the systemd journal, state files, the SQLite outbox, and optional backups can reveal media paths or configuration. Treat them as private operational data.
