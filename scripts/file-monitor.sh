#!/bin/bash
#
# file-monitor.sh — ARM file change logger
#
# Monitors ~/Library/Application Support/AudioRecordingManager/ for changes.
# On each run, takes a snapshot, compares with the previous one, and logs:
#   - Created files
#   - Deleted files
#   - Modified files (with diffs for text files)
#   - Timestamp and user info
#
# Usage:
#   ./scripts/file-monitor.sh              # Run once (compare with last snapshot)
#   ./scripts/file-monitor.sh --watch      # Run continuously every 30 seconds
#   ./scripts/file-monitor.sh --init       # Take initial snapshot without comparing
#
# Log file: ~/Library/Application Support/AudioRecordingManager/audit/file-changes.log
# Snapshots: ~/Library/Application Support/AudioRecordingManager/audit/.snapshot

set -euo pipefail

ARM_ROOT="$HOME/Library/Application Support/AudioRecordingManager"
AUDIT_DIR="$ARM_ROOT/audit"
LOG_FILE="$AUDIT_DIR/file-changes.log"
SNAPSHOT_FILE="$AUDIT_DIR/.snapshot"
SNAPSHOT_PREV="$AUDIT_DIR/.snapshot.prev"
TEXT_CACHE_DIR="$AUDIT_DIR/.text-cache"

USER_INFO="$(whoami)@$(hostname -s)"
TIMESTAMP_FMT="+%Y-%m-%d %H:%M:%S"

# Ensure directories exist
mkdir -p "$AUDIT_DIR"
mkdir -p "$TEXT_CACHE_DIR"

# ─────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────

log() {
    local ts
    ts=$(date "$TIMESTAMP_FMT")
    echo "[$ts] [$USER_INFO] $*" | tee -a "$LOG_FILE"
}

log_separator() {
    echo "────────────────────────────────────────────────────" >> "$LOG_FILE"
}

# ─────────────────────────────────────────────
# Snapshot: list of files with size + mtime hash
# Format: <relative-path>\t<size>\t<mtime>\t<sha256-for-text-files>
# ─────────────────────────────────────────────

take_snapshot() {
    # Only track audio files (.m4a, .mp3, .wav) and text files (.txt)
    find "$ARM_ROOT" -type f \
        \( -name "*.m4a" -o -name "*.mp3" -o -name "*.wav" -o -name "*.aac" -o -name "*.ds2" -o -name "*.txt" \) \
        -not -path "*/audit/*" \
        -not -path "*/no-transcribe-venv/*" \
        -not -path "*/.build/*" \
        2>/dev/null | sort | while IFS= read -r filepath; do

        local relpath="${filepath#$ARM_ROOT/}"
        local size
        size=$(stat -f%z "$filepath" 2>/dev/null || echo "0")
        local mtime
        mtime=$(stat -f%m "$filepath" 2>/dev/null || echo "0")

        # For text files, compute SHA-256 for content change detection
        local hash="-"
        local ext="${filepath##*.}"
        case "$ext" in
            txt|json|jsonl|md|swift|py|sh|xml|plist|csv)
                hash=$(shasum -a 256 "$filepath" 2>/dev/null | cut -d' ' -f1 || echo "-")
                ;;
        esac

        printf '%s\t%s\t%s\t%s\n' "$relpath" "$size" "$mtime" "$hash"
    done
}

# ─────────────────────────────────────────────
# Cache text file contents for diffing
# ─────────────────────────────────────────────

cache_text_file() {
    local relpath="$1"
    local filepath="$ARM_ROOT/$relpath"
    local cache_path="$TEXT_CACHE_DIR/$(echo "$relpath" | sed 's|/|__|g')"

    local ext="${filepath##*.}"
    case "$ext" in
        txt|json|jsonl|md)
            cp "$filepath" "$cache_path" 2>/dev/null || true
            ;;
    esac
}

get_cached_path() {
    local relpath="$1"
    echo "$TEXT_CACHE_DIR/$(echo "$relpath" | sed 's|/|__|g')"
}

# ─────────────────────────────────────────────
# Compare snapshots
# ─────────────────────────────────────────────

