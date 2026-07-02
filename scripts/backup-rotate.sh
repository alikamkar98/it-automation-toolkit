#!/usr/bin/env bash
#
# backup-rotate.sh - Create a compressed backup of a source directory and
#                    enforce a 7-daily / 4-weekly retention policy.
#
# Description:
#   Produces a timestamped tar.gz of SOURCE_DIR in BACKUP_DIR. Daily backups are
#   kept for 7 days. Every Sunday's backup is also promoted to a "weekly" copy;
#   the 4 most recent weeklies are retained. Older files in each tier are pruned.
#   All actions are appended to a log file.
#
# Usage:
#   ./backup-rotate.sh -s SOURCE_DIR -d BACKUP_DIR [-n NAME] [-l LOGFILE] [-r]
#
#   -s  Source directory to back up            (required)
#   -d  Destination directory for backups       (required)
#   -n  Base name for archives (default: basename of source)
#   -l  Log file (default: BACKUP_DIR/backup-rotate.log)
#   -r  Dry run - show what would happen, change nothing
#   -h  Show this help
#
# Examples:
#   ./backup-rotate.sh -s /var/www -d /mnt/backups
#   ./backup-rotate.sh -s /etc -d /mnt/backups -n etc-config -r
#
# Exit codes: 0 success, 1 usage error, 2 runtime error
#
# Cron example (02:30 every day):
#   30 2 * * * /opt/scripts/backup-rotate.sh -s /var/www -d /mnt/backups >> /var/log/backup.log 2>&1

set -euo pipefail

DAILY_KEEP=7
WEEKLY_KEEP=4
DRY_RUN=false
NAME=""
LOGFILE=""

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# --- Parse arguments -------------------------------------------------------
while getopts ":s:d:n:l:rh" opt; do
  case "$opt" in
    s) SOURCE_DIR="$OPTARG" ;;
    d) BACKUP_DIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    l) LOGFILE="$OPTARG" ;;
    r) DRY_RUN=true ;;
    h) usage 0 ;;
    :) echo "Error: -$OPTARG requires an argument." >&2; usage 1 ;;
    \?) echo "Error: unknown option -$OPTARG." >&2; usage 1 ;;
  esac
done

# --- Validate --------------------------------------------------------------
: "${SOURCE_DIR:?Error: -s SOURCE_DIR is required}"
: "${BACKUP_DIR:?Error: -d BACKUP_DIR is required}"

[[ -d "$SOURCE_DIR" ]] || { echo "Error: source '$SOURCE_DIR' is not a directory." >&2; exit 1; }

NAME="${NAME:-$(basename "$SOURCE_DIR")}"
DAILY_DIR="$BACKUP_DIR/daily"
WEEKLY_DIR="$BACKUP_DIR/weekly"
LOGFILE="${LOGFILE:-$BACKUP_DIR/backup-rotate.log}"

log() {
  local msg="$(date '+%Y-%m-%d %H:%M:%S')  $*"
  echo "$msg"
  $DRY_RUN || echo "$msg" >> "$LOGFILE"
}

# Wrapper so every mutating command respects -r (dry run).
run() {
  if $DRY_RUN; then
    echo "DRY-RUN: $*"
  else
    "$@"
  fi
}

# --- Prepare directories ---------------------------------------------------
run mkdir -p "$DAILY_DIR" "$WEEKLY_DIR"

STAMP="$(date '+%Y%m%d-%H%M%S')"
DOW="$(date '+%u')"   # 1=Monday .. 7=Sunday
ARCHIVE="$DAILY_DIR/${NAME}-${STAMP}.tar.gz"

# --- Create the daily backup ----------------------------------------------
log "Starting backup of '$SOURCE_DIR' -> '$ARCHIVE'"
if $DRY_RUN; then
  echo "DRY-RUN: tar -czf $ARCHIVE -C $(dirname "$SOURCE_DIR") $(basename "$SOURCE_DIR")"
else
  if tar -czf "$ARCHIVE" -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")"; then
    log "Backup created: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
  else
    log "ERROR: tar failed for '$SOURCE_DIR'"
    exit 2
  fi
fi

# --- Promote Sunday backups to weekly -------------------------------------
if [[ "$DOW" == "7" ]]; then
  WEEKLY_COPY="$WEEKLY_DIR/${NAME}-${STAMP}.tar.gz"
  log "Sunday detected - promoting to weekly: $WEEKLY_COPY"
  run cp "$ARCHIVE" "$WEEKLY_COPY"
fi

# --- Prune old backups -----------------------------------------------------
# Keep the newest N archives in a directory, delete the rest.
prune() {
  local dir="$1" keep="$2" tier="$3"
  # List matching archives newest-first, skip the first $keep, delete remainder.
  mapfile -t old < <(ls -1t "$dir/${NAME}-"*.tar.gz 2>/dev/null | tail -n +$((keep + 1)))
  if [[ ${#old[@]} -eq 0 ]]; then
    log "$tier retention OK - nothing to prune."
    return
  fi
  for f in "${old[@]}"; do
    log "Pruning old $tier backup: $f"
    run rm -f "$f"
  done
}

prune "$DAILY_DIR"  "$DAILY_KEEP"  "daily"
prune "$WEEKLY_DIR" "$WEEKLY_KEEP" "weekly"

log "Backup rotation complete."
