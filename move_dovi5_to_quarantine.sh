#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LOG_DIR="${LOG_DIR:-/mnt/media/_orphaned_quarantine}"
LOG="$LOG_DIR/move_dovi5_to_quarantine.log"
SERVARR_OUTBOX_DB="${SERVARR_OUTBOX_DB:-${OUTBOX_DB:-/var/lib/dovi5-frigate-ops/servarr-outbox.sqlite3}}"
LOCKFILE="${LOCKFILE:-$(dirname -- "$SERVARR_OUTBOX_DB")/scan.lock}"
STATE_FILE="${STATE_FILE:-$LOG_DIR/dovi5_checked_files.tsv}"
MEDIA_MOUNTPOINT="${MEDIA_MOUNTPOINT:-/mnt/media}"
SERVARR_OUTBOX_HELPER="${SERVARR_OUTBOX_HELPER:-${OUTBOX_HELPER:-$SCRIPT_DIR/servarr_outbox.py}}"
SERVARR_ENV_FILE="${SERVARR_ENV_FILE:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

PLEX_TV_DIR="${PLEX_TV_DIR:-/mnt/media/PlexTV}"
PLEX_TVHD_DIR="${PLEX_TVHD_DIR:-/mnt/media/PlexTVHD}"
PLEX_FILMS_DIR="${PLEX_FILMS_DIR:-/mnt/media/PlexFilms}"
PLEX_FILMSHD_DIR="${PLEX_FILMSHD_DIR:-/mnt/media/PlexFilmsHD}"

FIND_TIMEOUT_SECONDS="${FIND_TIMEOUT_SECONDS:-600}"
FINGERPRINT_TIMEOUT_SECONDS="${FINGERPRINT_TIMEOUT_SECONDS:-30}"
MEDIAINFO_TIMEOUT_SECONDS="${MEDIAINFO_TIMEOUT_SECONDS:-300}"
FFPROBE_BIN="${FFPROBE_BIN:-ffprobe}"
FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"
FFPROBE_TIMEOUT_SECONDS="${FFPROBE_TIMEOUT_SECONDS:-60}"
FFMPEG_TIMEOUT_SECONDS="${FFMPEG_TIMEOUT_SECONDS:-120}"
VALIDATOR_MEMORY_LIMIT_KIB="${VALIDATOR_MEMORY_LIMIT_KIB:-2097152}"
MAX_VALIDATION_DELETIONS_PER_RUN="${MAX_VALIDATION_DELETIONS_PER_RUN:-1}"
MIN_FILE_AGE_SECONDS="${MIN_FILE_AGE_SECONDS:-300}"
STATE_COMPACT_EVERY="${STATE_COMPACT_EVERY:-5000}"
STATE_COMPACT_INTERVAL_SECONDS="${STATE_COMPACT_INTERVAL_SECONDS:-86400}"
STATE_MARKER="# dovi5-state-v2"

mkdir -p "$LOG_DIR" "$(dirname -- "$STATE_FILE")"
touch "$LOG"

log() {
    echo "$(date '+%F %T') $*" | tee -a "$LOG"
}

fatal() {
    log "ERROR $*"
    exit 1
}

if [[ "${SERVARR_DRY_RUN:-0}" == "1" ]]; then
    fatal "SERVARR_DRY_RUN=1 is incompatible with the delete-only scanner; refusing to scan"
fi

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log "SKIP another DoVi Profile 5 scan is already running"
    exit 0
fi

for dependency in find flock mediainfo mountpoint realpath timeout "$PYTHON_BIN"; do
    command -v "$dependency" >/dev/null 2>&1 || fatal "missing dependency: $dependency"
done
command -v "$FFPROBE_BIN" >/dev/null 2>&1 || fatal "missing dependency: $FFPROBE_BIN"
command -v "$FFMPEG_BIN" >/dev/null 2>&1 || fatal "missing dependency: $FFMPEG_BIN"
[[ -f "$SERVARR_OUTBOX_HELPER" ]] || fatal "missing Servarr outbox helper"

