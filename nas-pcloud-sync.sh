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
#   -h, --help             Show this help
#
# Requires: rclone (configured with a "pcloud" remote), bash, awk, date, du-like
#           size parsing via rclone's own JSON stats (no extra deps needed).

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/folders.conf"
STATE_DIR="${SCRIPT_DIR}/state"
LOG_DIR="${SCRIPT_DIR}/logs"
STATE_FILE="${STATE_DIR}/usage_state.tsv"   # cycle_start_date<TAB>bytes_transferred
CAP_GB=50
DRY_RUN=0
NO_CAP=0
FORCE_RESET=0

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
        -h|--help)
            usage ;;
        *)
            die "Unknown option: $1 (use -h for help)" ;;
    esac
done

[ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
command -v rclone >/dev/null 2>&1 || die "rclone not found in PATH. Install/configure rclone first."

CAP_BYTES="$(human_to_bytes_gb "$CAP_GB")"

log "=== NAS -> pCloud sync started ==="
log "Config file:   $CONFIG_FILE"
log "Dry run:       $([ "$DRY_RUN" -eq 1 ] && echo yes || echo no)"
log "Cap:           ${CAP_GB} GB ($([ "$NO_CAP" -eq 1 ] && echo "warn-only, override active" || echo "hard stop when reached"))"

load_state
log "Cycle:         $(current_cycle_start) -> next reset on 16th of following month"
log "Used so far this cycle: $(bytes_to_human "$CURRENT_BYTES") of ${CAP_GB} GB"

if [ "$NO_CAP" -eq 0 ] && [ "$CURRENT_BYTES" -ge "$CAP_BYTES" ]; then
    log "Monthly cap already reached for this cycle. Stopping until next cycle (16th)."
    summary "Run ${RUN_TS}: SKIPPED - cap already reached ($(bytes_to_human "$CURRENT_BYTES")/${CAP_GB}GB)."
    exit 0
fi

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

    if [ ! -d "$origin" ]; then
        log "WARNING: origin path does not exist, skipping: $origin"
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

    # Plain human-readable log goes to the run log file.
    RCLONE_ARGS=(copy "$origin" "$destination"
        --log-file="$RUN_LOG" --log-level INFO
        --create-empty-src-dirs)

    if [ "$DRY_RUN" -eq 1 ]; then
        RCLONE_ARGS+=(--dry-run)
    fi

    if [ "$NO_CAP" -eq 0 ]; then
        # Limit this pair's transfer to the remaining budget for the cycle.
        # --cutoff-mode soft lets any file currently being transferred finish
        # (rather than truncating it mid-write) and just stops starting new
        # ones once the limit is reached. rclone exits with code 8 in that case.
        RCLONE_ARGS+=(--max-transfer="${REMAINING_BYTES}B" --cutoff-mode soft)
    fi

    # Separately, capture a final JSON stats snapshot to get an exact byte count
    # for this pair. rclone's --use-json-log emits one JSON object per log line,
    # and periodic stats lines include a "stats" object with a precise "bytes"
    # field. We parse the last such value rather than regexing human units,
    # since human formatting (KiB/MiB/GiB, locale) is not reliable to parse.
    PAIR_STATS_LOG="$(mktemp)"
    set +e
    rclone "${RCLONE_ARGS[@]}" \
        --stats 1s --stats-one-line --use-json-log \
        2>"$PAIR_STATS_LOG"
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
