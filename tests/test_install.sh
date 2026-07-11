#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
REAL_INSTALL="$(command -v install)"
REAL_PYTHON="$(command -v python)"
REAL_SLEEP="$(command -v sleep)"
TEST_TARGET_UID="${TEST_TARGET_UID:-$(id -u)}"
TEST_TARGET_GID="${TEST_TARGET_GID:-$(id -g)}"
TEST_SECURE_ENV_HELPER_EMULATION="${TEST_SECURE_ENV_HELPER_EMULATION:-1}"
TMP_ROOT="$(mktemp -d)"
if [[ "${KEEP_TEST_TMP:-0}" == "1" ]]; then
    trap 'echo "test workspace retained at $TMP_ROOT" >&2' EXIT
else
    trap 'rm -rf "$TMP_ROOT"' EXIT
fi

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local text="$2"
    grep -F -- "$text" "$file" >/dev/null || fail "$file does not contain: $text"
}

assert_not_contains() {
    local file="$1"
    local text="$2"
    if grep -F -- "$text" "$file" >/dev/null; then
        fail "$file unexpectedly contains: $text"
    fi
}

assert_mode() {
    local expected="$1"
    local path="$2"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) return ;;
    esac
    [[ "$(stat -c '%a' "$path")" == "$expected" ]] || \
        fail "$path does not have mode $expected"
}

assert_owner() {
    local expected_uid="$1"
    local expected_gid="$2"
    local path="$3"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac
    [[ "$(stat -c '%u:%g' "$path")" == "$expected_uid:$expected_gid" ]] || \
        fail "$path is not owned by $expected_uid:$expected_gid"
}

write_stubs() {
    local work="$1"
    mkdir -p "$work/bin"

    cat >"$work/bin/sudo" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'sudo:%s\n' "$*" >>"$TEST_COMMAND_LOG"
if [[ "${1:-}" == "-u" ]]; then
    shift 2
    [[ "${1:-}" != "--" ]] || shift
fi
exec "$@"
STUB

    cat >"$work/bin/runuser" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'runuser:%s\n' "$*" >>"$TEST_COMMAND_LOG"
[[ "${1:-}" == "-u" ]] || exit 2
shift 2
[[ "${1:-}" != "--" ]] || shift
exec "$@"
STUB

    cat >"$work/bin/getent" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}:${2:-}" in
    passwd:frigate)
        printf 'frigate:x:%s:%s::/home/frigate:/bin/bash\n' \
            "$TEST_TARGET_UID" "$TEST_TARGET_GID"
        ;;
    group:"$TEST_TARGET_GID")
        [[ "${TEST_PRIMARY_GROUP_LOOKUP_FAIL:-0}" != "1" ]] || exit 2
        printf 'frigate:x:%s:\n' "$TEST_TARGET_GID"
        ;;
    group:media) printf 'media:x:1001:frigate\n' ;;
    *) exit 2 ;;
esac
STUB

    cat >"$work/bin/install" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'install:%s\n' "$*" >>"$TEST_COMMAND_LOG"
