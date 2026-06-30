#!/usr/bin/env bash
#
# nas-pcloud-sync.sh
#
# One-way copy (no deletions) from NAS folders to pCloud via rclone,
# with a monthly transfer cap tracked over a custom billing cycle
# (the 16th of month M through the 15th of month M+1).
#
# Usage:
#   ./nas-pcloud-sync.sh [options]
#
# Options:
#   -c, --config FILE      Path to folders config file (default: ./folders.conf)
#   -n, --dry-run          Show what would be transferred without transferring
#   --no-cap               Ignore the monthly cap: warn instead of stopping
#   --cap-gb N             Override the cap size in GB (default: 50)
#   --reset-cycle          Force-reset the current cycle's usage counter to 0
#   --wait-for-nas N       Retry up to N times (30s apart) waiting for the first
#                          origin path to become reachable before giving up.
#                          Useful when launched at Windows logon, before the
#                          NAS network share has finished reconnecting.
#                          Default: 0 (no wait, fail immediately if unreachable)
#   --exclude "a,b,c"      Comma-separated list of glob patterns to exclude from
#                          every pair's transfer (e.g. "Thumbs.db,desktop.ini,*.tmp").
#                          Default: "Thumbs.db,desktop.ini,.DS_Store,*.tmp"
#   --checksum             Compare files by checksum instead of size+modtime.
#                          Catches corruption that preserves size/timestamp, at
#                          the cost of reading every file fully on both sides
#                          (slower, especially over a home network/NAS link).
#                          Off by default.
#   -h, --help             Show this help
#
# Requires: rclone (configured with a "pcloud" remote), bash, awk, date, du-like
#           size parsing via rclone's own JSON stats (no extra deps needed).
#
# Resilience notes:
#   - Transient network errors (NAS or pCloud) are retried automatically by
#     rclone itself (--retries 5, --low-level-retries 10) before being treated
#     as a real failure.
#   - Progress toward the monthly cap is checkpointed to disk roughly every
#     60 seconds WHILE a pair is transferring, not just after it completes.
#     If the script/PC crashes mid-transfer, at most ~60s of cap accounting
#     is lost - not the whole pair, regardless of how long it runs.
#   - rclone copy never deletes; re-running after a crash is always safe and
#     will only re-transfer what's missing or changed at the destination.
#   - A lock file (state/run.lock) prevents two instances from running at the
#     same time (e.g. a manual run overlapping a scheduled one), which could
#     otherwise corrupt the cap accounting via concurrent writes.
#   - Multi-thread uploads are disabled (--multi-thread-streams 0). pCloud's
#     chunked upload path returns "Access denied (2003)" on files above the
#     256MiB multi-thread cutoff with some rclone versions (seen on v1.69.1;
#     reportedly fixed in v1.71.0+). Disabling it trades some upload speed on
#     very large files for reliability across rclone versions.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/folders.conf"
STATE_DIR="${SCRIPT_DIR}/state"
LOG_DIR="${SCRIPT_DIR}/logs"
STATE_FILE="${STATE_DIR}/usage_state.tsv"   # cycle_start_date<TAB>bytes_transferred
LOCK_FILE="${STATE_DIR}/run.lock"
CAP_GB=50
DRY_RUN=0
NO_CAP=0
FORCE_RESET=0
WAIT_FOR_NAS=0
EXCLUDE_PATTERNS="Thumbs.db,desktop.ini,.DS_Store,*.tmp"
USE_CHECKSUM=0

mkdir -p "$STATE_DIR" "$LOG_DIR"

RUN_TS="$(date '+%Y-%m-%d_%H-%M-%S')"
RUN_LOG="${LOG_DIR}/run_${RUN_TS}.log"
SUMMARY_LOG="${LOG_DIR}/summary.log"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    # Echo to stdout and append to the run log
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$RUN_LOG"
}

summary() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$SUMMARY_LOG"
}

die() {
    log "ERROR: $*"
    summary "ERROR: $*"
    exit 1
}

usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

human_to_bytes_gb() {
    # $1 = number of GB -> bytes
    awk -v gb="$1" 'BEGIN { printf "%.0f", gb * 1024 * 1024 * 1024 }'
}

bytes_to_human() {
    # $1 = bytes -> human readable GB string
    awk -v b="$1" 'BEGIN { printf "%.2f GB", b / 1024 / 1024 / 1024 }'
}

