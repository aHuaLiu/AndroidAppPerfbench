#!/bin/bash

################################################################################
# HTML Report Generator (React + Chart.js + Tabulator, CDN)
# Purpose: Render cpu_log.csv + mem_log.csv into an interactive report.html
# Platform: macOS, Linux
# Requirements: awk, sed, tr (same baseline as main script)
#
# Inputs (environment variables):
#   TEST_DIR (required)
#   CPU_LOG (optional, default: $TEST_DIR/cpu_log.csv)
#   MEM_LOG (optional, default: $TEST_DIR/mem_log.csv)
#   REPORT_HTML_FILE (optional, default: $TEST_DIR/report.html)
#
#   Metadata (optional, for header display):
#   TEST_START_TIME, PACKAGE_NAME, CPU_METHOD, CPU_INTERVAL, MEM_INTERVAL,
#   TEST_DURATION_MINUTES, actual_duration, actual_minutes, test_status
#
#   Thresholds (optional):
#   MIN_CPU_PERCENT, STRICT_WINDOW, DUMPSYS_WINDOW_MIN_MS, DUMPSYS_WINDOW_MAX_MS,
#   MEM_LEAK_THRESHOLD_MBS, MEM_DECLINE_THRESHOLD_MBS, SINGLE_CORE_DMIPS
#
#   Precomputed summary (optional):
#   avg_cpu, peak_cpu, min_cpu, avg_dmips, peak_dmips, min_dmips
#   avg_mem, max_mem, min_mem, avg_rss, max_rss, min_rss
#   mem_leak
#   cpu_samples, valid_cpu_samples, invalid_cpu_samples, unknown_window_samples, mem_samples
################################################################################

set -u

warn() {
    echo "[WARN] $1" >&2
}

info() {
    echo "[INFO] $1" >&2
}

usage() {
    cat >&2 <<'EOF'
Usage:
  tools/report_html.sh --test-dir <test_dir> [--cpu-log <path>] [--mem-log <path>] [--out <path>]

Notes:
  - If --cpu-log/--mem-log are not provided, defaults to <test_dir>/cpu_log.csv and <test_dir>/mem_log.csv
  - If --out is not provided, defaults to <test_dir>/report.html
  - Environment variables are still supported (used by android_app_perfbench.sh), but not required for manual use.
EOF
}

escape_json() {
    # Escape JSON string content (minimal set for our data)
    # Args: $1 = raw string
    echo "$1" | awk '
    {
        s = $0
        gsub(/\\/, "\\\\", s)
        gsub(/\"/, "\\\"", s)
        gsub(/\r/, "", s)
        gsub(/\t/, "\\t", s)
        gsub(/\n/, "\\n", s)
        print s
    }'
}

read_meta_from_report_md() {
    # Best-effort metadata extraction from report.md (if exists)
    # Outputs: sets TEST_START_TIME, PACKAGE_NAME, CPU_METHOD, TEST_DURATION_MINUTES, actual_duration, actual_minutes, test_status
    local test_dir="$1"
    local md_file="${test_dir}/report.md"
    [[ ! -f "$md_file" ]] && return 0

    if [[ -z "${TEST_START_TIME:-}" ]]; then
        TEST_START_TIME=$(awk -F'`' '/\*\*Test ID\*\*/ {print $2; exit}' "$md_file" 2>/dev/null)
    fi
    if [[ -z "${PACKAGE_NAME:-}" ]]; then
        PACKAGE_NAME=$(awk -F'`' '/\*\*Application Package Name\*\*/ {print $2; exit}' "$md_file" 2>/dev/null)
    fi
    if [[ -z "${CPU_METHOD:-}" ]]; then
        # The markdown line contains human-readable description.
        # Detect method by keyword.
        CPU_METHOD=$(awk '
            /\*\*CPU Collection Method\*\*/ {
                line=$0
                if (line ~ /\/proc\/stat/ || line ~ /procstat/) { print "procstat"; exit }
                if (line ~ /dumpsys/) { print "dumpsys"; exit }
            }
        ' "$md_file" 2>/dev/null)
    fi
    if [[ -z "${TEST_DURATION_MINUTES:-}" ]]; then
        TEST_DURATION_MINUTES=$(awk '
            /\*\*Planned Duration\*\*/ {
                for (i=1;i<=NF;i++) {
                    if ($i ~ /^[0-9]+$/) { print $i; exit }
                }
            }
        ' "$md_file" 2>/dev/null)
    fi
    if [[ -z "${actual_duration:-}" ]]; then
        actual_duration=$(awk '
            /\*\*Actual Duration\*\*/ {
                for (i=1;i<=NF;i++) {
                    if ($i == "seconds" && i>1 && $(i-1) ~ /^[0-9]+$/) { print $(i-1); exit }
                }
            }
        ' "$md_file" 2>/dev/null)
    fi
    if [[ -z "${actual_minutes:-}" ]]; then
        actual_minutes=$(awk '
            /\*\*Actual Duration\*\*/ {
                for (i=1;i<=NF;i++) {
                    if ($i == "minutes" && i>1 && $(i-1) ~ /^[0-9]+(\.[0-9]+)?$/) { print $(i-1); exit }
                }
            }
        ' "$md_file" 2>/dev/null)
    fi
    if [[ -z "${test_status:-}" ]]; then
        test_status=$(awk -F': ' '/\*\*Test Status\*\*/ {print $2; exit}' "$md_file" 2>/dev/null)
        test_status=${test_status%\r}
    fi

    return 0
}

set_if_empty() {
    # Args: $1 = var name, $2 = value
    local var_name="$1"
    local var_value="$2"
    if [[ -z "$var_name" ]]; then
        return 0
    fi
    # Don't overwrite explicitly provided env/CLI values.
    if [[ -n "${!var_name:-}" ]]; then
        return 0
    fi
    printf -v "$var_name" '%s' "$var_value"
    return 0
}

read_machine_blocks_from_report_md() {
    # Parse machine-readable CONFIG/STATS blocks from report.md.
    # Precedence: existing env/CLI values win; we only fill missing variables.
    local test_dir="$1"
    local md_file="${test_dir}/report.md"
    [[ ! -f "$md_file" ]] && return 0

    local line key val

    # CONFIG block
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            *=*)
                key=${line%%=*}
                val=${line#*=}
                case "$key" in
                    CPU_METHOD|CPU_INTERVAL|MEM_INTERVAL|MIN_CPU_PERCENT|STRICT_WINDOW|DUMPSYS_WINDOW_MIN_MS|DUMPSYS_WINDOW_MAX_MS|MEM_LEAK_THRESHOLD_MBS|MEM_DECLINE_THRESHOLD_MBS|SINGLE_CORE_DMIPS)
                        set_if_empty "$key" "$val"
                        ;;
                esac
                ;;
        esac
    done < <(
        awk '
            /<!-- PERFbench:CONFIG:BEGIN -->/ {inside=1; next}
            /<!-- PERFbench:CONFIG:END -->/ {inside=0}
            inside {
                gsub(/\r/, "")
                sub(/^[[:space:]]+/, "")
                sub(/[[:space:]]+$/, "")
                if ($0 ~ /^<!--/) next
                if ($0 == "") next
                print
            }
        ' "$md_file" 2>/dev/null
    )

    # STATS block
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            *=*)
                key=${line%%=*}
                val=${line#*=}
                case "$key" in
                    AVG_CPU) set_if_empty "avg_cpu" "$val" ;;
                    PEAK_CPU) set_if_empty "peak_cpu" "$val" ;;
                    MIN_CPU) set_if_empty "min_cpu" "$val" ;;
                    AVG_DMIPS) set_if_empty "avg_dmips" "$val" ;;
                    PEAK_DMIPS) set_if_empty "peak_dmips" "$val" ;;
                    MIN_DMIPS) set_if_empty "min_dmips" "$val" ;;
                    AVG_PSS_MB) set_if_empty "avg_mem" "$val" ;;
                    MAX_PSS_MB) set_if_empty "max_mem" "$val" ;;
                    MIN_PSS_MB) set_if_empty "min_mem" "$val" ;;
                    AVG_RSS_MB) set_if_empty "avg_rss" "$val" ;;
                    MAX_RSS_MB) set_if_empty "max_rss" "$val" ;;
                    MIN_RSS_MB) set_if_empty "min_rss" "$val" ;;
                    CPU_SAMPLES_TOTAL) set_if_empty "cpu_samples" "$val" ;;
                    CPU_SAMPLES_VALID) set_if_empty "valid_cpu_samples" "$val" ;;
                    CPU_SAMPLES_FILTERED) set_if_empty "invalid_cpu_samples" "$val" ;;
                    CPU_SAMPLES_UNKNOWN_WINDOW) set_if_empty "unknown_window_samples" "$val" ;;
                    MEM_SAMPLES_TOTAL) set_if_empty "mem_samples" "$val" ;;
                esac
                ;;
        esac
    done < <(
        awk '
            /<!-- PERFbench:STATS:BEGIN -->/ {inside=1; next}
            /<!-- PERFbench:STATS:END -->/ {inside=0}
            inside {
                gsub(/\r/, "")
                sub(/^[[:space:]]+/, "")
                sub(/[[:space:]]+$/, "")
                if ($0 ~ /^<!--/) next
                if ($0 == "") next
                print
            }
        ' "$md_file" 2>/dev/null
    )

    return 0
}