args=()
while (($#)); do
    case "$1" in
        -o|-g)
            shift 2
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done
last="${args[${#args[@]} - 1]}"
case "$last" in
    "$TEST_ROOT"/*) ;;
    *) echo "unsafe install destination: $last" >&2; exit 90 ;;
esac
exec "$REAL_INSTALL" "${args[@]}"
STUB

    cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'systemctl:%s\n' "$*" >>"$TEST_COMMAND_LOG"
if [[ "${1:-}" == "stop" && "${2:-}" == "move-dovi5-to-quarantine.timer" && "${TEST_TIMER_STOP_NOT_FOUND:-0}" == "1" ]]; then
    exit 5
fi
if [[ "${1:-}" == "is-active" && "${*: -1}" == "move-dovi5-to-quarantine.service" ]]; then
    [[ "${TEST_SERVICE_QUERY_FAIL:-0}" != "1" ]] || exit 1
    calls=0
    [[ ! -f "$TEST_STATE_CALLS" ]] || calls="$(<"$TEST_STATE_CALLS")"
    calls=$((calls + 1))
    printf '%s\n' "$calls" >"$TEST_STATE_CALLS"
    if [[ "${TEST_ALWAYS_ACTIVE:-0}" == "1" || "$calls" -le "${TEST_ACTIVE_POLLS:-0}" ]]; then
        printf 'active\n'
        exit 0
    fi
    printf 'inactive\n'
    exit 3
fi
case "${1:-}" in
    is-enabled) printf 'enabled\n' ;;
    is-active) printf 'active\n' ;;
    show)
        if [[ "$*" == *'LoadState'* ]]; then
            printf 'not-found\n'
        else
            printf 'NextElapseUSecRealtime=mock-next\nActiveState=active\n'
        fi
        ;;
esac
STUB

    cat >"$work/bin/mountpoint" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
target="${*: -1}"
case "$target" in
    */validation-mount/*) exit 1 ;;
esac
exit 0
STUB

    cat >"$work/bin/python3" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "-" && "${2:-}" == "dovi5-secure-env-install-v1" ]]; then
    printf 'secure-env-helper:%s\n' "$*" >>"$TEST_COMMAND_LOG"
    if [[ "${TEST_SWAP_ENV_DURING_SECURE_INSTALL:-0}" == "1" ]]; then
        env_path="$3/$4"
        rm -f -- "$env_path"
        case "$(uname -s)" in
            MINGW*|MSYS*)
                sentinel_dir="$(dirname -- "$TEST_ENV_SWAP_SENTINEL")"
                MSYS2_ARG_CONV_EXCL='*' cmd.exe /c mklink /J \
                    "$(cygpath -wa "$env_path")" "$(cygpath -wa "$sentinel_dir")" >/dev/null
                ;;
            *) ln -s -- "$TEST_ENV_SWAP_SENTINEL" "$env_path" ;;
        esac
    fi
    if [[ "${TEST_SWAP_ENV_TO_FIFO_DURING_SECURE_INSTALL:-0}" == "1" ]]; then
        env_path="$3/$4"
        rm -f -- "$env_path"
        mkfifo "$env_path"
    fi
    if [[ "${TEST_SECURE_ENV_HELPER_EMULATION:-1}" == "1" ]]; then
        env_path="$3/$4"
        if [[ "${TEST_MUTATE_ENV_DURING_SECURE_INSTALL:-0}" == "1" \
            || "${TEST_MUTATE_ENV_AFTER_READ:-0}" == "1" \
            || "${TEST_SWAP_SECURE_TEMP_DURING_INSTALL:-0}" == "1" ]]; then
            exit 2
        fi
        if [[ -e "$env_path" || -L "$env_path" ]]; then
            [[ -f "$env_path" && ! -L "$env_path" ]] || exit 2
            env_source="$env_path"
        else
            env_source="$5"
        fi
        env_size="$(wc -c <"$env_source")"
        ((env_size <= 1048576)) || exit 2
        env_temp="$(mktemp "${env_path}.tmp.XXXXXXXXXXXXXXXX")"
        trap '[[ -z "${env_temp:-}" ]] || rm -f -- "$env_temp"' EXIT
        cp -- "$env_source" "$env_temp"
        chmod 0600 "$env_temp"
        mv -f -- "$env_temp" "$env_path"
        env_temp=""
        exit 0
    fi
    if [[ "${TEST_MUTATE_ENV_DURING_SECURE_INSTALL:-0}" == "1" \
        || "${TEST_MUTATE_ENV_AFTER_READ:-0}" == "1" \
        || "${TEST_SWAP_SECURE_TEMP_DURING_INSTALL:-0}" == "1" ]]; then
        exec "__REAL_PYTHON__" -c '
import os
import sys

source = sys.stdin.read()
sys.argv = sys.argv[1:]
env_path = os.path.join(sys.argv[2], sys.argv[3])
original_read = os.read
original_fsync = os.fsync
original_lstat = os.lstat
state = {
    "post_read_changed": False,
    "read_changed": False,
    "temp_swapped": False,
}


def racing_read(fd, size):
    data = original_read(fd, size)
    if os.environ.get("TEST_MUTATE_ENV_DURING_SECURE_INSTALL") == "1" \
            and not state["read_changed"]:
        current = os.stat(env_path, follow_symlinks=False)
        os.utime(
            env_path,
            ns=(current.st_atime_ns, current.st_mtime_ns + 1_000_000_000),
            follow_symlinks=False,
        )
        state["read_changed"] = True
    return data


def racing_fsync(fd):
    result = original_fsync(fd)
    if os.environ.get("TEST_MUTATE_ENV_AFTER_READ") == "1" \
            and not state["post_read_changed"]:
        current = os.stat(env_path, follow_symlinks=False)
        os.utime(
            env_path,
            ns=(current.st_atime_ns, current.st_mtime_ns + 2_000_000_000),
            follow_symlinks=False,
        )
        state["post_read_changed"] = True
    return result


def racing_lstat(path, *, dir_fd=None):
    name = os.fspath(path)
    if os.environ.get("TEST_SWAP_SECURE_TEMP_DURING_INSTALL") == "1" \
            and ".tmp." in name and dir_fd is not None \
            and not state["temp_swapped"]:
        os.unlink(name, dir_fd=dir_fd)
        with open(os.environ["TEST_SECURE_TEMP_SWAP_SENTINEL"], "rb") as source_file:
            replacement = source_file.read()
        replacement_fd = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=dir_fd,
        )
        try:
            os.write(replacement_fd, replacement)
        finally:
            os.close(replacement_fd)
        state["temp_swapped"] = True
    return original_lstat(name, dir_fd=dir_fd)


os.read = racing_read
os.fsync = racing_fsync
os.lstat = racing_lstat
exec(compile(source, "<secure-environment-helper>", "exec"))
' "$@"
    fi
    exec "__REAL_PYTHON__" "$@"
fi
if [[ "${1:-}" == "-m" || "${1:-}" == "-c" || "${1:-}" == "-" ]]; then
    exec "__REAL_PYTHON__" "$@"
fi
if [[ "${1:-}" == */servarr_outbox.py ]]; then
    work="$(cd "$(dirname "$1")/../../.." && pwd)"
    log="$work/commands.log"
    printf 'cli:%s\n' "$*" >>"$log"
    printf 'roots:%s|%s|%s|%s\n' \
        "${PLEX_TV_DIR:-}" "${PLEX_TVHD_DIR:-}" \
        "${PLEX_FILMS_DIR:-}" "${PLEX_FILMSHD_DIR:-}" >>"$log"
    [[ "$1" != */validation-api/* ]] || exit 2
    env_file=""
    while (($#)); do
        if [[ "$1" == "--env-file" ]]; then
            env_file="$2"
            break
        fi
        shift
    done
    [[ -n "$env_file" ]] || exit 2
    for name in SONARR_TV_API_KEY SONARR_TVHD_API_KEY RADARR_FILMS_API_KEY RADARR_FILMSHD_API_KEY; do
        grep -Eq "^${name}=.+$" "$env_file" || exit 2
    done
    exit 0
fi
exec "__REAL_PYTHON__" "$@"
STUB
    sed -i "s|__REAL_PYTHON__|$REAL_PYTHON|g" "$work/bin/python3"

    cat >"$work/bin/sleep" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'sleep:%s\n' "$*" >>"$TEST_COMMAND_LOG"
STUB

    cat >"$work/bin/mediainfo" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

    cat >"$work/bin/ffprobe" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ffprobe:%s:%s\n' "$0" "$*" >>"$TEST_COMMAND_LOG"
[[ "${TEST_FFPROBE_SELF_TEST_FAIL:-0}" != "1" ]] || exit 70
if [[ "$*" == *'-version'* ]]; then
    printf 'ffprobe version test-build\n'
fi
STUB

    cat >"$work/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ffmpeg:%s:%s\n' "$0" "$*" >>"$TEST_COMMAND_LOG"
case "$*" in
    *-version*)
        printf 'ffmpeg version test-build\n'
        ;;
    *-decoders*)
        [[ "${TEST_FFMPEG_CAPABILITY_MODE:-complete}" == "missing_h264" ]] || \
            printf ' V....D h264                 H.264 / AVC / MPEG-4 AVC\n'
        [[ "${TEST_FFMPEG_CAPABILITY_MODE:-complete}" == "missing_hevc" ]] || \
            printf ' V....D hevc                 HEVC (High Efficiency Video Coding)\n'
        ;;
    *-demuxers*)
        [[ "${TEST_FFMPEG_CAPABILITY_MODE:-complete}" == "missing_matroska" ]] || \
            printf ' D  matroska,webm           Matroska / WebM\n'
        [[ "${TEST_FFMPEG_CAPABILITY_MODE:-complete}" == "missing_mp4" ]] || \
            printf ' D  mov,mp4,m4a,3gp,3g2,mj2 QuickTime / MOV\n'
        ;;
esac
STUB

    cat >"$work/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'apt-get:%s\n' "$*" >>"$TEST_COMMAND_LOG"
[[ "${TEST_APT_FAIL:-0}" != "1" ]] || exit 100
if [[ " $* " == *' install '* && " $* " == *' ffmpeg '* ]]; then
    for tool in ffprobe ffmpeg; do
        source_var="TEST_${tool^^}_SOURCE"
        source="${!source_var}"
        destination="$TEST_VALIDATION_BIN/$tool"
        if [[ "$source" != "$destination" ]]; then
            cp -- "$source" "$destination"
            chmod 0755 "$destination"
        fi
    done
fi
STUB

    chmod +x "$work/bin/"*
}

new_case() {
    local name="$1"
    local work="$TMP_ROOT/$name"
    mkdir -p "$work/root/home/frigate" "$work/root/etc/systemd/system" "$work/media"
    for library in PlexTV PlexTVHD PlexFilms PlexFilmsHD; do
        mkdir -p "$work/media/$library"
    done
    : >"$work/commands.log"
    write_stubs "$work"
    printf '%s\n' "$work"
}

prepare_validation_path() {
    local work="$1"
    local missing="$2"
    local validation_bin="$work/validation-bin"
    mkdir -p "$validation_bin"
    cp "$work/bin/python3" "$work/bin/mountpoint" "$work/bin/mediainfo" "$validation_bin/"
    [[ "$missing" == "ffprobe" || "$missing" == "both" ]] || \
        cp "$work/bin/ffprobe" "$validation_bin/ffprobe"
    [[ "$missing" == "ffmpeg" || "$missing" == "both" ]] || \
        cp "$work/bin/ffmpeg" "$validation_bin/ffmpeg"
    chmod 0755 "$validation_bin/"*
    printf '%s:/usr/bin:/bin\n' "$validation_bin"
}

write_configured_env() {
    local path="$1"
    local media="$2"
    cat >"$path" <<EOF
MEDIA_MOUNTPOINT=$media
PLEX_TV_DIR=$media/PlexTV
PLEX_TVHD_DIR=$media/PlexTVHD
PLEX_FILMS_DIR=$media/PlexFilms
PLEX_FILMSHD_DIR=$media/PlexFilmsHD
SONARR_TV_URL=http://sonarr-tv.invalid
SONARR_TV_API_KEY=tv-secret
SONARR_TVHD_URL=http://sonarr-tvhd.invalid
SONARR_TVHD_API_KEY=tvhd-secret
RADARR_FILMS_URL=http://radarr-films.invalid
RADARR_FILMS_API_KEY=films-secret
RADARR_FILMSHD_URL=http://radarr-filmshd.invalid
RADARR_FILMSHD_API_KEY=filmshd-secret
EOF
    chmod 0600 "$path"
}

run_installer() {
    local work="$1"
    shift
    local -a installer_command=(bash "$INSTALLER")
    if [[ -n "${TEST_INSTALL_TIMEOUT_SECONDS:-}" ]]; then
        installer_command=(
            timeout --kill-after=1 "$TEST_INSTALL_TIMEOUT_SECONDS"
            bash "$INSTALLER"
        )
    fi
    env \
        PATH="$work/bin:$PATH" \
        TEST_ROOT="$work/root" \
        TEST_COMMAND_LOG="$work/commands.log" \
        TEST_STATE_CALLS="$work/state-calls" \
        TEST_VALIDATION_BIN="$work/bin" \
        TEST_FFPROBE_SOURCE="$work/bin/ffprobe" \
        TEST_FFMPEG_SOURCE="$work/bin/ffmpeg" \
        TEST_TARGET_UID="$TEST_TARGET_UID" \
        TEST_TARGET_GID="$TEST_TARGET_GID" \
        TEST_SECURE_ENV_HELPER_EMULATION="$TEST_SECURE_ENV_HELPER_EMULATION" \
        REAL_INSTALL="$REAL_INSTALL" \
        REAL_PYTHON="$REAL_PYTHON" \
        REAL_SLEEP="$REAL_SLEEP" \
        INSTALL_HOME_ROOT="$work/root/home" \
        INSTALL_SYSTEMD_ROOT="$work/root/etc/systemd/system" \
        INSTALL_DEFAULT_MEDIA_MOUNTPOINT="$work/media" \
        INSTALL_VALIDATION_PATH="$work/bin:$PATH" \
        INSTALL_WAIT_SECONDS=3 \
        INSTALL_POLL_SECONDS=1 \
        TARGET_USER=frigate \
        "$@" \
        "${installer_command[@]}" >"$work/stdout" 2>"$work/stderr"
}

test_configured_root_install() {
    local work
    work="$(new_case configured-root)"
    write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"
    local before after before_mode after_mode
    before="$(sha256sum "$work/root/home/frigate/dovi5-frigate-ops.env")"
    before_mode="$(stat -c '%a' "$work/root/home/frigate/dovi5-frigate-ops.env")"

    run_installer "$work" INSTALL_EUID_OVERRIDE=0

    after="$(sha256sum "$work/root/home/frigate/dovi5-frigate-ops.env")"
    [[ "$before" == "$after" ]] || fail "existing environment bytes changed"
    after_mode="$(stat -c '%a' "$work/root/home/frigate/dovi5-frigate-ops.env")"
    [[ "$before_mode" == "$after_mode" ]] || fail "existing environment mode changed: $before_mode -> $after_mode"
    [[ -x "$work/root/home/frigate/move_dovi5_to_quarantine.sh" ]] || fail "scanner not executable"
    [[ -x "$work/root/home/frigate/servarr_outbox.py" ]] || fail "CLI not executable"
    [[ "$(stat -c '%a' "$work/root/home/frigate/dovi5_ops")" == "755" ]] || fail "package directory mode"
    for module in __init__.py config.py schema.py servarr.py outbox.py; do
        [[ -f "$work/root/home/frigate/dovi5_ops/$module" ]] || fail "missing package module $module"
        [[ "$(stat -c '%a' "$work/root/home/frigate/dovi5_ops/$module")" == "644" ]] || fail "module mode $module"
    done
    assert_not_contains "$work/commands.log" 'sudo:'
    assert_contains "$work/commands.log" 'install:-m 0755 -o root -g root'
    assert_contains "$work/commands.log" 'install:-m 0644 -o root -g root'
    assert_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
    assert_not_contains "$work/commands.log" 'systemctl:start move-dovi5-to-quarantine.service'
    assert_not_contains "$work/commands.log" 'systemctl:stop move-dovi5-to-quarantine.service'
    assert_not_contains "$work/commands.log" 'systemctl:kill move-dovi5-to-quarantine.service'
    assert_not_contains "$work/commands.log" 'tv-secret'
    local secure_env_line stop_line idle_line install_line
    secure_env_line="$(grep -nF 'secure-env-helper:- dovi5-secure-env-install-v1' "$work/commands.log" | head -1 | cut -d: -f1)"
    stop_line="$(grep -nF 'systemctl:stop move-dovi5-to-quarantine.timer' "$work/commands.log" | head -1 | cut -d: -f1)"
    idle_line="$(grep -nF 'systemctl:is-active move-dovi5-to-quarantine.service' "$work/commands.log" | tail -1 | cut -d: -f1)"
    install_line="$(grep -nF 'install:-m 0755 -o root -g root' "$work/commands.log" | head -1 | cut -d: -f1)"
    ((secure_env_line < stop_line && stop_line < idle_line && idle_line < install_line)) || \
        fail "environment repair / timer stop / idle wait / replacement order"
}

test_non_root_uses_sudo() {
    local work
    work="$(new_case configured-nonroot)"
    write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"
    run_installer "$work" INSTALL_EUID_OVERRIDE=1000
    assert_contains "$work/commands.log" 'sudo:systemctl stop move-dovi5-to-quarantine.timer'
    assert_contains "$work/commands.log" 'sudo:install -m 0755 -o root -g root'
    assert_contains "$work/commands.log" 'sudo:systemctl enable --now move-dovi5-to-quarantine.timer'
}

test_blank_fresh_install_is_inactive() {
    local work
    work="$(new_case blank)"
    run_installer "$work" INSTALL_EUID_OVERRIDE=0
    local env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    [[ -f "$env_file" ]] || fail "fresh environment was not installed"
    cmp -s "$ROOT/dovi5-frigate-ops.env.example" "$env_file" || \
        fail "fresh environment bytes differ from the staged example"
    assert_mode 600 "$env_file"
    assert_owner "$TEST_TARGET_UID" "$TEST_TARGET_GID" "$env_file"
    grep -Eq "^secure-env-helper:- dovi5-secure-env-install-v1 $work/root/home/frigate dovi5-frigate-ops\.env .+ $TEST_TARGET_UID $TEST_TARGET_GID$" \
        "$work/commands.log" || fail "fresh environment was not securely installed for the target account"
    assert_contains "$work/commands.log" 'systemctl:disable --now move-dovi5-to-quarantine.timer'
    assert_not_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
    assert_not_contains "$work/commands.log" 'systemctl:start'
    assert_contains "$work/stdout" 'installed but inactive'
}

test_existing_regular_env_is_repaired_atomically_without_rewrite() {
    local work env_file before
    work="$(new_case existing-env-repair)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    write_configured_env "$env_file" "$work/media"
    chmod 0644 "$env_file"
    before="$(sha256sum "$env_file")"

    run_installer "$work" INSTALL_EUID_OVERRIDE=0

    [[ "$before" == "$(sha256sum "$env_file")" ]] || fail "existing environment bytes changed"
    assert_mode 600 "$env_file"
    assert_owner "$TEST_TARGET_UID" "$TEST_TARGET_GID" "$env_file"
    grep -Eq "^secure-env-helper:- dovi5-secure-env-install-v1 $work/root/home/frigate dovi5-frigate-ops\.env .+ $TEST_TARGET_UID $TEST_TARGET_GID$" \
        "$work/commands.log" || fail "existing environment was not securely repaired for the target account"
    if compgen -G "$env_file.tmp.*" >/dev/null; then
        fail "environment repair left a temporary file"
    fi
}

test_existing_env_symlink_fails_before_system_changes() {
    local work env_file target
    work="$(new_case env-symlink)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    target="$work/external.env"
    write_configured_env "$target" "$work/media"
    ln -s "$target" "$env_file"
    if [[ ! -L "$env_file" ]]; then
        rm -f "$env_file"
        case "$(uname -s)" in
            MINGW*|MSYS*)
                target="$work/external-env-dir"
                mkdir "$target"
                MSYS2_ARG_CONV_EXCL='*' cmd.exe /c mklink /J \
                    "$(cygpath -wa "$env_file")" "$(cygpath -wa "$target")" >/dev/null
                ;;
            *) fail "could not create an environment-file symlink for the test" ;;
        esac
    fi
    [[ -L "$env_file" ]] || fail "environment-file symlink test setup failed"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0; then
        fail "installer accepted an environment-file symlink"
    fi

    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_existing_env_directory_fails_before_system_changes() {
    local work env_file
    work="$(new_case env-directory)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    mkdir "$env_file"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0; then
        fail "installer accepted a non-regular environment path"
    fi

    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_existing_env_fifo_fails_before_system_changes() {
    local work env_file
    work="$(new_case env-fifo)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    mkfifo "$env_file"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0; then
        fail "installer accepted a special environment path"
    fi

    assert_not_contains "$work/commands.log" 'secure-env-helper:'
    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_environment_path_swap_fails_before_system_changes() {
    local work home env_file protected_dir sentinel sentinel_before marker candidate
    work="$(new_case env-path-swap)"
    home="$work/root/home/frigate"
    env_file="$home/dovi5-frigate-ops.env"
    protected_dir="$work/protected"
    sentinel="$protected_dir/sentinel.env"
    marker='protected-sentinel-content-must-not-be-copied'
    mkdir "$protected_dir"
    write_configured_env "$env_file" "$work/media"
    printf '%s\n' "$marker" >"$sentinel"
    sentinel_before="$(sha256sum "$sentinel")"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        TEST_SWAP_ENV_DURING_SECURE_INSTALL=1 TEST_ENV_SWAP_SENTINEL="$sentinel"; then
        fail "installer accepted an environment path changed after validation"
    fi

    [[ "$sentinel_before" == "$(sha256sum "$sentinel")" ]] || \
        fail "protected sentinel bytes changed"
    [[ -L "$env_file" ]] || fail "adversarial test did not leave the swapped environment symlink"
    for candidate in "$home"/* "$home"/.[!.]*; do
        [[ -f "$candidate" && ! -L "$candidate" ]] || continue
        assert_not_contains "$candidate" "$marker"
    done
    assert_not_contains "$work/commands.log" "$marker"
    assert_not_contains "$work/stdout" "$marker"
    assert_not_contains "$work/stderr" "$marker"
    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
    if compgen -G "$env_file.tmp.*" >/dev/null; then
        fail "failed environment repair left a temporary file"
    fi
}

test_oversized_existing_env_fails_before_system_changes() {
    local work env_file
    work="$(new_case oversized-env)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    write_configured_env "$env_file" "$work/media"
    dd if=/dev/zero bs=1048577 count=1 2>/dev/null | tr '\0' x >>"$env_file"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0; then
        fail "installer accepted an oversized environment file"
    fi

    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_environment_in_place_change_fails_before_system_changes() {
    local work env_file
    work="$(new_case env-in-place-change)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    write_configured_env "$env_file" "$work/media"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        TEST_MUTATE_ENV_DURING_SECURE_INSTALL=1; then
        fail "installer accepted an environment file changed while being read"
    fi

    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_environment_post_read_change_fails_before_system_changes() {
    local work env_file
    work="$(new_case env-post-read-change)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    write_configured_env "$env_file" "$work/media"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        TEST_MUTATE_ENV_AFTER_READ=1; then
        fail "installer accepted an environment file changed after its final read fstat"
    fi

    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_environment_fifo_swap_does_not_block_before_system_changes() {
    local work env_file status
    case "$(uname -s)" in
        MINGW*|MSYS*) return 0 ;;
    esac
    work="$(new_case env-fifo-swap)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    write_configured_env "$env_file" "$work/media"

    if TEST_INSTALL_TIMEOUT_SECONDS=3 run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        TEST_SWAP_ENV_TO_FIFO_DURING_SECURE_INSTALL=1; then
        fail "installer accepted an environment path swapped to a FIFO"
    else
        status=$?
    fi

    [[ "$status" != "124" && "$status" != "137" ]] || \
        fail "installer blocked while opening an environment path swapped to a FIFO"
    [[ -p "$env_file" ]] || fail "environment FIFO swap test setup failed"
    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_secure_temp_substitution_fails_before_system_changes() {
    local work env_file sentinel marker env_before sentinel_before
    work="$(new_case secure-temp-substitution)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    sentinel="$work/protected-temp-source"
    marker='protected-temp-substitution-must-not-be-installed'
    write_configured_env "$env_file" "$work/media"
    printf '%s\n' "$marker" >"$sentinel"
    env_before="$(sha256sum "$env_file")"
    sentinel_before="$(sha256sum "$sentinel")"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        TEST_SWAP_SECURE_TEMP_DURING_INSTALL=1 \
        TEST_SECURE_TEMP_SWAP_SENTINEL="$sentinel"; then
        fail "installer accepted a substituted secure temporary file"
    fi

    [[ "$env_before" == "$(sha256sum "$env_file")" ]] || \
        fail "temporary-file substitution changed the environment"
    [[ "$sentinel_before" == "$(sha256sum "$sentinel")" ]] || \
        fail "temporary-file substitution changed the protected sentinel"
    assert_not_contains "$env_file" "$marker"
    assert_not_contains "$work/commands.log" "$marker"
    assert_not_contains "$work/stdout" "$marker"
    assert_not_contains "$work/stderr" "$marker"
    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
    if compgen -G "$work/root/home/.dovi5-frigate-ops.env.stage.*" >/dev/null; then
        fail "failed secure environment install left a staging directory"
    fi
}

test_group_writable_home_parent_fails_before_system_changes() {
    local work
    [[ "$(id -u)" == "0" ]] || return 0
    work="$(new_case group-writable-home-parent)"
    chmod 0775 "$work/root/home"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        TEST_SECURE_ENV_HELPER_EMULATION=0; then
        fail "installer accepted a group-writable target home parent"
    fi

    assert_contains "$work/stderr" 'target home parent is not root-controlled'
    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_non_root_owned_home_parent_fails_before_system_changes() {
    local work
    [[ "$(id -u)" == "0" ]] || return 0
    work="$(new_case non-root-owned-home-parent)"
    chown 12345:12345 "$work/root/home"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        TEST_SECURE_ENV_HELPER_EMULATION=0; then
        fail "installer accepted a non-root-owned target home parent"
    fi

    assert_contains "$work/stderr" 'target home parent is not root-controlled'
    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_ci_runs_installer_as_root_with_real_helper() {
    local workflow="$ROOT/.github/workflows/ci.yml"
    assert_contains "$workflow" 'sudo bash -c'
    assert_contains "$workflow" 'TEST_SECURE_ENV_HELPER_EMULATION=0'
    assert_contains "$workflow" "TEST_TARGET_UID=\"\$SUDO_UID\""
    assert_contains "$workflow" "TEST_TARGET_GID=\"\$SUDO_GID\""
}

test_missing_primary_group_fails_before_system_changes() {
    local work
    work="$(new_case missing-primary-group)"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 TEST_PRIMARY_GROUP_LOOKUP_FAIL=1; then
        fail "installer succeeded without resolving the target user's primary group"
    fi

    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_active_scan_waits_without_termination() {
    local work
    work="$(new_case active-wait)"
    write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"
    run_installer "$work" INSTALL_EUID_OVERRIDE=0 TEST_ACTIVE_POLLS=2
    [[ "$(grep -c '^sleep:1$' "$work/commands.log")" == "2" ]] || fail "active service was not polled twice"
    assert_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
    assert_not_contains "$work/commands.log" 'systemctl:stop move-dovi5-to-quarantine.service'
    assert_not_contains "$work/commands.log" 'systemctl:kill move-dovi5-to-quarantine.service'
}

test_timeout_preserves_deployment() {
    local work
    work="$(new_case timeout)"
    local home="$work/root/home/frigate"
    local units="$work/root/etc/systemd/system"
    mkdir -p "$home/dovi5_ops"
    printf 'old-scanner\n' >"$home/move_dovi5_to_quarantine.sh"
    printf 'old-cli\n' >"$home/servarr_outbox.py"
    printf 'old-module\n' >"$home/dovi5_ops/config.py"
    printf 'old-service\n' >"$units/move-dovi5-to-quarantine.service"
    printf 'old-timer\n' >"$units/move-dovi5-to-quarantine.timer"
    write_configured_env "$home/dovi5-frigate-ops.env" "$work/media"
    local before after
    before="$(find "$work/root" -type f -print0 | sort -z | xargs -0 sha256sum)"
    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 TEST_ALWAYS_ACTIVE=1 INSTALL_WAIT_SECONDS=2; then
        fail "installer succeeded while service stayed active"
    fi
    after="$(find "$work/root" -type f -print0 | sort -z | xargs -0 sha256sum)"
    [[ "$before" == "$after" ]] || fail "timeout changed deployed files"
    assert_contains "$work/commands.log" 'systemctl:stop move-dovi5-to-quarantine.timer'
    assert_not_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
    assert_not_contains "$work/commands.log" 'systemctl:stop move-dovi5-to-quarantine.service'
}

test_validation_failures_remain_inactive() {
    local kind work
    for kind in mount api; do
        work="$(new_case "validation-$kind")"
        write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"
        if [[ "$kind" == "mount" ]]; then
            run_installer "$work" INSTALL_EUID_OVERRIDE=0 TEST_MOUNT_FAIL=1
        else
            run_installer "$work" INSTALL_EUID_OVERRIDE=0 TEST_API_FAIL=1
        fi
        assert_contains "$work/commands.log" 'systemctl:disable --now move-dovi5-to-quarantine.timer'
        assert_not_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
        assert_not_contains "$work/commands.log" 'systemctl:start'
    done
}

test_missing_validator_tools_are_provisioned_and_rendered() {
    local missing work env_file before service validation_path validation_bin
    for missing in ffprobe ffmpeg both; do
        work="$(new_case "validator-provision-$missing")"
        env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
        service="$work/root/etc/systemd/system/move-dovi5-to-quarantine.service"
        validation_path="$(prepare_validation_path "$work" "$missing")"
        validation_bin="${validation_path%%:*}"
        write_configured_env "$env_file" "$work/media"
        before="$(sha256sum "$env_file")"

        run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
            INSTALL_VALIDATION_PATH="$validation_path" \
            TEST_VALIDATION_BIN="$validation_bin"

        assert_contains "$work/commands.log" 'apt-get:update'
        assert_contains "$work/commands.log" 'apt-get:install -y ffmpeg'
        assert_contains "$work/commands.log" 'ffprobe:'
        assert_contains "$work/commands.log" 'ffmpeg:'
        assert_contains "$service" "Environment=FFPROBE_BIN=$validation_bin/ffprobe"
        assert_contains "$service" "Environment=FFMPEG_BIN=$validation_bin/ffmpeg"
        assert_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
        [[ "$before" == "$(sha256sum "$env_file")" ]] || \
            fail "validator provisioning rewrote the existing environment"
    done
}

test_validator_provisioning_failure_fails_closed() {
    local work validation_path validation_bin
    work="$(new_case validator-provision-failure)"
    validation_path="$(prepare_validation_path "$work" both)"
    validation_bin="${validation_path%%:*}"
    write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        INSTALL_VALIDATION_PATH="$validation_path" \
        TEST_VALIDATION_BIN="$validation_bin" TEST_APT_FAIL=1; then
        fail "installer succeeded after validator package provisioning failed"
    fi

    assert_contains "$work/commands.log" 'systemctl:stop move-dovi5-to-quarantine.timer'
    assert_contains "$work/commands.log" 'apt-get:update'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
    assert_not_contains "$work/commands.log" 'systemctl:start'
}

test_explicit_validator_paths_are_rendered_without_rewriting_env() {
    local work env_file before validator_dir ffprobe ffmpeg service
    work="$(new_case explicit-validator-paths)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    validator_dir="$work/root/opt/dovi5-validator"
    mkdir -p "$validator_dir"
    cp "$work/bin/ffprobe" "$validator_dir/ffprobe"
    cp "$work/bin/ffmpeg" "$validator_dir/ffmpeg"
    chmod 0555 "$validator_dir/ffprobe" "$validator_dir/ffmpeg"
    ffprobe="$(realpath "$validator_dir/ffprobe")"
    ffmpeg="$(realpath "$validator_dir/ffmpeg")"
    write_configured_env "$env_file" "$work/media"
    before="$(sha256sum "$env_file")"

    run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        VALIDATOR_FFPROBE_BIN="$ffprobe" VALIDATOR_FFMPEG_BIN="$ffmpeg"

    service="$work/root/etc/systemd/system/move-dovi5-to-quarantine.service"
    assert_contains "$service" "Environment=FFPROBE_BIN=$ffprobe"
    assert_contains "$service" "Environment=FFMPEG_BIN=$ffmpeg"
    assert_contains "$work/commands.log" "ffprobe:$ffprobe:"
    assert_contains "$work/commands.log" "ffmpeg:$ffmpeg:"
    assert_not_contains "$work/commands.log" 'apt-get:'
    [[ "$before" == "$(sha256sum "$env_file")" ]] || \
        fail "explicit validator paths rewrote the existing environment"
    assert_not_contains "$env_file" 'VALIDATOR_FFPROBE_BIN='
    assert_not_contains "$env_file" 'VALIDATOR_FFMPEG_BIN='
}

test_existing_validator_selection_survives_rerun_without_selectors() {
    local work env_file validator_dir ffprobe ffmpeg service
    work="$(new_case preserved-validator-selection)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    validator_dir="$work/root/opt/dovi5-validator"
    mkdir -p "$validator_dir"
    cp "$work/bin/ffprobe" "$validator_dir/ffprobe"
    cp "$work/bin/ffmpeg" "$validator_dir/ffmpeg"
    chmod 0555 "$validator_dir/ffprobe" "$validator_dir/ffmpeg"
    ffprobe="$(realpath "$validator_dir/ffprobe")"
    ffmpeg="$(realpath "$validator_dir/ffmpeg")"
    write_configured_env "$env_file" "$work/media"

    run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        VALIDATOR_FFPROBE_BIN="$ffprobe" VALIDATOR_FFMPEG_BIN="$ffmpeg"
    run_installer "$work" INSTALL_EUID_OVERRIDE=0

    service="$work/root/etc/systemd/system/move-dovi5-to-quarantine.service"
    assert_contains "$service" "Environment=FFPROBE_BIN=$ffprobe"
    assert_contains "$service" "Environment=FFMPEG_BIN=$ffmpeg"
    assert_not_contains "$service" "Environment=FFPROBE_BIN=$work/bin/ffprobe"
    assert_not_contains "$service" "Environment=FFMPEG_BIN=$work/bin/ffmpeg"
}

test_relative_explicit_validator_path_fails_before_system_changes() {
    local work
    work="$(new_case relative-validator-path)"
    write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        VALIDATOR_FFPROBE_BIN=relative/ffprobe \
        VALIDATOR_FFMPEG_BIN="$work/bin/ffmpeg"; then
        fail "installer accepted a relative explicit validator path"
    fi

    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_missing_explicit_validator_path_fails_before_system_changes() {
    local work
    work="$(new_case missing-validator-path)"
    write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"

    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 \
        VALIDATOR_FFPROBE_BIN="$work/bin/ffprobe" \
        VALIDATOR_FFMPEG_BIN="$work/does-not-exist/ffmpeg"; then
        fail "installer accepted a missing explicit validator path"
    fi

    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'apt-get:'
}

test_validator_capability_failures_leave_timer_inactive() {
    local mode work
    for mode in ffprobe missing_h264 missing_hevc missing_matroska missing_mp4; do
        work="$(new_case "validator-capability-$mode")"
        write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"

        if [[ "$mode" == "ffprobe" ]]; then
            if run_installer "$work" INSTALL_EUID_OVERRIDE=0 TEST_FFPROBE_SELF_TEST_FAIL=1; then
                fail "installer accepted a failing FFprobe self-test"
            fi
            assert_contains "$work/commands.log" 'ffprobe:'
        else
            if run_installer "$work" INSTALL_EUID_OVERRIDE=0 TEST_FFMPEG_CAPABILITY_MODE="$mode"; then
                fail "installer accepted incomplete FFmpeg capability set: $mode"
            fi
            case "$mode" in
                missing_h264|missing_hevc)
                    assert_contains "$work/commands.log" '-decoders'
                    ;;
                missing_matroska|missing_mp4)
                    assert_contains "$work/commands.log" '-demuxers'
                    ;;
            esac
        fi

        assert_contains "$work/commands.log" 'systemctl:stop move-dovi5-to-quarantine.timer'
        assert_not_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
        assert_not_contains "$work/commands.log" 'systemctl:start'
    done
}

test_legacy_env_gets_default_roots_without_rewrite() {
    local work env_file before
    work="$(new_case legacy-env)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    write_configured_env "$env_file.tmp" "$work/media"
    grep -vE '^(MEDIA_MOUNTPOINT|PLEX_[A-Z]+_DIR)=' "$env_file.tmp" >"$env_file"
    rm "$env_file.tmp"
    chmod 0640 "$env_file"
    before="$(sha256sum "$env_file")"
    run_installer "$work" INSTALL_EUID_OVERRIDE=0
    [[ "$before" == "$(sha256sum "$env_file")" ]] || fail "legacy environment was rewritten"
    assert_contains "$work/commands.log" 'roots:'
    for library in PlexTV PlexTVHD PlexFilms PlexFilmsHD; do
        assert_contains "$work/commands.log" "legacy-env/media/$library"
    done
    assert_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
}

test_rendered_units_are_hardened() {
    local work service timer env_line ffprobe_line ffmpeg_line
    work="$(new_case units)"
    write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"
    run_installer "$work" INSTALL_EUID_OVERRIDE=0
    service="$work/root/etc/systemd/system/move-dovi5-to-quarantine.service"
    timer="$work/root/etc/systemd/system/move-dovi5-to-quarantine.timer"
    assert_contains "$service" 'Description=Delete Dolby Vision Profile 5 media and queue Servarr recovery'
    assert_contains "$service" "EnvironmentFile=$work/root/home/frigate/dovi5-frigate-ops.env"
    assert_not_contains "$service" 'EnvironmentFile=-'
    assert_contains "$service" 'Group=media'
    assert_contains "$service" 'StateDirectory=dovi5-frigate-ops'
    assert_contains "$service" 'StateDirectoryMode=0700'
    assert_contains "$service" 'TimeoutStartSec=12h'
    assert_contains "$service" 'UMask=0077'
    assert_contains "$service" "WorkingDirectory=$work/root/home/frigate"
    assert_contains "$service" 'Environment=SERVARR_OUTBOX_DB=/var/lib/dovi5-frigate-ops/servarr-outbox.sqlite3'
    env_line="$(grep -n -m1 '^EnvironmentFile=' "$service" | cut -d: -f1)"
    ffprobe_line="$(grep -n -m1 '^Environment=FFPROBE_BIN=' "$service" | cut -d: -f1)"
    ffmpeg_line="$(grep -n -m1 '^Environment=FFMPEG_BIN=' "$service" | cut -d: -f1)"
    ((env_line < ffprobe_line && env_line < ffmpeg_line)) || \
        fail "root-owned validator paths must override any EnvironmentFile entries"
    assert_not_contains "$service" 'PrivateTmp='
    assert_contains "$timer" 'Description=Run DoVi 5 delete-and-recover scan every 15 minutes'
}

test_invalid_wait_values_fail_before_system_changes() {
    local work
    work="$(new_case invalid-wait)"
    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 INSTALL_WAIT_SECONDS=not-a-number; then
        fail "invalid wait value was accepted"
    fi
    [[ ! -s "$work/commands.log" ]] || fail "invalid wait value changed system state"
}

test_missing_timer_unit_is_allowed() {
    local work
    work="$(new_case missing-timer)"
    write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"
    run_installer "$work" INSTALL_EUID_OVERRIDE=0 TEST_TIMER_STOP_NOT_FOUND=1
    assert_contains "$work/commands.log" 'systemctl:show move-dovi5-to-quarantine.timer -p LoadState --value'
    assert_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
}

test_service_query_error_fails_closed() {
    local work
    work="$(new_case service-query-error)"
    write_configured_env "$work/root/home/frigate/dovi5-frigate-ops.env" "$work/media"
    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 TEST_SERVICE_QUERY_FAIL=1; then
        fail "systemctl service query failure was treated as idle"
    fi
    assert_contains "$work/commands.log" 'systemctl:stop move-dovi5-to-quarantine.timer'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
}

test_environment_data_is_never_executed() {
    local work env_file marker
    work="$(new_case env-data)"
    env_file="$work/root/home/frigate/dovi5-frigate-ops.env"
    marker="$work/env-was-executed"
    write_configured_env "$env_file" "$work/media"
    # This must remain inert environment data.
    # shellcheck disable=SC2016
    printf 'EVIL=$(touch${IFS}%s)\n' "$marker" >>"$env_file"
    run_installer "$work" INSTALL_EUID_OVERRIDE=0
    [[ ! -e "$marker" ]] || fail "environment data was executed as shell code"
    assert_contains "$work/commands.log" 'systemctl:enable --now move-dovi5-to-quarantine.timer'
}

test_invalid_staged_scanner_stops_before_system_changes() {
    local work source
    work="$(new_case invalid-staged-scanner)"
    source="$work/source"
    mkdir -p "$source/dovi5_ops" "$source/systemd"
    cp "$ROOT/move_dovi5_to_quarantine.sh" "$ROOT/servarr_outbox.py" \
        "$ROOT/dovi5-frigate-ops.env.example" "$source/"
    cp "$ROOT/dovi5_ops/"*.py "$source/dovi5_ops/"
    cp "$ROOT/systemd/move-dovi5-to-quarantine.service.tpl" \
        "$ROOT/systemd/move-dovi5-to-quarantine.timer" "$source/systemd/"
    printf '\nif broken scanner syntax\n' >>"$source/move_dovi5_to_quarantine.sh"
    if run_installer "$work" INSTALL_EUID_OVERRIDE=0 INSTALL_SOURCE_ROOT="$source"; then
        fail "invalid staged scanner syntax was deployed"
    fi
    assert_not_contains "$work/commands.log" 'systemctl:'
    assert_not_contains "$work/commands.log" 'install:'
    assert_not_contains "$work/commands.log" 'secure-env-helper:'
}

tests=(
    test_configured_root_install
    test_non_root_uses_sudo
    test_blank_fresh_install_is_inactive
    test_existing_regular_env_is_repaired_atomically_without_rewrite
    test_existing_env_symlink_fails_before_system_changes
    test_existing_env_directory_fails_before_system_changes
    test_existing_env_fifo_fails_before_system_changes
    test_environment_path_swap_fails_before_system_changes
    test_oversized_existing_env_fails_before_system_changes
    test_environment_in_place_change_fails_before_system_changes
    test_environment_post_read_change_fails_before_system_changes
    test_environment_fifo_swap_does_not_block_before_system_changes
    test_secure_temp_substitution_fails_before_system_changes
    test_group_writable_home_parent_fails_before_system_changes
    test_non_root_owned_home_parent_fails_before_system_changes
    test_ci_runs_installer_as_root_with_real_helper
    test_missing_primary_group_fails_before_system_changes
    test_active_scan_waits_without_termination
    test_timeout_preserves_deployment
    test_validation_failures_remain_inactive
    test_missing_validator_tools_are_provisioned_and_rendered
    test_validator_provisioning_failure_fails_closed
    test_explicit_validator_paths_are_rendered_without_rewriting_env
    test_existing_validator_selection_survives_rerun_without_selectors
    test_relative_explicit_validator_path_fails_before_system_changes
    test_missing_explicit_validator_path_fails_before_system_changes
    test_validator_capability_failures_leave_timer_inactive
    test_legacy_env_gets_default_roots_without_rewrite
    test_rendered_units_are_hardened
    test_invalid_wait_values_fail_before_system_changes
    test_missing_timer_unit_is_allowed
    test_service_query_error_fails_closed
    test_environment_data_is_never_executed
    test_invalid_staged_scanner_stops_before_system_changes
)

if (($#)); then
    for requested in "$@"; do
        if [[ "$requested" != test_* ]] || ! declare -F "$requested" >/dev/null; then
            fail "unknown installer test: $requested"
        fi
        "$requested"
    done
else
    for installer_test in "${tests[@]}"; do
        "$installer_test"
    done
fi

echo "Installer lifecycle tests passed"