# ---------------------------------------------------------------------------
# Lock file: prevents two instances running at once (e.g. a manual run
# overlapping a scheduled one), which could corrupt the cap accounting via
# concurrent reads/writes to the state file. Implemented as a portable
# PID-checked lock rather than flock, since flock isn't available on Git
# Bash/MSYS (Windows) without extra installation.
# ---------------------------------------------------------------------------
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local existing_pid
        existing_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
            die "Another instance is already running (PID ${existing_pid}, lock: $LOCK_FILE). Exiting to avoid corrupting the cap accounting."
        else
            log "Found a stale lock file (process ${existing_pid:-unknown} is not running). Removing it and continuing."
            rm -f "$LOCK_FILE"
        fi
    fi
    # Write atomically: create in a temp file on the same filesystem, then
    # rename, so a crash mid-write can't leave a half-written lock file.
    local tmp_lock
    tmp_lock="$(mktemp "${STATE_DIR}/.run.lock.XXXXXX")"
    echo "$$" > "$tmp_lock"
    mv "$tmp_lock" "$LOCK_FILE"
}

release_lock() {
    # Only remove the lock if it's still ours - avoids a race where this
    # process's lock was already cleared/reclaimed by something else.
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$LOCK_FILE"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Billing cycle calculation: cycle runs from the 16th of month M
# to the 15th of month M+1 (inclusive).
# Returns the cycle start date as YYYY-MM-16 for "today".
# ---------------------------------------------------------------------------
current_cycle_start() {
    local today day year month
    today="$(date '+%Y-%m-%d')"
    day="$(date '+%d')"
    year="$(date '+%Y')"
    month="$(date '+%m')"

    # strip leading zero for arithmetic
    day=$((10#$day))

    if [ "$day" -ge 16 ]; then
        printf '%04d-%02d-16\n' "$year" "$((10#$month))"
    else
        # previous month's 16th
        local py pm
        py=$year
        pm=$((10#$month - 1))
        if [ "$pm" -lt 1 ]; then
            pm=12
            py=$((year - 1))
        fi
        printf '%04d-%02d-16\n' "$py" "$pm"
    fi
}

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------
load_state() {
    local cycle_start
    cycle_start="$(current_cycle_start)"

    if [ -f "$STATE_FILE" ]; then
        local stored_cycle stored_bytes
        IFS=$'\t' read -r stored_cycle stored_bytes < "$STATE_FILE" || true
        stored_cycle="${stored_cycle:-}"
        stored_bytes="${stored_bytes:-0}"

        if [ "$FORCE_RESET" -eq 1 ] || [ "$stored_cycle" != "$cycle_start" ]; then
            # New cycle (or forced reset): reset usage to 0
            printf "%s\t%s\n" "$cycle_start" "0" > "$STATE_FILE"
            CURRENT_BYTES=0
            log "New billing cycle detected (starts ${cycle_start}). Usage counter reset to 0."
        else
            CURRENT_BYTES="$stored_bytes"
        fi
    else
        printf "%s\t%s\n" "$cycle_start" "0" > "$STATE_FILE"
        CURRENT_BYTES=0
        log "No prior state found. Initialized cycle ${cycle_start} with 0 bytes used."
    fi
}

save_state() {
    local cycle_start
    cycle_start="$(current_cycle_start)"
    printf "%s\t%s\n" "$cycle_start" "$CURRENT_BYTES" > "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config)
            CONFIG_FILE="$2"; shift 2 ;;
        -n|--dry-run)
            DRY_RUN=1; shift ;;
        --no-cap)
            NO_CAP=1; shift ;;
        --cap-gb)
            CAP_GB="$2"; shift 2 ;;
        --reset-cycle)
            FORCE_RESET=1; shift ;;
        --wait-for-nas)
            WAIT_FOR_NAS="$2"; shift 2 ;;
        --exclude)
            EXCLUDE_PATTERNS="$2"; shift 2 ;;
        --checksum)
            USE_CHECKSUM=1; shift ;;
        -h|--help)
            usage ;;
        *)
            die "Unknown option: $1 (use -h for help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Input validation: fail with a clear message rather than a cryptic awk/
# arithmetic error later if these were typo'd or passed garbage.
# ---------------------------------------------------------------------------
case "$CAP_GB" in
    ''|*[!0-9.]*) die "--cap-gb must be a positive number, got: '$CAP_GB'" ;;
esac
case "$WAIT_FOR_NAS" in
    ''|*[!0-9]*) die "--wait-for-nas must be a non-negative integer, got: '$WAIT_FOR_NAS'" ;;
