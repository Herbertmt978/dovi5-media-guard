#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/move_dovi5_to_quarantine.sh"
OUTBOX_HELPER="$ROOT/servarr_outbox.py"
if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
    PYTHON_REAL="$(command -v python3)"
else
    PYTHON_REAL="$(command -v python)"
fi
FIND_REAL="$(command -v find)"
RM_REAL="$(command -v rm)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_exists() {
    [[ -e "$1" ]] || fail "expected path to exist: $1"
}

assert_missing() {
    [[ ! -e "$1" ]] || fail "expected path to be missing: $1"
}

assert_contains() {
    local path="$1"
    local pattern="$2"
    grep -F -- "$pattern" "$path" >/dev/null || fail "expected $path to contain: $pattern"
}

assert_not_contains() {
    local path="$1"
    local pattern="$2"
    ! grep -F -- "$pattern" "$path" >/dev/null || fail "expected $path not to contain: $pattern"
}

assert_line_count() {
    local expected="$1"
    local path="$2"
    local actual
    actual="$(wc -l <"$path")"
    [[ "$actual" -eq "$expected" ]] || fail "expected $expected lines in $path, got $actual"
}

assert_latest_state_status() {
    local state_file="$1"
    local media_path="$2"
    local expected="$3"
    local actual
    actual="$(
        awk -F '\t' -v target="$media_path" '
            $1 == target { status = $7 }
            END { print status }
        ' "$state_file"
    )"
    [[ "$actual" == "$expected" ]] || \
        fail "expected latest state for $media_path to be $expected, got ${actual:-missing}"
}

age_file() {
    touch -d '20 minutes ago' "$1"
}

write_ebml_prefixed_fixture() {
    local path="$1"
    local payload="${2:-validator fixture}"
    printf '\x1a\x45\xdf\xa3%s\n' "$payload" >"$path"
}

make_stubs() {
    local work="$1"
    local bin_dir="$work/bin"

    cat >"$bin_dir/mediainfo" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
file="${@: -1}"
printf '%s\n' "$file" >>"${MEDIAINFO_LOG:?}"

if [[ "${MEDIAINFO_MODE:-auto}" == "change" ]]; then
    if [[ ! -e "${MEDIAINFO_CHANGE_MARKER:?}" ]]; then
        printf 'changed during probe\n' >>"$file"
        touch -d '20 minutes ago' "$file"
        touch "$MEDIAINFO_CHANGE_MARKER"
    fi
    printf 'HEVC|dvhe.05\n'
    exit 0
fi
if [[ "${MEDIAINFO_MODE:-auto}" == "sdr" ]]; then
    printf 'AVC|\n'
    exit 0
fi

case "$file" in
    *ProbeError*) exit 7 ;;
    *ProbeTimeout*) sleep 5; printf 'HEVC|dvhe.05\n' ;;
    *Profile04*) printf 'HEVC|dvhe.04\n' ;;
    *Profile07*) printf 'HEVC|dvhe.07\n' ;;
    *Profile08*) printf 'HEVC|dvhe.08\n' ;;
    *NoHdr*) printf 'AVC|\n' ;;
    *NoVideo*) printf '\n' ;;
    *DoVi*) printf 'HEVC|dvhe.05.06\n' ;;
    *) printf 'AVC|\n' ;;
esac
STUB
    chmod +x "$bin_dir/mediainfo"

    cat >"$bin_dir/ffprobe" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${FFPROBE_LOG:?}"
case "${FFPROBE_MODE:-video}" in
    video) printf 'index=0\n' ;;
    dovi5) printf 'index=0\ndv_profile=5\n' ;;
    no_video) exit 0 ;;
    invalid)
        printf 'EBML header parsing failed: Invalid data found when processing input\n' >&2
        exit 1
        ;;
    timeout)
        sleep 5
        printf 'index=0\n'
        ;;
    oom)
        printf 'Out of memory\n' >&2
        exit 137
        ;;
    unsupported)
        printf 'Decoder not found\n' >&2
        exit 1
        ;;
    *)
        printf 'unknown FFPROBE_MODE: %s\n' "$FFPROBE_MODE" >&2
        exit 64
        ;;
esac
STUB
    chmod +x "$bin_dir/ffprobe"

    cat >"$bin_dir/ffmpeg" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${FFMPEG_LOG:?}"
case "${FFMPEG_MODE:-valid}" in
    valid) exit 0 ;;
    invalid)
        printf 'Error while decoding stream: Invalid data found when processing input\n' >&2
        exit 1
        ;;
    timeout)
        sleep 5
        exit 0
        ;;
    oom)
        printf 'Out of memory\n' >&2
        exit 137
        ;;
    unsupported)
        printf 'Decoder not found\n' >&2
        exit 1
        ;;
    *)
        printf 'unknown FFMPEG_MODE: %s\n' "$FFMPEG_MODE" >&2
        exit 64
        ;;
