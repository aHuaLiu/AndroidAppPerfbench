#!/bin/bash

################################################################################
# Performance Test Script (Multi-Process Accurate Statistics Version)
# Purpose: Test the CPU and memory performance of a specified application during
# video playback (including subprocesses like sandboxed/privileged, etc.)
# Platform: macOS, Linux
# Requirements: adb tool, bc tool installed
# created by hua.liu
################################################################################

################################################################################
# Configuration Parameters - Adjust as needed
################################################################################

# Application package name (main process name)
PACKAGE_NAME="com.xxx.yyy"

# ADB device serial number (optional) - Specify the target device when multiple
# devices are connected.
# Leave blank to automatically select the first online device; you can also
# manually specify, e.g., ADB_SERIAL="emulator-5554"
ADB_SERIAL=""

# Test duration (minutes)
TEST_DURATION_MINUTES=5

# Sampling interval (seconds)
CPU_INTERVAL=10
MEM_INTERVAL=10

# CPU Collection Method (dumpsys|procstat)
# dumpsys  = Use dumpsys cpuinfo (existing method, sliding window)
# procstat = Use /proc/stat (new method, precise time window, RECOMMENDED)
CPU_METHOD="procstat"

# Minimum CPU percentage threshold for valid samples
# Set to 0.0 to include all samples, or 1.0+ to filter out idle/low-activity
# periods
MIN_CPU_PERCENT=0.0

# Whether to strictly require WindowMs parsing
# 0 = allow WindowMs=-1 samples (with caution)
# 1 = exclude WindowMs=-1 samples (strict mode)
STRICT_WINDOW=1

# Performance benchmark (custom scale)
# Single-core 100% CPU ≈ 20K DMIPS (approximate comparison)
SINGLE_CORE_DMIPS=20599

# Debug mode (1=output more diagnostic information)
DEBUG_MODE=0

################################################################################
# Automatically Calculated Parameters (Do not modify)
################################################################################
TEST_DURATION=$((TEST_DURATION_MINUTES * 60))

CPU_LOG="cpu_log.csv"
MEM_LOG="mem_log.csv"
REPORT_FILE="report.md"

TEST_INTERRUPTED=0
TEST_START_TIME=""
TEST_DIR=""

# procstat method: File-based caching (bash 3.2 compatible)
PROCSTAT_TOTAL_PREV_FILE=""
PROCSTAT_PID_PREV_FILE=""
PROCSTAT_WALL_PREV_FILE=""
PROCSTAT_NCPU=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

################################################################################
# Print Utilities
################################################################################
print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

################################################################################
# adb Wrapper (Supports Multiple Devices)
################################################################################
adb_cmd() {
    if [[ -n "$ADB_SERIAL" ]]; then
        adb -s "$ADB_SERIAL" "$@"
    else
        adb "$@"
    fi
}

################################################################################
# Get ps Output (Compatible with ps -A / ps)
################################################################################
get_ps_output() {
    local out
    out=$(adb_cmd shell ps -A 2>/dev/null)
    if [[ -z "$out" ]]; then
        out=$(adb_cmd shell ps 2>/dev/null)
    fi
    echo "$out"
}

################################################################################
# Get All Related Process PIDs for the Package Name
#   (Including : and _ Subprocesses)
# Matching Rule: ^PACKAGE_NAME(:|_|$)
# Supported Formats: Package name, Package name:service, Package name_zygote
################################################################################
get_all_pids() {
    local out pkg_escaped
    out=$(get_ps_output)
    if [[ -z "$out" ]]; then
        echo ""
        return 0
    fi

    # Pass package name to awk without escaping
    #  - let awk handle it as plain text
    echo "$out" | awk -v pkg="$PACKAGE_NAME" '
    BEGIN {
        pid_col = 2
        found_pid_col = 0
        # Escape special regex characters in awk
        gsub(/[[\]()*^$|?+\\]/, "\\\\&", pkg)
        gsub(/\./, "\\.", pkg)
    }
    {
        # Identify header row (contains PID field)
        if (!found_pid_col && /PID/) {
            # Dynamically identify PID column position
            for (i=1; i<=NF; i++) {
                if ($i == "PID") { pid_col = i; found_pid_col = 1; break; }
            }
            next
        }

        # If PID column not found, dynamically identify
        #  (compatible with ps output without header)
        if (found_pid_col == 0 && NF > 2) {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+$/ && i <= 3) { pid_col = i; break; }
            }
            found_pid_col = 1
        }

        name = $NF
        # Match: Package name, Package name:xxx, Package name_xxx
        # (e.g., _zygote)
        if (name ~ ("^" pkg "(:|_|$)")) {
            print $pid_col
        }
    }' | tr -d '\r' | awk 'NF' | sort -n | uniq
}

################################################################################
# Handle Interrupt Signals
################################################################################
handle_interrupt() {
    # Remove trap to prevent repeated triggering
    trap - INT TERM

    print_warn "\nInterrupt signal detected (Ctrl+C), generating report..."
    TEST_INTERRUPTED=1

    if [[ -z "$TEST_DIR" ]] || [[ ! -d "$TEST_DIR" ]]; then
        print_warn "Test has not started, no data to save"
        exit 0
    fi

    if [[ -f "$CPU_LOG" ]] && [[ $(wc -l < "$CPU_LOG" 2>/dev/null || echo 0) -gt 1 ]]; then
        generate_report
        print_info "Report generated, test ended prematurely"
    else
        print_warn "Not enough data to generate a report"
    fi
    exit 0
}

################################################################################
# Check Dependencies
################################################################################
check_dependencies() {
    print_info "Checking dependencies..."
    local missing=""

    command -v adb &> /dev/null || missing="${missing}adb "
    command -v bc  &> /dev/null || missing="${missing}bc "
    command -v awk &> /dev/null || missing="${missing}awk "

    if [ -n "$missing" ]; then
        print_error "Missing required tools: $missing"
        print_info "macOS Installation Methods:"
        [[ $missing == *"adb"* ]] && echo "  - adb: brew install --cask android-platform-tools"
        [[ $missing == *"bc"*  ]] && echo "  - bc : brew install bc"
        [[ $missing == *"awk"* ]] && echo "  - awk: macOS built-in, if issues occur install gawk: brew install gawk"
        exit 1
    fi
    print_info "Dependency check passed"
}