esac

[ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
command -v rclone >/dev/null 2>&1 || die "rclone not found in PATH. Install/configure rclone first."

# ---------------------------------------------------------------------------
# Acquire the run lock before touching any state, and make sure it's always
# released on exit - normal completion, an error (die/set -e), or a signal
# like Ctrl+C - so a killed run doesn't permanently block future runs.
# ---------------------------------------------------------------------------
acquire_lock
trap release_lock EXIT INT TERM


# ---------------------------------------------------------------------------
# Optional: wait for the NAS to become reachable (useful at Windows logon,
# where the network share may not have finished reconnecting yet).
# Polls the first non-comment, non-blank origin path from the config.
# ---------------------------------------------------------------------------
if [ "$WAIT_FOR_NAS" -gt 0 ]; then
    FIRST_ORIGIN=""
    while IFS='|' read -r o _d || [ -n "${o:-}" ]; do
        [ -z "$(printf '%s' "$o" | tr -d ' \t')" ] && continue
        case "$o" in \#*) continue ;; esac
        FIRST_ORIGIN="$(echo "$o" | sed 's/^ *//;s/ *$//')"
        break
    done < "$CONFIG_FILE"

    if [ -n "$FIRST_ORIGIN" ]; then
        ATTEMPT=0
        # Use rclone itself to test reachability rather than bash's [ -d ] test:
        # native -d checks on UNC paths (\\host\share or //host/share) are
        # unreliable under Git Bash/MSYS, whereas rclone's local backend
        # already proved it can read these paths correctly.
        until rclone lsf "$FIRST_ORIGIN" >/dev/null 2>&1; do
            ATTEMPT=$((ATTEMPT + 1))
            if [ "$ATTEMPT" -gt "$WAIT_FOR_NAS" ]; then
                log "NAS still unreachable after ${WAIT_FOR_NAS} attempts (path: $FIRST_ORIGIN). Giving up for this run."
                summary "Run ${RUN_TS}: ABORTED - NAS unreachable after ${WAIT_FOR_NAS} attempts."
                exit 1
            fi
            log "Waiting for NAS to become reachable (attempt ${ATTEMPT}/${WAIT_FOR_NAS}): $FIRST_ORIGIN"
            sleep 30
        done
        log "NAS is reachable: $FIRST_ORIGIN"
    fi
fi

CAP_BYTES="$(human_to_bytes_gb "$CAP_GB")"

log "=== NAS -> pCloud sync started ==="
log "Config file:   $CONFIG_FILE"
log "Dry run:       $([ "$DRY_RUN" -eq 1 ] && echo yes || echo no)"
log "Cap:           ${CAP_GB} GB ($([ "$NO_CAP" -eq 1 ] && echo "warn-only, override active" || echo "hard stop when reached"))"
log "Checksum mode: $([ "$USE_CHECKSUM" -eq 1 ] && echo "yes (slower, verifies file content)" || echo "no (size+modtime comparison)")"

load_state
log "Cycle:         $(current_cycle_start) -> next reset on 16th of following month"
log "Used so far this cycle: $(bytes_to_human "$CURRENT_BYTES") of ${CAP_GB} GB"

if [ "$NO_CAP" -eq 0 ] && [ "$CURRENT_BYTES" -ge "$CAP_BYTES" ]; then
    log "Monthly cap already reached for this cycle. Stopping until next cycle (16th)."
    summary "Run ${RUN_TS}: SKIPPED - cap already reached ($(bytes_to_human "$CURRENT_BYTES")/${CAP_GB}GB)."
    exit 0
fi

# ---------------------------------------------------------------------------
# Build the exclude flag list once. rclone's --exclude does NOT split on
# commas within a single flag value (that would try to match a literal
# filename containing a comma) - it needs one --exclude per pattern.
# ---------------------------------------------------------------------------
EXCLUDE_ARGS=()
if [ -n "$EXCLUDE_PATTERNS" ]; then
    IFS=',' read -ra _EXCLUDE_LIST <<< "$EXCLUDE_PATTERNS"
    for pattern in "${_EXCLUDE_LIST[@]}"; do
        pattern="$(echo "$pattern" | sed 's/^ *//;s/ *$//')"
        [ -n "$pattern" ] && EXCLUDE_ARGS+=(--exclude "$pattern")
    done
fi
log "Exclude patterns: ${EXCLUDE_PATTERNS:-none}"

# ---------------------------------------------------------------------------
# Read folder pairs and process each
# ---------------------------------------------------------------------------
TOTAL_RUN_BYTES=0
PAIR_COUNT=0
CAP_HIT_MID_RUN=0

while IFS='|' read -r origin destination || [ -n "${origin:-}" ]; do
    # skip blank lines / comments (handles spaces, tabs, or fully empty)
    [ -z "$(printf '%s' "$origin" | tr -d ' \t')" ] && continue
    case "$origin" in \#*) continue ;; esac

    origin="$(echo "$origin" | sed 's/^ *//;s/ *$//')"
    destination="$(echo "$destination" | sed 's/^ *//;s/ *$//')"

    [ -z "$destination" ] && { log "WARNING: skipping malformed line (missing destination) for origin '$origin'"; continue; }

    PAIR_COUNT=$((PAIR_COUNT + 1))

    if ! rclone lsf "$origin" >/dev/null 2>&1; then
        log "WARNING: origin path not reachable via rclone, skipping: $origin"
        continue
    fi

    log "--- Pair #$PAIR_COUNT: '$origin' -> '$destination' ---"

    # Remaining budget for this transfer, if cap is enforced
    REMAINING_BYTES=$((CAP_BYTES - CURRENT_BYTES))
    if [ "$NO_CAP" -eq 0 ] && [ "$REMAINING_BYTES" -le 0 ]; then
        log "Cap reached mid-run. Stopping further transfers until next cycle."
        CAP_HIT_MID_RUN=1
        break
    fi

    # Plain human-readable log goes to the run log file. --use-json-log makes
    # THAT file's entries JSON (for precise byte-count parsing below) - it does
    # NOT affect the console, since --log-file redirects rclone's logger only.
    # --progress renders its live bar straight to the terminal independently,
    # so the two don't conflict even though --progress + --use-json-log can't
    # be combined on the SAME stream.
    PAIR_STATS_LOG="$(mktemp)"
    RCLONE_ARGS=(copy "$origin" "$destination"
        --progress
        --log-file="$PAIR_STATS_LOG" --log-level INFO --use-json-log
        --stats 2s --stats-one-line
        --create-empty-src-dirs
        --retries 5 --low-level-retries 10
        --multi-thread-streams 0
        "${EXCLUDE_ARGS[@]}")

    if [ "$DRY_RUN" -eq 1 ]; then
        RCLONE_ARGS+=(--dry-run)
    fi

    if [ "$USE_CHECKSUM" -eq 1 ]; then
        # Compare by checksum instead of size+modtime - catches corruption
        # that happens to preserve both, at the cost of reading every file
        # fully on both sides (slower over a home NAS/network link).
        RCLONE_ARGS+=(--checksum)
    fi

    if [ "$NO_CAP" -eq 0 ]; then
        # Limit this pair's transfer to the remaining budget for the cycle.
        # --cutoff-mode soft lets any file currently being transferred finish
        # (rather than truncating it mid-write) and just stops starting new
        # ones once the limit is reached. rclone exits with code 8 in that case.
        RCLONE_ARGS+=(--max-transfer="${REMAINING_BYTES}B" --cutoff-mode soft)
    fi

    # Run rclone in the BACKGROUND so this script can poll its progress and
    # persist a running total periodically (every ~60s). This means a crash
    # or power loss mid-transfer loses at most ~60s of accounting accuracy,
    # instead of the entire pair's progress (which is what happens if state
    # is only saved after the whole pair/run completes). --progress still
    # writes live to the terminal as normal since the background process
    # inherits this shell's stdout/stderr.
    set +e
    rclone "${RCLONE_ARGS[@]}" &
    RCLONE_PID=$!

    LAST_SAVED_PAIR_BYTES=0
    LAST_CHECKPOINT_EPOCH=$(date +%s)
    # Poll frequently (so fast/small pairs don't pay a needless wait before
    # the loop notices rclone already finished), but only WRITE a checkpoint
    # to disk at most once every ~60s, to keep disk I/O and log noise low.
    while kill -0 "$RCLONE_PID" 2>/dev/null; do
        sleep 2
        NOW_EPOCH=$(date +%s)
        if [ $((NOW_EPOCH - LAST_CHECKPOINT_EPOCH)) -lt 60 ]; then
            continue
        fi
        LAST_CHECKPOINT_EPOCH="$NOW_EPOCH"
        # rclone may not have flushed a stats line yet on the very first tick;
        # that's fine, we just keep the last known value in that case.
        POLL_BYTES="$(grep -o '"bytes":[0-9]*' "$PAIR_STATS_LOG" 2>/dev/null | tail -1 | grep -o '[0-9]*' || true)"
        if [ -n "$POLL_BYTES" ] && [ "$POLL_BYTES" -gt "$LAST_SAVED_PAIR_BYTES" ]; then
            LAST_SAVED_PAIR_BYTES="$POLL_BYTES"
            if [ "$DRY_RUN" -eq 0 ]; then
                PERSISTED_BYTES=$((CURRENT_BYTES + TOTAL_RUN_BYTES + LAST_SAVED_PAIR_BYTES))
                ORIGINAL_CURRENT_BYTES="$CURRENT_BYTES"
                CURRENT_BYTES="$PERSISTED_BYTES"
                save_state
                CURRENT_BYTES="$ORIGINAL_CURRENT_BYTES"
                log "Checkpoint: $(bytes_to_human "$LAST_SAVED_PAIR_BYTES") into this pair, $(bytes_to_human "$PERSISTED_BYTES")/${CAP_GB}GB saved to disk in case of crash."
            fi
        fi
    done

    wait "$RCLONE_PID"
    RC_EXIT=$?
    set -e

    # Append the JSON stats log into the human-readable run log too, for full traceability.
    cat "$PAIR_STATS_LOG" >> "$RUN_LOG"

    # Parse the LAST JSON line that contains a "stats" object with a "bytes" field.
    # Each line is a standalone JSON object (rclone's --use-json-log format).
    PAIR_BYTES="$(
        grep -o '"bytes":[0-9]*' "$PAIR_STATS_LOG" | tail -1 | grep -o '[0-9]*' || true
    )"
    PAIR_BYTES="${PAIR_BYTES:-0}"
    rm -f "$PAIR_STATS_LOG"

    TOTAL_RUN_BYTES=$((TOTAL_RUN_BYTES + PAIR_BYTES))

    if [ "$RC_EXIT" -eq 8 ]; then
        # rclone's dedicated exit code for "max-transfer limit reached".
        log "Cap reached during this pair's transfer (rclone exit code 8). Any in-progress file was allowed to finish (--cutoff-mode soft)."
        log "Pair #$PAIR_COUNT partially completed: $(bytes_to_human "$PAIR_BYTES") transferred before stopping."
        CAP_HIT_MID_RUN=1
        break
    elif [ "$RC_EXIT" -ne 0 ] && [ "$RC_EXIT" -ne 7 ]; then
        log "WARNING: rclone exited with code $RC_EXIT for pair '$origin' -> '$destination' (see log for details)"
    fi

    log "Pair #$PAIR_COUNT finished: $(bytes_to_human "$PAIR_BYTES") transferred (rclone exit code: $RC_EXIT)"