esac
STUB
    chmod +x "$bin_dir/ffmpeg"

    cat >"$bin_dir/find" <<STUB
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "\$*" >>"\${FIND_LOG:?}"
if [[ "\${FIND_STUB_MODE:-normal}" == "timeout" ]]; then
    sleep 2
fi
args=("\$@")
if [[ "\${FIND_CTIME_FROM_MTIME:-0}" == "1" ]]; then
    for index in "\${!args[@]}"; do
        args[index]="\${args[index]//%C@/%T@}"
    done
fi
exec "$FIND_REAL" "\${args[@]}"
STUB
    chmod +x "$bin_dir/find"

    cat >"$bin_dir/rm" <<STUB
#!/usr/bin/env bash
set -Eeuo pipefail
target="\${@: -1}"
if [[ "\${REQUIRE_OUTBOX_BEFORE_RM:-0}" == "1" && "\$target" == "\${MEDIA_MOUNTPOINT:?}"/* ]]; then
    count="\$("\${PYTHON_REAL:?}" "\${OUTBOX_HELPER:?}" --db "\${OUTBOX_DB:?}" count)"
    grep -Eq '"pending"[[:space:]]*:[[:space:]]*[1-9]' <<<"\$count" || {
        echo "rm observed no durable pending outbox job" >&2
        exit 88
    }
fi
if [[ "\$target" == "\${MEDIA_MOUNTPOINT:?}"/* ]]; then
    printf '%s\n' "\$target" >>"\${RM_LOG:?}"
fi
if [[ "\${RM_FAIL_MEDIA:-0}" == "1" && "\$target" == "\${MEDIA_MOUNTPOINT:?}"/* ]]; then
    exit 1
fi
if [[ "\${RM_DELETE_THEN_FAIL_MEDIA:-0}" == "1" && "\$target" == "\${MEDIA_MOUNTPOINT:?}"/* ]]; then
    "$RM_REAL" "\$@"
    exit 1
fi
exec "$RM_REAL" "\$@"
STUB
    chmod +x "$bin_dir/rm"

    cat >"$bin_dir/stat" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STAT_LOG:?}"
exit 99
STUB
    chmod +x "$bin_dir/stat"

    cat >"$bin_dir/flock" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$bin_dir/flock"

    cat >"$bin_dir/mountpoint" <<'STUB'
#!/usr/bin/env bash
if [[ "${MOUNTPOINT_OK:-1}" == "1" ]]; then
    exit 0
fi
exit 1
STUB
    chmod +x "$bin_dir/mountpoint"
}

setup_work() {
    local work="$1"
    mkdir -p \
        "$work/bin" \
        "$work/logs" \
        "$work/media/PlexTV" \
        "$work/media/PlexTVHD" \
        "$work/media/PlexFilms" \
        "$work/media/PlexFilmsHD"
    : >"$work/mediainfo.log"
    : >"$work/ffprobe.log"
    : >"$work/ffmpeg.log"
    : >"$work/find.log"
    : >"$work/rm.log"
    : >"$work/stat.log"
    make_stubs "$work"
}

run_script() {
    local work="$1"
    shift
    env \
        PATH="$work/bin:/usr/bin:/bin" \
        PYTHON_BIN="$PYTHON_REAL" \
        PYTHON_REAL="$PYTHON_REAL" \
        OUTBOX_HELPER="$OUTBOX_HELPER" \
        SERVARR_OUTBOX_HELPER="$OUTBOX_HELPER" \
        OUTBOX_DB="$work/outbox.sqlite3" \
        SERVARR_OUTBOX_DB="$work/outbox.sqlite3" \
        MEDIA_MOUNTPOINT="$work/media" \
        PLEX_TV_DIR="$work/media/PlexTV" \
        PLEX_TVHD_DIR="$work/media/PlexTVHD" \
        PLEX_FILMS_DIR="$work/media/PlexFilms" \
        PLEX_FILMSHD_DIR="$work/media/PlexFilmsHD" \
        SONARR_TV_URL="http://127.0.0.1:9" \
        SONARR_TV_API_KEY="tv-key" \
        SONARR_TVHD_URL="http://127.0.0.1:9" \
        SONARR_TVHD_API_KEY="tvhd-key" \
        RADARR_FILMS_URL="http://127.0.0.1:9" \
        RADARR_FILMS_API_KEY="films-key" \
        RADARR_FILMSHD_URL="http://127.0.0.1:9" \
        RADARR_FILMSHD_API_KEY="filmshd-key" \
        SERVARR_DRY_RUN=0 \
        SERVARR_API_TIMEOUT_SECONDS=0.2 \
        LOG_DIR="$work/logs" \
        STATE_FILE="$work/checked.tsv" \
        MIN_FILE_AGE_SECONDS=300 \
        FIND_TIMEOUT_SECONDS=30 \
        MEDIAINFO_TIMEOUT_SECONDS=2 \
        FFPROBE_BIN="$work/bin/ffprobe" \
        FFMPEG_BIN="$work/bin/ffmpeg" \
        FFPROBE_TIMEOUT_SECONDS=1 \
        FFMPEG_TIMEOUT_SECONDS=1 \
        MAX_VALIDATION_DELETIONS_PER_RUN=10 \
        STATE_COMPACT_EVERY=2 \
        MEDIAINFO_LOG="$work/mediainfo.log" \
        FFPROBE_LOG="$work/ffprobe.log" \
        FFMPEG_LOG="$work/ffmpeg.log" \
        MEDIAINFO_CHANGE_MARKER="$work/change.marker" \
        FIND_LOG="$work/find.log" \
        FIND_CTIME_FROM_MTIME=1 \
        RM_LOG="$work/rm.log" \
        STAT_LOG="$work/stat.log" \
        MOUNTPOINT_OK=1 \
        "$@" \
        "$SCRIPT"
}

assert_no_outbox() {
    local work="$1"
    if [[ -e "$work/outbox.sqlite3" ]]; then
        local count
        count="$($PYTHON_REAL "$OUTBOX_HELPER" --db "$work/outbox.sqlite3" count)"
        grep -Eq '"pending"[[:space:]]*:[[:space:]]*0' <<<"$count" || fail "expected no pending jobs: $count"
    fi
}

assert_one_pending_outbox() {
    local work="$1"
    local count
    count="$($PYTHON_REAL "$OUTBOX_HELPER" --db "$work/outbox.sqlite3" count)"
    grep -Eq '"pending"[[:space:]]*:[[:space:]]*1' <<<"$count" || \
        fail "expected one durable pending job: $count"
}

test_default_lock_is_created_beside_servarr_outbox_db() (
    local work
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    setup_work "$work"

    unset LOCKFILE
    run_script "$work"

    assert_exists "$work/scan.lock"
)

test_confirmed_aged_stable_dovi5_deletes_only_source_after_durable_enqueue() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local dir="$work/media/PlexTV/Example Series/Season 01"
    mkdir -p "$dir"
    local src="$dir/Example Series - S01E01 - DoVi.mkv"
    local sdr="${src%.mkv}.sdr.mkv"
    local tmp="${src%.mkv}.sdr.tmp.mkv"
    printf 'source\n' >"$src"
    printf 'sdr\n' >"$sdr"
    printf 'partial\n' >"$tmp"
    age_file "$src"
    age_file "$sdr"
    age_file "$tmp"

    if run_script "$work" SERVARR_DRY_RUN=0 REQUIRE_OUTBOX_BEFORE_RM=1; then
        fail "expected retained API-error outbox to make the run nonzero"
    fi

    assert_missing "$src"
    assert_exists "$sdr"
    assert_exists "$tmp"
    assert_line_count 1 "$work/rm.log"
    assert_one_pending_outbox "$work"
    assert_line_count 0 "$work/ffprobe.log"
    assert_line_count 0 "$work/ffmpeg.log"
    assert_contains "$work/logs/move_dovi5_to_quarantine.log" "DOVI5 delete-only label=PlexTV"
}

test_servarr_dry_run_fails_closed_before_scanning_or_deleting() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Dry Run - DoVi.mkv"
    printf 'source\n' >"$src"
    age_file "$src"

    if run_script "$work" SERVARR_DRY_RUN=1; then
        fail "Servarr dry-run unexpectedly allowed a destructive scan"
    fi

    assert_exists "$src"
    assert_line_count 0 "$work/find.log"
    assert_line_count 0 "$work/mediainfo.log"
    assert_line_count 0 "$work/rm.log"
    assert_missing "$work/outbox.sqlite3"
    assert_contains "$work/logs/move_dovi5_to_quarantine.log" "SERVARR_DRY_RUN=1"
}

test_other_profiles_are_cached_and_validated_no_video_is_cached_after_retry() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local dir="$work/media/PlexTV/Profiles"
    mkdir -p "$dir"
    local name
    for name in Profile04 Profile07 Profile08 NoHdr NoVideo; do
        write_ebml_prefixed_fixture "$dir/$name.mkv" "$name"
        age_file "$dir/$name.mkv"
    done

    run_script "$work"
    assert_line_count 5 "$work/mediainfo.log"
    run_script "$work"
    assert_line_count 6 "$work/mediainfo.log"
    run_script "$work"
    assert_line_count 6 "$work/mediainfo.log"
    assert_contains "$work/mediainfo.log" "NoVideo.mkv"
    assert_contains "$work/checked.tsv" "NoHdr.mkv"
    assert_latest_state_status "$work/checked.tsv" "$dir/NoVideo.mkv" "not_dovi5"
    assert_line_count 1 "$work/ffprobe.log"
    assert_line_count 1 "$work/ffmpeg.log"
    assert_contains "$work/ffprobe.log" '-select_streams V:0'
    assert_contains "$work/ffmpeg.log" '-map 0:V:0'
    assert_line_count 0 "$work/rm.log"
}

assert_invalid_setup_is_fail_closed() {
    local description="$1"
    shift
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Unsafe - DoVi.mkv"
    printf 'source\n' >"$src"
    age_file "$src"
    if run_script "$work" "$@"; then
        fail "$description unexpectedly succeeded"
    fi
    assert_exists "$src"
    assert_line_count 0 "$work/rm.log"
    assert_no_outbox "$work"
}

test_blank_missing_unmounted_duplicate_and_overlapping_roots_fail_closed() {
    assert_invalid_setup_is_fail_closed "blank config" SONARR_TV_API_KEY=

    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Unsafe - DoVi.mkv"
    printf 'source\n' >"$src"
    age_file "$src"
    mv "$work/media/PlexTVHD" "$work/PlexTVHD-missing"
    if run_script "$work"; then fail "missing root unexpectedly succeeded"; fi
    assert_exists "$src"
    assert_no_outbox "$work"

    assert_invalid_setup_is_fail_closed "unmounted media" MOUNTPOINT_OK=0

    work="$(mktemp -d)"
    setup_work "$work"
    src="$work/media/PlexTV/Unsafe - DoVi.mkv"
    printf 'source\n' >"$src"
    age_file "$src"
    if run_script "$work" PLEX_TVHD_DIR="$work/media/PlexTV"; then
        fail "duplicate roots unexpectedly succeeded"
    fi
    assert_exists "$src"
    assert_no_outbox "$work"

    work="$(mktemp -d)"
    setup_work "$work"
    mkdir -p "$work/media/PlexTV/HD"
    src="$work/media/PlexTV/Unsafe - DoVi.mkv"
    printf 'source\n' >"$src"
    age_file "$src"
    if run_script "$work" PLEX_TVHD_DIR="$work/media/PlexTV/HD"; then
        fail "overlapping roots unexpectedly succeeded"
    fi
    assert_exists "$src"
    assert_no_outbox "$work"
}

test_first_failure_is_recorded_and_retained() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local dir="$work/media/PlexTV/Stable Failures"
    mkdir -p "$dir"
    local name
    for name in ProbeError ProbeTimeout NoVideo; do
        write_ebml_prefixed_fixture "$dir/$name.mkv" "$name"
        age_file "$dir/$name.mkv"
    done

    run_script "$work"

    assert_line_count 3 "$work/mediainfo.log"
    assert_line_count 0 "$work/ffprobe.log"
    assert_line_count 0 "$work/ffmpeg.log"
    assert_line_count 0 "$work/rm.log"
    assert_no_outbox "$work"
    for name in ProbeError ProbeTimeout NoVideo; do
        assert_exists "$dir/$name.mkv"
        assert_latest_state_status "$work/checked.tsv" "$dir/$name.mkv" "validation_failed_once"
    done
}

test_second_unchanged_confirmed_invalid_failure_deletes() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Structurally Invalid NoVideo.mkv"
    printf 'this is not a Matroska container\n' >"$src"
    age_file "$src"

    run_script "$work"
    if run_script "$work" REQUIRE_OUTBOX_BEFORE_RM=1; then
        fail "second unchanged structurally invalid failure did not leave pending recovery"
    fi

    assert_missing "$src"
    assert_line_count 2 "$work/mediainfo.log"
    assert_line_count 0 "$work/ffprobe.log"
    assert_line_count 0 "$work/ffmpeg.log"
    assert_line_count 1 "$work/rm.log"
    assert_one_pending_outbox "$work"
}

test_second_unchanged_no_video_confirmation_deletes() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Confirmed NoVideo.mkv"
    write_ebml_prefixed_fixture "$src" "container without a video stream"
    age_file "$src"

    run_script "$work"
    if run_script "$work" FFPROBE_MODE=no_video REQUIRE_OUTBOX_BEFORE_RM=1; then
        fail "second unchanged no-video confirmation did not leave pending recovery"
    fi

    assert_missing "$src"
    assert_line_count 2 "$work/mediainfo.log"
    assert_line_count 1 "$work/ffprobe.log"
    assert_line_count 0 "$work/ffmpeg.log"
    assert_line_count 1 "$work/rm.log"
    assert_one_pending_outbox "$work"
}

test_second_pass_ffprobe_profile5_deletes_without_decode() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/FFprobe Profile Five NoVideo.mkv"
    write_ebml_prefixed_fixture "$src" "MediaInfo cannot classify this Profile 5 stream"
    age_file "$src"

    run_script "$work"
    if run_script "$work" FFPROBE_MODE=dovi5 REQUIRE_OUTBOX_BEFORE_RM=1; then
        fail "FFprobe-confirmed Profile 5 retry did not leave pending recovery"
    fi

    assert_missing "$src"
    assert_line_count 2 "$work/mediainfo.log"
    assert_line_count 1 "$work/ffprobe.log"
    assert_line_count 0 "$work/ffmpeg.log"
    assert_line_count 1 "$work/rm.log"
    assert_one_pending_outbox "$work"
}

test_ffprobe_profile5_bypasses_validation_circuit_breaker() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local -a sources=()
    local index src
    for index in 1 2; do
        src="$work/media/PlexTV/FFprobe Profile Five $index NoVideo.mkv"
        write_ebml_prefixed_fixture "$src" "Profile 5 retry $index"
        age_file "$src"
        sources+=("$src")
    done

    run_script "$work" MAX_VALIDATION_DELETIONS_PER_RUN=0
    local second_status=0
    run_script "$work" MAX_VALIDATION_DELETIONS_PER_RUN=0 FFPROBE_MODE=dovi5 \
        REQUIRE_OUTBOX_BEFORE_RM=1 || second_status=$?

    [[ "$second_status" -ne 0 ]] || fail "pending Profile 5 recovery did not fail the run"
    for src in "${sources[@]}"; do
        assert_missing "$src"
    done
    assert_line_count 2 "$work/ffprobe.log"
    assert_line_count 0 "$work/ffmpeg.log"
    assert_line_count 2 "$work/rm.log"
    local count
    count="$($PYTHON_REAL "$OUTBOX_HELPER" --db "$work/outbox.sqlite3" count)"
    grep -Eq '"pending"[[:space:]]*:[[:space:]]*2' <<<"$count" || \
        fail "expected two durable pending Profile 5 jobs: $count"
}

test_second_unchanged_decode_failure_deletes() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Undecodable NoVideo.mkv"
    write_ebml_prefixed_fixture "$src" "container with a broken video stream"
    age_file "$src"

    run_script "$work"
    if run_script "$work" FFMPEG_MODE=invalid REQUIRE_OUTBOX_BEFORE_RM=1; then
        fail "second unchanged decode failure did not leave pending recovery"
    fi

    assert_missing "$src"
    assert_line_count 2 "$work/mediainfo.log"
    assert_line_count 1 "$work/ffprobe.log"
    assert_line_count 1 "$work/ffmpeg.log"
    assert_line_count 1 "$work/rm.log"
    assert_one_pending_outbox "$work"
}

test_validator_success_retains_and_caches() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Decoder Valid NoVideo.mkv"
    write_ebml_prefixed_fixture "$src" "validator success fixture"
    age_file "$src"

    run_script "$work"
    run_script "$work"
    run_script "$work"

    assert_exists "$src"
    assert_line_count 2 "$work/mediainfo.log"
    assert_line_count 1 "$work/ffprobe.log"
    assert_line_count 1 "$work/ffmpeg.log"
    assert_line_count 0 "$work/rm.log"
    assert_no_outbox "$work"
    assert_latest_state_status "$work/checked.tsv" "$src" "not_dovi5"
}

test_validator_timeout_retains() {
    local stage work src
    for stage in ffprobe ffmpeg; do
        work="$(mktemp -d)"
        setup_work "$work"
        src="$work/media/PlexTV/${stage} Timeout NoVideo.mkv"
        write_ebml_prefixed_fixture "$src" "validator timeout fixture"
        age_file "$src"

        run_script "$work"
        if [[ "$stage" == "ffprobe" ]]; then
            run_script "$work" FFPROBE_MODE=timeout FFPROBE_TIMEOUT_SECONDS=0.1
            assert_line_count 0 "$work/ffmpeg.log"
        else
            run_script "$work" FFMPEG_MODE=timeout FFMPEG_TIMEOUT_SECONDS=0.1
            assert_line_count 1 "$work/ffmpeg.log"
        fi

        assert_exists "$src"
        assert_line_count 2 "$work/mediainfo.log"
        assert_line_count 1 "$work/ffprobe.log"
        assert_line_count 0 "$work/rm.log"
        assert_no_outbox "$work"
        assert_latest_state_status "$work/checked.tsv" "$src" "validation_failed_once"
    done
}

test_validator_resource_and_capability_failures_retain() {
    local stage mode work src
    for stage in ffprobe ffmpeg; do
        for mode in oom unsupported; do
            work="$(mktemp -d)"
            setup_work "$work"
            src="$work/media/PlexTV/${stage} ${mode} NoVideo.mkv"
            write_ebml_prefixed_fixture "$src" "validator infrastructure fixture"
            age_file "$src"

            run_script "$work"
            if [[ "$stage" == "ffprobe" ]]; then
                run_script "$work" FFPROBE_MODE="$mode"
                assert_line_count 0 "$work/ffmpeg.log"
            else
                run_script "$work" FFMPEG_MODE="$mode"
                assert_line_count 1 "$work/ffmpeg.log"
            fi

            assert_exists "$src"
            assert_line_count 2 "$work/mediainfo.log"
            assert_line_count 1 "$work/ffprobe.log"
            assert_line_count 0 "$work/rm.log"
            assert_no_outbox "$work"
            assert_latest_state_status "$work/checked.tsv" "$src" "validation_failed_once"
        done
    done
}

test_changed_failure_restarts_retry() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Replaced NoVideo.mkv"
    write_ebml_prefixed_fixture "$src" "first fingerprint"
    age_file "$src"

    run_script "$work"
    write_ebml_prefixed_fixture "$src" "replacement fingerprint is different"
    age_file "$src"
    run_script "$work" FFPROBE_MODE=invalid

    assert_exists "$src"
    assert_line_count 2 "$work/mediainfo.log"
    assert_line_count 0 "$work/ffprobe.log"
    assert_line_count 0 "$work/ffmpeg.log"
    assert_line_count 0 "$work/rm.log"
    assert_latest_state_status "$work/checked.tsv" "$src" "validation_failed_once"

    if run_script "$work" FFPROBE_MODE=invalid REQUIRE_OUTBOX_BEFORE_RM=1; then
        fail "unchanged replacement was not deleted after its own retained retry"
    fi
    assert_missing "$src"
    assert_line_count 1 "$work/ffprobe.log"
    assert_line_count 1 "$work/rm.log"
    assert_one_pending_outbox "$work"
}

test_compaction_preserves_failed_once_retry() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Compacted NoVideo.mkv"
    write_ebml_prefixed_fixture "$src" "compacted retry fixture"
    age_file "$src"

    run_script "$work" STATE_COMPACT_EVERY=1
    assert_latest_state_status "$work/checked.tsv" "$src" "validation_failed_once"
    assert_line_count 3 "$work/checked.tsv"

    if run_script "$work" STATE_COMPACT_EVERY=1 FFPROBE_MODE=invalid REQUIRE_OUTBOX_BEFORE_RM=1; then
        fail "compacted failed-once row did not activate validation on retry"
    fi
    assert_missing "$src"
    assert_line_count 1 "$work/ffprobe.log"
    assert_line_count 1 "$work/rm.log"
    assert_one_pending_outbox "$work"
}

test_validation_deletion_circuit_breaker_is_all_or_nothing() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local -a sources=()
    local index src
    for index in 1 2 3; do
        src="$work/media/PlexTV/Circuit $index NoVideo.mkv"
        printf 'not a Matroska container %s\n' "$index" >"$src"
        age_file "$src"
        sources+=("$src")
    done

    run_script "$work" MAX_VALIDATION_DELETIONS_PER_RUN=2
    local second_status=0
    run_script "$work" MAX_VALIDATION_DELETIONS_PER_RUN=2 || second_status=$?

    [[ "$second_status" -ne 0 ]] || fail "validation deletion circuit breaker did not fail the run"
    for src in "${sources[@]}"; do
        assert_exists "$src"
        assert_latest_state_status "$work/checked.tsv" "$src" "validation_failed_once"
    done
    assert_line_count 0 "$work/ffprobe.log"
    assert_line_count 0 "$work/ffmpeg.log"
    assert_line_count 0 "$work/rm.log"
    assert_no_outbox "$work"
}

test_file_changed_during_probe_is_cancelled_retained_and_reprobed() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Changing - DoVi.mkv"
    printf 'source\n' >"$src"
    age_file "$src"
    run_script "$work" MEDIAINFO_MODE=change
    assert_exists "$src"
    assert_line_count 1 "$work/mediainfo.log"
    assert_no_outbox "$work"
    run_script "$work" MEDIAINFO_MODE=sdr
    assert_exists "$src"
    assert_line_count 2 "$work/mediainfo.log"
    assert_contains "$work/checked.tsv" "$src"
}

test_too_young_file_ages_into_eligibility() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Young - DoVi.mkv"
    printf 'source\n' >"$src"
    run_script "$work"
    assert_exists "$src"
    assert_line_count 0 "$work/mediainfo.log"
    age_file "$src"
    if run_script "$work"; then
        fail "expected retained API-error outbox to make the run nonzero"
    fi
    assert_missing "$src"
    assert_line_count 1 "$work/mediainfo.log"
}

test_fresh_ctime_blocks_probe_when_mtime_is_old() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Fresh Ctime - NoHdr.mkv"
    printf 'source\n' >"$src"
    age_file "$src"

    run_script "$work" FIND_CTIME_FROM_MTIME=0

    assert_exists "$src"
    assert_line_count 0 "$work/mediainfo.log"
    assert_not_contains "$work/checked.tsv" "$src"
}

test_explicit_custom_root_routes_by_boundary_to_correct_label() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    mv "$work/media/PlexTV" "$work/media/TelevisionOne"
    local src="$work/media/TelevisionOne/Show/Custom - DoVi.mkv"
    mkdir -p "$(dirname "$src")"
    printf 'source\n' >"$src"
    age_file "$src"
    if run_script "$work" PLEX_TV_DIR="$work/media/TelevisionOne"; then
        fail "expected retained API-error outbox to make the run nonzero"
    fi
    assert_missing "$src"
    assert_contains "$work/logs/move_dovi5_to_quarantine.log" "label=PlexTV"
    assert_not_contains "$work/logs/move_dovi5_to_quarantine.log" "label=PlexTVHD"
}

test_cached_v2_path_uses_only_bulk_find_and_no_external_stat_or_probe() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Cached.mkv"
    printf 'media\n' >"$src"
    age_file "$src"
    run_script "$work"
    assert_line_count 1 "$work/mediainfo.log"
    assert_line_count 2 "$work/find.log"
    run_script "$work"
    assert_line_count 1 "$work/mediainfo.log"
    assert_line_count 3 "$work/find.log"
    assert_line_count 0 "$work/stat.log"
    assert_contains "$work/checked.tsv" "# dovi5-state-v2"
}

test_legacy_state_is_backed_up_and_revalidated() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Legacy.mkv"
    printf 'media\n' >"$src"
    age_file "$src"
    printf '%s\t6\t1\tnot_dovi5\told\n' "$src" >"$work/checked.tsv"
    run_script "$work"
    assert_line_count 1 "$work/mediainfo.log"
    assert_contains "$work/checked.tsv" "# dovi5-state-v2"
    compgen -G "$work/checked.tsv.legacy-*" >/dev/null || fail "expected timestamped legacy backup"
}

test_partial_v2_progress_resumes_without_reprobing_completed_rows() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local first="$work/media/PlexTV/First.mkv"
    local second="$work/media/PlexTV/Second.mkv"
    printf 'media\n' >"$first"
    age_file "$first"
    run_script "$work"
    printf 'media\n' >"$second"
    age_file "$second"
    run_script "$work"
    assert_line_count 2 "$work/mediainfo.log"
    [[ "$(grep -Fc "$first" "$work/mediainfo.log")" -eq 1 ]] || fail "first completed row was reprobed"
    [[ "$(grep -Fc "$second" "$work/mediainfo.log")" -eq 1 ]] || fail "second row was not probed once"
}

test_failed_enumeration_never_deletes_or_prunes_state() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local cached="$work/media/PlexTV/Cached.mkv"
    local dovi="$work/media/PlexTV/Enumerate - DoVi.mkv"
    printf 'media\n' >"$cached"
    age_file "$cached"
    run_script "$work"
    local stale="$work/media/PlexTV/Removed.mkv"
    append_stale_state_row "$work/checked.tsv" "$stale"
    printf '# compacted_at\t0\n' >>"$work/checked.tsv"
    local state_before
    state_before="$(sha256sum "$work/checked.tsv" | cut -d' ' -f1)"
    printf 'media\n' >"$dovi"
    age_file "$dovi"
    if run_script "$work" FIND_STUB_MODE=timeout FIND_TIMEOUT_SECONDS=0.1 STATE_COMPACT_INTERVAL_SECONDS=1; then
        fail "timed out enumeration unexpectedly succeeded"
    fi
    assert_exists "$dovi"
    assert_contains "$work/checked.tsv" "$stale"
    [[ "$(sha256sum "$work/checked.tsv" | cut -d' ' -f1)" == "$state_before" ]] || fail "partial enumeration changed state"
}

append_stale_state_row() {
    local state_file="$1"
    local stale_path="$2"
    printf '%s\t1\t2\t3\t4\t5\tnot_dovi5\t0\n' "$stale_path" >>"$state_file"
}

test_due_record_threshold_compaction_prunes_paths_absent_from_complete_walk() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local first="$work/media/PlexTV/First.mkv"
    local second="$work/media/PlexTV/Second.mkv"
    local stale="$work/media/PlexTV/Removed.mkv"
    printf 'media\n' >"$first"
    age_file "$first"
    run_script "$work" STATE_COMPACT_EVERY=9999 STATE_COMPACT_INTERVAL_SECONDS=999999
    append_stale_state_row "$work/checked.tsv" "$stale"
    assert_contains "$work/checked.tsv" "$stale"

    printf 'media\n' >"$second"
    age_file "$second"
    run_script "$work" STATE_COMPACT_EVERY=1 STATE_COMPACT_INTERVAL_SECONDS=999999

    assert_not_contains "$work/checked.tsv" "$stale"
    assert_contains "$work/checked.tsv" "$first"
    assert_contains "$work/checked.tsv" "$second"
}

test_aged_compaction_stamp_prunes_without_new_records() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local live="$work/media/PlexTV/Cached.mkv"
    local stale="$work/media/PlexTV/Removed.mkv"
    printf 'media\n' >"$live"
    age_file "$live"
    run_script "$work" STATE_COMPACT_EVERY=9999 STATE_COMPACT_INTERVAL_SECONDS=999999
    append_stale_state_row "$work/checked.tsv" "$stale"
    printf '# compacted_at\t0\n' >>"$work/checked.tsv"
    assert_contains "$work/checked.tsv" "$stale"

    run_script "$work" STATE_COMPACT_EVERY=9999 STATE_COMPACT_INTERVAL_SECONDS=1

    assert_not_contains "$work/checked.tsv" "$stale"
    assert_contains "$work/checked.tsv" "$live"
    assert_contains "$work/checked.tsv" $'# compacted_at\t'
    assert_line_count 1 "$work/mediainfo.log"
}

test_outbox_commit_failure_retains_confirmed_source() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Corrupt DB - DoVi.mkv"
    printf 'source\n' >"$src"
    age_file "$src"
    printf 'not sqlite' >"$work/outbox.sqlite3"
    if run_script "$work"; then fail "corrupt outbox unexpectedly succeeded"; fi
    assert_exists "$src"
    assert_line_count 0 "$work/rm.log"
}

test_rm_failure_with_original_fingerprint_cancels_job_and_retains_confirmed_source() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Delete Failure - DoVi.mkv"
    printf 'source\n' >"$src"
    age_file "$src"
    if run_script "$work" RM_FAIL_MEDIA=1; then
        fail "failed source deletion unexpectedly made the run successful"
    fi
    assert_exists "$src"
    assert_line_count 1 "$work/rm.log"
    assert_no_outbox "$work"
    assert_contains "$work/logs/move_dovi5_to_quarantine.log" "failed to delete DoVi5 source"
    local cancelled_count
    cancelled_count="$(
        "$PYTHON_REAL" -c '
import os
import sqlite3
import sys

database, source = sys.argv[1:]
canonical = os.path.realpath(os.path.abspath(source))
connection = sqlite3.connect(database)
count = connection.execute(
    "SELECT COUNT(*) FROM jobs "
    "WHERE canonical_path=? AND phase=\"superseded\" "
    "AND last_error=\"source deletion failed\"",
    (canonical,),
).fetchone()[0]
total = connection.execute("SELECT COUNT(*) FROM jobs").fetchone()[0]
connection.close()
print(f"{count}:{total}")
' "$work/outbox.sqlite3" "$src"
    )"
    [[ "$cancelled_count" == "1:1" ]] || fail "exact failed-delete job was not cancelled: $cancelled_count"
}

test_rm_delete_then_failure_retains_pending_recovery_job() {
    local work
    work="$(mktemp -d)"
    setup_work "$work"
    local src="$work/media/PlexTV/Delete Then Failure - DoVi.mkv"
    printf 'source\n' >"$src"
    age_file "$src"

    if run_script "$work" SERVARR_DRY_RUN=0 RM_DELETE_THEN_FAIL_MEDIA=1; then
        fail "failed rm after unlink unexpectedly made the run successful"
    fi

    assert_missing "$src"
    assert_line_count 1 "$work/rm.log"
    assert_contains "$work/logs/move_dovi5_to_quarantine.log" "retaining recovery job"
    local recovery_state
    recovery_state="$(
        "$PYTHON_REAL" -c '
import os
import sqlite3
import sys

database, source = sys.argv[1:]
canonical = os.path.realpath(os.path.abspath(source))
connection = sqlite3.connect(database)
row = connection.execute(
    "SELECT phase, last_error FROM jobs WHERE canonical_path=?",
    (canonical,),
).fetchone()
connection.close()
print("missing" if row is None else "{}:{}".format(row[0], row[1] or ""))
' "$work/outbox.sqlite3" "$src"
    )"
    [[ "$recovery_state" == queued:* ]] || fail "recovery job was not retained queued: $recovery_state"
    local count
    count="$($PYTHON_REAL "$OUTBOX_HELPER" --db "$work/outbox.sqlite3" count)"
    grep -Eq '"pending"[[:space:]]*:[[:space:]]*1' <<<"$count" || fail "recovery job was not pending: $count"
}

if (($# > 0)); then
    for selected_test in "$@"; do
        "$selected_test"
    done
    echo "Selected scanner safety tests passed"
    exit 0
fi

test_default_lock_is_created_beside_servarr_outbox_db
test_confirmed_aged_stable_dovi5_deletes_only_source_after_durable_enqueue
test_servarr_dry_run_fails_closed_before_scanning_or_deleting
test_other_profiles_are_cached_and_validated_no_video_is_cached_after_retry
test_blank_missing_unmounted_duplicate_and_overlapping_roots_fail_closed
test_first_failure_is_recorded_and_retained
test_second_unchanged_confirmed_invalid_failure_deletes
test_second_unchanged_no_video_confirmation_deletes
test_second_pass_ffprobe_profile5_deletes_without_decode
test_ffprobe_profile5_bypasses_validation_circuit_breaker
test_second_unchanged_decode_failure_deletes
test_validator_success_retains_and_caches
test_validator_timeout_retains
test_validator_resource_and_capability_failures_retain
test_changed_failure_restarts_retry
test_compaction_preserves_failed_once_retry
test_validation_deletion_circuit_breaker_is_all_or_nothing
test_file_changed_during_probe_is_cancelled_retained_and_reprobed
test_too_young_file_ages_into_eligibility
test_fresh_ctime_blocks_probe_when_mtime_is_old
test_explicit_custom_root_routes_by_boundary_to_correct_label
test_cached_v2_path_uses_only_bulk_find_and_no_external_stat_or_probe
test_legacy_state_is_backed_up_and_revalidated
test_partial_v2_progress_resumes_without_reprobing_completed_rows
test_failed_enumeration_never_deletes_or_prunes_state
test_due_record_threshold_compaction_prunes_paths_absent_from_complete_walk
test_aged_compaction_stamp_prunes_without_new_records
test_outbox_commit_failure_retains_confirmed_source
test_rm_failure_with_original_fingerprint_cancels_job_and_retains_confirmed_source
test_rm_delete_then_failure_retains_pending_recovery_job

echo "All scanner safety tests passed"
