#!/bin/bash

################################################################################
# Performance Test Script (Multi-Process Accurate Statistics Version)
# Purpose: Test the CPU and memory performance of a specified application during video playback (including subprocesses like sandboxed/privileged, etc.)
# Platform: macOS, Linux
# Requirements: adb tool, bc tool installed
# created by hua.liu
################################################################################

################################################################################
# Configuration Parameters - Adjust as needed
################################################################################

# Application package name (main process name)
PACKAGE_NAME="com.xxx.yyy"

# ADB device serial number (optional) - Specify the target device when multiple devices are connected
# Leave blank to automatically select the first online device; you can also manually specify, e.g., ADB_SERIAL="emulator-5554"
ADB_SERIAL=""

# Test duration (minutes)
TEST_DURATION_MINUTES=5

# Sampling interval (seconds)
CPU_INTERVAL=10
MEM_INTERVAL=10

# Performance benchmark (custom scale)
SINGLE_CORE_DMIPS=20599  # Single-core 100% CPU ≈ 20K DMIPS (approximate comparison)

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
# Get All Related Process PIDs for the Package Name (Including : and _ Subprocesses)
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

    # Pass package name to awk without escaping - let awk handle it as plain text
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

        # If PID column not found, dynamically identify (compatible with ps output without header)
        if (found_pid_col == 0 && NF > 2) {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+$/ && i <= 3) { pid_col = i; break; }
            }
            found_pid_col = 1
        }

        name = $NF
        # Match: Package name, Package name:xxx, Package name_xxx (e.g., _zygote)
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

    # Multiple devices: If serial not specified, automatically select the first online device
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
# Check Application Running Status (Any process with the same package is considered running)
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
    # Check if there are any matching package processes (allowing dynamic process changes)
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

    if ! echo "Timestamp,Time(Seconds),CPU Percentage(%),DMIPS" > "$CPU_LOG" 2>/dev/null; then
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
# Collect CPU Data (Aggregate Same-Package Multi-Process)
################################################################################
collect_cpu() {
    local timestamp elapsed
    timestamp=$(date +%s)
    elapsed=$1

    # dumpsys cpuinfo lines are generally:  12% 1234/com.xxx:proc or 12% 1234/com.xxx_zygote
    # Matching rule is consistent with get_all_pids: package name followed by : or _ or space/end of line
    local cpu_output
    # Use simple grep with fixed string, then filter with awk
    cpu_output=$(adb_cmd shell dumpsys cpuinfo 2>/dev/null | grep -F "/$PACKAGE_NAME" | awk -v pkg="$PACKAGE_NAME" '
        $0 ~ ("/" pkg "(:|_|[[:space:]]|$)") { print }
    ')

    if [[ $DEBUG_MODE -eq 1 ]]; then
        echo "=== DEBUG: dumpsys cpuinfo head (elapsed=${elapsed}s) ===" >&2
        adb_cmd shell dumpsys cpuinfo 2>&1 | head -30 >&2
        echo "=== DEBUG: matched lines ===" >&2
        echo "$cpu_output" >&2
        echo "================================" >&2
    fi

    if [ -z "$cpu_output" ]; then
        print_warn "Unable to obtain CPU data (Time: ${elapsed}s）- Possible reasons: No activity within the sampling window"
        echo "$timestamp,$elapsed,0.00,0" >> "$CPU_LOG"
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

    echo "$timestamp,$elapsed,$cpu_percent,$dmips" >> "$CPU_LOG"
    print_info "CPU Sample [${elapsed}s]: ${cpu_percent}% → ${dmips} DMIPS"
    return 0
}

################################################################################
# Collect Memory Data (Forced PID-by-PID Aggregation: Ensures Inclusion of : Subprocesses)
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

    # Use for loop instead of while read (to avoid adb shell consuming stdin causing premature loop termination)
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

        # Independently parse RSS (optional, missing RSS does not affect PSS statistics)
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

    local start_time last_cpu_time last_mem_time last_alive_check
    start_time=$(date +%s)
    last_cpu_time=$start_time
    last_mem_time=$start_time
    last_alive_check=$start_time

    print_info "Starting first sample..."
    collect_cpu 0
    collect_memory 0

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

    local avg_cpu peak_cpu avg_dmips peak_dmips min_cpu min_dmips
    avg_cpu=$(tail -n +2 "$CPU_LOG" | awk -F',' '{sum+=$3; c++} END{if(c>0) printf "%.2f", sum/c; else print "0"}')
    peak_cpu=$(tail -n +2 "$CPU_LOG" | awk -F',' 'NR==1{m=$3} {if($3+0>m+0) m=$3} END{printf "%.2f", m}')
    min_cpu=$(tail -n +2 "$CPU_LOG" | awk -F',' 'NR==1{m=$3} {if($3+0<m+0 || m==0) m=$3} END{printf "%.2f", m}')
    avg_dmips=$(tail -n +2 "$CPU_LOG" | awk -F',' '{sum+=$4; c++} END{if(c>0) printf "%.0f", sum/c; else print "0"}')
    peak_dmips=$(tail -n +2 "$CPU_LOG" | awk -F',' 'NR==1{m=$4} {if($4+0>m+0) m=$4} END{printf "%.0f", m}')
    min_dmips=$(tail -n +2 "$CPU_LOG" | awk -F',' 'NR==1{m=$4} {if($4+0<m+0 || m==0) m=$4} END{printf "%.0f", m}')

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
        is_high=$(echo "$mem_slope > 0.005" | bc 2>/dev/null | tr -d '\r\n')   # 0.005MB/s ≈ 300MB/h
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

    cat > "$REPORT_FILE" << EOF
# Performance Test Report (Multi-Process Statistics)

## Test Information

- **Test ID**: \`$TEST_START_TIME\`
- **Application Package Name**: \`$PACKAGE_NAME\`
- **Process Matching Rule**: \`^${PACKAGE_NAME}(:|_|$)\`（Includes :service and _zygote subprocesses）
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

- **CPU Sampling Count**: $cpu_samples times (every ${CPU_INTERVAL} seconds)
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
    echo "   Performance Test Script v2.1 (multi-process)"
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