compare_snapshots() {
    local old_snap="$1"
    local new_snap="$2"
    local changes_found=0

    # Build associative-style lookups via temp files
    local old_paths new_paths
    old_paths=$(cut -f1 "$old_snap" | sort)
    new_paths=$(cut -f1 "$new_snap" | sort)

    # Created files (in new but not old)
    local created
    created=$(comm -13 <(echo "$old_paths") <(echo "$new_paths"))
    if [ -n "$created" ]; then
        while IFS= read -r relpath; do
            [ -z "$relpath" ] && continue
            local size
            size=$(grep "^${relpath}	" "$new_snap" | cut -f2)
            log "CREATED  $relpath  (${size} bytes)"
            cache_text_file "$relpath"
            changes_found=1
        done <<< "$created"
    fi

    # Deleted files (in old but not new)
    local deleted
    deleted=$(comm -23 <(echo "$old_paths") <(echo "$new_paths"))
    if [ -n "$deleted" ]; then
        while IFS= read -r relpath; do
            [ -z "$relpath" ] && continue
            log "DELETED  $relpath"
            # Remove cached version
            local cache_path
            cache_path=$(get_cached_path "$relpath")
            rm -f "$cache_path"
            changes_found=1
        done <<< "$deleted"
    fi

    # Modified files (in both, but hash or size changed)
    local common
    common=$(comm -12 <(echo "$old_paths") <(echo "$new_paths"))
    if [ -n "$common" ]; then
        while IFS= read -r relpath; do
            [ -z "$relpath" ] && continue
            local old_line new_line
            old_line=$(grep "^${relpath}	" "$old_snap" || true)
            new_line=$(grep "^${relpath}	" "$new_snap" || true)

            [ "$old_line" = "$new_line" ] && continue

            local old_size new_size old_hash new_hash
            old_size=$(echo "$old_line" | cut -f2)
            new_size=$(echo "$new_line" | cut -f2)
            old_hash=$(echo "$old_line" | cut -f4)
            new_hash=$(echo "$new_line" | cut -f4)

            local size_delta=""
            if [ "$old_size" != "$new_size" ]; then
                size_delta="  (${old_size} → ${new_size} bytes)"
            fi

            log "MODIFIED $relpath$size_delta"

            # Show diff for text files
            if [ "$old_hash" != "$new_hash" ] && [ "$old_hash" != "-" ] && [ "$new_hash" != "-" ]; then
                local cache_path
                cache_path=$(get_cached_path "$relpath")
                local filepath="$ARM_ROOT/$relpath"
                if [ -f "$cache_path" ] && [ -f "$filepath" ]; then
                    local diff_output
                    diff_output=$(diff --unified=2 "$cache_path" "$filepath" 2>/dev/null || true)
                    if [ -n "$diff_output" ]; then
                        echo "  --- diff ---" >> "$LOG_FILE"
                        echo "$diff_output" | head -50 >> "$LOG_FILE"
                        local diff_lines
                        diff_lines=$(echo "$diff_output" | wc -l)
                        if [ "$diff_lines" -gt 50 ]; then
                            echo "  ... ($diff_lines total lines, showing first 50)" >> "$LOG_FILE"
                        fi
                        echo "  --- end diff ---" >> "$LOG_FILE"
                    fi
                fi
                cache_text_file "$relpath"
            fi
            changes_found=1
        done <<< "$common"
    fi

    return $changes_found
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

run_once() {
    local new_snap
    new_snap=$(mktemp)
    take_snapshot > "$new_snap"

    if [ ! -f "$SNAPSHOT_FILE" ]; then
        # First run — just take snapshot
        mv "$new_snap" "$SNAPSHOT_FILE"
        log "INIT     Initial snapshot taken ($(wc -l < "$SNAPSHOT_FILE") files)"
        # Cache all text files
        while IFS=$'\t' read -r relpath _ _ _; do
            cache_text_file "$relpath"
        done < "$SNAPSHOT_FILE"
        return
    fi

    # Compare
    log_separator
    if compare_snapshots "$SNAPSHOT_FILE" "$new_snap"; then
        : # changes were found and logged
    else
        log "CHECK    No changes detected"
    fi

    # Rotate snapshots
    cp "$SNAPSHOT_FILE" "$SNAPSHOT_PREV"
    mv "$new_snap" "$SNAPSHOT_FILE"
}

case "${1:-}" in
    --init)
        rm -f "$SNAPSHOT_FILE" "$SNAPSHOT_PREV"
        rm -rf "$TEXT_CACHE_DIR"
        mkdir -p "$TEXT_CACHE_DIR"
        run_once
        echo "Initial snapshot taken. Run without --init to detect changes."
        ;;
    --watch)
        interval="${2:-30}"
        log "WATCH    Starting continuous monitoring (every ${interval}s)"
        echo "Monitoring $ARM_ROOT every ${interval}s. Log: $LOG_FILE"
        echo "Press Ctrl+C to stop."
        while true; do
            run_once
            sleep "$interval"
        done
        ;;
    *)
        run_once
        ;;
esac