[[ "$MIN_FILE_AGE_SECONDS" =~ ^[0-9]+$ ]] || fatal "MIN_FILE_AGE_SECONDS must be a non-negative integer"
[[ "$STATE_COMPACT_EVERY" =~ ^[1-9][0-9]*$ ]] || fatal "STATE_COMPACT_EVERY must be a positive integer"
[[ "$STATE_COMPACT_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || fatal "STATE_COMPACT_INTERVAL_SECONDS must be a positive integer"
[[ "$VALIDATOR_MEMORY_LIMIT_KIB" =~ ^[1-9][0-9]*$ ]] || fatal "VALIDATOR_MEMORY_LIMIT_KIB must be a positive integer"
[[ "$MAX_VALIDATION_DELETIONS_PER_RUN" =~ ^[0-9]+$ ]] || fatal "MAX_VALIDATION_DELETIONS_PER_RUN must be a non-negative integer"
for timeout_value in "$FIND_TIMEOUT_SECONDS" "$FINGERPRINT_TIMEOUT_SECONDS" "$MEDIAINFO_TIMEOUT_SECONDS" \
    "$FFPROBE_TIMEOUT_SECONDS" "$FFMPEG_TIMEOUT_SECONDS"; do
    [[ "$timeout_value" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || fatal "timeout settings must be numeric"
done

canonical_mount="$(realpath -e -- "$MEDIA_MOUNTPOINT" 2>/dev/null)" || fatal "media mountpoint does not exist"
[[ -d "$canonical_mount" ]] || fatal "media mountpoint is not a directory"
mountpoint -q -- "$canonical_mount" || fatal "media mountpoint is not mounted"

ROOT_INPUTS=("$PLEX_TV_DIR" "$PLEX_TVHD_DIR" "$PLEX_FILMS_DIR" "$PLEX_FILMSHD_DIR")
ROOT_LABELS=("PlexTV" "PlexTVHD" "PlexFilms" "PlexFilmsHD")
SCAN_ROOTS=()

for index in "${!ROOT_INPUTS[@]}"; do
    root="$(realpath -e -- "${ROOT_INPUTS[$index]}" 2>/dev/null)" || fatal "${ROOT_LABELS[$index]} root does not exist"
    [[ -d "$root" ]] || fatal "${ROOT_LABELS[$index]} root is not a directory"
    [[ "$root" == "$canonical_mount"/* ]] || fatal "${ROOT_LABELS[$index]} root is outside the media mountpoint"
    SCAN_ROOTS+=("$root")
done

for ((left = 0; left < ${#SCAN_ROOTS[@]}; left++)); do
    for ((right = left + 1; right < ${#SCAN_ROOTS[@]}; right++)); do
        left_root="${SCAN_ROOTS[$left]}"
        right_root="${SCAN_ROOTS[$right]}"
        if [[ "$left_root" == "$right_root" || "$left_root" == "$right_root"/* || "$right_root" == "$left_root"/* ]]; then
            fatal "library roots duplicate or overlap: ${ROOT_LABELS[$left]} and ${ROOT_LABELS[$right]}"
        fi
    done
done

PLEX_TV_DIR="${SCAN_ROOTS[0]}"
PLEX_TVHD_DIR="${SCAN_ROOTS[1]}"
PLEX_FILMS_DIR="${SCAN_ROOTS[2]}"
PLEX_FILMSHD_DIR="${SCAN_ROOTS[3]}"

# Git Bash invokes a native Windows Python. Convert only the exported helper
# configuration; Bash keeps the canonical POSIX roots for find and routing.
if command -v cygpath >/dev/null 2>&1 && "$PYTHON_BIN" -c 'import os,sys; sys.exit(0 if os.name == "nt" else 1)' >/dev/null 2>&1; then
    PLEX_TV_DIR="$(cygpath -w "$PLEX_TV_DIR")"
    PLEX_TVHD_DIR="$(cygpath -w "$PLEX_TVHD_DIR")"
    PLEX_FILMS_DIR="$(cygpath -w "$PLEX_FILMS_DIR")"
    PLEX_FILMSHD_DIR="$(cygpath -w "$PLEX_FILMSHD_DIR")"
    export PLEX_TV_DIR PLEX_TVHD_DIR PLEX_FILMS_DIR PLEX_FILMSHD_DIR
else
    export PLEX_TV_DIR PLEX_TVHD_DIR PLEX_FILMS_DIR PLEX_FILMSHD_DIR
fi

OUTBOX_COMMAND=("$PYTHON_BIN" "$SERVARR_OUTBOX_HELPER" --db "$SERVARR_OUTBOX_DB")
if [[ -n "$SERVARR_ENV_FILE" ]]; then
    OUTBOX_COMMAND+=(--env-file "$SERVARR_ENV_FILE")
fi

if ! config_output="$("${OUTBOX_COMMAND[@]}" check-config 2>&1)"; then
    fatal "Servarr static configuration failed: $config_output"
fi

run_drain() {
    local position="$1"
    local output status=0
    output="$("${OUTBOX_COMMAND[@]}" drain 2>&1)" || status=$?
    log "OUTBOX $position status=$status $output"
    if [[ "$status" -ge 2 ]]; then
        fatal "outbox $position failed closed"
    fi
    return 0
}

run_drain "pre-drain"

initialize_state_v2() {
    local first_line="" backup temporary initialized_at
    if [[ -e "$STATE_FILE" ]]; then
        IFS= read -r first_line <"$STATE_FILE" || true
    fi
    if [[ "$first_line" == "$STATE_MARKER" ]]; then
        return
    fi
    if [[ -e "$STATE_FILE" ]]; then
        backup="$STATE_FILE.legacy-$(date '+%Y%m%d%H%M%S')-$$"
        mv -- "$STATE_FILE" "$backup"
        sync -f "$backup" || fatal "could not durably back up legacy state"
        log "STATE backed up untrusted legacy cache: $backup"
    fi
    temporary="$STATE_FILE.tmp.$$"
    initialized_at="$(date '+%s')"
    printf '%s\n# compacted_at\t%s\n' "$STATE_MARKER" "$initialized_at" >"$temporary"
    sync -f "$temporary" || fatal "could not persist state-v2 marker"
    mv -- "$temporary" "$STATE_FILE"
    sync -f "$STATE_FILE" || fatal "could not persist state-v2 file"
}

initialize_state_v2

declare -A CHECKED_FINGERPRINT=()
declare -A CHECKED_STATUS=()
STATE_LAST_COMPACT_AT=0
# State v2 is TSV: tab/newline path names are unsupported and safely reprobed.
load_state_v2() {
    local marker path device inode size mtime_ns ctime_ns status _checked_at
    IFS= read -r marker <"$STATE_FILE" || fatal "could not read state-v2 marker"
    [[ "$marker" == "$STATE_MARKER" ]] || fatal "state-v2 marker changed unexpectedly"
    while IFS=$'\t' read -r path device inode size mtime_ns ctime_ns status _checked_at; do
        if [[ "$path" == "# compacted_at" && "$device" =~ ^[0-9]+$ ]]; then
            STATE_LAST_COMPACT_AT="$device"
            continue
        fi
        [[ -n "${path:-}" && -n "${device:-}" && -n "${inode:-}" && -n "${size:-}" ]] || continue
        [[ "$status" == "not_dovi5" || "$status" == "validation_failed_once" ]] || continue
        CHECKED_FINGERPRINT["$path"]="$device:$inode:$size:$mtime_ns:$ctime_ns"
        CHECKED_STATUS["$path"]="$status"
    done < <(tail -n +2 "$STATE_FILE")
}

load_state_v2

RUN_CHECKED_AT="$(date '+%s')"
STATE_NEW_RECORDS=0
STATE_COMPACTION_REQUESTED=0
declare -A SEEN_PATHS=()

compact_state() {
    local temporary path fingerprint status device inode size mtime_ns ctime_ns compacted_at
    temporary="$STATE_FILE.tmp.$$"
    compacted_at="$(date '+%s')"
    printf '%s\n# compacted_at\t%s\n' "$STATE_MARKER" "$compacted_at" >"$temporary"
    for path in "${!CHECKED_FINGERPRINT[@]}"; do
        [[ -n "${SEEN_PATHS[$path]+present}" ]] || continue
        fingerprint="${CHECKED_FINGERPRINT[$path]}"
        status="${CHECKED_STATUS[$path]}"
        IFS=: read -r device inode size mtime_ns ctime_ns <<<"$fingerprint"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$path" "$device" "$inode" "$size" "$mtime_ns" "$ctime_ns" "$status" "$RUN_CHECKED_AT" >>"$temporary"
    done
    sync -f "$temporary" || fatal "could not persist compacted state"
    mv -- "$temporary" "$STATE_FILE"
    sync -f "$STATE_FILE" || fatal "could not install compacted state"
    STATE_LAST_COMPACT_AT="$compacted_at"
    STATE_NEW_RECORDS=0
    STATE_COMPACTION_REQUESTED=0
}

record_state() {
    local path="$1"
    local fingerprint="$2"
    local status="$3"
    local device inode size mtime_ns ctime_ns
    [[ "$status" == "not_dovi5" || "$status" == "validation_failed_once" ]] || \
        fatal "refusing to persist unknown state status: $status"
    CHECKED_FINGERPRINT["$path"]="$fingerprint"
    CHECKED_STATUS["$path"]="$status"
    IFS=: read -r device inode size mtime_ns ctime_ns <<<"$fingerprint"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$path" "$device" "$inode" "$size" "$mtime_ns" "$ctime_ns" "$status" "$RUN_CHECKED_AT" >>"$STATE_FILE"
    ((STATE_NEW_RECORDS += 1))
    if ((STATE_NEW_RECORDS >= STATE_COMPACT_EVERY)); then
        STATE_COMPACTION_REQUESTED=1
    fi
}

normalize_find_time() {
    local raw="$1"
    local destination="$2"
    local seconds fraction
    seconds="${raw%%.*}"
    if [[ "$raw" == *.* ]]; then
        fraction="${raw#*.}"
    else
        fraction=""
    fi
    fraction="${fraction//[^0-9]/}"
    fraction="${fraction:0:9}"
    while ((${#fraction} < 9)); do
        fraction+="0"
    done
    printf -v "$destination" '%s%s' "$seconds" "$fraction"
}

POST_FINGERPRINT=""
POST_FINGERPRINT_FILE=""
refingerprint_after_probe() {
    local path="$1"
    local device inode size mtime_raw ctime_raw mtime_ns ctime_ns
    : >"$POST_FINGERPRINT_FILE"
    if ! timeout --signal=TERM "$FINGERPRINT_TIMEOUT_SECONDS" \
        find "$path" -maxdepth 0 -type f -printf '%D\0%i\0%s\0%T@\0%C@\0' >"$POST_FINGERPRINT_FILE"; then
        return 1
    fi
    exec 7<"$POST_FINGERPRINT_FILE"
    IFS= read -r -d '' device <&7 || return 1
    IFS= read -r -d '' inode <&7 || return 1
    IFS= read -r -d '' size <&7 || return 1
    IFS= read -r -d '' mtime_raw <&7 || return 1
    IFS= read -r -d '' ctime_raw <&7 || return 1
    exec 7<&-
    normalize_find_time "$mtime_raw" mtime_ns
    normalize_find_time "$ctime_raw" ctime_ns
    POST_FINGERPRINT="$device:$inode:$size:$mtime_ns:$ctime_ns"
}

label_for_path() {
    local path="$1"
    local destination="$2"
    local index selected=""
    for index in "${!SCAN_ROOTS[@]}"; do
        if [[ "$path" == "${SCAN_ROOTS[$index]}"/* ]]; then
            selected="${ROOT_LABELS[$index]}"
            break
        fi
    done
    [[ -n "$selected" ]] || return 1
    printf -v "$destination" '%s' "$selected"
}

validator_failure_is_confirmed_invalid() {
    local status="$1"
    local error_file="$2"
    local line lower confirmed=0
    if ((status == 124 || status == 125 || status == 126 || status == 127 || status >= 128)); then
        return 1
    fi
    while IFS= read -r line; do
        lower="${line,,}"
        case "$lower" in
            *"cannot allocate memory"*|*"out of memory"*|*"memory exhausted"*|*"std::bad_alloc"*|*"failed to allocate"*|\
            *"permission denied"*|*"operation not permitted"*|*"resource temporarily unavailable"*|*"input/output error"*|\
            *"i/o error"*|*"stale file handle"*|*"no such file"*|*"unsupported"*|*"not supported"*|\
            *"unknown decoder"*|*"decoder not found"*|*"protocol not found"*|*"unknown protocol"*|*"not on whitelist"*|*"demuxer not found"*)
                return 1
                ;;
            *"invalid data found when processing input"*|*"ebml header parsing failed"*|*"error while decoding stream"*|\
            *"invalid nal unit"*|*"error splitting the input into nal units"*|*"moov atom not found"*)
                confirmed=1
                ;;
        esac
    done <"$error_file"
    ((confirmed > 0))
}

apply_validator_limits() {
    ulimit -v "$VALIDATOR_MEMORY_LIMIT_KIB" || return 125
    # Limit diagnostic growth as well as virtual memory. MSYS cannot lower
    # RLIMIT_FSIZE, but production is Linux and must fail closed if it cannot.
    if ! ulimit -f 2048 2>/dev/null; then
        [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]] || return 125
    fi
}

VALIDATION_RESULT=""
validate_failed_media() {
    local media_path="$1"
    local fingerprint="$2"
    local _device _inode expected_size _mtime_ns _ctime_ns
    local magic="" probe_output="" probe_status=0 line has_video=0 has_dovi5=0 decode_status=0
    local LC_ALL=C

    VALIDATION_RESULT="inconclusive"
    IFS=: read -r _device _inode expected_size _mtime_ns _ctime_ns <<<"$fingerprint"

    if [[ "${media_path,,}" == *.mkv ]]; then
        if [[ ! "$expected_size" =~ ^[0-9]+$ ]] || ((expected_size < 4)); then
            VALIDATION_RESULT="invalid_container"
            return 0
        fi
        : >"$VALIDATION_ERROR_FILE"
        if ! IFS= read -r -N 4 magic <"$media_path" 2>"$VALIDATION_ERROR_FILE"; then
            return 0
        fi
        if [[ "$magic" != $'\x1a\x45\xdf\xa3' ]]; then
            VALIDATION_RESULT="invalid_container"
            return 0
        fi
    fi

    : >"$VALIDATION_ERROR_FILE"
    probe_output="$(
        (
            apply_validator_limits || exit $?
            exec timeout --signal=TERM --kill-after=5s "$FFPROBE_TIMEOUT_SECONDS" \
                "$FFPROBE_BIN" -hide_banner -v error -max_alloc 268435456 \
                -protocol_whitelist file,pipe -probesize 67108864 \
                -analyzeduration 30000000 -max_probe_packets 5000 -max_streams 64 \
                -select_streams V:0 \
                -show_entries 'stream=index:stream_side_data=dv_profile' \
                -of 'default=noprint_wrappers=1:nokey=0' "$media_path"
        ) 2>"$VALIDATION_ERROR_FILE"
    )" || probe_status=$?
    if ((probe_status != 0)); then
        if validator_failure_is_confirmed_invalid "$probe_status" "$VALIDATION_ERROR_FILE"; then
            VALIDATION_RESULT="invalid_probe"
        fi
        return 0
    fi

    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^index=[0-9]+$ ]]; then
            has_video=1
        elif [[ "$line" == "dv_profile=5" ]]; then
            has_dovi5=1
        fi
    done <<<"$probe_output"
    if ((has_video == 0)); then
        VALIDATION_RESULT="no_video"
        return 0
    fi
    if ((has_dovi5 > 0)); then
        VALIDATION_RESULT="dovi5"
        return 0
    fi

    : >"$VALIDATION_ERROR_FILE"
    (
        apply_validator_limits || exit $?
        exec timeout --signal=TERM --kill-after=5s "$FFMPEG_TIMEOUT_SECONDS" \
            "$FFMPEG_BIN" -hide_banner -v error -nostdin -xerror -err_detect explode \
            -max_alloc 268435456 -protocol_whitelist file,pipe -probesize 67108864 \
            -analyzeduration 30000000 -max_probe_packets 5000 -max_streams 64 \
            -max_pixels 35389440 -hwaccel none -threads:v 1 \
            -i "$media_path" -map 0:V:0 -frames:v 1 -an -sn -dn -f null -
    ) 2>"$VALIDATION_ERROR_FILE" || decode_status=$?
    if ((decode_status == 0)); then
        VALIDATION_RESULT="valid"
    elif validator_failure_is_confirmed_invalid "$decode_status" "$VALIDATION_ERROR_FILE"; then
        VALIDATION_RESULT="invalid_decode"
    fi
}

queue_and_delete() {
    local media_path="$1"
    local media_label="$2"
    local fingerprint="$3"
    local reason="$4"
    local profile="${5:-}"
    local enqueue_status=0 enqueue_output job_id cancel_status

    enqueue_output="$(
        "${OUTBOX_COMMAND[@]}" enqueue \
            --label "$media_label" \
            --path "$media_path" \
            --fingerprint "$fingerprint" 2>&1
    )" || enqueue_status=$?
    if ((enqueue_status != 0)) || [[ ! "$enqueue_output" =~ ^[0-9]+$ ]]; then
        ((ENQUEUE_FAILED += 1))
        log "ERROR durable enqueue failed label=$media_label status=$enqueue_status: $media_path"
        return 0
    fi
    job_id="$enqueue_output"

    # POSIX has a narrow path-replacement race between this final check and rm;
    # an unsafe pseudo-atomic unlink would weaken, not improve, this boundary.
    if ! refingerprint_after_probe "$media_path" || [[ "$POST_FINGERPRINT" != "$fingerprint" ]]; then
        ((UNSTABLE += 1))
        cancel_status=0
        "${OUTBOX_COMMAND[@]}" cancel --job-id "$job_id" --reason "source changed before delete" >>"$LOG" 2>&1 || cancel_status=$?
        if ((cancel_status != 0)); then
            log "ERROR could not supersede changed-source job id=$job_id"
        fi
        log "WARN source changed during MediaInfo probe; retaining: $media_path"
        return 0
    fi

    if [[ "$reason" == "dovi5" ]]; then
        log "DOVI5 delete-only label=$media_label job=$job_id: $media_path [$profile]"
    else
        log "VALIDATION delete-only label=$media_label job=$job_id reason=$reason: $media_path"
    fi
    if rm -f -- "$media_path"; then
        ((DELETED += 1))
        if [[ "$reason" == "dovi5" ]]; then
            log "DELETE DoVi5 source job=$job_id: $media_path"
        else
            log "DELETE unplayable source job=$job_id reason=$reason: $media_path"
        fi
    else
        ((DELETE_FAILED += 1))
        if refingerprint_after_probe "$media_path" && [[ "$POST_FINGERPRINT" == "$fingerprint" ]]; then
            cancel_status=0
            "${OUTBOX_COMMAND[@]}" cancel --job-id "$job_id" --reason "source deletion failed" >>"$LOG" 2>&1 || cancel_status=$?
            if ((cancel_status != 0)); then
                log "ERROR could not cancel failed-delete job id=$job_id"
            fi
        else
            log "WARN source deletion failed but the original fingerprint was not confirmed; retaining recovery job id=$job_id"
        fi
        if [[ "$reason" == "dovi5" ]]; then
            log "ERROR failed to delete DoVi5 source job=$job_id: $media_path"
        else
            log "ERROR failed to delete unplayable source job=$job_id reason=$reason: $media_path"
        fi
    fi
}

ENUMERATION_FILE="$(mktemp "${TMPDIR:-/tmp}/dovi5-enumeration.XXXXXX")"
POST_FINGERPRINT_FILE="$(mktemp "${TMPDIR:-/tmp}/dovi5-fingerprint.XXXXXX")"
VALIDATION_ERROR_FILE="$(mktemp "${TMPDIR:-/tmp}/dovi5-validation-error.XXXXXX")"
cleanup() {
    rm -f -- "$ENUMERATION_FILE" "$POST_FINGERPRINT_FILE" "$VALIDATION_ERROR_FILE"
}
trap cleanup EXIT

log "Starting DoVi Profile 5 delete-only scan on $(hostname) mode=complete state=v2"
START_SECONDS=$SECONDS

if ! timeout --signal=TERM "$FIND_TIMEOUT_SECONDS" \
    find "${SCAN_ROOTS[@]}" -type f \
        \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \) \
        ! -iname '*.sdr.mkv' \
        ! -iname '*.sdr.tmp.mkv' \
        -printf '%p\0%D\0%i\0%s\0%T@\0%C@\0' >"$ENUMERATION_FILE"; then
    fatal "complete media enumeration failed or timed out; state was not pruned"
fi

TOTAL=0
CACHED=0
TOO_YOUNG=0
PROBED=0
PROBE_FAILED=0
UNSTABLE=0
DOVI5=0
DELETED=0
ENQUEUE_FAILED=0
DELETE_FAILED=0
VALIDATION_INCONCLUSIVE=0
VALIDATION_CONFIRMED=0
VALIDATION_LIMIT_EXCEEDED=0
NOW_SECONDS="$(date '+%s')"
declare -a VALIDATION_PATHS=()
declare -a VALIDATION_LABELS=()
declare -a VALIDATION_FINGERPRINTS=()
declare -a VALIDATION_REASONS=()

exec 8<"$ENUMERATION_FILE"
while IFS= read -r -d '' media_path <&8; do
    IFS= read -r -d '' device <&8 || fatal "enumeration fingerprint stream was incomplete"
    IFS= read -r -d '' inode <&8 || fatal "enumeration fingerprint stream was incomplete"
    IFS= read -r -d '' size <&8 || fatal "enumeration fingerprint stream was incomplete"
    IFS= read -r -d '' mtime_raw <&8 || fatal "enumeration fingerprint stream was incomplete"
    IFS= read -r -d '' ctime_raw <&8 || fatal "enumeration fingerprint stream was incomplete"
    ((TOTAL += 1))
    SEEN_PATHS["$media_path"]=1

    normalize_find_time "$mtime_raw" mtime_ns
    normalize_find_time "$ctime_raw" ctime_ns
    fingerprint="$device:$inode:$size:$mtime_ns:$ctime_ns"

    validation_retry=0
    if [[ "${CHECKED_FINGERPRINT[$media_path]-}" == "$fingerprint" ]]; then
        if [[ "${CHECKED_STATUS[$media_path]-}" == "not_dovi5" ]]; then
            ((CACHED += 1))
            continue
        elif [[ "${CHECKED_STATUS[$media_path]-}" == "validation_failed_once" ]]; then
            validation_retry=1
        fi
    fi

    mtime_seconds="${mtime_raw%%.*}"
    ctime_seconds="${ctime_raw%%.*}"
    if [[ ! "$mtime_seconds" =~ ^-?[0-9]+$ || ! "$ctime_seconds" =~ ^-?[0-9]+$ ]]; then
        ((TOO_YOUNG += 1))
        continue
    fi
    latest_change_seconds="$mtime_seconds"
    if ((ctime_seconds > latest_change_seconds)); then
        latest_change_seconds="$ctime_seconds"
    fi
    if ((NOW_SECONDS - latest_change_seconds < MIN_FILE_AGE_SECONDS)); then
        ((TOO_YOUNG += 1))
        continue
    fi

    media_label=""
    if ! label_for_path "$media_path" media_label; then
        fatal "enumerated path has no exact root mapping: $media_path"
    fi

    ((PROBED += 1))
    probe_status=0
    probe_warning=""
    primary_line=""
    primary_format=""
    profile=""
    probe_output="$(
        timeout --signal=TERM "$MEDIAINFO_TIMEOUT_SECONDS" \
            mediainfo --Inform='Video;%Format%|%HDR_Format_Profile%\n' "$media_path" 2>>"$LOG"
    )" || probe_status=$?
    if ((probe_status != 0)); then
        probe_warning="MediaInfo probe failed status=$probe_status"
    else
        primary_line="${probe_output%%$'\n'*}"
        if [[ "$primary_line" == *'|'* ]]; then
            primary_format="${primary_line%%|*}"
            profile="${primary_line#*|}"
        fi
        if [[ -z "$primary_format" ]]; then
            probe_warning="MediaInfo returned no primary video stream"
        fi
    fi

    if [[ -n "$probe_warning" ]]; then
        ((PROBE_FAILED += 1))
        log "WARN $probe_warning: $media_path"
        if ! refingerprint_after_probe "$media_path" || [[ "$POST_FINGERPRINT" != "$fingerprint" ]]; then
            ((UNSTABLE += 1))
            log "WARN source changed during MediaInfo probe; retaining: $media_path"
            continue
        fi
        if ((validation_retry == 0)); then
            record_state "$media_path" "$fingerprint" "validation_failed_once"
            continue
        fi

        validate_failed_media "$media_path" "$fingerprint"
        if ! refingerprint_after_probe "$media_path" || [[ "$POST_FINGERPRINT" != "$fingerprint" ]]; then
            ((UNSTABLE += 1))
            log "WARN source changed during independent validation; retaining: $media_path"
            continue
        fi
        case "$VALIDATION_RESULT" in
            valid)
                record_state "$media_path" "$fingerprint" "not_dovi5"
                ;;
            inconclusive)
                ((VALIDATION_INCONCLUSIVE += 1))
                log "WARN independent validation was inconclusive; retaining failed-once state: $media_path"
                ;;
            dovi5)
                ((VALIDATION_CONFIRMED += 1))
                ((DOVI5 += 1))
                queue_and_delete "$media_path" "$media_label" "$fingerprint" "dovi5" "dvhe.05 (FFprobe)"
                ;;
            *)
                ((VALIDATION_CONFIRMED += 1))
                VALIDATION_PATHS+=("$media_path")
                VALIDATION_LABELS+=("$media_label")
                VALIDATION_FINGERPRINTS+=("$fingerprint")
                VALIDATION_REASONS+=("$VALIDATION_RESULT")
                ;;
        esac
        continue
    fi

    if [[ "$profile" != dvhe.05* ]]; then
        if ! refingerprint_after_probe "$media_path" || [[ "$POST_FINGERPRINT" != "$fingerprint" ]]; then
            ((UNSTABLE += 1))
            log "WARN source changed during MediaInfo probe; retaining: $media_path"
            continue
        fi
        record_state "$media_path" "$fingerprint" "not_dovi5"
        continue
    fi

    ((DOVI5 += 1))
    queue_and_delete "$media_path" "$media_label" "$fingerprint" "dovi5" "$profile"
done
exec 8<&-

if ((${#VALIDATION_PATHS[@]} > MAX_VALIDATION_DELETIONS_PER_RUN)); then
    VALIDATION_LIMIT_EXCEEDED=1
    log "ERROR validation deletion circuit breaker candidates=${#VALIDATION_PATHS[@]} limit=$MAX_VALIDATION_DELETIONS_PER_RUN; deleting none"
else
    for index in "${!VALIDATION_PATHS[@]}"; do
        queue_and_delete \
            "${VALIDATION_PATHS[$index]}" \
            "${VALIDATION_LABELS[$index]}" \
            "${VALIDATION_FINGERPRINTS[$index]}" \
            "${VALIDATION_REASONS[$index]}"
    done
fi

FINISH_SECONDS="$(date '+%s')"
if ((STATE_COMPACTION_REQUESTED > 0 || FINISH_SECONDS - STATE_LAST_COMPACT_AT >= STATE_COMPACT_INTERVAL_SECONDS)); then
    compact_state
fi

run_drain "post-drain"

count_status=0
count_output="$("${OUTBOX_COMMAND[@]}" count 2>&1)" || count_status=$?
if ((count_status != 0)); then
    fatal "could not count outbox state: $count_output"
fi
pending=0
errors=0
if [[ "$count_output" =~ \"pending\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
    pending="${BASH_REMATCH[1]}"
else
    fatal "outbox count omitted pending counter"
fi
if [[ "$count_output" =~ \"errors\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
    errors="${BASH_REMATCH[1]}"
else
    fatal "outbox count omitted error counter"
fi

runtime=$((SECONDS - START_SECONDS))
log "Finished DoVi Profile 5 scan mode=complete runtime_seconds=$runtime total=$TOTAL cached=$CACHED young=$TOO_YOUNG probed=$PROBED probe_failed=$PROBE_FAILED validation_confirmed=$VALIDATION_CONFIRMED validation_inconclusive=$VALIDATION_INCONCLUSIVE validation_limit_exceeded=$VALIDATION_LIMIT_EXCEEDED unstable=$UNSTABLE dovi5=$DOVI5 deleted=$DELETED enqueue_failed=$ENQUEUE_FAILED delete_failed=$DELETE_FAILED outbox_pending=$pending outbox_errors=$errors"

if ((VALIDATION_LIMIT_EXCEEDED > 0 || ENQUEUE_FAILED > 0 || DELETE_FAILED > 0 || pending > 0 || errors > 0)); then
    exit 1
fi
