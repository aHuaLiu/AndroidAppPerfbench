# Android Application Performance Benchmark Script

## Technical Documentation

> **Version**: 3.0
> **Author**: hua.liu
> **Platform**: macOS, Linux
> **Purpose**: Measure CPU and memory performance of Android applications during runtime (supports multi-process statistics)

---

## Table of Contents

1. [Overview](#overview)
2. [Features](#features)
3. [System Requirements](#system-requirements)
4. [Configuration Parameters](#configuration-parameters)
5. [CPU Collection Methods](#cpu-collection-methods)
6. [Memory Collection](#memory-collection)
7. [Memory Leak Detection](#memory-leak-detection)
8. [Output Files](#output-files)
9. [Technical Implementation](#technical-implementation)
10. [Troubleshooting](#troubleshooting)

---

## Overview

This script is an automated performance testing tool designed to measure CPU and memory consumption of Android applications during video playback or other intensive operations. It supports **multi-process statistics**, automatically detecting and aggregating metrics from the main process and all related subprocesses (such as sandboxed processes, privileged processes, service processes, etc.).

### Key Capabilities

- 📊 **Dual CPU Engine**: Two CPU collection methods (`/proc/stat` and `dumpsys cpuinfo`)
- 💾 **Comprehensive Memory Metrics**: Both PSS and RSS with per-PID aggregation
- 🔍 **Memory Leak Detection**: Linear regression analysis to detect memory growth trends
- 🔄 **Multi-Process Support**: Automatic detection of main and child processes
- 📝 **Detailed Reporting**: Markdown reports with statistical analysis
- ⚡ **Graceful Interruption**: `Ctrl+C` generates partial reports from collected data

---

## Features

### 1. Dependency Verification

The script automatically checks for required tools:
- `adb` - Android Debug Bridge for device communication
- `bc` - Command-line calculator for floating-point arithmetic
- `awk` - Text processing for parsing system output

### 2. Multi-Device Support

- Automatic device detection when only one device is connected
- Manual device selection via `ADB_SERIAL` parameter for multi-device scenarios
- Validation of specified device availability

### 3. Process Detection and Management

**Matching Pattern**: `^PACKAGE_NAME(:|_|$)`

This pattern matches:
| Process Name | Description |
|--------------|-------------|
| `com.xxx.yyy` | Main application process |
| `com.xxx.yyy:service` | Service subprocess (colon separator) |
| `com.xxx.yyy:media` | Media subprocess |
| `com.xxx.yyy_zygote` | Zygote-spawned subprocess (underscore separator) |

### 4. Residual Process Cleanup

Before testing begins, the script:
1. Detects any existing processes matching the package name
2. Attempts `force-stop` up to 3 times with increasing wait intervals
3. Prompts user if processes cannot be terminated

### 5. Interrupt Handling

- Graceful handling of `Ctrl+C` (SIGINT) and SIGTERM signals
- Automatic report generation with collected data upon interruption
- Prevents data loss during unexpected termination

---

## System Requirements

| Requirement | Details |
|-------------|---------|
| **Operating System** | macOS or Linux |
| **Shell** | Bash 3.2+ (compatible with older macOS) |
| **Android Device** | USB debugging enabled |
| **Tools** | `adb`, `bc`, `awk` |

---

## Command Options/Configuration Parameters

All configurable parameters are located at the top of the script:

### Basic Settings

| Command Option | Parameter | Type | Default | Description |
|----|-----------|------|---------|-------------|
| `(package_name)` | `PACKAGE_NAME` | String | `com.xxx.yyy` | Target application package name |
| `-a` | `ADB_SERIAL` | String | `""` (empty) | Device serial number (leave empty for auto-detection) |
| `-t` | `TEST_DURATION_MINUTES` | Integer | `5` | Test duration in minutes |

### Sampling Settings

The command option shared by CPU and Memory interval.
| Command Option | Parameter | Type | Default | Description |
|----|-----------|------|---------|-------------|
| `-i` | `CPU_INTERVAL` | Integer | `10` | CPU sampling interval in seconds |
| `-i` | `MEM_INTERVAL` | Integer | `10` | Memory sampling interval in seconds |

### CPU Collection Settings

| Command Option | Parameter | Type | Default | Description |
|----|-----------|------|---------|-------------|
| `-m` | `CPU_METHOD` | String | `procstat` | CPU collection method: `procstat` or `dumpsys` |
| NotDefined | `MIN_CPU_PERCENT` | Float | `0.0` | Minimum CPU% threshold for valid samples |
| NotDefined | `STRICT_WINDOW` | Integer | `1` | WindowMs parsing strictness (0=lenient, 1=strict) |
| `-s` | `SINGLE_CORE_DMIPS` | Integer | `20599` | DMIPS value per CPU core at 100% utilization |

### Debug Settings

| Command Option | Parameter | Type | Default | Description |
|-----|-----------|------|---------|-------------|
| `-d` | `DEBUG_MODE` | Integer | `0` | Enable verbose diagnostic output (0=off, 1=on) |

---

## CPU Collection Methods

### Method 1: `/proc/stat` (Recommended)

**Configuration**: `CPU_METHOD="procstat"`

This method reads raw CPU jiffies from the Linux kernel's `/proc/stat` interface and calculates CPU usage using precise time windows.

#### Algorithm

```
CPU% = 100 × NCPU × (ΔProcess_jiffies / ΔSystem_jiffies)
```

Where:
- `ΔProcess_jiffies` = Sum of (current - previous) CPU time for all matched PIDs
- `ΔSystem_jiffies` = Total system CPU time delta
- `NCPU` = Number of online CPU cores

#### Advantages
- ✅ Precise wall-clock time windows
- ✅ Accurate per-process CPU accounting
- ✅ Handles dynamic process creation/termination
- ✅ Consistent sampling intervals

#### Data Sources
- `/proc/stat` - System-wide CPU statistics
- `/proc/[PID]/stat` - Per-process CPU statistics
- `/sys/devices/system/cpu/online` - Online CPU core detection

---

### Method 2: `dumpsys cpuinfo` (Legacy)

**Configuration**: `CPU_METHOD="dumpsys"`

This method uses Android's built-in `dumpsys cpuinfo` command, which reports CPU usage within a sliding time window.

#### Window Validity

Samples are filtered based on the reported time window:
- **Valid Range**: 5000ms - 30000ms
- **Too Short** (<5000ms): Excluded from statistics
- **Too Long** (>30000ms): Excluded from statistics
- **Unknown** (-1): Controlled by `STRICT_WINDOW` setting

#### Output Parsing

The script parses lines matching the package name pattern:
```
12% 1234/com.xxx.yyy:service
8% 5678/com.xxx.yyy
```

---

### DMIPS Calculation

Both methods convert CPU percentage to DMIPS (Dhrystone Million Instructions Per Second) for cross-device comparison:

```
DMIPS = (CPU% × SINGLE_CORE_DMIPS) / 100
```

**Note**: DMIPS values are approximations for relative comparison, not absolute hardware measurements.

---

## Memory Collection

### Collection Method

The script uses `dumpsys meminfo [PID]` for each matched process, aggregating results across all subprocesses.

### Metrics Collected

| Metric | Description | Use Case |
|--------|-------------|----------|
| **PSS** (Proportional Set Size) | Actual memory usage with proportionally shared memory | Primary metric for memory analysis |
| **RSS** (Resident Set Size) | Physical memory usage including shared memory | Secondary metric, may overcount |

### Per-PID Aggregation

Unlike simple `dumpsys meminfo <package>` which may miss some subprocesses, this script:
1. Enumerates all PIDs matching the package pattern
2. Queries `dumpsys meminfo` for each PID individually
3. Aggregates PSS and RSS values across all processes

This ensures subprocesses with `:suffix` naming are never missed.

---

## Memory Leak Detection

### Algorithm

The script performs **linear regression** on PSS samples over time to detect memory growth trends.

### Calculation

```
slope = (n×Σxy - Σx×Σy) / (n×Σx² - (Σx)²)
```

Where:
- `x` = elapsed time in seconds
- `y` = PSS value in MB
- `n` = number of samples

### Thresholds

| Slope (MB/s) | Interpretation |
|--------------|----------------|
| `> 0.005` | **Possible Leak** (~300 MB/hour growth) |
| `-0.001` to `0.005` | **Stable** (no leak detected) |
| `< -0.001` | **Decreasing** (memory being released) |

### Output

The detection result includes:
- Growth rate (MB/second)
- Estimated growth over test duration
- Head-to-tail percentage change

---

## Output Files

The script creates a timestamped directory for each test run:

```
test_YYYYMMDD_HHMMSS/
├── cpu_log.csv      # CPU sampling data
├── mem_log.csv      # Memory sampling data
└── report.md        # Comprehensive test report
```

### CPU Log Format (`cpu_log.csv`)

| Column | Description |
|--------|-------------|
| Timestamp | Unix timestamp |
| Time(Seconds) | Elapsed seconds since test start |
| CPU Percentage(%) | Aggregated CPU usage across all processes |
| DMIPS | Calculated DMIPS value |
| WindowMs | Time window length in milliseconds |
| FilterReason | Sample validity status |

**FilterReason Values**:
- `Valid` - Sample included in statistics
- `Baseline` - Initial calibration sample
- `WindowTooShort` - Window < 5000ms (dumpsys only)
- `WindowTooLong` - Window > 30000ms (dumpsys only)
- `WindowUnknown` - Unable to parse window
- `NoPID` - No matching processes found
- `ReadFailed` - Failed to read /proc/stat

### Memory Log Format (`mem_log.csv`)

| Column | Description |
|--------|-------------|
| Timestamp | Unix timestamp |
| Time(Seconds) | Elapsed seconds since test start |
| TOTAL_RSS(KB) | Total RSS in kilobytes |
| RSS(MB) | Total RSS in megabytes |
| TOTAL_PSS(KB) | Total PSS in kilobytes |
| PSS(MB) | Total PSS in megabytes |

### Report Format (`report.md`)

The Markdown report includes:
- Test information (ID, package name, duration, status)
- CPU performance statistics (average, peak, minimum)
- Memory performance statistics (PSS and RSS)
- Sample analysis (valid/filtered counts, filter reasons)
- Memory leak detection results

---

## Technical Implementation

### Compatibility Features

1. **Bash 3.2 Compatible**: Uses file-based caching instead of associative arrays
2. **POSIX awk**: Avoids GNU awk-specific features for macOS compatibility
3. **Cross-platform**: Works on both macOS and Linux

### Process Parsing

The script handles various `ps` output formats:
- Dynamically identifies PID column position
- Handles `ps -A` and `ps` variants
- Strips carriage returns from Windows-style line endings

### Error Handling

- Validates all required parameters before starting
- Checks device connectivity and authorization
- Handles process disappearance during testing
- Prevents data loss on interruption

---

## Troubleshooting

### Common Issues

#### No Devices Detected

```bash
# Restart ADB server
adb kill-server && adb start-server

# Check USB debugging is enabled on device
```

#### Package Not Found

```bash
# Verify package name
adb shell pm list packages | grep <package_keyword>

# Check if app is installed
adb shell pm path <package_name>
```

#### CPU Always 0%

1. Ensure the app is actively running (not in background)
2. Check if `/proc/stat` is readable on device
3. Try switching to `dumpsys` method

#### Memory Parsing Fails

1. Enable DEBUG_MODE to see raw output
2. Check `dumpsys meminfo <PID>` format on your device
3. Some devices may have non-standard output formats

### Debug Mode

Enable verbose output:
```bash
DEBUG_MODE=1
```

This prints:
- Raw `ps` output and PID matching
- CPU jiffies calculation details
- Memory parsing intermediate values

---

## License

See [LICENSE](LICENSE) for details.

---

## Changelog

### Version 3.0
- Added dual CPU engine (procstat + dumpsys)
- Improved multi-process detection
- Enhanced memory leak detection algorithm
- Better cross-platform compatibility

---

**Happy Testing!** 🚀