################################################################################
# Check ADB Connection and Device Selection
################################################################################
check_adb_connection() {
    print_info "Checking ADB connection status..."

    local device_count
    device_count=$(adb devices | awk 'NR>1 && $2=="device"{c++} END{print c+0}')

    if [[ "$device_count" -eq 0 ]]; then
        print_error "No online Android devices detected (device status), please connect a device and try again"
        adb devices
        exit 1
    fi

    # Multiple devices: If serial not specified, automatically select the first
    # online device
    if [[ -z "$ADB_SERIAL" ]] && [[ "$device_count" -gt 1 ]]; then
        print_warn "$device_count devices detected, ADB_SERIAL not specified"
        print_info "Available device list:"
        adb devices

        ADB_SERIAL=$(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')
        print_info "Automatically selected device: $ADB_SERIAL"
        print_warn "To specify another device, configure ADB_SERIAL=\"<serial number>\" at the top of the script"
        sleep 2
    elif [[ -n "$ADB_SERIAL" ]]; then
        # Validate manually specified serial number exists and is online
        if ! adb devices | awk -v s="$ADB_SERIAL" 'NR>1 && $1==s && $2=="device"{found=1} END{exit !found}'; then
            print_error "Specified ADB_SERIAL=$ADB_SERIAL does not exist or is not in device status"
            print_info "Currently available devices:"
            adb devices
            exit 1
        fi
        print_info "Using specified device: $ADB_SERIAL"
    fi

    print_info "Device connection normal"
    adb devices
}

################################################################################
# Check Application Running Status
# (Any process with the same package is considered running)
################################################################################
check_app_running() {
    print_info "Cleaning up all related processes (to prevent residual process statistics)..."

    # Check for residual processes
    local old_pids
    old_pids=$(get_all_pids | tr '\n' ' ')

    if [[ -n "$old_pids" ]]; then
        print_warn "Residual process PID(s) detected: $old_pids"
        print_info "Forcibly stopping the application..."

        # Try force-stop multiple times with increasing wait times
        local max_attempts=3
        local attempt=1
        local remaining_pids

        while [[ $attempt -le $max_attempts ]]; do
            adb_cmd shell am force-stop "$PACKAGE_NAME" 2>/dev/null

            # Wait time increases with each attempt: 2s, 3s, 5s
            local wait_time=$((attempt + 1))
            [[ $attempt -eq 3 ]] && wait_time=5
            sleep $wait_time

            remaining_pids=$(get_all_pids | tr '\n' ' ' | tr -d '\r')

            if [[ -z "$remaining_pids" ]]; then
                print_info "All residual processes cleaned up successfully"
                break
            else
                if [[ $attempt -lt $max_attempts ]]; then
                    print_warn "Attempt $attempt: Some processes still exist (PID: $remaining_pids), retrying..."
                else
                    print_warn "After $max_attempts attempts, some processes still exist (PID: $remaining_pids)"
                    print_warn "This may be a system-level process that cannot be stopped"
                    print_warn "The test will continue, but this may affect accuracy"
                    echo ""
                    print_warn "Do you want to:"
                    print_warn "  1) Continue testing anyway (Press Enter)"
                    print_warn "  2) Manually kill processes and restart test (Press Ctrl+C, then run script again)"
                    print_warn ""
                    read -p "Press Enter to continue or Ctrl+C to exit..."
                fi
            fi
            attempt=$((attempt + 1))
        done
    else
        print_info "No residual processes detected"
    fi

    print_info "Checking if the application is running (multi-process mode)..."

    local pids
    pids=$(get_all_pids | tr '\n' ' ')

    if [[ -z "$pids" ]]; then
        print_info "Application $PACKAGE_NAME is not running, please start the application"
        print_warn "Please manually open the application and start an operation (e.g., play a video)"
        print_warn "Press Enter to continue..."
        read

        pids=$(get_all_pids | tr '\n' ' ')
        if [[ -z "$pids" ]]; then
            print_error "Application is still not running, exiting test"
            exit 1
        fi
    fi

    local pid_count=$(echo "$pids" | wc -w | tr -d ' ')
    print_info "Detected $pid_count process PID(s): $pids"

    if [[ $DEBUG_MODE -eq 1 ]]; then
        print_info "DEBUG: Process name list (ps last column matches ^${PACKAGE_NAME}(:|_|$)）："
        get_ps_output | awk -v pkg="$PACKAGE_NAME" '$NF ~ ("^"pkg"(:|_|$)") {print $NF}' | tr -d '\r' | sort | uniq
    fi
}

################################################################################
# Check if the Application is Still Running During the Test
################################################################################
check_app_alive() {
    # Check if there are any matching package processes
    # (allowing dynamic process changes)
    local current_pids
    current_pids=$(get_all_pids | tr '\n' ' ')

    if [[ -z "$current_pids" ]]; then
        print_error "The application has stopped running (no matching processes), test terminated"
        if [[ -f "$CPU_LOG" ]] && [[ $(wc -l < "$CPU_LOG" 2>/dev/null || echo 0) -gt 1 ]]; then
            print_info "Generating report with existing data..."
            generate_report
        fi
        exit 1
    fi
}

################################################################################
# Create Test Directory
################################################################################
create_test_directory() {
    print_info "Creating test directory..."

    TEST_START_TIME=$(date '+%Y%m%d_%H%M%S')
    TEST_DIR="test_${TEST_START_TIME}"

    if [ -d "$TEST_DIR" ]; then
        print_warn "Directory $TEST_DIR already exists, adding timestamp suffix..."
        TEST_DIR="${TEST_DIR}_$(date +%s)"
    fi

    mkdir -p "$TEST_DIR"
    if [ ! -d "$TEST_DIR" ]; then
        print_error "Unable to create test directory: $TEST_DIR"
        exit 1
    fi

    CPU_LOG="${TEST_DIR}/cpu_log.csv"
    MEM_LOG="${TEST_DIR}/mem_log.csv"
    REPORT_FILE="${TEST_DIR}/report.md"

    print_info "Test directory created: $TEST_DIR"
    print_info "Test ID：$TEST_START_TIME"
}

################################################################################
# Initialize Logs
################################################################################
init_logs() {
    print_info "Initializing log files..."

    if ! echo "Timestamp,Time(Seconds),CPU Percentage(%),DMIPS,WindowMs,FilterReason" > "$CPU_LOG" 2>/dev/null; then
        print_error "Unable to create CPU log file：$CPU_LOG（Please check disk space or permissions）"
        exit 1
    fi

    if ! echo "Timestamp,Time(Seconds),TOTAL_RSS(KB),RSS(MB),TOTAL_PSS(KB),PSS(MB)" > "$MEM_LOG" 2>/dev/null; then
        print_error "Unable to create memory log file：$MEM_LOG（Please check disk space or permissions）"
        exit 1
    fi

    print_info "Log files created: $CPU_LOG, $MEM_LOG"
}

################################################################################
# procstat: Get CPU Core Count (prefer online cores)
################################################################################
procstat_get_ncpu() {
    local ncpu

    # Try to get online CPU count first (more accurate for dynamic core scaling)
    # Format: "0-7" or "0,2-5,7" etc.
    local online
    online=$(adb_cmd shell cat /sys/devices/system/cpu/online 2>/dev/null | tr -d '\r')

    if [[ -n "$online" ]]; then
        # Parse ranges like "0-7" or "0,2-5,7"
        ncpu=$(echo "$online" | awk -F',' '{
            count=0
            for(i=1; i<=NF; i++) {
                if($i ~ /-/) {
                    split($i, r, "-")
                    count += r[2] - r[1] + 1
                } else {
                    count++
                }
            }
            print count
        }')

        if [[ -n "$ncpu" ]] && [[ "$ncpu" -gt 0 ]]; then
            echo "$ncpu"
            return 0
        fi
    fi

    # Fallback: Count cpu0, cpu1, ... lines in /proc/stat
    ncpu=$(adb_cmd shell cat /proc/stat 2>/dev/null | grep -c "^cpu[0-9]" | tr -d '\r')
    if [[ -z "$ncpu" ]] || [[ "$ncpu" -eq 0 ]]; then
        print_warn "NCPU detection failed, defaulting to 1"
        echo "1"
    else
        echo "$ncpu"
    fi
}

################################################################################
# procstat: Read Total System CPU Jiffies
################################################################################
procstat_read_total_jiffies() {
    # Read "cpu " line (note the space) and sum all numeric fields
    local line
    line=$(adb_cmd shell cat /proc/stat 2>/dev/null | grep "^cpu " | tr -d '\r')
    if [[ -z "$line" ]]; then
        echo ""
        return 1
    fi

    # Sum all fields after "cpu"
    echo "$line" | awk '{sum=0; for(i=2; i<=NF; i++) sum+=$i; print sum}'
}

################################################################################
# procstat: Read Single Process CPU Jiffies (utime + stime)
# Args: $1 = PID
# Returns: utime+stime, or empty string on error
################################################################################
procstat_read_pid_jiffies() {
    local pid="$1"
    [[ -z "$pid" ]] && return 1

    local stat_line
    stat_line=$(adb_cmd shell cat /proc/$pid/stat 2>/dev/null | tr -d '\r')
    if [[ -z "$stat_line" ]]; then
        return 1
    fi

    # Parse stat line: handle comm field in parentheses (may contain spaces)
    # Find position after ") " and extract fields from there
    local jiffies
    jiffies=$(echo "$stat_line" | awk '
    {
        line = $0
        # Find the last ")" to handle comm with parentheses
        idx = 0
        for (i=1; i<=length(line); i++) {
            if (substr(line, i, 1) == ")") idx = i
        }
        if (idx == 0) { print ""; exit }

        # Get substring after ") "
        rest = substr(line, idx+1)
        gsub(/^[[:space:]]+/, "", rest)  # trim leading spaces

        # Split rest into fields
        n = split(rest, a, " ")

        # Original stat: 1=pid, 2=comm, 3=state, ..., 14=utime, 15=stime
        # rest starts from field 3 (state), so:
        # rest[1]=state(3), rest[2]=ppid(4), ...,
        #   rest[12]=utime(14), rest[13]=stime(15)
        utime = a[12]
        stime = a[13]

        if (utime ~ /^[0-9]+$/ && stime ~ /^[0-9]+$/) {
            print utime + stime
        } else {
            print ""
        }
    }')

    echo "$jiffies"
}

################################################################################
# procstat: Initialize (called once at test start)
################################################################################
procstat_init() {
    print_info "Initializing procstat method..."

    # Set file paths
    PROCSTAT_TOTAL_PREV_FILE="${TEST_DIR}/procstat_total_prev.txt"
    PROCSTAT_PID_PREV_FILE="${TEST_DIR}/procstat_pid_prev.tsv"
    PROCSTAT_WALL_PREV_FILE="${TEST_DIR}/procstat_wall_prev.txt"

    # Get NCPU
    PROCSTAT_NCPU=$(procstat_get_ncpu)
    print_info "Detected CPU cores: $PROCSTAT_NCPU"

    # Check if /proc/stat is readable
    if ! adb_cmd shell test -r /proc/stat 2>/dev/null; then
        print_error "/proc/stat is not readable on device"
        print_error "Falling back to dumpsys method (set CPU_METHOD=\"dumpsys\")"
        exit 1
    fi

    # Read initial baseline (total jiffies)
    local total_now
    total_now=$(procstat_read_total_jiffies)
    if [[ -z "$total_now" ]]; then
        print_error "Failed to read /proc/stat"
        exit 1
    fi

    # Save baseline (total jiffies)
    echo "$total_now" > "$PROCSTAT_TOTAL_PREV_FILE"

    # Initialize PID cache with current values
    #  (baseline for all existing processes)
    print_info "Recording baseline for all current processes..."
    local pids baseline_count=0
    pids=$(get_all_pids)

    : > "$PROCSTAT_PID_PREV_FILE"  # Clear file first

    if [[ -n "$pids" ]]; then
        for pid in $pids; do
            pid=$(echo "$pid" | tr -d ' \r\n')
            [[ -z "$pid" ]] && continue

            local proc_jiffies
            proc_jiffies=$(procstat_read_pid_jiffies "$pid")
            if [[ -n "$proc_jiffies" ]] && [[ "$proc_jiffies" =~ ^[0-9]+$ ]]; then
                echo -e "${pid}\t${proc_jiffies}" >> "$PROCSTAT_PID_PREV_FILE"
                baseline_count=$((baseline_count + 1))
            fi
        done
    fi

    # Save baseline wall-clock time AFTER all init work
    #  (to avoid timing skew from PID reading)
    echo "$(date +%s)" > "$PROCSTAT_WALL_PREV_FILE"

    print_info "CPU Method: /proc/stat (real wall-clock window, target ~${CPU_INTERVAL}s, NCPU=$PROCSTAT_NCPU)"
    print_info "Baseline recorded: total_jiffies=$total_now, ${baseline_count} processes"
}

################################################################################
# Collect CPU Data - /proc/stat Method (Precise Time Window)
# Algorithm:
#   CPU% = 100 * NCPU * (ΔProc_jiffies / ΔTotal_jiffies)
# Where:
#   - ΔProc_jiffies
#        sum of (current_pid_jiffies - prev_pid_jiffies)for all PIDs
#   - ΔTotal_jiffies
#        current_total_jiffies - prev_total_jiffies
#   - NCPU
#        number of CPU cores (to normalize to "100% = 1 core fully utilized")
################################################################################
collect_cpu_procstat() {
    local timestamp elapsed
    timestamp=$(date +%s)
    elapsed=$1

    # Compute real window_ms based on wall-clock delta
    local wall_prev wall_delta window_ms_real
    wall_prev=$(cat "$PROCSTAT_WALL_PREV_FILE" 2>/dev/null)
    [[ -z "$wall_prev" ]] && wall_prev="$timestamp"
    wall_delta=$((timestamp - wall_prev))
    [[ $wall_delta -lt 0 ]] && wall_delta=0
    window_ms_real=$((wall_delta * 1000))

    # 1. Read current system total jiffies
    local total_now
    total_now=$(procstat_read_total_jiffies)
    if [[ -z "$total_now" ]]; then
        print_warn "Failed to read /proc/stat (Time: ${elapsed}s)"
        echo "$timestamp,$elapsed,0.00,0,0,ReadFailed:/proc/stat" >> "$CPU_LOG"
        # Update wall-clock to avoid cumulative delta
        echo "$timestamp" > "$PROCSTAT_WALL_PREV_FILE"
        return 1
    fi

    # 2. Read previous total jiffies
    local total_prev
    if [[ -f "$PROCSTAT_TOTAL_PREV_FILE" ]]; then
        total_prev=$(cat "$PROCSTAT_TOTAL_PREV_FILE" 2>/dev/null)
    fi
    [[ -z "$total_prev" ]] && total_prev="0"

    # 3. Get all current PIDs
    local pids
    pids=$(get_all_pids)
    if [[ -z "$pids" ]]; then
        print_warn "No process PIDs found (Time: ${elapsed}s)"
        echo "$timestamp,$elapsed,0.00,0,0,NoPID" >> "$CPU_LOG"
        # Update wall-clock to avoid cumulative delta
        echo "$timestamp" > "$PROCSTAT_WALL_PREV_FILE"
        return 1
    fi

    # 4. Read current PID jiffies and calculate delta
    local proc_delta_total=0
    local pid_count=0
    local new_pid_cache=""

    for pid in $pids; do
        pid=$(echo "$pid" | tr -d ' \r\n')
        [[ -z "$pid" ]] && continue

        # Read current jiffies for this PID
        local proc_now
        proc_now=$(procstat_read_pid_jiffies "$pid")
        if [[ -z "$proc_now" ]] || ! [[ "$proc_now" =~ ^[0-9]+$ ]]; then
            if [[ $DEBUG_MODE -eq 1 ]]; then
                print_warn "Failed to read /proc/$pid/stat (process may have exited)"
            fi
            continue
        fi

        # Find previous jiffies from cache
        local proc_prev=""
        if [[ -f "$PROCSTAT_PID_PREV_FILE" ]]; then
            proc_prev=$(awk -v p="$pid" '$1==p {print $2; exit}' "$PROCSTAT_PID_PREV_FILE" 2>/dev/null)
        fi

        # Calculate delta for this PID
        local proc_delta
        if [[ -z "$proc_prev" ]]; then
            # New PID: baseline only
            # (do NOT count accumulated time since process start)
            proc_delta=0
        else
            proc_delta=$((proc_now - proc_prev))
            [[ $proc_delta -lt 0 ]] && proc_delta=0
        fi

        proc_delta_total=$((proc_delta_total + proc_delta))
        pid_count=$((pid_count + 1))

        # Append to new cache
        new_pid_cache="${new_pid_cache}${pid}\t${proc_now}\n"

        if [[ $DEBUG_MODE -eq 1 ]]; then
            echo "  PID=$pid: prev=$proc_prev, now=$proc_now, delta=$proc_delta" >&2
        fi
    done

    # 5. Calculate system delta
    local total_delta=$((total_now - total_prev))
    if [[ $total_delta -le 0 ]]; then
        print_warn "System jiffies delta invalid (delta=$total_delta), recording 0% (Time: ${elapsed}s)"
        echo "$timestamp,$elapsed,0.00,0,0,InvalidDelta:$total_delta" >> "$CPU_LOG"
        # Still update cache for next iteration
        echo "$total_now" > "$PROCSTAT_TOTAL_PREV_FILE"
        printf "%b" "$new_pid_cache" > "$PROCSTAT_PID_PREV_FILE"
        # Update wall-clock to avoid cumulative delta
        echo "$timestamp" > "$PROCSTAT_WALL_PREV_FILE"
        return 0
    fi

    # 6. Check if this is the first sample (calibration sample)
    # If elapsed time is very short (< CPU_INTERVAL/2), treat as baseline
    # calibration
    local cpu_percent window_ms filter_reason
    if [[ $elapsed -lt $((CPU_INTERVAL / 2)) ]]; then
        # First sample: calibration only, output 0% to establish clean baseline
        cpu_percent="0.00"
        window_ms=0  # Force 0 for baseline (even if wall_delta > 0)
        filter_reason="Baseline"
        print_info "CPU Sample [${elapsed}s]: Baseline calibration (${pid_count} processes)"
    else
        # 7. Calculate CPU%: 100 * NCPU * (proc_delta / total_delta)
        # This makes "100% = 1 core fully utilized", matching dumpsys/top output
        cpu_percent=$(awk -v pd="$proc_delta_total" -v td="$total_delta" -v nc="$PROCSTAT_NCPU" \
            'BEGIN {printf "%.2f", 100.0 * nc * pd / td}')
        window_ms=$window_ms_real  # Use real wall-clock delta
        filter_reason="Valid"
    fi

    # 8. Calculate DMIPS
    local dmips
    dmips=$(awk -v cpu="$cpu_percent" -v base="$SINGLE_CORE_DMIPS" \
        'BEGIN {printf "%.0f", (cpu * base) / 100}')

    # 9. Save to CSV
    echo "$timestamp,$elapsed,$cpu_percent,$dmips,$window_ms,$filter_reason" >> "$CPU_LOG"

    if [[ $elapsed -lt $((CPU_INTERVAL / 2)) ]]; then
        # Calibration sample: no detailed output
        :
    else
        # Determine if sample will be excluded from stats
        local excluded_marker=""
        if [[ "$filter_reason" != "Valid" ]]; then
            excluded_marker=" [excluded from stats]"
        fi
        print_info "CPU Sample [${elapsed}s]: ${cpu_percent}% → ${dmips} DMIPS (window=${window_ms}ms, ${pid_count} processes, ${filter_reason})${excluded_marker}"
    fi

    # 10. Update cache files for next iteration
    echo "$total_now" > "$PROCSTAT_TOTAL_PREV_FILE"
    printf "%b" "$new_pid_cache" > "$PROCSTAT_PID_PREV_FILE"
    echo "$timestamp" > "$PROCSTAT_WALL_PREV_FILE"

    if [[ $DEBUG_MODE -eq 1 ]]; then
        echo "=== DEBUG: procstat (elapsed=${elapsed}s) ===" >&2
        echo "  total: prev=$total_prev, now=$total_now, delta=$total_delta" >&2
        echo "  proc: delta_total=$proc_delta_total, pid_count=$pid_count" >&2
        echo "  CPU%: 100 * $PROCSTAT_NCPU * $proc_delta_total / $total_delta = $cpu_percent%" >&2
        echo "========================================" >&2
    fi

    return 0
}

################################################################################
# Collect CPU Data - dumpsys Method (Sliding Window)
################################################################################
collect_cpu_dumpsys() {
    local timestamp elapsed
    timestamp=$(date +%s)
    elapsed=$1

    # Baseline sample: always excluded from statistics
    # - Still triggers dumpsys once to "prime" the tracker
    # - Record WindowMs=0 so report filter (>=5000ms) will exclude it
    if [[ "$elapsed" -eq 0 ]]; then
        adb_cmd shell dumpsys cpuinfo >/dev/null 2>&1 || true
        echo "$timestamp,$elapsed,0.00,0,0,Baseline" >> "$CPU_LOG"
        print_info "CPU Sample [0s]: Baseline (excluded from stats)"
        return 0
    fi

    # Get raw dumpsys cpuinfo output first
    local raw
    raw=$(adb_cmd shell dumpsys cpuinfo 2>/dev/null | tr -d '\r')

    # Parse window length from: "CPU usage from XXXms to YYYms ago"
    # This tells us the actual time range of this CPU sample
    # Note: Using POSIX-compatible awk (no match() with capture array,
    #       which gawk supports but macOS awk doesn't)
    local window_ms
    window_ms=$(echo "$raw" | awk '
    /^CPU usage from / {
        from_val=""; to_val=""
        for(i=1; i<=NF; i++) {
            if($i == "from") { from_val = $(i+1) }
            if($i == "to")   { to_val   = $(i+1) }
        }
        gsub(/ms/, "", from_val)
        gsub(/ms/, "", to_val)
        if(from_val != "" && to_val != "") {
            d = from_val - to_val
            if (d < 0) d = -d
            print d
            exit
        }
    }')
    [[ -z "$window_ms" ]] && window_ms="-1"

    # dumpsys cpuinfo lines are generally:
    #    12% 1234/com.xxx:proc or 12% 1234/com.xxx_zygote
    # Matching rule is consistent with get_all_pids: package name followed by :
    #    or _ or space/end of line
    local cpu_output
    cpu_output=$(echo "$raw" | awk -v pkg="/$PACKAGE_NAME" '
    {
        pos = index($0, pkg);
        if (pos == 0) next;

        after = substr($0, pos + length(pkg), 1);

        # accept: end-of-string / ":" / "_" / whitespace
        if (after == "" || after == ":" || after == "_" || after ~ /[[:space:]]/) {
            print;
        }
    }
    ')

    if [[ $DEBUG_MODE -eq 1 ]]; then
        echo "=== DEBUG: dumpsys cpuinfo head (elapsed=${elapsed}s) ===" >&2
        echo "$raw" | head -30 >&2
        echo "=== DEBUG: window_ms=$window_ms ===" >&2
        echo "=== DEBUG: matched lines ===" >&2
        echo "$cpu_output" >&2
        echo "================================" >&2
    fi

    if [ -z "$cpu_output" ]; then
        local filter_reason="NoActivity"
        [[ "$window_ms" == "-1" ]] && filter_reason="ParseFailed"
        echo "$timestamp,$elapsed,0.00,0,$window_ms,$filter_reason" >> "$CPU_LOG"
        print_warn "CPU Sample [${elapsed}s]: 0.00% → 0 DMIPS (window=${window_ms}ms, ${filter_reason}) [excluded from stats]"
        return 0
    fi

    local cpu_percent
    cpu_percent=$(echo "$cpu_output" | awk '{
        gsub(/[+%-]/, "", $1);
        if ($1 ~ /^[0-9]+(\.[0-9]+)?$/) sum += $1;
    } END { if (sum=="") sum=0; printf "%.2f", sum; }')

    [[ -z "$cpu_percent" ]] && cpu_percent="0.00"

    local dmips
    # Use awk for calculation if bc fails (MinGW compatibility)
    dmips=$(echo "scale=2; ($cpu_percent * $SINGLE_CORE_DMIPS) / 100" | bc 2>/dev/null)
    if [[ -z "$dmips" ]] || [[ "$dmips" == "0" ]] && [[ "$cpu_percent" != "0.00" ]]; then
        dmips=$(awk -v cpu="$cpu_percent" -v base="$SINGLE_CORE_DMIPS" 'BEGIN {printf "%.0f", (cpu * base) / 100}')
    elif [ -n "$dmips" ]; then
        dmips=$(printf "%.0f" "$dmips" 2>/dev/null)
    fi
    [[ -z "$dmips" ]] && dmips="0"

    # Determine filter reason
    local filter_reason="Valid"
    if [[ "$window_ms" == "-1" ]]; then
        filter_reason="WindowUnknown"
    elif [[ "$window_ms" -lt 5000 ]]; then
        filter_reason="WindowTooShort"
    elif [[ "$window_ms" -gt 30000 ]]; then
        filter_reason="WindowTooLong"
    fi

    echo "$timestamp,$elapsed,$cpu_percent,$dmips,$window_ms,$filter_reason" >> "$CPU_LOG"

    # Determine if sample will be excluded from stats
    local excluded_marker=""
    if [[ "$filter_reason" != "Valid" ]] && ! ([[ $STRICT_WINDOW -eq 0 ]] && [[ "$filter_reason" == "WindowUnknown" ]]); then
        excluded_marker=" [excluded from stats]"
    fi
    print_info "CPU Sample [${elapsed}s]: ${cpu_percent}% → ${dmips} DMIPS (window=${window_ms}ms, ${filter_reason})${excluded_marker}"
    return 0
}

################################################################################
# Collect CPU Data - Routing Function (Select method based on CPU_METHOD)
################################################################################
collect_cpu() {
    if [[ "$CPU_METHOD" == "procstat" ]]; then
        collect_cpu_procstat "$@"
    elif [[ "$CPU_METHOD" == "dumpsys" ]]; then
        collect_cpu_dumpsys "$@"
    else
        print_error "Unknown CPU_METHOD: $CPU_METHOD (use 'dumpsys' or 'procstat')"
        exit 1
    fi
}

################################################################################
# Collect Memory Data
#  (Forced PID-by-PID Aggregation: Ensures Inclusion of : Subprocesses)
################################################################################
collect_memory() {
    local timestamp elapsed
    timestamp=$(date +%s)
    elapsed=$1

    local TOTAL_PSS_KB=0
    local TOTAL_RSS_KB=0
    local proc_count=0

    local pids
    pids=$(get_all_pids)

    if [[ -z "$pids" ]]; then
        print_warn "Unable to obtain process PID (Time: ${elapsed}s）"
        return 1
    fi

    if [[ $DEBUG_MODE -eq 1 ]]; then
        echo "=== DEBUG: memory PIDs (elapsed=${elapsed}s) ===" >&2
        echo "$pids" >&2
        echo "============================================" >&2
    fi

    # Use for loop instead of while read (to avoid adb shell consuming stdin
    # causing premature loop termination)
    for PID in $pids; do
        PID=$(echo "$PID" | tr -d ' \r\n')
        [[ -z "$PID" ]] && continue

        if [[ $DEBUG_MODE -eq 1 ]]; then
            echo "  → Processing PID=$PID ..." >&2
        fi

        # Get dumpsys meminfo output
        local meminfo_output
        meminfo_output=$(adb_cmd shell dumpsys meminfo "$PID" 2>/dev/null | tr -d '\r')

        if [[ -z "$meminfo_output" ]]; then
            if [[ $DEBUG_MODE -eq 1 ]]; then
                echo "    ✗ Unable to obtain dumpsys meminfo output" >&2
            fi
            continue
        fi

        # Independently parse PSS (highest priority, must not be missed)
        local PSS
        # Try multiple patterns for better compatibility
        PSS=$(echo "$meminfo_output" | grep -i "TOTAL PSS:" | head -1 | awk '{
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+$/) {
                    prev = (i > 1) ? $(i-1) : ""
                    if (prev ~ /PSS:?$/ || prev == "PSS" || prev == "PSS:") { print $i; exit }
                }
            }
        }')
        # Fallback: try to find first number after "TOTAL PSS"
        if [[ -z "$PSS" ]] || ! [[ "$PSS" =~ ^[0-9]+$ ]]; then
            PSS=$(echo "$meminfo_output" | grep -i "TOTAL PSS" | head -1 | grep -oE '[0-9]{3,}' | head -1)
        fi

        # Independently parse RSS
        # (optional, missing RSS does not affect PSS statistics)
        local RSS
        # Try multiple patterns for better compatibility
        RSS=$(echo "$meminfo_output" | grep -i "TOTAL RSS:" | head -1 | awk '{
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+$/) {
                    prev = (i > 1) ? $(i-1) : ""
                    if (prev ~ /RSS:?$/ || prev == "RSS" || prev == "RSS:") { print $i; exit }
                }
            }
        }')
        # Fallback: try to find first number after "TOTAL RSS"
        if [[ -z "$RSS" ]] || ! [[ "$RSS" =~ ^[0-9]+$ ]]; then
            RSS=$(echo "$meminfo_output" | grep -i "TOTAL RSS" | head -1 | grep -oE '[0-9]{3,}' | head -1)
        fi

        if [[ $DEBUG_MODE -eq 1 ]]; then
            echo "    Parsed: PSS=$PSS KB, RSS=$RSS KB" >&2
        fi

        # PSS is mandatory, skip this PID if missing
        if [[ "$PSS" =~ ^[0-9]+$ ]] && [[ $PSS -gt 0 ]]; then
            TOTAL_PSS_KB=$((TOTAL_PSS_KB + PSS))

            # RSS optional, record 0 if missing
            if [[ "$RSS" =~ ^[0-9]+$ ]] && [[ $RSS -gt 0 ]]; then
                TOTAL_RSS_KB=$((TOTAL_RSS_KB + RSS))
            fi

            proc_count=$((proc_count + 1))

            if [[ $DEBUG_MODE -eq 1 ]]; then
                echo "    ✓ Included (Current Total: PSS=${TOTAL_PSS_KB} KB, RSS=${TOTAL_RSS_KB} KB, count=${proc_count}）" >&2
            fi
        else
            if [[ $DEBUG_MODE -eq 1 ]]; then
                echo "    ✗ PSS validation failed (PSS=$PSS）" >&2
                echo "    TOTAL PSS line:" >&2
                echo "$meminfo_output" | grep -i "TOTAL PSS:" | head -1 >&2
            fi
        fi
    done

    if [[ $TOTAL_PSS_KB -eq 0 ]]; then
        print_warn "Memory data extraction failed (Time: ${elapsed}s）"
        return 1
    fi

    local pss_mb rss_mb
    # Use awk fallback if bc fails (MinGW compatibility)
    pss_mb=$(echo "scale=2; $TOTAL_PSS_KB / 1024" | bc 2>/dev/null)
    if [[ -z "$pss_mb" ]]; then
        pss_mb=$(awk -v kb="$TOTAL_PSS_KB" 'BEGIN {printf "%.2f", kb / 1024}')
    fi

    rss_mb=$(echo "scale=2; $TOTAL_RSS_KB / 1024" | bc 2>/dev/null)
    if [[ -z "$rss_mb" ]]; then
        rss_mb=$(awk -v kb="$TOTAL_RSS_KB" 'BEGIN {printf "%.2f", kb / 1024}')
    fi

    echo "$timestamp,$elapsed,$TOTAL_RSS_KB,$rss_mb,$TOTAL_PSS_KB,$pss_mb" >> "$MEM_LOG"
    print_info "Memory Sample [${elapsed}s]: PSS=${pss_mb} MB, RSS=${rss_mb} MB (pid-by-pid, ${proc_count} processes)"
    return 0
}

