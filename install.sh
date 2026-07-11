#!/usr/bin/env bash
set -Eeuo pipefail

# INSTALL_SOURCE_ROOT, INSTALL_HOME_ROOT, INSTALL_SYSTEMD_ROOT,
# INSTALL_DEFAULT_MEDIA_MOUNTPOINT, INSTALL_VALIDATION_PATH, and
# INSTALL_EUID_OVERRIDE are narrow test seams. Their production defaults retain
# the system paths, a fixed validation PATH, and the caller EUID.
SOURCE_ROOT="${INSTALL_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
TARGET_USER="${TARGET_USER:-frigate}"
HOME_ROOT="${INSTALL_HOME_ROOT:-/home}"
SYSTEMD_ROOT="${INSTALL_SYSTEMD_ROOT:-/etc/systemd/system}"
DEFAULT_MEDIA_MOUNTPOINT="${INSTALL_DEFAULT_MEDIA_MOUNTPOINT:-/mnt/media}"
CURRENT_EUID="${INSTALL_EUID_OVERRIDE:-$EUID}"
VALIDATION_PATH="${INSTALL_VALIDATION_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
INSTALL_WAIT_SECONDS="${INSTALL_WAIT_SECONDS:-43200}"
INSTALL_POLL_SECONDS="${INSTALL_POLL_SECONDS:-5}"

SERVICE_UNIT="move-dovi5-to-quarantine.service"
TIMER_UNIT="move-dovi5-to-quarantine.timer"
HOME_DEST="${HOME_ROOT%/}/${TARGET_USER}"
SCRIPT_DEST="$HOME_DEST/move_dovi5_to_quarantine.sh"
CLI_DEST="$HOME_DEST/servarr_outbox.py"
PACKAGE_DEST="$HOME_DEST/dovi5_ops"
ENV_DEST="$HOME_DEST/dovi5-frigate-ops.env"
SERVICE_DEST="${SYSTEMD_ROOT%/}/$SERVICE_UNIT"
TIMER_DEST="${SYSTEMD_ROOT%/}/$TIMER_UNIT"

STAGE_DIR=""
TIMER_STOPPED=0
ATOMIC_TEMP=""
FFPROBE_EXPLICIT=0
FFMPEG_EXPLICIT=0
FFPROBE_BIN=""
FFMPEG_BIN=""

die() {
    echo "ERROR: $*" >&2
    exit 1
}