compute_cpu_summary_if_missing() {
    # Fills avg_cpu/peak_cpu/min_cpu/avg_dmips/peak_dmips/min_dmips and sample counts if empty.
    local cpu_log="$1"

    # If caller already provided canonical values, do nothing.
    if [[ -n "${avg_cpu:-}" ]] && [[ -n "${peak_cpu:-}" ]] && [[ -n "${min_cpu:-}" ]]; then
        return 0
    fi

    # Defaults aligned with main script config.
    local method="${CPU_METHOD:-procstat}"
    local strict="${STRICT_WINDOW:-1}"
    local min_cpu_threshold="${MIN_CPU_PERCENT:-0.0}"
    local wmin="${DUMPSYS_WINDOW_MIN_MS:-5000}"
    local wmax="${DUMPSYS_WINDOW_MAX_MS:-30000}"

    # Compute avg/peak/min for CPU and DMIPS using the same inclusion rule.
    local out
    out=$(tail -n +2 "$cpu_log" 2>/dev/null | awk -F',' -v min_cpu="$min_cpu_threshold" -v strict="$strict" -v method="$method" -v wmin="$wmin" -v wmax="$wmax" '
        function check_window() {
            if (method == "procstat") return $5 > 0
            else return ($5>=wmin && $5<=wmax)
        }
        function included() {
            return ( ( check_window() || (strict==0 && $5==-1) ) && ($3>=min_cpu) && ( $6=="Valid" || (strict==0 && $6=="WindowUnknown") ) )
        }
        {
            gsub(/\r/, "", $6)
            total++
            if ($5==-1) unk++
            if (included()) {
                c++
                sum_cpu += $3
                sum_dmips += $4
                if (max_cpu=="" || $3+0>max_cpu+0) max_cpu=$3
                if (min_cpu_v=="" || $3+0<min_cpu_v+0) min_cpu_v=$3
                if (max_dmips=="" || $4+0>max_dmips+0) max_dmips=$4
                if (min_dmips_v=="" || $4+0<min_dmips_v+0) min_dmips_v=$4
            } else {
                filtered++
            }
        }
        END {
            if (c>0) {
                printf "%.2f %.2f %.2f %.0f %.0f %.0f %d %d %d %d", sum_cpu/c, max_cpu+0, min_cpu_v+0, sum_dmips/c, max_dmips+0, min_dmips_v+0, total+0, c+0, filtered+0, unk+0
            } else {
                printf "0 0 0 0 0 0 %d 0 %d %d", total+0, filtered+0, unk+0
            }
        }')

    # Parse outputs
    if [[ -n "$out" ]]; then
        avg_cpu=$(echo "$out" | awk '{print $1}')
        peak_cpu=$(echo "$out" | awk '{print $2}')
        min_cpu=$(echo "$out" | awk '{print $3}')
        avg_dmips=$(echo "$out" | awk '{print $4}')
        peak_dmips=$(echo "$out" | awk '{print $5}')
        min_dmips=$(echo "$out" | awk '{print $6}')
        cpu_samples=$(echo "$out" | awk '{print $7}')
        valid_cpu_samples=$(echo "$out" | awk '{print $8}')
        invalid_cpu_samples=$(echo "$out" | awk '{print $9}')
        unknown_window_samples=$(echo "$out" | awk '{print $10}')
    fi

    return 0
}

compute_mem_summary_if_missing() {
    # Fills avg_mem/max_mem/min_mem and avg_rss/max_rss/min_rss and mem_samples and mem_leak if empty.
    local mem_log="$1"

    # Check if we need to compute stats OR leak detection
    local need_stats=0
    local need_leak=0
    
    if [[ -z "${avg_mem:-}" ]] || [[ -z "${max_mem:-}" ]] || [[ -z "${min_mem:-}" ]]; then
        need_stats=1
    fi
    
    if [[ -z "${mem_leak:-}" ]]; then
        need_leak=1
    fi
    
    if [[ $need_stats -eq 0 ]] && [[ $need_leak -eq 0 ]]; then
        return 0
    fi

    local out
    out=$(tail -n +2 "$mem_log" 2>/dev/null | awk -F',' '
        {
            n++
            p=$6+0
            r=$4+0
            sum_p+=p
            sum_r+=r
            if (max_p=="" || p>max_p) max_p=p
            if (min_p=="" || p<min_p) min_p=p
            if (max_r=="" || r>max_r) max_r=r
            if (min_r=="" || r<min_r) min_r=r

            # for regression (x=t, y=pssMB)
            x=$2+0
            y=p
            sx+=x; sy+=y; sxy+=x*y; sxx+=x*x
            if (n==1) first_p=p
            last_p=p
        }
        END {
            avg_p = (n>0)?(sum_p/n):0
            avg_r = (n>0)?(sum_r/n):0
            slope="N/A"
            if (n>=3) {
                d=n*sxx - sx*sx
                if (d!=0) slope=(n*sxy - sx*sy)/d
                else slope=0
            }
            printf "%.2f %.2f %.2f %.2f %.2f %.2f %d %.6f %.2f %.2f", avg_p, max_p+0, min_p+0, avg_r, max_r+0, min_r+0, n+0, slope+0, first_p+0, last_p+0
        }')

    if [[ -n "$out" ]]; then
        avg_mem=$(echo "$out" | awk '{print $1}')
        max_mem=$(echo "$out" | awk '{print $2}')
        min_mem=$(echo "$out" | awk '{print $3}')
        avg_rss=$(echo "$out" | awk '{print $4}')
        max_rss=$(echo "$out" | awk '{print $5}')
        min_rss=$(echo "$out" | awk '{print $6}')
        mem_samples=$(echo "$out" | awk '{print $7}')
        local slope first_p last_p
        slope=$(echo "$out" | awk '{print $8}')
        first_p=$(echo "$out" | awk '{print $9}')
        last_p=$(echo "$out" | awk '{print $10}')

        if [[ -z "${mem_leak:-}" ]]; then
            local leak_th="${MEM_LEAK_THRESHOLD_MBS:-0.005}"
            local decline_th="${MEM_DECLINE_THRESHOLD_MBS:-0.001}"

            # Basic leak wording (matches report style but shorter)
            if [[ "$mem_samples" =~ ^[0-9]+$ ]] && [[ "$mem_samples" -lt 3 ]]; then
                mem_leak="Unable to determine (Insufficient data)"
            else
                # Compare with awk for portability
                local is_high is_low
                is_high=$(awk -v s="$slope" -v t="$leak_th" 'BEGIN{print (s>t)?1:0}')
                is_low=$(awk -v s="$slope" -v t="$decline_th" 'BEGIN{print (s< -t)?1:0}')
                if [[ "$is_high" == "1" ]]; then
                    mem_leak="Possible (Growth rate ${slope} MB/second)"
                elif [[ "$is_low" == "1" ]]; then
                    mem_leak="No (Memory trending down, slope ${slope} MB/second)"
                else
                    mem_leak="No (Memory stable, slope ${slope} MB/second)"
                fi
            fi
        fi
    fi

    return 0
}

emit_cpu_json() {
    local cpu_log="$1"

    # Output JSON array for CPU samples.
    # Fields: ts, t, cpu, dmips, windowMs, reason, included
    # Included rule MUST match generate_report() in android_app_perfbench.sh.
    awk -F',' \
        -v method="${CPU_METHOD:-}" \
        -v strict="${STRICT_WINDOW:-1}" \
        -v min_cpu="${MIN_CPU_PERCENT:-0.0}" \
        -v wmin="${DUMPSYS_WINDOW_MIN_MS:-5000}" \
        -v wmax="${DUMPSYS_WINDOW_MAX_MS:-30000}" '
    function is_num(s) { return (s ~ /^-?[0-9]+(\.[0-9]+)?$/) }
    function check_window(window_ms) {
        if (method == "procstat") return (window_ms > 0)
        # dumpsys
        if (window_ms == -1) return (strict == 0)
        return (window_ms >= wmin && window_ms <= wmax)
    }
    function check_reason(reason) {
        if (reason == "Valid") return 1
        if (strict == 0 && reason == "WindowUnknown") return 1
        return 0
    }
    BEGIN {
        print "["
        first = 1
    }
    NR == 1 { next }
    {
        ts = $1
        t = $2
        cpu = $3
        dmips = $4
        window_ms = $5
        reason = $6

        # normalize
        gsub(/\r/, "", reason)
        if (!is_num(ts)) ts = 0
        if (!is_num(t)) t = 0
        if (!is_num(cpu)) cpu = 0
        if (!is_num(dmips)) dmips = 0
        if (!is_num(window_ms)) window_ms = -1

        included = 0
        if (check_window(window_ms) && (cpu + 0) >= (min_cpu + 0) && check_reason(reason)) {
            included = 1
        }

        if (!first) print ","
        first = 0

        # Escape reason for JSON string
        gsub(/\\/, "\\\\", reason)
        gsub(/\"/, "\\\"", reason)
        printf "{\"ts\":%d,\"t\":%d,\"cpu\":%.2f,\"dmips\":%.0f,\"windowMs\":%d,\"reason\":\"%s\",\"included\":%d}", ts+0, t+0, cpu+0, dmips+0, window_ms+0, reason, included
    }
    END {
        print "\n]"
    }' "$cpu_log"
}

emit_mem_json() {
    local mem_log="$1"

    # Output JSON array for Memory samples.
    # Fields: ts, t, rssKb, rssMb, pssKb, pssMb
    awk -F',' '
    function is_num(s) { return (s ~ /^-?[0-9]+(\.[0-9]+)?$/) }
    BEGIN {
        print "["
        first = 1
    }
    NR == 1 { next }
    {
        ts = $1
        t = $2
        rss_kb = $3
        rss_mb = $4
        pss_kb = $5
        pss_mb = $6
        gsub(/\r/, "", pss_mb)

        if (!is_num(ts)) ts = 0
        if (!is_num(t)) t = 0
        if (!is_num(rss_kb)) rss_kb = 0
        if (!is_num(rss_mb)) rss_mb = 0
        if (!is_num(pss_kb)) pss_kb = 0
        if (!is_num(pss_mb)) pss_mb = 0

        if (!first) print ","
        first = 0
        printf "{\"ts\":%d,\"t\":%d,\"rssKb\":%d,\"rssMb\":%.2f,\"pssKb\":%d,\"pssMb\":%.2f}", ts+0, t+0, rss_kb+0, rss_mb+0, pss_kb+0, pss_mb+0
    }
    END {
        print "\n]"
    }' "$mem_log"
}

emit_reason_counts_json() {
    local cpu_log="$1"
    awk -F',' '
    BEGIN { print "["; first=1 }
    NR==1 { next }
    {
        r=$6
        gsub(/\r/, "", r)
        if (r=="") r="Unknown"
        c[r]++
    }
    END {
        for (r in c) {
            rr=r
            gsub(/\\/, "\\\\", rr)
            gsub(/\"/, "\\\"", rr)
            if (!first) print ","
            first=0
            printf "{\"reason\":\"%s\",\"count\":%d}", rr, c[r]
        }
        print "\n]"
    }' "$cpu_log"
}

main() {
    local test_dir="${TEST_DIR:-}"
    local cpu_log_arg=""
    local mem_log_arg=""
    local out_file="${REPORT_HTML_FILE:-}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --test-dir)
                test_dir="$2"
                shift 2
                ;;
            --cpu-log)
                cpu_log_arg="$2"
                shift 2
                ;;
            --mem-log)
                mem_log_arg="$2"
                shift 2
                ;;
            --out)
                out_file="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                warn "Unknown argument: $1"
                usage
                exit 0
                ;;
        esac
    done

    if [[ -z "$test_dir" ]] || [[ ! -d "$test_dir" ]]; then
        warn "TEST_DIR is missing or not a directory: '$test_dir'"
        usage
        exit 0
    fi

    # If invoked manually, best-effort fill metadata/config/stats from report.md
    read_meta_from_report_md "$test_dir" 2>/dev/null || true
    read_machine_blocks_from_report_md "$test_dir" 2>/dev/null || true

    # Apply defaults for common config/thresholds when not provided.
    [[ -z "${CPU_METHOD:-}" ]] && CPU_METHOD="procstat"
    [[ -z "${MIN_CPU_PERCENT:-}" ]] && MIN_CPU_PERCENT="0.0"
    [[ -z "${STRICT_WINDOW:-}" ]] && STRICT_WINDOW="1"
    [[ -z "${DUMPSYS_WINDOW_MIN_MS:-}" ]] && DUMPSYS_WINDOW_MIN_MS="5000"
    [[ -z "${DUMPSYS_WINDOW_MAX_MS:-}" ]] && DUMPSYS_WINDOW_MAX_MS="30000"
    [[ -z "${MEM_LEAK_THRESHOLD_MBS:-}" ]] && MEM_LEAK_THRESHOLD_MBS="0.005"
    [[ -z "${MEM_DECLINE_THRESHOLD_MBS:-}" ]] && MEM_DECLINE_THRESHOLD_MBS="0.001"

    local cpu_log="${cpu_log_arg:-${CPU_LOG:-$test_dir/cpu_log.csv}}"
    local mem_log="${mem_log_arg:-${MEM_LOG:-$test_dir/mem_log.csv}}"
    out_file="${out_file:-$test_dir/report.html}"

    if [[ ! -f "$cpu_log" ]]; then
        warn "CPU log not found: $cpu_log"
        exit 0
    fi
    if [[ ! -f "$mem_log" ]]; then
        warn "Memory log not found: $mem_log"
        exit 0
    fi

    # Compute summary values from CSV when not provided
    compute_cpu_summary_if_missing "$cpu_log" 2>/dev/null || true
    compute_mem_summary_if_missing "$mem_log" 2>/dev/null || true

    local meta_test_start_time="${TEST_START_TIME:-}"
    local meta_pkg="${PACKAGE_NAME:-}"
    local meta_method="${CPU_METHOD:-}"
    local meta_status="${test_status:-}"
    local meta_planned_min="${TEST_DURATION_MINUTES:-}"
    local meta_actual_min="${actual_minutes:-}"
    local meta_actual_sec="${actual_duration:-}"

    local th_min_cpu="${MIN_CPU_PERCENT:-}"
    local th_strict="${STRICT_WINDOW:-}"
    local th_wmin="${DUMPSYS_WINDOW_MIN_MS:-}"
    local th_wmax="${DUMPSYS_WINDOW_MAX_MS:-}"
    local th_leak="${MEM_LEAK_THRESHOLD_MBS:-}"
    local th_decline="${MEM_DECLINE_THRESHOLD_MBS:-}"

    # Precomputed summary values (may be empty)
    local s_avg_cpu="${avg_cpu:-}"
    local s_peak_cpu="${peak_cpu:-}"
    local s_min_cpu="${min_cpu:-}"
    local s_avg_dmips="${avg_dmips:-}"
    local s_peak_dmips="${peak_dmips:-}"
    local s_min_dmips="${min_dmips:-}"

    local s_avg_mem="${avg_mem:-}"
    local s_max_mem="${max_mem:-}"
    local s_min_mem="${min_mem:-}"
    local s_avg_rss="${avg_rss:-}"
    local s_max_rss="${max_rss:-}"
    local s_min_rss="${min_rss:-}"

    local s_mem_leak="${mem_leak:-}"
    local s_cpu_samples="${cpu_samples:-}"
    local s_valid_cpu="${valid_cpu_samples:-}"
    local s_invalid_cpu="${invalid_cpu_samples:-}"
    local s_unknown_win="${unknown_window_samples:-}"
    local s_mem_samples="${mem_samples:-}"

    local cpu_json mem_json reason_json meta_json
    cpu_json=$(emit_cpu_json "$cpu_log") || { warn "Failed to parse CPU log"; exit 0; }
    mem_json=$(emit_mem_json "$mem_log") || { warn "Failed to parse memory log"; exit 0; }
    reason_json=$(emit_reason_counts_json "$cpu_log") || reason_json="[]"

    # Build meta JSON to avoid template interpolation issues in heredocs
    meta_json=$(awk -v testId="$meta_test_start_time" \
                    -v pkg="$meta_pkg" \
                    -v method="$meta_method" \
                    -v planned="$meta_planned_min" \
                    -v actualMin="$meta_actual_min" \
                    -v actualSec="$meta_actual_sec" \
                    -v status="$meta_status" \
                    -v minCpu="$th_min_cpu" \
                    -v strict="$th_strict" \
                    -v wmin="$th_wmin" \
                    -v wmax="$th_wmax" \
                    -v leakTh="$th_leak" \
                    -v declineTh="$th_decline" \
                    -v cpuAvg="$s_avg_cpu" -v cpuPeak="$s_peak_cpu" -v cpuMin="$s_min_cpu" \
                    -v dmipsAvg="$s_avg_dmips" -v dmipsPeak="$s_peak_dmips" -v dmipsMin="$s_min_dmips" \
                    -v pssAvg="$s_avg_mem" -v pssMax="$s_max_mem" -v pssMin="$s_min_mem" \
                    -v rssAvg="$s_avg_rss" -v rssMax="$s_max_rss" -v rssMin="$s_min_rss" \
                    -v leak="$s_mem_leak" \
                    -v cpuSamples="$s_cpu_samples" -v cpuValid="$s_valid_cpu" -v cpuFiltered="$s_invalid_cpu" -v cpuUnknown="$s_unknown_win" \
                    -v memSamples="$s_mem_samples" '
        function esc(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/\"/, "\\\"", s)
            gsub(/\r/, "", s)
            gsub(/\n/, "\\n", s)
            return s
        }
        BEGIN {
            printf "{"
            printf "\"testId\":\"%s\",", esc(testId)
            printf "\"packageName\":\"%s\",", esc(pkg)
            printf "\"cpuMethod\":\"%s\",", esc(method)
            printf "\"plannedMinutes\":\"%s\",", esc(planned)
            printf "\"actualMinutes\":\"%s\",", esc(actualMin)
            printf "\"actualSeconds\":\"%s\",", esc(actualSec)
            printf "\"status\":\"%s\",", esc(status)
            printf "\"thresholds\":{"
            printf "\"minCpu\":\"%s\",", esc(minCpu)
            printf "\"strictWindow\":\"%s\",", esc(strict)
            printf "\"windowMinMs\":\"%s\",", esc(wmin)
            printf "\"windowMaxMs\":\"%s\",", esc(wmax)
            printf "\"leakThreshold\":\"%s\",", esc(leakTh)
            printf "\"declineThreshold\":\"%s\"", esc(declineTh)
            printf "},"
            printf "\"summary\":{"
            printf "\"cpuAvg\":\"%s\",\"cpuPeak\":\"%s\",\"cpuMin\":\"%s\",", esc(cpuAvg), esc(cpuPeak), esc(cpuMin)
            printf "\"dmipsAvg\":\"%s\",\"dmipsPeak\":\"%s\",\"dmipsMin\":\"%s\",", esc(dmipsAvg), esc(dmipsPeak), esc(dmipsMin)
            printf "\"pssAvg\":\"%s\",\"pssMax\":\"%s\",\"pssMin\":\"%s\",", esc(pssAvg), esc(pssMax), esc(pssMin)
            printf "\"rssAvg\":\"%s\",\"rssMax\":\"%s\",\"rssMin\":\"%s\",", esc(rssAvg), esc(rssMax), esc(rssMin)
            printf "\"leak\":\"%s\",", esc(leak)
            printf "\"cpuSamples\":\"%s\",\"cpuValid\":\"%s\",\"cpuFiltered\":\"%s\",\"cpuUnknownWindow\":\"%s\",", esc(cpuSamples), esc(cpuValid), esc(cpuFiltered), esc(cpuUnknown)
            printf "\"memSamples\":\"%s\"", esc(memSamples)
            printf "}"
            printf "}"
        }')

    # Write HTML with JSON blocks inserted without templating.
    local tmp_dir tmp_meta tmp_cpu tmp_mem tmp_reason
    tmp_dir=$(mktemp -d 2>/dev/null)
    if [[ -z "$tmp_dir" ]] || [[ ! -d "$tmp_dir" ]]; then
        tmp_dir=$(mktemp -d -t perfbench_html 2>/dev/null || echo "")
    fi
    if [[ -z "$tmp_dir" ]] || [[ ! -d "$tmp_dir" ]]; then
        warn "Failed to create temp directory for HTML generation"
        exit 0
    fi
    tmp_meta="${tmp_dir}/meta.json"
    tmp_cpu="${tmp_dir}/cpu.json"
    tmp_mem="${tmp_dir}/mem.json"
    tmp_reason="${tmp_dir}/reason.json"
    printf "%s" "$meta_json" > "$tmp_meta" 2>/dev/null || { warn "Failed to write temp meta.json"; rm -rf "$tmp_dir"; exit 0; }
    printf "%s" "$cpu_json" > "$tmp_cpu" 2>/dev/null || { warn "Failed to write temp cpu.json"; rm -rf "$tmp_dir"; exit 0; }
    printf "%s" "$mem_json" > "$tmp_mem" 2>/dev/null || { warn "Failed to write temp mem.json"; rm -rf "$tmp_dir"; exit 0; }
    printf "%s" "$reason_json" > "$tmp_reason" 2>/dev/null || { warn "Failed to write temp reason.json"; rm -rf "$tmp_dir"; exit 0; }

    if ! cat > "$out_file" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Performance Test Report</title>
  <link rel="preconnect" href="https://cdn.jsdelivr.net" />
  <link href="https://cdn.jsdelivr.net/npm/tabulator-tables@6.2.5/dist/css/tabulator.min.css" rel="stylesheet">
  <style>
    :root {
      --bg: #f8f9fa;
      --panel: #ffffff;
      --panel2: #ffffff;
      --border: #e2e8f0;
      --text: #1e293b;
      --muted: #64748b;
      --good: #10b981;
      --warn: #f59e0b;
      --bad: #ef4444;
      --accent: #3b82f6;
      --accent2: #8b5cf6;
      --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
      --sans: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, "Apple Color Emoji", "Segoe UI Emoji";
      --radius: 12px;
      --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05), 0 2px 4px -1px rgba(0, 0, 0, 0.03);
    }
    html, body {
      height: 100%;
      background: var(--bg);
      color: var(--text);
      font-family: var(--sans);
      margin: 0;
    }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .wrap { max-width: 1200px; margin: 0 auto; padding: 40px 24px 80px; }
    .hero {
      display: grid;
      grid-template-columns: repeat(12, 1fr);
      gap: 24px;
      align-items: stretch;
      margin-bottom: 32px;
    }
    @media (max-width: 1100px) { 
      .hero .span-8, .hero .span-4 { grid-column: span 12; }
    }
    .card {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      box-shadow: var(--shadow);
      overflow: hidden;
      transition: transform 0.2s, box-shadow 0.2s;
    }
    .card:hover {
      box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.05), 0 4px 6px -2px rgba(0, 0, 0, 0.025);
    }
    .card .hd {
      padding: 20px 24px;
      border-bottom: 1px solid var(--border);
      background: #fdfdfd;
    }
    .title { font-size: 18px; font-weight: 600; letter-spacing: -0.01em; margin: 0; color: #0f172a; }
    .sub { margin: 6px 0 0; color: var(--muted); font-size: 13px; }
    .card .bd { padding: 24px; }
    .kv { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px 24px; font-size: 13px; }
    .kv-item { display: flex; flex-direction: column; gap: 4px; }
    @media (max-width: 768px) { .kv { grid-template-columns: 1fr 1fr; } }
    @media (max-width: 520px) { .kv { grid-template-columns: 1fr; } }
    .k { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }
    .v { font-family: var(--mono); color: var(--text); font-size: 14px; font-weight: 500; }
    .chips { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 20px; padding-top: 16px; border-top: 1px solid #f1f5f9; }
    .chip {
      font-family: var(--mono);
      font-size: 11px;
      padding: 4px 10px;
      border-radius: 6px;
      background: #f1f5f9;
      border: 1px solid #e2e8f0;
      color: var(--muted);
      font-weight: 500;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(12, 1fr);
      gap: 24px;
      margin-top: 24px;
    }
    .span-3 { grid-column: span 3; }
    .span-4 { grid-column: span 4; }
    .span-6 { grid-column: span 6; }
    .span-8 { grid-column: span 8; }
    .span-9 { grid-column: span 9; }
    .span-12 { grid-column: span 12; }
    
    @media (max-width: 1100px) {
      /* Stack main elements earlier for better readability on tablets */
      .span-8, .span-9 { grid-column: span 12; }
      /* If CPU chart expands to full width, the Reason chart (span-4) must also expand or it looks orphaned */
      .card.span-4 { grid-column: span 12; }
      /* Note: This also stacks the KPI cards vertically. */
    }
    
    @media (max-width: 768px) {
      .span-3, .span-4, .span-6, .span-8, .span-9 { grid-column: span 12; }
      .card .bd { padding: 16px; }
      .wrap { padding: 20px 16px 60px; }
    }

    /* KPI Card Styles */
    .kpi-card {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 20px;
      box-shadow: var(--shadow);
      position: relative;
      overflow: hidden;
      display: flex;
      flex-direction: column;
      justify-content: center;
    }
    .kpi-card::before {
      content: "";
      position: absolute;
      left: 0; top: 0; bottom: 0;
      width: 4px;
      background: var(--accent);
    }
    .kpi-card.purple::before { background: var(--accent2); }
    .kpi-card.teal::before { background: #10b981; }
    .kpi-card.green::before { background: var(--good); }
    .kpi-card.orange::before { background: var(--warn); }
    .kpi-card.red::before { background: var(--bad); }
    
    /* Subtle tints for KPI cards */
    .kpi-card.tint-blue { background: linear-gradient(145deg, #eff6ff 0%, #ffffff 60%); }
    .kpi-card.tint-teal { background: linear-gradient(145deg, #f0fdf4 0%, #ffffff 60%); }
    .kpi-card.tint-gray { background: linear-gradient(145deg, #f8fafc 0%, #ffffff 60%); }
    
    .kpi-label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; color: #64748b; font-weight: 700; margin-bottom: 8px; opacity: 0.9; }
    .kpi-value { font-size: 28px; font-family: var(--mono); font-weight: 700; color: #1e293b; line-height: 1.1; }
    .kpi-sub { font-size: 13px; color: #64748b; margin-top: 8px; display: flex; align-items: center; gap: 8px; font-weight: 500; }
    
    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
    }
    .btn {
      cursor: pointer;
      border: 1px solid var(--border);
      background: #fff;
      color: var(--text);
      padding: 8px 14px;
      border-radius: 6px;
      font-family: var(--sans);
      font-size: 13px;
      font-weight: 500;
      transition: all 0.15s;
      box-shadow: 0 1px 2px 0 rgba(0, 0, 0, 0.05);
    }
    .btn:hover { background: #f8fafc; border-color: #cbd5e1; }
    .btn.primary { border-color: var(--accent); background: var(--accent); color: #fff; }
    .btn.primary:hover { background: #2563eb; border-color: #2563eb; }
    .note { color: var(--muted); font-size: 13px; margin-top: 12px; line-height: 1.6; background: #fffbeb; border: 1px solid #fcd34d; padding: 12px; border-radius: 8px; color: #92400e; }
    .chartWrap { height: 320px; position: relative; }
    .chartWrap.tall { height: 400px; }

    /* Tabulator theme tweaks for light mode */
    .tabulator {
      border: 1px solid var(--border);
      border-radius: 8px;
      overflow: hidden;
      background: #fff;
      font-family: var(--sans);
      font-size: 13px;
    }
    .tabulator .tabulator-header {
      background: #f8fafc;
      border-bottom: 1px solid var(--border);
      color: #475569;
      font-weight: 600;
    }
    .tabulator .tabulator-header .tabulator-col {
      background: transparent;
      border-right: 1px solid var(--border);
    }
    .tabulator .tabulator-col-title { color: #475569; }
    .tabulator .tabulator-row {
      background: #fff;
      border-bottom: 1px solid #f1f5f9;
      color: #334155;
    }
    .tabulator .tabulator-row.tabulator-row-even { background: #f8fafc; }
    .tabulator .tabulator-row:hover { background: #eff6ff; }
    .footer {
      margin-top: 60px;
      padding-top: 24px;
      border-top: 1px solid var(--border);
      text-align: center;
      color: var(--muted);
      font-size: 13px;
    }
    .config-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 12px;
      margin-bottom: 16px;
    }
    .config-item {
      background: #f8fafc;
      border: 1px solid var(--border);
      padding: 8px 12px;
      border-radius: 6px;
      font-size: 12px;
    }
    .config-label { color: var(--muted); font-weight: 600; margin-bottom: 2px; }
    .config-val { font-family: var(--mono); color: var(--text); font-weight: 600; }
    /* Chip Overrides */
    .chip { font-family: var(--mono); font-size: 11px; padding: 4px 10px; border-radius: 6px; background: #ffffff; border: 1px solid #e2e8f0; color: #64748b; font-weight: 500; box-shadow: 0 1px 2px 0 rgba(0,0,0,0.02); }
  </style>
</head>
<body>
  <div class="wrap">
    <div id="app"></div>
  </div>

EOF
    then
        warn "Failed to write HTML report: $out_file"
        rm -rf "$tmp_dir"
        exit 0
    fi

    {
        printf '<script type="application/json" id="meta-data">'
        cat "$tmp_meta"
        printf '</script>\n'

        printf '<script type="application/json" id="cpu-data">'
        cat "$tmp_cpu"
        printf '</script>\n'

        printf '<script type="application/json" id="mem-data">'
        cat "$tmp_mem"
        printf '</script>\n'

        printf '<script type="application/json" id="reason-data">'
        cat "$tmp_reason"
        printf '</script>\n'
    } >> "$out_file" 2>/dev/null || {
        warn "Failed to write embedded JSON blocks"
        rm -rf "$tmp_dir"
        exit 0
    }

    if ! cat >> "$out_file" <<'EOF'

  <!-- React (no build) -->
  <script>console.log('[LOAD] Starting to load libraries...');</script>
  <script src="https://cdn.jsdelivr.net/npm/react@18.3.1/umd/react.production.min.js" crossorigin></script>
  <script>console.log('[LOAD] React loaded:', typeof React);</script>
  <script src="https://cdn.jsdelivr.net/npm/react-dom@18.3.1/umd/react-dom.production.min.js" crossorigin></script>
  <script>console.log('[LOAD] ReactDOM loaded:', typeof ReactDOM);</script>
  <!-- htm: JSX-less templating for React -->
  <script src="https://cdn.jsdelivr.net/npm/htm@3.1.1/dist/htm.umd.js"></script>
  <script>console.log('[LOAD] htm loaded:', typeof htm);</script>

  <!-- Charts -->
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
  <script>console.log('[LOAD] Chart.js loaded:', typeof Chart);</script>
  <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@2.0.1/dist/chartjs-plugin-zoom.min.js"></script>
  <script>console.log('[LOAD] Chart zoom plugin loaded');</script>

  <!-- Tables -->
  <script src="https://cdn.jsdelivr.net/npm/tabulator-tables@6.2.5/dist/js/tabulator.min.js"></script>
  <script>console.log('[LOAD] Tabulator loaded:', typeof Tabulator);</script>

  <script>
  (function () {
    console.log('[DEBUG] Script started');
    
    const { useEffect, useMemo, useRef, useState } = React;
    console.log('[DEBUG] React hooks extracted:', { useEffect: !!useEffect, useMemo: !!useMemo, useRef: !!useRef, useState: !!useState });
    
    const html = htm.bind(React.createElement);
    console.log('[DEBUG] htm bound to React.createElement');

    function getJson(id) {
      const el = document.getElementById(id);
      if (!el) {
        console.warn('[DEBUG] Element not found:', id);
        return [];
      }
      try { 
        const result = JSON.parse(el.textContent || '[]');
        console.log('[DEBUG] Parsed JSON for', id, '- length:', Array.isArray(result) ? result.length : 'N/A');
        return result;
      } catch (e) { 
        console.error('[DEBUG] Failed to parse JSON for', id, e);
        return [];
      }
    }

    const meta = (function(){
      const el = document.getElementById('meta-data');
      if (!el) {
        console.warn('[DEBUG] meta-data element not found');
        return { thresholds: {}, summary: {} };
      }
      try {
        const v = JSON.parse(el.textContent || '{}');
        console.log('[DEBUG] Parsed meta-data:', v);
        return (v && typeof v === 'object' && !Array.isArray(v)) ? v : { thresholds: {}, summary: {} };
      } catch (e) {
        console.error('[DEBUG] Failed to parse meta-data:', e);
        return { thresholds: {}, summary: {} };
      }
    })();
    const cpuData = getJson('cpu-data');
    const memData = getJson('mem-data');
    const reasonData = getJson('reason-data');
    
    console.log('[DEBUG] Data loaded - CPU:', cpuData.length, 'MEM:', memData.length, 'Reasons:', reasonData.length);

    function formatMaybe(v, fallback) {
      return (v === undefined || v === null || String(v).trim() === "") ? fallback : v;
    }

    function leakTone(text) {
      const s = String(text || "").toLowerCase();
      if (s.indexOf('possible') >= 0) return 'warn';
      if (s.indexOf('unable') >= 0) return 'warn';
      if (s.indexOf('no') === 0) return 'good';
      return 'warn';
    }

    function buildLineDataset(rows, yKey, label, color, yAxisID) {
      return {
        label,
        data: rows.map(r => ({ x: r.t, y: r[yKey] })),
        borderColor: color,
        backgroundColor: color,
        pointRadius: 0,
        borderWidth: 2,
        tension: 0.25,
        yAxisID,
      };
    }

    function useChart(canvasRef, configFactory, deps) {
      useEffect(() => {
        const canvas = canvasRef.current;
        if (!canvas) return;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;

        const config = configFactory();
        const chart = new Chart(ctx, config);
        return () => chart.destroy();
      // eslint-disable-next-line react-hooks/exhaustive-deps
      }, deps);
    }

    function Charts({ rows, memRows, reasons, onlyIncluded }) {
      console.log('[DEBUG] Charts component rendering - rows:', rows.length, 'memRows:', memRows.length, 'reasons:', reasons.length);
      
      const cpuRows = useMemo(() => onlyIncluded ? rows.filter(r => r.included === 1) : rows, [rows, onlyIncluded]);
      console.log('[DEBUG] cpuRows filtered:', cpuRows.length);

      const cpuCanvas = useRef(null);
      const memCanvas = useRef(null);
      const reasonCanvas = useRef(null);

      useChart(cpuCanvas, () => {
        console.log('[DEBUG] Building CPU chart config');
        return {
        type: 'line',
        data: {
          datasets: [
            buildLineDataset(cpuRows, 'cpu', 'CPU %', 'rgba(37, 99, 235, 1.0)', 'cpuY'), // Blue-600
            buildLineDataset(cpuRows, 'dmips', 'DMIPS', 'rgba(124, 58, 237, 0.85)', 'dmipsY'), // Violet-600
          ]
        },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            parsing: false,
            normalized: true,
            interaction: { mode: 'index', intersect: false },
            scales: {
              x: {
                type: 'linear',
                title: { display: true, text: 'Elapsed (s)', color: '#94a3b8' },
                grid: { color: '#f1f5f9' },
                ticks: { color: '#64748b' },
              },
              cpuY: {
                type: 'linear', position: 'left',
                title: { display: true, text: 'CPU %', color: '#94a3b8' },
                grid: { color: '#f1f5f9' },
                ticks: { color: '#64748b' },
              },
              dmipsY: {
                type: 'linear', position: 'right',
                title: { display: true, text: 'DMIPS', color: '#94a3b8' },
                grid: { drawOnChartArea: false },
                ticks: { color: '#64748b' },
              }
            },
            plugins: {
              legend: { labels: { color: '#475569', usePointStyle: true, boxWidth: 6 } },
              tooltip: { 
                enabled: true,
                backgroundColor: 'rgba(255, 255, 255, 0.95)',
                titleColor: '#0f172a',
                bodyColor: '#334155',
                borderColor: '#e2e8f0',
                borderWidth: 1,
                padding: 10,
                boxPadding: 4
              },
              zoom: {
                zoom: {
                  wheel: { enabled: true },
                  pinch: { enabled: true },
                  mode: 'x',
                },
                pan: { enabled: true, mode: 'x', modifierKey: 'shift' },
              },
            }
          }
        };
      }, [cpuRows.length, onlyIncluded]);

      useChart(memCanvas, () => ({
        type: 'line',
        data: {
          datasets: [
            buildLineDataset(memRows, 'pssMb', 'PSS (MB)', 'rgba(5, 150, 105, 1.0)'), // Emerald-600
            buildLineDataset(memRows, 'rssMb', 'RSS (MB)', 'rgba(217, 119, 6, 0.90)'), // Amber-600
          ]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          parsing: false,
          normalized: true,
          interaction: { mode: 'index', intersect: false },
          scales: {
            x: {
              type: 'linear',
              title: { display: true, text: 'Elapsed (s)', color: '#94a3b8' },
              grid: { color: '#f1f5f9' },
              ticks: { color: '#64748b' },
            },
            y: {
              title: { display: true, text: 'MB', color: '#94a3b8' },
              grid: { color: '#f1f5f9' },
              ticks: { color: '#64748b' },
            }
          },
          plugins: {
            legend: { labels: { color: '#475569', usePointStyle: true, boxWidth: 6 } },
            tooltip: { 
              enabled: true,
              backgroundColor: 'rgba(255, 255, 255, 0.95)',
              titleColor: '#0f172a',
              bodyColor: '#334155',
              borderColor: '#e2e8f0',
              borderWidth: 1,
              padding: 10,
              boxPadding: 4
            },
            zoom: {
              zoom: {
                wheel: { enabled: true },
                pinch: { enabled: true },
                mode: 'x',
              },
              pan: { enabled: true, mode: 'x', modifierKey: 'shift' },
            },
          }
        }
      }), [memRows.length]);

      useChart(reasonCanvas, () => ({
        type: 'bar',
        data: {
          labels: reasons.map(r => r.reason),
          datasets: [{
            label: 'Count',
            data: reasons.map(r => r.count),
            backgroundColor: 'rgba(59, 130, 246, 0.5)', // Blue-500 transparent
            borderColor: 'rgba(37, 99, 235, 1.0)',      // Blue-600
            borderWidth: 1,
          }]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          scales: {
            x: { grid: { display: false }, ticks: { color: '#64748b', font: {size: 11} } },
            y: { grid: { color: '#f1f5f9' }, ticks: { color: '#64748b' } },
          },
          plugins: {
            legend: { display: false },
            tooltip: { 
              enabled: true,
              backgroundColor: 'rgba(255, 255, 255, 0.95)',
              titleColor: '#0f172a',
              bodyColor: '#334155',
              borderColor: '#e2e8f0',
              borderWidth: 1
            },
          }
        }
      }), [reasons.length]);

      return html`
        <div className="grid">
          <div className="card span-8">
            <div className="hd">
              <div className="toolbar">
                <h3 className="title" style=${{marginRight: 'auto'}}>CPU & DMIPS Timeline</h3>
                <div className="chip">Zoom: mouse wheel / pinch</div>
                <div className="chip">Pan: Shift + drag</div>
              </div>
              <div className="sub">${onlyIncluded ? 'Showing included samples only' : 'Showing all samples'} · Source: cpu_log.csv</div>
            </div>
            <div className="bd"><div className="chartWrap"><canvas ref=${cpuCanvas}></canvas></div></div>
          </div>

          <div className="card span-4">
            <div className="hd">
              <h3 className="title">FilterReason Breakdown</h3>
              <div className="sub">Source: cpu_log.csv</div>
            </div>
            <div className="bd"><div className="chartWrap"><canvas ref=${reasonCanvas}></canvas></div></div>
          </div>

          <div className="card span-12">
            <div className="hd">
              <h3 className="title">Memory Timeline (PSS/RSS)</h3>
              <div className="sub">Source: mem_log.csv</div>
            </div>
            <div className="bd"><div className="chartWrap tall"><canvas ref=${memCanvas}></canvas></div></div>
          </div>
        </div>
      `;
    }

    function Tables({ rows, memRows, onlyIncluded, setOnlyIncluded }) {
      const cpuTableEl = useRef(null);
      const memTableEl = useRef(null);
      const cpuTable = useRef(null);
      const memTable = useRef(null);

      useEffect(() => {
        if (!cpuTableEl.current) return;
        cpuTable.current = new Tabulator(cpuTableEl.current, {
          data: rows,
          layout: 'fitDataStretch',
          height: 420,
          pagination: true,
          paginationSize: 15,
          paginationSizeSelector: [15, 30, 60, 120],
          movableColumns: true,
          columns: [
            { title: 't(s)', field: 't', sorter: 'number', width: 90 },
            { title: 'CPU %', field: 'cpu', sorter: 'number', formatter: (c) => c.getValue().toFixed(2), width: 110 },
            { title: 'DMIPS', field: 'dmips', sorter: 'number', formatter: (c) => Math.round(c.getValue()).toString(), width: 110 },
            { title: 'WindowMs', field: 'windowMs', sorter: 'number', width: 120 },
            { title: 'Reason', field: 'reason', sorter: 'string', widthGrow: 2 },
            { title: 'Included', field: 'included', sorter: 'number', formatter: (c) => c.getValue() === 1 ? 'Yes' : 'No', width: 110 },
            { title: 'Timestamp', field: 'ts', sorter: 'number', visible: false },
          ],
        });
        return () => { try { cpuTable.current && cpuTable.current.destroy(); } catch (e) {} };
      }, []);

      useEffect(() => {
        if (!memTableEl.current) return;
        memTable.current = new Tabulator(memTableEl.current, {
          data: memRows,
          layout: 'fitDataStretch',
          height: 380,
          pagination: true,
          paginationSize: 15,
          paginationSizeSelector: [15, 30, 60, 120],
          movableColumns: true,
          columns: [
            { title: 't(s)', field: 't', sorter: 'number', width: 90 },
            { title: 'PSS (MB)', field: 'pssMb', sorter: 'number', formatter: (c) => c.getValue().toFixed(2), width: 130 },
            { title: 'RSS (MB)', field: 'rssMb', sorter: 'number', formatter: (c) => c.getValue().toFixed(2), width: 130 },
            { title: 'PSS (KB)', field: 'pssKb', sorter: 'number', visible: false },
            { title: 'RSS (KB)', field: 'rssKb', sorter: 'number', visible: false },
            { title: 'Timestamp', field: 'ts', sorter: 'number', visible: false },
          ],
        });
        return () => { try { memTable.current && memTable.current.destroy(); } catch (e) {} };
      }, []);

      useEffect(() => {
        if (!cpuTable.current) return;
        if (onlyIncluded) cpuTable.current.setFilter('included', '=', 1);
        else cpuTable.current.clearFilter(true);
      }, [onlyIncluded]);

      const exportCpu = () => {
        if (!cpuTable.current) return;
        cpuTable.current.download('csv', 'cpu_samples_view.csv');
      };
      const exportMem = () => {
        if (!memTable.current) return;
        memTable.current.download('csv', 'mem_samples_view.csv');
      };

      return html`
        <div className="grid">
          <div className="card span-12">
            <div className="hd">
              <div className="toolbar">
                <h3 className="title" style=${{marginRight: 'auto'}}>CPU Samples</h3>
                <button className=${"btn " + (onlyIncluded ? "primary" : "")} onClick=${() => setOnlyIncluded(!onlyIncluded)}>
                  ${onlyIncluded ? 'Included only: ON' : 'Included only: OFF'}
                </button>
                <button className="btn" onClick=${exportCpu}>Export CSV</button>
                <a className="btn" href="cpu_log.csv" target="_blank" rel="noreferrer">Open cpu_log.csv</a>
              </div>
              <div className="sub">Sortable, filterable table · Column drag enabled</div>
            </div>
            <div className="bd"><div ref=${cpuTableEl}></div></div>
          </div>

          <div className="card span-12">
            <div className="hd">
              <div className="toolbar">
                <h3 className="title" style=${{marginRight: 'auto'}}>Memory Samples</h3>
                <button className="btn" onClick=${exportMem}>Export CSV</button>
                <a className="btn" href="mem_log.csv" target="_blank" rel="noreferrer">Open mem_log.csv</a>
              </div>
              <div className="sub">Sortable table · Column drag enabled</div>
            </div>
            <div className="bd"><div ref=${memTableEl}></div></div>
          </div>
        </div>
      `;
    }


    // Optional chaining polyfill function because raw optional chaining ?. isn't supported in all embedded environments or older browsers
    function getLeakSlope(leakStr) {
      if (!leakStr) return 'N/A';
      const match = leakStr.match(/slope\s+([\-0-9\.]+)/);
      return match ? match[1] : 'N/A';
    }

    function App() {
      console.log('[DEBUG] App component rendering');
      
      const [onlyIncluded, setOnlyIncluded] = useState(true);

      const cpuCount = cpuData.length;
      const cpuIncluded = cpuData.filter(r => r.included === 1).length;
      const leak = formatMaybe(meta.summary.leak, 'N/A');
      
      console.log('[DEBUG] App state - cpuCount:', cpuCount, 'cpuIncluded:', cpuIncluded, 'leak:', leak);

      return html`
        <div style=${{marginBottom: '24px'}}>
          <div className="hero">
            <div className="card span-8">
              <div className="hd">
                <h1 className="title">Performance Test Report</h1>
                <div className="sub">Interactive HTML · React + Chart.js + Tabulator (CDN)</div>
              </div>
              <div className="bd">
                <div className="kv">
                  <div className="kv-item"><div className="k">Test ID</div><div className="v">${formatMaybe(meta.testId, 'N/A')}</div></div>
                  <div className="kv-item"><div className="k">Package</div><div className="v">${formatMaybe(meta.packageName, 'N/A')}</div></div>
                  <div className="kv-item"><div className="k">CPU Method</div><div className="v">${formatMaybe(meta.cpuMethod, 'N/A')}</div></div>
                  <div className="kv-item"><div className="k">Planned</div><div className="v">${formatMaybe(meta.plannedMinutes, 'N/A')} min</div></div>
                  <div className="kv-item"><div className="k">Actual</div><div className="v">${formatMaybe(meta.actualMinutes, 'N/A')} min (${formatMaybe(meta.actualSeconds, 'N/A')} s)</div></div>
                  <div className="kv-item"><div className="k">Status</div><div className="v">${formatMaybe(meta.status, 'N/A')}</div></div>
                </div>
                <div className="chips">
                  <span className="chip">MIN_CPU_PERCENT=${formatMaybe(meta.thresholds.minCpu, 'N/A')}</span>
                  <span className="chip">STRICT_WINDOW=${formatMaybe(meta.thresholds.strictWindow, 'N/A')}</span>
                  <span className="chip">WINDOW_MS=${formatMaybe(meta.thresholds.windowMinMs, 'N/A')}-${formatMaybe(meta.thresholds.windowMaxMs, 'N/A')}</span>
                  <span className="chip">MEM_LEAK_THRESHOLD_MBS=${formatMaybe(meta.thresholds.leakThreshold, 'N/A')}</span>
                </div>
              </div>
            </div>

            <div className="card span-4">
              <div className="hd">
                <h2 className="title">Test Configuration</h2>
                <div className="sub">Thresholds & Constraints</div>
              </div>
              <div className="bd">
                <div className="config-grid">
                  <div className="config-item"><div className="config-label">Min CPU %</div><div className="config-val">${formatMaybe(meta.thresholds.minCpu, 'N/A')}</div></div>
                  <div className="config-item"><div className="config-label">Strict Window</div><div className="config-val">${formatMaybe(meta.thresholds.strictWindow, 'N/A')}</div></div>
                  <div className="config-item"><div className="config-label">Window Range</div><div className="config-val">${formatMaybe(meta.thresholds.windowMinMs, 'N/A')}-${formatMaybe(meta.thresholds.windowMaxMs, 'N/A')} ms</div></div>
                  <div className="config-item"><div className="config-label">Leak Threshold</div><div className="config-val">${formatMaybe(meta.thresholds.leakThreshold, 'N/A')} MB/s</div></div>
                </div>
                
                <div className="note" style=${{marginTop: 0, fontSize: '12px'}}>
                   <strong>Filter Logic:</strong> Samples are valid if CPU > Min CPU. Dumpsys samples must also fall within the Window Range.
                </div>
              </div>
            </div>
          </div>

          <div className="grid" style=${{marginTop: 0}}>
             <div className="kpi-card tint-blue span-4">
               <div className="kpi-label">Average CPU</div>
               <div className="kpi-value">${formatMaybe(meta.summary.cpuAvg, 'N/A')}%</div>
               <div className="kpi-sub">
                 <span>Peak: ${formatMaybe(meta.summary.cpuPeak, 'N/A')}%</span>
                 <span style=${{opacity: 0.3}}>|</span>
                 <span>Min: ${formatMaybe(meta.summary.cpuMin, 'N/A')}%</span>
               </div>
             </div>

             <div className="kpi-card tint-teal teal span-4">
               <div className="kpi-label">Average PSS</div>
               <div className="kpi-value">${formatMaybe(meta.summary.pssAvg, 'N/A')} <span style=${{fontSize: '16px', fontWeight: 500, color: 'var(--muted)'}}>MB</span></div>
               <div className="kpi-sub">
                 <span>Max: ${formatMaybe(meta.summary.pssMax, 'N/A')}</span>
                 <span style=${{opacity: 0.3}}>|</span>
                 <span>RSS Avg: ${formatMaybe(meta.summary.rssAvg, 'N/A')}</span>
               </div>
             </div>

             <div className=${"kpi-card span-4 tint-gray " + (leakTone(leak) === 'good' ? 'green' : (leakTone(leak) === 'bad' ? 'red' : 'orange'))}>
               <div className="kpi-label">Memory Leak Status</div>
               <div className="kpi-value" style=${{fontSize: '22px'}}>${leak}</div>
               <div className="kpi-sub">
                 <span>Samples: ${formatMaybe(meta.summary.memSamples, memData.length)}</span>
                 <span style=${{opacity: 0.3}}>|</span>
                 <span>Slope: ${getLeakSlope(meta.summary.leak)}</span>
               </div>
             </div>
          </div>

          ${html`<${Charts} rows=${cpuData} memRows=${memData} reasons=${reasonData} onlyIncluded=${onlyIncluded} />`}
          ${html`<${Tables} rows=${cpuData} memRows=${memData} onlyIncluded=${onlyIncluded} setOnlyIncluded=${setOnlyIncluded} />`}
          
          <div className="footer">
            Generated by AndroidAppPerfbench · <a href="https://github.com" target="_blank">View on GitHub</a>
          </div>
        </div>
      `;
    }


    console.log('[DEBUG] Attempting to render React app');
    const root = ReactDOM.createRoot(document.getElementById('app'));
    console.log('[DEBUG] Root created:', !!root);
    root.render(html`<${App} />`);
    console.log('[DEBUG] Render called successfully');
  })();
  </script>
</body>
</html>
EOF
    then
        warn "Failed to append HTML body"
        rm -rf "$tmp_dir"
        exit 0
    fi

    rm -rf "$tmp_dir" 2>/dev/null || true

    info "HTML report generated: $out_file"
    exit 0
}

main "$@"