################################################################################
# Main Test Loop
################################################################################
run_test() {
    print_info "Test started, total duration: ${TEST_DURATION} seconds (${TEST_DURATION_MINUTES} minutes)"
    print_warn "Please ensure the application is playing a video!"
    sleep 3

    # Initialize CPU collection method
    if [[ "$CPU_METHOD" == "procstat" ]]; then
        # procstat: Initialize baseline (no warm-up needed, uses precise delta)
        procstat_init
        print_info "procstat initialized, starting data collection..."
    elif [[ "$CPU_METHOD" == "dumpsys" ]]; then
        # dumpsys: No explicit warm-up needed
        # (baseline sample will prime the tracker)
        print_info "CPU Method: dumpsys cpuinfo (sliding window, baseline will prime tracker)"
    else
        print_error "Unknown CPU_METHOD: $CPU_METHOD"
        exit 1
    fi

    local start_time last_cpu_time last_mem_time last_alive_check
    start_time=$(date +%s)
    last_cpu_time=$start_time
    last_mem_time=$start_time
    last_alive_check=$start_time

    print_info "Starting first sample..."
    collect_cpu 0
    collect_memory 0

    # Update last sample times to avoid baseline execution time affecting next
    # interval
    last_cpu_time=$(date +%s)
    last_mem_time=$(date +%s)

    while true; do
        local current_time elapsed
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        if [ $elapsed -ge $TEST_DURATION ]; then
            print_info "Test completed!"
            break
        fi

        if [ $((current_time - last_alive_check)) -ge 10 ]; then
            check_app_alive
            last_alive_check=$current_time
        fi

        if [ $((current_time - last_cpu_time)) -ge $CPU_INTERVAL ]; then
            collect_cpu "$elapsed"
            last_cpu_time=$current_time
        fi

        if [ $((current_time - last_mem_time)) -ge $MEM_INTERVAL ]; then
            collect_memory "$elapsed"
            last_mem_time=$current_time
        fi

        sleep 1
    done
}

