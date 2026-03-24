#!/bin/bash
set -euo pipefail

# --- Configuration ---
SLEEPTIME="${SLEEPTIME:-5m}"
CPU_CORES="${CPU_CORES:-0}"
MAKE_BACKUP="${MAKE_BACKUP:-N}"
AUDIO_BITRATE="${AUDIO_BITRATE:-auto}"
AUDIO_CODEC="${AUDIO_CODEC:-libfdk_aac}"
INPUT_DIR="/input"
OUTPUT_DIR="/output"
TEMP_DIR="/temp/merge"
BACKUP_DIR="/backup"
LOG_DIR="/config/logs"

# Auto-detect CPU cores
if [[ "$CPU_CORES" == "0" ]]; then
    CPU_CORES=$(nproc 2>/dev/null || echo 2)
fi

# --- Helpers ---
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

has_audio_files() {
    local dir="$1"
    find "$dir" -maxdepth 1 -type f \( \
        -iname "*.mp3" -o -iname "*.m4a" -o -iname "*.m4b" -o \
        -iname "*.ogg" -o -iname "*.flac" -o -iname "*.wma" -o \
        -iname "*.aac" -o -iname "*.opus" -o -iname "*.wav" \
    \) -print -quit 2>/dev/null | grep -q .
}

count_audio_files() {
    local dir="$1"
    find "$dir" -maxdepth 1 -type f \( \
        -iname "*.mp3" -o -iname "*.m4a" -o -iname "*.m4b" -o \
        -iname "*.ogg" -o -iname "*.flac" -o -iname "*.wma" -o \
        -iname "*.aac" -o -iname "*.opus" -o -iname "*.wav" \
    \) 2>/dev/null | wc -l
}

detect_bitrate() {
    local dir="$1"
    local first_audio
    first_audio=$(find "$dir" -maxdepth 1 -type f \( \
        -iname "*.mp3" -o -iname "*.m4a" -o -iname "*.m4b" -o \
        -iname "*.ogg" -o -iname "*.flac" -o -iname "*.aac" \
    \) -print -quit 2>/dev/null)
    if [[ -n "$first_audio" ]]; then
        local raw
        raw=$(ffprobe -v quiet -show_entries format=bit_rate \
            -of default=noprint_wrappers=1:nokey=1 "$first_audio" 2>/dev/null)
        if [[ -n "$raw" && "$raw" != "N/A" ]]; then
            echo "$((raw / 1000))k"
            return
        fi
    fi
    echo "128k"
}

# --- Graceful shutdown ---
RUNNING=true
trap 'RUNNING=false; log "Shutdown requested, finishing current book..."' SIGTERM SIGINT

# --- Main Loop ---
log "Started. Watching $INPUT_DIR every $SLEEPTIME..."