run_privileged() {
    if [[ "$CURRENT_EUID" == "0" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_as_target() {
    if [[ "$CURRENT_EUID" == "0" ]]; then
        runuser -u "$TARGET_USER" -- "$@"
    else
        sudo -u "$TARGET_USER" -- "$@"
    fi
}

is_safe_executable_path() {
    local path="$1"
    [[ "$path" =~ ^/[A-Za-z0-9_./:+-]+$ && -f "$path" && -x "$path" ]]
}

canonical_explicit_executable() {
    local selector="$1"
    local path="$2"
    local canonical

    [[ "$path" == /* ]] || die "$selector must be an absolute path"
    is_safe_executable_path "$path" || die "$selector must name a safe existing executable"
    canonical="$(PATH="$VALIDATION_PATH" realpath -e -- "$path")" \
        || die "$selector could not be resolved"
    is_safe_executable_path "$canonical" \
        || die "$selector resolved to an unsafe or unusable executable"
    printf '%s\n' "$canonical"
}

read_installed_validator_path() {
    local variable_name="$1"
    local prefix="Environment=$variable_name="
    local line value=""

    [[ -f "$SERVICE_DEST" ]] || return 1
    while IFS= read -r line; do
        if [[ "$line" == "$prefix"* ]]; then
            value="${line#"$prefix"}"
        fi
    done <"$SERVICE_DEST"
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

resolve_validator_executable() {
    local name="$1"
    local path

    path="$(PATH="$VALIDATION_PATH" command -v "$name" 2>/dev/null)" || return 1
    [[ "$path" == /* ]] || return 1
    path="$(PATH="$VALIDATION_PATH" realpath -e -- "$path")" || return 1
    is_safe_executable_path "$path" || return 1
    printf '%s\n' "$path"
}

validate_ffprobe() {
    local path="$1"
    local version

    version="$("$path" -version 2>&1)" || return 1
    grep -Eq '^ffprobe version[[:space:]]' <<<"$version"
}

validate_ffmpeg() {
    local path="$1"
    local version decoders demuxers

    version="$("$path" -version 2>&1)" || return 1
    grep -Eq '^ffmpeg version[[:space:]]' <<<"$version" || return 1
    decoders="$("$path" -hide_banner -decoders 2>&1)" || return 1
    grep -Eq '(^|[[:space:]])h264([[:space:]]|$)' <<<"$decoders" || return 1
    grep -Eq '(^|[[:space:]])hevc([[:space:]]|$)' <<<"$decoders" || return 1
    demuxers="$("$path" -hide_banner -demuxers 2>&1)" || return 1
    grep -Eq '(^|[[:space:],])matroska([,[:space:]]|$)' <<<"$demuxers" || return 1
    grep -Eq '(^|[[:space:],])mp4([,[:space:]]|$)' <<<"$demuxers"
}

cleanup() {
    if [[ -n "$ATOMIC_TEMP" ]]; then
        run_privileged rm -f -- "$ATOMIC_TEMP" >/dev/null 2>&1 || true
    fi
    [[ -z "$STAGE_DIR" ]] || rm -rf -- "$STAGE_DIR"
}

leave_timer_inactive_on_error() {
    local status=$?
    trap - ERR
    if [[ "$TIMER_STOPPED" == "1" ]]; then
        run_privileged systemctl stop "$TIMER_UNIT" >/dev/null 2>&1 || true
    fi
    exit "$status"
}

trap cleanup EXIT
trap leave_timer_inactive_on_error ERR

[[ "$CURRENT_EUID" =~ ^[0-9]+$ ]] || die "INSTALL_EUID_OVERRIDE must be a non-negative integer"
[[ "$INSTALL_WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "INSTALL_WAIT_SECONDS must be a non-negative integer"
[[ "$INSTALL_POLL_SECONDS" =~ ^[0-9]+$ ]] || die "INSTALL_POLL_SECONDS must be a positive integer"
((INSTALL_POLL_SECONDS > 0)) || die "INSTALL_POLL_SECONDS must be a positive integer"
[[ "$TARGET_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "TARGET_USER is invalid"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
command -v mountpoint >/dev/null 2>&1 || die "mountpoint is required"
command -v realpath >/dev/null 2>&1 || die "realpath is required"
if [[ "$CURRENT_EUID" != "0" ]]; then
    command -v sudo >/dev/null 2>&1 || die "sudo is required for non-root installation"
else
    command -v runuser >/dev/null 2>&1 || die "runuser is required for root installation"
fi
target_passwd="$(getent passwd "$TARGET_USER" 2>/dev/null)" \
    || die "target user '$TARGET_USER' does not exist"
IFS=: read -r _ _ target_uid target_primary_gid _ <<<"$target_passwd"
[[ "$target_uid" =~ ^[0-9]+$ && "$target_primary_gid" =~ ^[0-9]+$ ]] \
    || die "target user '$TARGET_USER' has an invalid account identity"
target_group_entry="$(getent group "$target_primary_gid" 2>/dev/null)" \
    || die "could not resolve the primary group for target user '$TARGET_USER'"
IFS=: read -r TARGET_PRIMARY_GROUP _ resolved_primary_gid _ <<<"$target_group_entry"
[[ -n "$TARGET_PRIMARY_GROUP" && "$resolved_primary_gid" == "$target_primary_gid" ]] \
    || die "could not resolve the primary group for target user '$TARGET_USER'"
getent group media >/dev/null 2>&1 || die "required group 'media' does not exist"
[[ -d "$HOME_DEST" ]] || die "target home directory does not exist: $HOME_DEST"
[[ -d "$SYSTEMD_ROOT" ]] || die "systemd unit directory does not exist: $SYSTEMD_ROOT"
if [[ -e "$ENV_DEST" || -L "$ENV_DEST" ]]; then
    [[ -f "$ENV_DEST" && ! -L "$ENV_DEST" ]] \
        || die "environment path must be a regular non-symlink file: $ENV_DEST"
fi

# Explicit validator selectors are installer-only inputs. Reject unsafe or
# missing paths before stopping timers, installing packages, or replacing any
# deployed file. Their canonical paths are rendered directly into the unit.
if [[ -n "${VALIDATOR_FFPROBE_BIN+x}" ]]; then
    FFPROBE_EXPLICIT=1
    FFPROBE_BIN="$(canonical_explicit_executable VALIDATOR_FFPROBE_BIN "$VALIDATOR_FFPROBE_BIN")"
fi
if [[ -n "${VALIDATOR_FFMPEG_BIN+x}" ]]; then
    FFMPEG_EXPLICIT=1
    FFMPEG_BIN="$(canonical_explicit_executable VALIDATOR_FFMPEG_BIN "$VALIDATOR_FFMPEG_BIN")"
fi

# A subsequent installer run should not silently replace a previously pinned
# service-only toolchain with the distro defaults. Reuse and revalidate each
# root-owned unit selection unless the caller explicitly supplies a new one.
if (( ! FFPROBE_EXPLICIT )); then
    if installed_ffprobe="$(read_installed_validator_path FFPROBE_BIN)"; then
        FFPROBE_BIN="$(canonical_explicit_executable 'installed FFPROBE_BIN' "$installed_ffprobe")"
        FFPROBE_EXPLICIT=1
    fi
fi
if (( ! FFMPEG_EXPLICIT )); then
    if installed_ffmpeg="$(read_installed_validator_path FFMPEG_BIN)"; then
        FFMPEG_BIN="$(canonical_explicit_executable 'installed FFMPEG_BIN' "$installed_ffmpeg")"
        FFMPEG_EXPLICIT=1
    fi
fi

required_sources=(
    move_dovi5_to_quarantine.sh
    servarr_outbox.py
    dovi5_ops/__init__.py
    dovi5_ops/config.py
    dovi5_ops/schema.py
    dovi5_ops/servarr.py
    dovi5_ops/outbox.py
    systemd/move-dovi5-to-quarantine.service.tpl
    systemd/move-dovi5-to-quarantine.timer
    dovi5-frigate-ops.env.example
)
for relative_path in "${required_sources[@]}"; do
    [[ -f "$SOURCE_ROOT/$relative_path" ]] || die "required source is missing: $relative_path"
done

STAGE_DIR="$(mktemp -d)"
mkdir -p "$STAGE_DIR/dovi5_ops" "$STAGE_DIR/systemd"
for relative_path in "${required_sources[@]}"; do
    cp -- "$SOURCE_ROOT/$relative_path" "$STAGE_DIR/$relative_path"
done

bash -n "$STAGE_DIR/move_dovi5_to_quarantine.sh"
PYTHONPATH="$STAGE_DIR" python3 -m py_compile \
    "$STAGE_DIR/servarr_outbox.py" \
    "$STAGE_DIR/dovi5_ops/__init__.py" \
    "$STAGE_DIR/dovi5_ops/config.py" \
    "$STAGE_DIR/dovi5_ops/schema.py" \
    "$STAGE_DIR/dovi5_ops/servarr.py" \
    "$STAGE_DIR/dovi5_ops/outbox.py"
(
    cd "$STAGE_DIR"
    PYTHONPATH="$STAGE_DIR" python3 -c \
        'import dovi5_ops; import dovi5_ops.config; import dovi5_ops.outbox; import dovi5_ops.schema; import dovi5_ops.servarr; import servarr_outbox'
)

# Preserve existing credential bytes (or install the staged example) through a
# single privileged, bounded, no-follow operation before changing timer or
# deployment state. The POSIX path holds a stable home-directory descriptor
# throughout the atomic replacement. This systemd installer is POSIX-only and
# fails closed where those ownership and dir_fd primitives are unavailable.
run_privileged python3 - \
    dovi5-secure-env-install-v1 \
    "$HOME_DEST" \
    dovi5-frigate-ops.env \
    "$STAGE_DIR/dovi5-frigate-ops.env.example" \
    "$target_uid" \
    "$target_primary_gid" <<'PY'
import os
import secrets
import stat
import sys

MAX_ENV_BYTES = 1024 * 1024
MARKER = "dovi5-secure-env-install-v1"


class SecureInstallError(Exception):
    pass


def identity(info):
    return info.st_dev, info.st_ino


def read_identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def read_bounded(fd, description):
    before = os.fstat(fd)
    if not stat.S_ISREG(before.st_mode):
        raise SecureInstallError(f"{description} is not a regular file")
    if before.st_size < 0 or before.st_size > MAX_ENV_BYTES:
        raise SecureInstallError(f"{description} exceeds the size limit")

    chunks = []
    total = 0
    while True:
        chunk = os.read(fd, min(65536, MAX_ENV_BYTES + 1 - total))
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_ENV_BYTES:
            raise SecureInstallError(f"{description} exceeds the size limit")
        chunks.append(chunk)
    after = os.fstat(fd)
    if read_identity(before) != read_identity(after):
        raise SecureInstallError(f"{description} changed while being read")
    return b"".join(chunks), after


def write_fully(fd, data):
    remaining = memoryview(data)
    while remaining:
        written = os.write(fd, remaining)
        if written <= 0:
            raise SecureInstallError("environment temporary file write failed")
        remaining = remaining[written:]


def validate_name(name):
    if not name or name in {".", ".."} or os.path.basename(name) != name:
        raise SecureInstallError("environment filename is invalid")


def read_staged_posix(source_path, nofollow, nonblock, cloexec):
    source_fd = None
    try:
        source_fd = os.open(
            source_path,
            os.O_RDONLY | nofollow | nonblock | cloexec,
        )
        data, opened = read_bounded(source_fd, "staged environment example")
        current = os.lstat(source_path)
        if (
            not stat.S_ISREG(current.st_mode)
            or read_identity(current) != read_identity(opened)
        ):
            raise SecureInstallError("staged environment example changed while being read")
        return data
    finally:
        if source_fd is not None:
            os.close(source_fd)


def install_posix(home_dir, env_name, source_path, target_uid, target_gid):
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    nonblock = getattr(os, "O_NONBLOCK", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    cloexec = getattr(os, "O_CLOEXEC", 0)
    if not nofollow or not nonblock or not directory or not hasattr(os, "fchown"):
        raise SecureInstallError("required POSIX no-follow primitives are unavailable")
    if os.geteuid() != 0:
        raise SecureInstallError("secure environment installation requires root")

    if not os.path.isabs(home_dir):
        raise SecureInstallError("target home must be an absolute path")
    home_path = os.path.abspath(home_dir)
    parent_path, home_name = os.path.split(home_path)
    validate_name(home_name)

    parent_fd = None
    home_fd = None
    stage_fd = None
    existing_fd = None
    temp_fd = None
    stage_name = None
    temp_name = None
    try:
        parent_fd = os.open(
            parent_path,
            os.O_RDONLY | directory | nofollow | cloexec,
        )
        parent_info = os.fstat(parent_fd)
        if not stat.S_ISDIR(parent_info.st_mode):
            raise SecureInstallError("target home parent is not a directory")
        if parent_info.st_uid != 0 or stat.S_IMODE(parent_info.st_mode) & 0o022:
            raise SecureInstallError("target home parent is not root-controlled")

        home_fd = os.open(
            home_name,
            os.O_RDONLY | directory | nofollow | cloexec,
            dir_fd=parent_fd,
        )
        home_info = os.fstat(home_fd)
        current_home = os.lstat(home_name, dir_fd=parent_fd)
        if not stat.S_ISDIR(home_info.st_mode) or identity(current_home) != identity(home_info):
            raise SecureInstallError("target home is not a directory")
        if home_info.st_dev != parent_info.st_dev:
            raise SecureInstallError("target home and secure staging must share a filesystem")

        try:
            existing_fd = os.open(
                env_name,
                os.O_RDONLY | nofollow | nonblock | cloexec,
                dir_fd=home_fd,
            )
        except FileNotFoundError:
            expected_source_metadata = None
            data = read_staged_posix(source_path, nofollow, nonblock, cloexec)
        else:
            data, opened = read_bounded(existing_fd, "existing environment file")
            expected_source_metadata = read_identity(opened)
        finally:
            if existing_fd is not None:
                os.close(existing_fd)
                existing_fd = None

        for _ in range(128):
            stage_name = f".{env_name}.stage.{secrets.token_hex(16)}"
            try:
                os.mkdir(stage_name, 0o700, dir_fd=parent_fd)
                break
            except FileExistsError:
                stage_name = None
        else:
            raise SecureInstallError("could not allocate secure environment staging")

        stage_fd = os.open(
            stage_name,
            os.O_RDONLY | directory | nofollow | cloexec,
            dir_fd=parent_fd,
        )
        os.fchmod(stage_fd, 0o700)
        stage_info = os.fstat(stage_fd)
        current_stage = os.lstat(stage_name, dir_fd=parent_fd)
        if (
            not stat.S_ISDIR(stage_info.st_mode)
            or stage_info.st_uid != 0
            or stat.S_IMODE(stage_info.st_mode) != 0o700
            or identity(current_stage) != identity(stage_info)
        ):
            raise SecureInstallError("secure environment staging is unsafe")

        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow | cloexec
        for _ in range(128):
            temp_name = f"{env_name}.tmp.{secrets.token_hex(16)}"
            try:
                temp_fd = os.open(temp_name, flags, 0o600, dir_fd=stage_fd)
                break
            except FileExistsError:
                temp_name = None
        else:
            raise SecureInstallError("could not allocate an environment temporary file")

        write_fully(temp_fd, data)
        os.fchown(temp_fd, target_uid, target_gid)
        os.fchmod(temp_fd, 0o600)
        os.fsync(temp_fd)
        prepared_identity = identity(os.fstat(temp_fd))

        try:
            current = os.lstat(env_name, dir_fd=home_fd)
        except FileNotFoundError:
            current_source_metadata = None
        else:
            current_source_metadata = read_identity(current)
        if current_source_metadata != expected_source_metadata:
            raise SecureInstallError("environment path changed during secure installation")

        current_temp = os.lstat(temp_name, dir_fd=stage_fd)
        if (
            not stat.S_ISREG(current_temp.st_mode)
            or identity(current_temp) != prepared_identity
        ):
            raise SecureInstallError("secure environment temporary file changed")

        os.replace(
            temp_name,
            env_name,
            src_dir_fd=stage_fd,
            dst_dir_fd=home_fd,
        )
        temp_name = None
        os.fsync(home_fd)
        os.fsync(stage_fd)
        os.rmdir(stage_name, dir_fd=parent_fd)
        stage_name = None
        os.fsync(parent_fd)
    finally:
        if temp_fd is not None:
            os.close(temp_fd)
        if temp_name is not None and stage_fd is not None:
            try:
                os.unlink(temp_name, dir_fd=stage_fd)
            except FileNotFoundError:
                pass
        if existing_fd is not None:
            os.close(existing_fd)
        if stage_fd is not None:
            os.close(stage_fd)
        if stage_name is not None and parent_fd is not None:
            try:
                os.rmdir(stage_name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        if home_fd is not None:
            os.close(home_fd)
        if parent_fd is not None:
            os.close(parent_fd)


try:
    if len(sys.argv) != 7 or sys.argv[1] != MARKER:
        raise SecureInstallError("secure environment helper arguments are invalid")
    _, home_dir, env_name, source_path, uid_text, gid_text = sys.argv[1:]
    validate_name(env_name)
    target_uid = int(uid_text)
    target_gid = int(gid_text)
    if target_uid < 0 or target_gid < 0:
        raise ValueError
    if os.name != "posix":
        raise SecureInstallError("secure environment installation requires POSIX")
    install_posix(home_dir, env_name, source_path, target_uid, target_gid)
except (OSError, SecureInstallError, ValueError) as exc:
    print(f"ERROR: secure environment install failed: {exc}", file=sys.stderr)
    raise SystemExit(2)
PY

# Prevent a new scheduled run, then let any legacy run finish on its own. A
# blank host legitimately has no loaded timer yet; other manager failures are
# fatal and fail closed.
TIMER_STOPPED=1
if ! run_privileged systemctl stop "$TIMER_UNIT"; then
    if timer_load_state="$(run_privileged systemctl show "$TIMER_UNIT" -p LoadState --value 2>/dev/null)"; then
        timer_load_state="${timer_load_state//$'\r'/}"
    else
        die "could not stop or inspect $TIMER_UNIT"
    fi
    [[ "$timer_load_state" == "not-found" ]] || die "could not stop $TIMER_UNIT"
fi

waited=0
while true; do
    if service_state="$(run_privileged systemctl is-active "$SERVICE_UNIT" 2>/dev/null)"; then
        service_status=0
    else
        service_status=$?
    fi
    service_state="${service_state//$'\r'/}"
    case "$service_state" in
        active|activating|deactivating|reloading)
            if ((waited >= INSTALL_WAIT_SECONDS)); then
                die "timed out waiting for $SERVICE_UNIT to finish; existing deployment was not changed"
            fi
            sleep_for="$INSTALL_POLL_SECONDS"
            remaining=$((INSTALL_WAIT_SECONDS - waited))
            ((sleep_for <= remaining)) || sleep_for="$remaining"
            sleep "$sleep_for"
            waited=$((waited + sleep_for))
            ;;
        inactive|failed|unknown|not-found)
            break
            ;;
        *)
            die "could not determine whether $SERVICE_UNIT is inactive (systemctl status $service_status)"
            ;;
    esac
done

# Prefer explicit validated executables. For defaults, use only the fixed
# validation PATH; if either tool is absent or unusable, provision the distro's
# matched FFmpeg/FFprobe package once and validate the resulting pair again.
if ((FFPROBE_EXPLICIT)); then
    validate_ffprobe "$FFPROBE_BIN" || die "the selected FFprobe failed its version self-test"
elif ! FFPROBE_BIN="$(resolve_validator_executable ffprobe)" \
    || ! validate_ffprobe "$FFPROBE_BIN"; then
    PROVISION_VALIDATORS=1
else
    PROVISION_VALIDATORS=0
fi

if ((FFMPEG_EXPLICIT)); then
    validate_ffmpeg "$FFMPEG_BIN" || die "the selected FFmpeg lacks required validation capabilities"
elif ! FFMPEG_BIN="$(resolve_validator_executable ffmpeg)" \
    || ! validate_ffmpeg "$FFMPEG_BIN"; then
    PROVISION_VALIDATORS=1
fi

if [[ "${PROVISION_VALIDATORS:-0}" == "1" ]]; then
    command -v apt-get >/dev/null 2>&1 || die "FFmpeg validators are unavailable and apt-get is unavailable"
    run_privileged apt-get update
    run_privileged apt-get install -y ffmpeg
    if (( ! FFPROBE_EXPLICIT )); then
        FFPROBE_BIN="$(resolve_validator_executable ffprobe)" \
            || die "ffprobe is unavailable after installing ffmpeg"
    fi
    if (( ! FFMPEG_EXPLICIT )); then
        FFMPEG_BIN="$(resolve_validator_executable ffmpeg)" \
            || die "ffmpeg is unavailable after installing ffmpeg"
    fi
fi

validate_ffprobe "$FFPROBE_BIN" || die "FFprobe failed its version self-test"
validate_ffmpeg "$FFMPEG_BIN" || die "FFmpeg lacks H.264/HEVC decoders or Matroska/MP4 demuxers"

sed \
    -e "s|__TARGET_USER__|$TARGET_USER|g" \
    -e "s|__HOME_DIR__|$HOME_DEST|g" \
    -e "s|__FFPROBE_BIN__|$FFPROBE_BIN|g" \
    -e "s|__FFMPEG_BIN__|$FFMPEG_BIN|g" \
    "$STAGE_DIR/systemd/move-dovi5-to-quarantine.service.tpl" \
    >"$STAGE_DIR/systemd/$SERVICE_UNIT"
grep -F "EnvironmentFile=$HOME_DEST/dovi5-frigate-ops.env" "$STAGE_DIR/systemd/$SERVICE_UNIT" >/dev/null \
    || die "rendered service does not require the environment file"
grep -F "Environment=FFPROBE_BIN=$FFPROBE_BIN" "$STAGE_DIR/systemd/$SERVICE_UNIT" >/dev/null \
    || die "rendered service does not select the validated FFprobe"
grep -F "Environment=FFMPEG_BIN=$FFMPEG_BIN" "$STAGE_DIR/systemd/$SERVICE_UNIT" >/dev/null \
    || die "rendered service does not select the validated FFmpeg"
grep -F 'StateDirectory=dovi5-frigate-ops' "$STAGE_DIR/systemd/$SERVICE_UNIT" >/dev/null \
    || die "rendered service does not define its state directory"
grep -F 'StateDirectoryMode=0700' "$STAGE_DIR/systemd/$SERVICE_UNIT" >/dev/null \
    || die "rendered service does not protect its state directory"
grep -F 'TimeoutStartSec=12h' "$STAGE_DIR/systemd/$SERVICE_UNIT" >/dev/null \
    || die "rendered service does not allow a full scan to finish"
grep -F 'UMask=0077' "$STAGE_DIR/systemd/$SERVICE_UNIT" >/dev/null \
    || die "rendered service does not use the required umask"

if ! command -v mediainfo >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || die "mediainfo is missing and apt-get is unavailable"
    run_privileged apt-get update
    run_privileged apt-get install -y mediainfo
fi

atomic_install() {
    local mode="$1"
    local owner="$2"
    local group="$3"
    local source="$4"
    local destination="$5"
    local temporary="${destination}.tmp.$$"
    ATOMIC_TEMP="$temporary"
    run_privileged install -m "$mode" -o "$owner" -g "$group" "$source" "$temporary"
    run_privileged mv -f -- "$temporary" "$destination"
    ATOMIC_TEMP=""
}

atomic_install 0755 root root "$STAGE_DIR/move_dovi5_to_quarantine.sh" "$SCRIPT_DEST"
atomic_install 0755 root root "$STAGE_DIR/servarr_outbox.py" "$CLI_DEST"
run_privileged install -d -m 0755 -o root -g root "$PACKAGE_DEST"
for module in __init__.py config.py schema.py servarr.py outbox.py; do
    atomic_install 0644 root root "$STAGE_DIR/dovi5_ops/$module" "$PACKAGE_DEST/$module"
done

atomic_install 0644 root root "$STAGE_DIR/systemd/$SERVICE_UNIT" "$SERVICE_DEST"
atomic_install 0644 root root "$STAGE_DIR/systemd/move-dovi5-to-quarantine.timer" "$TIMER_DEST"
run_privileged systemctl daemon-reload

read_validation_paths() {
    run_as_target env -i \
        PATH="$VALIDATION_PATH" \
        PYTHONPATH="$HOME_DEST" \
        python3 - "$ENV_DEST" "$DEFAULT_MEDIA_MOUNTPOINT" <<'PY'
import sys

from dovi5_ops.config import ConfigurationError, _read_env_file

try:
    values = _read_env_file(sys.argv[1])
except ConfigurationError as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    raise SystemExit(2)

default_mount = sys.argv[2]
defaults = {
    "MEDIA_MOUNTPOINT": default_mount,
    "PLEX_TV_DIR": f"{default_mount}/PlexTV",
    "PLEX_TVHD_DIR": f"{default_mount}/PlexTVHD",
    "PLEX_FILMS_DIR": f"{default_mount}/PlexFilms",
    "PLEX_FILMSHD_DIR": f"{default_mount}/PlexFilmsHD",
}
for name in defaults:
    print(values[name] if name in values else defaults[name])
PY
}

validate_configuration() (
    set +x
    local parsed_paths
    parsed_paths="$(read_validation_paths)" || return 1
    mapfile -t paths <<<"$parsed_paths"
    [[ "${#paths[@]}" == "5" ]] || return 1
    for index in "${!paths[@]}"; do
        paths[index]="${paths[index]%$'\r'}"
    done
    MEDIA_MOUNTPOINT="${paths[0]}"
    PLEX_TV_DIR="${paths[1]}"
    PLEX_TVHD_DIR="${paths[2]}"
    PLEX_FILMS_DIR="${paths[3]}"
    PLEX_FILMSHD_DIR="${paths[4]}"

    PATH="$VALIDATION_PATH" mountpoint -q -- "$MEDIA_MOUNTPOINT" || return 1
    canonical_mount="$(PATH="$VALIDATION_PATH" realpath -e -- "$MEDIA_MOUNTPOINT")" || return 1
    [[ -d "$canonical_mount" ]] || return 1
    for root in "$PLEX_TV_DIR" "$PLEX_TVHD_DIR" "$PLEX_FILMS_DIR" "$PLEX_FILMSHD_DIR"; do
        [[ -n "$root" && -d "$root" ]] || return 1
        canonical_root="$(PATH="$VALIDATION_PATH" realpath -e -- "$root")" || return 1
        [[ "$canonical_root" == "$canonical_mount"/* ]] || return 1
    done

    run_as_target env -i \
        PATH="$VALIDATION_PATH" \
        PLEX_TV_DIR="$PLEX_TV_DIR" \
        PLEX_TVHD_DIR="$PLEX_TVHD_DIR" \
        PLEX_FILMS_DIR="$PLEX_FILMS_DIR" \
        PLEX_FILMSHD_DIR="$PLEX_FILMSHD_DIR" \
        python3 "$CLI_DEST" --env-file "$ENV_DEST" check-config --verify-api >/dev/null
)

if validate_configuration; then
    run_privileged systemctl enable --now "$TIMER_UNIT"
    echo "Timer enablement:"
    run_privileged systemctl is-enabled "$TIMER_UNIT"
    echo "Timer activity:"
    run_privileged systemctl is-active "$TIMER_UNIT"
    run_privileged systemctl show "$TIMER_UNIT" -p ActiveState -p NextElapseUSecRealtime
    TIMER_STOPPED=0
    echo "Installation complete; the timer is enabled and active."
else
    run_privileged systemctl disable --now "$TIMER_UNIT"
    TIMER_STOPPED=0
    echo "installed but inactive: configure $ENV_DEST, confirm the media mount and Servarr APIs, then rerun install.sh."
fi
