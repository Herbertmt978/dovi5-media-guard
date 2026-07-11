[Unit]
Description=Delete Dolby Vision Profile 5 media and queue Servarr recovery
After=network-online.target remote-fs.target
Wants=network-online.target remote-fs.target

[Service]
Type=oneshot
Environment=SERVARR_OUTBOX_DB=/var/lib/dovi5-frigate-ops/servarr-outbox.sqlite3
EnvironmentFile=__HOME_DIR__/dovi5-frigate-ops.env
Environment=FFPROBE_BIN=__FFPROBE_BIN__
Environment=FFMPEG_BIN=__FFMPEG_BIN__
ExecStart=__HOME_DIR__/move_dovi5_to_quarantine.sh
User=__TARGET_USER__
Group=media
WorkingDirectory=__HOME_DIR__
StateDirectory=dovi5-frigate-ops
StateDirectoryMode=0700
TimeoutStartSec=12h
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UMask=0077