while $RUNNING; do
    FOUND_WORK=false

    while IFS= read -r -d '' bookdir; do
        [[ "$RUNNING" == "false" ]] && break

        bookname=$(basename "$bookdir")
        lockfile="${bookdir}/.processing"
        book_log="${LOG_DIR}/${bookname}.log"

        # Skip if locked (with 24h stale detection)
        if [[ -f "$lockfile" ]]; then
            lock_age=$(( $(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
            if [[ $lock_age -gt 86400 ]]; then
                log "Removing stale lock for '$bookname' (age: ${lock_age}s)"
                rm -f "$lockfile"
            else
                log "Skipping '$bookname' — already being processed"
                continue
            fi
        fi

        # Skip directories without audio files
        if ! has_audio_files "$bookdir"; then
            continue
        fi

        FOUND_WORK=true
        file_count=$(count_audio_files "$bookdir")
        log "Found '$bookname' with $file_count audio file(s)"

        # Create lock
        echo "$$" > "$lockfile"

        # Per-book log header
        {
            echo "=== m4b-audiobook-converter ==="
            echo "Started: $(date)"
            echo "Book:    $bookname"
            echo "Files:   $file_count"
        } > "$book_log"

        # Determine bitrate
        if [[ "$AUDIO_BITRATE" == "auto" ]]; then
            bitrate=$(detect_bitrate "$bookdir")
            log "Auto-detected bitrate: $bitrate"
        else
            bitrate="$AUDIO_BITRATE"
        fi
        echo "Bitrate: $bitrate" >> "$book_log"

        # Prepare working directory
        work_dir="${TEMP_DIR}/${bookname}"
        rm -rf "$work_dir"
        mkdir -p "$work_dir"

        # Copy source to working dir (preserves originals)
        log "Copying '$bookname' to working directory..."
        cp -a "$bookdir"/. "$work_dir"/ 2>>"$book_log"
        rm -f "${work_dir}/.processing"

        # Build m4b-tool merge command
        output_file="${work_dir}/${bookname}.m4b"
        m4b_args=(
            merge
            "$work_dir"
            --output-file="$output_file"
            --jobs="$CPU_CORES"
            --audio-codec="$AUDIO_CODEC"
            --audio-bitrate="$bitrate"
            --no-interaction
            --use-filenames-as-chapters
            --no-chapter-reindexing
        )

        # Log chapter source
        if [[ -f "${work_dir}/chapters.txt" ]]; then
            log "Found chapters.txt for '$bookname'"
            echo "Chapters: from chapters.txt" >> "$book_log"
        else
            echo "Chapters: from filenames" >> "$book_log"
        fi

        # Run m4b-tool
        log "Starting conversion of '$bookname'..."
        echo "=== m4b-tool output ===" >> "$book_log"

        set +e
        m4b-tool "${m4b_args[@]}" 2>&1 | tee -a "$book_log"
        m4b_exit=${PIPESTATUS[0]}
        set -e

        # Handle result
        if [[ $m4b_exit -eq 0 ]] && [[ -f "$output_file" ]]; then
            output_size=$(du -h "$output_file" | cut -f1)
            log "SUCCESS: '$bookname' converted ($output_size)"
            echo "=== Conversion successful: $(date) ===" >> "$book_log"

            # Move result to output
            mkdir -p "${OUTPUT_DIR}/${bookname}"
            mv "$output_file" "${OUTPUT_DIR}/${bookname}/"

            # Copy the per-book log to output
            cp "$book_log" "${OUTPUT_DIR}/${bookname}/"

            # Copy cover art if present
            for cover in "${work_dir}"/cover.{jpg,jpeg,png} "${work_dir}"/folder.{jpg,jpeg,png}; do
                if [[ -f "$cover" ]]; then
                    cp "$cover" "${OUTPUT_DIR}/${bookname}/"
                    break
                fi
            done

            # Backup if requested
            if [[ "${MAKE_BACKUP^^}" == "Y" ]]; then
                mkdir -p "${BACKUP_DIR}/${bookname}"
                cp -a "$bookdir"/. "${BACKUP_DIR}/${bookname}/"
                log "Backup created for '$bookname'"
            fi

            # Clean up source from input
            rm -rf "$bookdir"
            log "Removed source files for '$bookname'"
        else
            log_err "FAILED to convert '$bookname' (exit code: $m4b_exit)"
            echo "=== Conversion FAILED: $(date) (exit: $m4b_exit) ===" >> "$book_log"

            # Move source to failed directory with error log
            mkdir -p "${OUTPUT_DIR}/failed/${bookname}"
            mv "$bookdir" "${OUTPUT_DIR}/failed/${bookname}/source" 2>/dev/null || true
            cp "$book_log" "${OUTPUT_DIR}/failed/${bookname}/error.log"
            log_err "Source moved to /output/failed/${bookname}/"
        fi

        # Clean up working directory and lock
        rm -rf "$work_dir"
        rm -f "$lockfile"

    done < <(find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

    # Sleep between scans (interruptible)
    if $RUNNING; then
        if [[ "$FOUND_WORK" == "true" ]]; then
            log "Scan complete. Sleeping ${SLEEPTIME}..."
        fi
        sleep "$SLEEPTIME" &
        wait $! 2>/dev/null || true
    fi
done

log "m4b-audiobook-converter stopped."