################################################################################
# Analyze Data and Generate Report
################################################################################
generate_report() {
    print_info "Analyzing data and generating report..."

    local cpu_samples
    cpu_samples=$(tail -n +2 "$CPU_LOG" 2>/dev/null | wc -l | tr -d ' ')
    if [ -z "$cpu_samples" ] || [ "$cpu_samples" -eq 0 ]; then
        print_error "No valid CPU data, unable to generate report"
        exit 1
    fi

    # CPU statistics: Filter samples based on window validity
    # Window range depends on CPU_METHOD:
    #   - dumpsys: 5000ms-30000ms (sliding window variability)
    #   - procstat: >0 (fixed window=CPU_INTERVAL*1000, baseline has window=0)
    # STRICT_WINDOW:
    #   0 => allow WindowMs=-1 samples (parse failed, include with caution)
    #   1 => exclude WindowMs=-1 samples
    local avg_cpu peak_cpu avg_dmips peak_dmips min_cpu min_dmips
    local valid_cpu_samples invalid_cpu_samples unknown_window_samples

    unknown_window_samples=$(tail -n +2 "$CPU_LOG" | awk -F',' '$5==-1{c++} END{print c+0}')

    # Define filter condition based on CPU_METHOD
    local window_filter
    if [[ "$CPU_METHOD" == "procstat" ]]; then
        window_filter='$5 > 0'  # procstat: exclude baseline (window=0)
    else
        window_filter='($5>=5000 && $5<=30000)'  # dumpsys: sliding window range
    fi

    # Unified filter condition: window_filter OR (STRICT_WINDOW==0 and window==-1), AND CPU% >= MIN_CPU_PERCENT
    valid_cpu_samples=$(tail -n +2 "$CPU_LOG" | awk -F',' -v min_cpu="$MIN_CPU_PERCENT" -v strict="$STRICT_WINDOW" -v method="$CPU_METHOD" '
        function check_window() {
            if (method == "procstat") return $5 > 0
            else return ($5>=5000 && $5<=30000)
        }
        ( check_window() || (strict==0 && $5==-1) ) && ($3>=min_cpu) && ( $6=="Valid" || (strict==0 && $6=="WindowUnknown") ) {c++}
        END{print c+0}
    ')
    invalid_cpu_samples=$(tail -n +2 "$CPU_LOG" | awk -F',' -v min_cpu="$MIN_CPU_PERCENT" -v strict="$STRICT_WINDOW" -v method="$CPU_METHOD" '
        function check_window() {
            if (method == "procstat") return $5 > 0
            else return ($5>=5000 && $5<=30000)
        }
        !( ( check_window() || (strict==0 && $5==-1) ) && ($3>=min_cpu) && ( $6=="Valid" || (strict==0 && $6=="WindowUnknown") ) ) {c++}
        END{print c+0}
    ')

    avg_cpu=$(tail -n +2 "$CPU_LOG" | awk -F',' -v min_cpu="$MIN_CPU_PERCENT" -v strict="$STRICT_WINDOW" -v method="$CPU_METHOD" '
        function check_window() {
            if (method == "procstat") return $5 > 0
            else return ($5>=5000 && $5<=30000)
        }
        ( check_window() || (strict==0 && $5==-1) ) && ($3>=min_cpu) && ( $6=="Valid" || (strict==0 && $6=="WindowUnknown") ) {sum+=$3; c++}
        END{if(c>0) printf "%.2f", sum/c; else print "0"}
    ')
    avg_dmips=$(tail -n +2 "$CPU_LOG" | awk -F',' -v min_cpu="$MIN_CPU_PERCENT" -v strict="$STRICT_WINDOW" -v method="$CPU_METHOD" '
        function check_window() {
            if (method == "procstat") return $5 > 0
            else return ($5>=5000 && $5<=30000)
        }
        ( check_window() || (strict==0 && $5==-1) ) && ($3>=min_cpu) && ( $6=="Valid" || (strict==0 && $6=="WindowUnknown") ) {sum+=$4; c++}
        END{if(c>0) printf "%.0f", sum/c; else print "0"}
    ')

    peak_cpu=$(tail -n +2 "$CPU_LOG" | awk -F',' -v min_cpu="$MIN_CPU_PERCENT" -v strict="$STRICT_WINDOW" -v method="$CPU_METHOD" '
        function check_window() {
            if (method == "procstat") return $5 > 0
            else return ($5>=5000 && $5<=30000)
        }
        ( check_window() || (strict==0 && $5==-1) ) && ($3>=min_cpu) && ( $6=="Valid" || (strict==0 && $6=="WindowUnknown") ) {
            if(m=="" || $3+0>m+0) m=$3
        }
        END{if(m!="") printf "%.2f", m; else print "0"}
    ')
    peak_dmips=$(tail -n +2 "$CPU_LOG" | awk -F',' -v min_cpu="$MIN_CPU_PERCENT" -v strict="$STRICT_WINDOW" -v method="$CPU_METHOD" '
        function check_window() {
            if (method == "procstat") return $5 > 0
            else return ($5>=5000 && $5<=30000)
        }
        ( check_window() || (strict==0 && $5==-1) ) && ($3>=min_cpu) && ( $6=="Valid" || (strict==0 && $6=="WindowUnknown") ) {
            if(m=="" || $4+0>m+0) m=$4
        }
        END{if(m!="") printf "%.0f", m; else print "0"}
    ')

    min_cpu=$(tail -n +2 "$CPU_LOG" | awk -F',' -v min_cpu="$MIN_CPU_PERCENT" -v strict="$STRICT_WINDOW" -v method="$CPU_METHOD" '
        function check_window() {
            if (method == "procstat") return $5 > 0
            else return ($5>=5000 && $5<=30000)
        }
        ( check_window() || (strict==0 && $5==-1) ) && ($3>=min_cpu) && ( $6=="Valid" || (strict==0 && $6=="WindowUnknown") ) {
            if(m=="" || $3+0<m+0) m=$3
        }
        END{if(m!="") printf "%.2f", m; else print "0"}
    ')
    min_dmips=$(tail -n +2 "$CPU_LOG" | awk -F',' -v min_cpu="$MIN_CPU_PERCENT" -v strict="$STRICT_WINDOW" -v method="$CPU_METHOD" '
        function check_window() {
            if (method == "procstat") return $5 > 0
            else return ($5>=5000 && $5<=30000)
        }
        ( check_window() || (strict==0 && $5==-1) ) && ($3>=min_cpu) && ( $6=="Valid" || (strict==0 && $6=="WindowUnknown") ) {
            if(m=="" || $4+0<m+0) m=$4
        }
        END{if(m!="") printf "%.0f", m; else print "0"}
    ')

    # Collect FilterReason statistics
    local filter_reason_stats
    filter_reason_stats=$(tail -n +2 "$CPU_LOG" | awk -F',' '
    {
        reason = ($6 != "") ? $6 : "Unknown"
        count[reason]++
        total++
    }
    END {
        for (r in count) {
            print r ": " count[r]
        }
    }' | sort)

    local mem_samples
    mem_samples=$(tail -n +2 "$MEM_LOG" 2>/dev/null | wc -l | tr -d ' ')
    if [ -z "$mem_samples" ] || [ "$mem_samples" -eq 0 ]; then
        print_error "No valid memory data, unable to generate report"
        exit 1
    fi

    local max_mem min_mem avg_mem
    max_mem=$(tail -n +2 "$MEM_LOG" | awk -F',' 'NR==1{m=$6} {if($6+0>m+0) m=$6} END{printf "%.2f", m}')
    min_mem=$(tail -n +2 "$MEM_LOG" | awk -F',' 'NR==1{m=$6} {if($6+0<m+0) m=$6} END{printf "%.2f", m}')
    avg_mem=$(tail -n +2 "$MEM_LOG" | awk -F',' '{sum+=$6; c++} END{if(c>0) printf "%.2f", sum/c; else print "0"}')

    local max_rss min_rss avg_rss
    max_rss=$(tail -n +2 "$MEM_LOG" | awk -F',' 'NR==1{m=$4} {if($4+0>m+0) m=$4} END{printf "%.2f", m}')
    min_rss=$(tail -n +2 "$MEM_LOG" | awk -F',' 'NR==1{m=$4} {if($4+0<m+0) m=$4} END{printf "%.2f", m}')
    avg_rss=$(tail -n +2 "$MEM_LOG" | awk -F',' '{sum+=$4; c++} END{if(c>0) printf "%.2f", sum/c; else print "0"}')

    # Memory leak detection: Linear regression (based on PSS)
    local first_mem last_mem mem_increase mem_increase_display
    first_mem=$(tail -n +2 "$MEM_LOG" | head -1 | awk -F',' '{print $6}')
    last_mem=$(tail -n +2 "$MEM_LOG" | tail -1 | awk -F',' '{print $6}')
    mem_increase_display="Increase 0.00%"
    mem_increase="0"

    # First validate data format, then calculate increment
    if [[ "$first_mem" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$last_mem" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        mem_increase=$(echo "$last_mem - $first_mem" | bc 2>/dev/null)
        [[ -z "$mem_increase" ]] && mem_increase="0"
    fi

    local mem_slope
    mem_slope=$(tail -n +2 "$MEM_LOG" | awk -F',' '
    {
        n++
        x=$2; y=$6
        sx+=x; sy+=y; sxy+=x*y; sxx+=x*x
    }
    END{
        if(n<3){print "N/A"; exit}
        d=n*sxx - sx*sx
        if(d==0){print "0"; exit}
        s=(n*sxy - sx*sy)/d
        printf "%.6f", s
    }')

    # Head-to-Tail Percentage (for display)
    if [[ "$first_mem" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$last_mem" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        local ok
        ok=$(echo "$first_mem > 0" | bc 2>/dev/null | tr -d '\r\n')
        if [[ "$ok" == "1" ]]; then
            local pct
            pct=$(echo "scale=2; ($mem_increase / $first_mem) * 100" | bc 2>/dev/null)
            if [[ -n "$pct" ]]; then
                mem_increase_display="Increase ${pct}%"
            else
                mem_increase_display="N/A（Calculation failed）"
            fi
        else
            mem_increase_display="N/A（Insufficient data）"
        fi
    else
        mem_increase_display="N/A（Insufficient data）"
    fi

    local mem_leak
    mem_leak="No"
    if [[ "$mem_slope" == "N/A" ]]; then
        mem_leak="Unable to determine (Insufficient data)"
    elif [[ "$mem_slope" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        local is_high is_low
        # 0.005MB/s ≈ 300MB/h
        is_high=$(echo "$mem_slope > 0.005" | bc 2>/dev/null | tr -d '\r\n')
        is_low=$(echo "$mem_slope < -0.001" | bc 2>/dev/null | tr -d '\r\n')
        if [[ "$is_high" == "1" ]]; then
            local inc
            inc=$(echo "scale=2; $mem_slope * $TEST_DURATION" | bc 2>/dev/null)
            mem_leak="Possible (Growth rate ${mem_slope} MB/second, Estimated ${TEST_DURATION_MINUTES} minutes growth ${inc} MB)"
        elif [[ "$is_low" == "1" ]]; then
            mem_leak="No (Memory trending down, slope ${mem_slope} MB/second)"
        else
            mem_leak="No (Memory stable, slope ${mem_slope} MB/second, Head-to-Tail ${mem_increase_display})"
        fi
    else
        mem_leak="No (Memory stable, Head-to-Tail ${mem_increase_display})"
    fi

    local actual_duration actual_minutes test_status
    actual_duration=$(tail -n +2 "$CPU_LOG" 2>/dev/null | tail -1 | awk -F',' '{print $2}')
    actual_minutes="N/A"
    test_status="Normally Completed"

    if [[ -n "$actual_duration" ]] && [[ "$actual_duration" =~ ^[0-9]+$ ]]; then
        actual_minutes=$(echo "scale=1; $actual_duration / 60" | bc 2>/dev/null)
    else
        actual_duration="N/A"
    fi

    [[ $TEST_INTERRUPTED -eq 1 ]] && test_status="User Interrupted (Ctrl+C)"

    # Determine CPU method description
    local cpu_method_desc
    if [[ "$CPU_METHOD" == "procstat" ]]; then
        cpu_method_desc="/proc/stat (real wall-clock window, ~${CPU_INTERVAL}s)"
    elif [[ "$CPU_METHOD" == "dumpsys" ]]; then
        cpu_method_desc="dumpsys cpuinfo (sliding window)"
    else
        cpu_method_desc="$CPU_METHOD"
    fi

    cat > "$REPORT_FILE" << EOF
# Performance Test Report (Multi-Process Statistics)

## Test Information

- **Test ID**: \`$TEST_START_TIME\`
- **Application Package Name**: \`$PACKAGE_NAME\`
- **Process Matching Rule**: \`^${PACKAGE_NAME}(:|_|$)\`（Includes :service and _zygote subprocesses）
- **CPU Collection Method**: ${cpu_method_desc}
- **Test Scenario**: Video Playback
- **Planned Duration**: $TEST_DURATION_MINUTES minutes
- **Actual Duration**: ${actual_minutes} minutes (${actual_duration} seconds)
- **Test Status**: ${test_status}
- **Test Start Time**: $(echo "$TEST_START_TIME" | sed -E 's/_/ /; s/([0-9]{4})([0-9]{2})([0-9]{2}) ([0-9]{2})([0-9]{2})([0-9]{2})/\1-\2-\3 \4:\5:\6/')
- **Test Completion Time**: $(date '+%Y-%m-%d %H:%M:%S')

---

## Test Results

### 📊 CPU Performance (Same-Package Multi-Process Aggregate)

| Metric | Measured Value |
|------|--------|
| Average CPU | ${avg_cpu}% (${avg_dmips} DMIPS) |
| Peak CPU | ${peak_cpu}% (${peak_dmips} DMIPS) |
| Minimum CPU | ${min_cpu}% (${min_dmips} DMIPS) |

- **CPU Sampling Count**: $cpu_samples total, $valid_cpu_samples valid, $invalid_cpu_samples filtered, $unknown_window_samples WindowMs=-1 (every ${CPU_INTERVAL} seconds)
- **CPU Method**: ${cpu_method_desc}
- **Sample Status Breakdown**:
$(echo "$filter_reason_stats" | sed 's/^/  - /')
- **STRICT_WINDOW**: ${STRICT_WINDOW} (0=allow WindowMs=-1, 1=exclude WindowMs=-1)
- **Filtering Criteria**:
  - Valid window range: 5000ms - 30000ms (for dumpsys sliding window) or >0ms (for procstat real wall-clock delta)
  - Minimum CPU threshold: >= ${MIN_CPU_PERCENT}% (configurable via MIN_CPU_PERCENT parameter)
- **Description**:
  - CPU% is the sum of CPU occupancy ratios of all matched same-package processes within the sampling window (may be > 100% on multi-core devices)
  - DMIPS is a custom conversion scale for horizontal comparison, not the actual hardware DMIPS measurement value

### 💾 Memory Performance (Forced PID-by-PID Aggregate, Includes : Subprocesses)

#### PSS (Actual Memory Usage, Proportionally Shared Memory)

| Metric | Measured Value |
|------|--------|
| Max PSS | ${max_mem} MB |
| Average PSS | ${avg_mem} MB |
| Min PSS | ${min_mem} MB |

#### RSS (Physical Memory Usage, Includes Shared Memory)

| Metric | Measured Value |
|------|--------|
| Max RSS | ${max_rss} MB |
| Average RSS | ${avg_rss} MB |
| Min RSS | ${min_rss} MB |

#### Memory Leak Detection (Based on PSS Linear Regression)

- **Detection Result**: ${mem_leak}
- **Memory Sampling Count**: $mem_samples times (every ${MEM_INTERVAL} seconds)
- **PSS Change**: From ${first_mem} MB to ${last_mem} MB（${mem_increase_display}）
- **Threshold**: 0.005 MB/second (≈ 300 MB/hour)

---

## Detailed Data

- **Test Result Directory**: \`$TEST_DIR\`
- **CPU Data Log**: \`cpu_log.csv\`
- **Memory Data Log**: \`mem_log.csv\`

---

**Test Completion Time**: $(date '+%Y-%m-%d %H:%M:%S')
EOF

    print_info "Report generated: $REPORT_FILE"

    echo ""
    echo "=========================================="
    echo "        Test Result Summary"
    echo "=========================================="
    echo ""
    echo "📊 CPU Performance (Multi-Process Total)"
    echo "  Average: ${avg_cpu}% (${avg_dmips} DMIPS)"
    echo "  Peak:    ${peak_cpu}% (${peak_dmips} DMIPS)"
    echo "  Minimum: ${min_cpu}% (${min_dmips} DMIPS)"
    echo "  Samples: ${valid_cpu_samples} valid / ${cpu_samples} total (${invalid_cpu_samples} filtered, ${unknown_window_samples} unknown-window)"
    echo ""
    echo "💾 Memory Performance (PSS - Real Usage)"
    echo "  Average: ${avg_mem} MB"
    echo "  Maximum: ${max_mem} MB"
    echo "  Minimum: ${min_mem} MB"
    echo ""
    echo "💾 Memory Performance (RSS - Including Shared)"
    echo "  Average: ${avg_rss} MB"
    echo "  Maximum: ${max_rss} MB"
    echo "  Minimum: ${min_rss} MB"
    echo ""
    echo "🔍 Memory Leak Detection"
    echo "  ${mem_leak}"
    echo ""
    echo "=========================================="
    echo ""
}

################################################################################
# Main Function
################################################################################
main() {
    trap 'handle_interrupt' INT TERM

    echo ""
    echo "=========================================="
    echo "   Performance Test Script v3.0"
    echo "   (Multi-process + Dual CPU Engine)"
    echo "=========================================="
    echo ""

    check_dependencies
    check_adb_connection
    check_app_running
    create_test_directory
    init_logs
    run_test
    generate_report

    print_info "Test completed! Please check the report: $REPORT_FILE"
    echo ""
    echo "=========================================="
    echo "   Test Results Saved To Directory："
    echo "   📁 $TEST_DIR"
    echo ""
    echo "   Test ID: $TEST_START_TIME"
    echo ""
    echo "   Included Files："
    echo "   - CPU Data: $CPU_LOG"
    echo "   - Memory Data: $MEM_LOG"
    echo "   - Test Report: $REPORT_FILE"
    echo "=========================================="
    echo ""
}

main