done < "$CONFIG_FILE"

TOTAL_RUN_BYTES="${TOTAL_RUN_BYTES:-0}"

if [ "$DRY_RUN" -eq 0 ]; then
    CURRENT_BYTES=$((CURRENT_BYTES + TOTAL_RUN_BYTES))
    save_state
fi

log "=== Run complete ==="
log "Pairs processed: $PAIR_COUNT"
log "Transferred this run: $(bytes_to_human "$TOTAL_RUN_BYTES")"
log "Total used this cycle: $(bytes_to_human "$CURRENT_BYTES") / ${CAP_GB} GB"

if [ "$CAP_HIT_MID_RUN" -eq 1 ]; then
    if [ "$NO_CAP" -eq 1 ]; then
        log "NOTE: cap exceeded but --no-cap is active, transfers continued (warn-only mode)."
    else
        log "Cap reached: remaining pairs were NOT processed. They will resume on the next run after the cycle resets (16th)."
    fi
fi

if [ "$NO_CAP" -eq 1 ] && [ "$CURRENT_BYTES" -ge "$CAP_BYTES" ]; then
    log "WARNING: monthly cap of ${CAP_GB} GB exceeded (currently $(bytes_to_human "$CURRENT_BYTES")). Continuing because --no-cap is set."
fi

summary "Run ${RUN_TS}: transferred $(bytes_to_human "$TOTAL_RUN_BYTES"), cycle total $(bytes_to_human "$CURRENT_BYTES")/${CAP_GB}GB, pairs=${PAIR_COUNT}, dry_run=${DRY_RUN}, cap_hit_mid_run=${CAP_HIT_MID_RUN}"

log "Full log: $RUN_LOG"
log "Summary log: $SUMMARY_LOG"