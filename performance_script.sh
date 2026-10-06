#!/usr/bin/sh

# Usage:
#   ./performance_script.sh <test_name> <duration_seconds> [process_name ...]
#
# Examples:
#   ./performance_script.sh test_A 10
#   ./performance_script.sh test_A 60 com.example.app
#   ./performance_script.sh login_test 60 com.example.app com.example.service
#
# Environment overrides:
#   GPU_PATH=<file>   sysfs file with GPU load (first number in it is used)
#
# Output:
#   <test_name>_YYYYMMDD_HHMMSS.csv
#
# Columns:
#   time               wall clock of the sample
#   elapsed_ms         time since the baseline snapshot
#   interval_ms        actual time since the previous sample
#   cpu_total_pct      whole system CPU load
#   cpuN_pct           per-core load (N/A while the core is offline)
#   ram_used_pct/_mb   MemTotal - MemAvailable
#   gpu_pct            GPU load (N/A if no known GPU file is readable)
#   <proc>_cpu_pct     process CPU as % of the whole system (max 100)
#   <proc>_cpu_core_pct  process CPU as % of one core, like `top` (max N*100)
#   <proc>_rss_mb      process resident memory (VmRSS)
#
# Process values are N/A while the process is not running. Missing
# processes are looked up again on every sample, so a restarted app
# is picked up automatically under its new PID.

INTERVAL_MS=1000

usage()
{
    echo "Usage: $0 <test_name> <duration_seconds> [process_name ...]"
}

if [ "$#" -lt 2 ]; then
    usage
    exit 1
fi

TEST_NAME="$1"
DURATION="$2"
shift 2

case "$DURATION" in
    ''|*[!0-9]*)
        echo "ERROR: duration must be a positive integer (seconds), got: $DURATION"
        exit 1
        ;;
esac

if [ "$DURATION" -le 0 ]; then
    echo "ERROR: duration must be greater than 0"
    exit 1
fi

OUT="${TEST_NAME}_$(date +%Y%m%d_%H%M%S).csv"

NL='
'

# ------------------------------------------------------------
# Clock ticks per second (USER_HZ), used for per-core process %
# ------------------------------------------------------------

HZ=$(getconf CLK_TCK 2>/dev/null)

case "$HZ" in
    ''|*[!0-9]*|0) HZ=100 ;;
esac

# ------------------------------------------------------------
# Detect CPU cores
#
# Use the "possible" list, not the lines in /proc/stat: offline
# cores disappear from /proc/stat, and core numbers are not always
# contiguous (e.g. 0-3,6-7).
# ------------------------------------------------------------

CORES=$(awk '
    {
        n = split($0, part, ",")

        for (i = 1; i <= n; i++) {
            if (split(part[i], r, "-") == 2) {
                for (c = r[1]; c <= r[2]; c++)
                    printf "%d ", c
            } else if (part[i] != "") {
                printf "%d ", part[i]
            }
        }
    }
' /sys/devices/system/cpu/possible 2>/dev/null)

if [ -z "$CORES" ]; then
    CORES=$(awk '
        /^cpu[0-9]+ / {
            printf "%s ", substr($1, 4)
        }
    ' /proc/stat)
fi

if [ -z "$CORES" ]; then
    echo "ERROR: Could not detect CPU cores."
    exit 1
fi

CPU_COUNT=0

for C in $CORES; do
    CPU_COUNT=$((CPU_COUNT + 1))
done

# ------------------------------------------------------------
# Detect GPU load file
#
#   Qualcomm Adreno : /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage
#   Samsung Exynos  : /sys/kernel/gpu/gpu_busy
#   MediaTek        : /sys/kernel/ged/hal/gpu_utilization
#
# Most of these need root on recent Android versions (SELinux).
# ------------------------------------------------------------

gpu_readable()
{
    [ -r "$1" ] && grep -q '[0-9]' "$1" 2>/dev/null
}

if [ -n "$GPU_PATH" ]; then
    if ! gpu_readable "$GPU_PATH"; then
        echo "WARNING: GPU_PATH is not readable: $GPU_PATH"
        GPU_PATH=""
    fi
else
    for CANDIDATE in \
        /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage \
        /sys/kernel/gpu/gpu_busy \
        /sys/kernel/ged/hal/gpu_utilization; do

        if gpu_readable "$CANDIDATE"; then
            GPU_PATH="$CANDIDATE"
            break
        fi
    done
fi

# ------------------------------------------------------------
# Find PID by process name
#
# Prefer pidof (toybox on Android, procps on Linux). The fallback
# scans /proc and compares argv[0] or its basename.
# ------------------------------------------------------------

if command -v pidof >/dev/null 2>&1; then
    HAVE_PIDOF=1
else
    HAVE_PIDOF=0
fi

find_pid()
{
    if [ "$HAVE_PIDOF" -eq 1 ]; then
        pidof -s "$1" 2>/dev/null
        return
    fi

    for DIR in /proc/[0-9]*; do
        [ -r "$DIR/cmdline" ] || continue

        ARG0=$(tr '\000' '\n' < "$DIR/cmdline" 2>/dev/null | head -n 1)

        if [ "$ARG0" = "$1" ] || [ "${ARG0##*/}" = "$1" ]; then
            echo "${DIR#/proc/}"
            return
        fi
    done
}

# ------------------------------------------------------------
# Store process names
# ------------------------------------------------------------

PROCESS_COUNT=$#

INDEX=1

for PROCESS in "$@"; do
    eval "PROCESS_NAME_$INDEX=\"\$PROCESS\""
    eval "PROCESS_PID_$INDEX=0"

    INDEX=$((INDEX + 1))
done

# ------------------------------------------------------------
# Look up every process that currently has no PID and rebuild
# the PID list passed to the sampler.
# ------------------------------------------------------------

resolve_pids()
{
    PIDS=""

    I=1

    while [ "$I" -le "$PROCESS_COUNT" ]; do
        eval "PID=\$PROCESS_PID_$I"

        if [ "$PID" -eq 0 ]; then
            eval "PROCESS=\$PROCESS_NAME_$I"

            PID=$(find_pid "$PROCESS")

            case "$PID" in
                ''|*[!0-9]*) PID=0 ;;
            esac

            if [ "$PID" -gt 0 ]; then
                echo "Process found: $PROCESS -> PID $PID"
            fi

            eval "PROCESS_PID_$I=\$PID"
        fi

        PIDS="$PIDS $PID"

        I=$((I + 1))
    done
}

# ------------------------------------------------------------
# Sampler
#
# One awk run per sample reads everything at the same moment:
# /proc/uptime, /proc/stat, /proc/meminfo, the GPU file and
# /proc/<pid>/stat + status for each process. This keeps the
# script's own CPU usage (and its effect on the numbers) low.
#
# The previous snapshot is passed in as "prev" and the new one is
# returned, so the shell only has to keep one string.
#
# Output (3 lines):
#   1. <elapsed_ms> <sleep_seconds> [lost process indexes ...]
#   2. CSV line without the time column ("-" for the baseline)
#   3. new state
#
# State: start=<ms> t=<ms> call=<total>:<idle> c<N>=<total>:<idle>
#        p<I>=<pid>:<starttime>:<ticks>
# ------------------------------------------------------------

SAMPLE_AWK='
function fmt(x)
{
    return sprintf("%.2f", x)
}

function read_line(file,    line)
{
    line = ""

    if ((getline line < file) <= 0)
        line = ""

    close(file)

    return line
}

# /proc/stat line:
#   cpu user nice system idle iowait irq softirq steal guest guest_nice
# guest and guest_nice are already included in user and nice, so
# only fields 2..9 are summed.

function busy_pct(key,    pv, dt, di, p)
{
    if (first || !(key in CT) || !(key in P))
        return "N/A"

    split(P[key], pv, ":")

    dt = CT[key] - pv[1]
    di = CI[key] - pv[2]

    if (dt <= 0)
        return "N/A"

    p = (dt - di) * 100 / dt

    if (p < 0)
        p = 0

    if (p > 100)
        p = 100

    return fmt(p)
}

function read_rss(pid,    file, line, f, rss)
{
    file = "/proc/" pid "/status"
    rss = "N/A"

    while ((getline line < file) > 0) {
        split(line, f, " ")

        if (f[1] == "VmRSS:") {
            rss = fmt(f[2] / 1024)
            break
        }
    }

    close(file)

    return rss
}

BEGIN {
    n = split(prev, kv, " ")

    for (i = 1; i <= n; i++) {
        eq = index(kv[i], "=")

        if (eq > 0)
            P[substr(kv[i], 1, eq - 1)] = substr(kv[i], eq + 1)
    }

    first = !("t" in P)

    # --------------------------------------------------------
    # Time
    # --------------------------------------------------------

    split(read_line("/proc/uptime"), up, " ")

    now = int(up[1] * 1000 + 0.5)
    start = first ? now : P["start"] + 0
    dt_ms = first ? 0 : now - P["t"]

    state = "start=" start " t=" now

    # --------------------------------------------------------
    # CPU
    # --------------------------------------------------------

    while ((getline line < "/proc/stat") > 0) {
        if (substr(line, 1, 3) != "cpu")
            break

        nf = split(line, f, " ")
        last = nf < 9 ? nf : 9

        total = 0

        for (i = 2; i <= last; i++)
            total += f[i]

        idle = f[5] + f[6]

        key = (f[1] == "cpu") ? "call" : "c" substr(f[1], 4)

        CT[key] = total
        CI[key] = idle

        state = state " " key "=" total ":" idle
    }

    close("/proc/stat")

    csv = (now - start) "," dt_ms "," busy_pct("call")

    nc = split(cores, core_list, " ")

    for (i = 1; i <= nc; i++)
        csv = csv "," busy_pct("c" core_list[i])

    # --------------------------------------------------------
    # RAM
    # --------------------------------------------------------

    mem_total = 0
    mem_avail = -1
    mem_fallback = 0

    while ((getline line < "/proc/meminfo") > 0) {
        split(line, f, " ")

        if (f[1] == "MemTotal:")
            mem_total = f[2]
        else if (f[1] == "MemAvailable:")
            mem_avail = f[2]
        else if (f[1] == "MemFree:" || f[1] == "Buffers:")
            mem_fallback += f[2]
        else if (f[1] == "Cached:") {
            mem_fallback += f[2]
            break
        }
    }

    close("/proc/meminfo")

    # Kernels older than 3.14 have no MemAvailable
    if (mem_avail < 0)
        mem_avail = mem_fallback

    if (mem_total > 0)
        csv = csv "," fmt((mem_total - mem_avail) * 100 / mem_total) \
                  "," fmt((mem_total - mem_avail) / 1024)
    else
        csv = csv ",N/A,N/A"

    # --------------------------------------------------------
    # GPU
    # --------------------------------------------------------

    gpu_val = "N/A"

    if (gpu != "") {
        line = read_line(gpu)

        if (match(line, /[0-9]+(\.[0-9]+)?/))
            gpu_val = substr(line, RSTART, RLENGTH)
    }

    csv = csv "," gpu_val

    # --------------------------------------------------------
    # Processes
    #
    # /proc/<pid>/stat: comm can contain spaces and parentheses,
    # so split after the last ") ". After that, f[k] is field k+2:
    #   f[12] = utime, f[13] = stime, f[20] = starttime
    #
    # starttime identifies the process: if it changes for the same
    # PID, the PID was reused by another process.
    # --------------------------------------------------------

    dt_all = 0

    if (!first && ("call" in P)) {
        split(P["call"], pv, ":")
        dt_all = CT["call"] - pv[1]
    }

    lost = ""

    np = split(pids, pid_list, " ")

    for (i = 1; i <= np; i++) {
        pid = pid_list[i]
        key = "p" i

        cpu = "N/A"
        core = "N/A"
        rss = "N/A"

        if (pid > 0) {
            line = read_line("/proc/" pid "/stat")

            end = 0

            for (j = length(line) - 1; j > 0; j--) {
                if (substr(line, j, 2) == ") ") {
                    end = j
                    break
                }
            }

            if (end == 0) {
                lost = lost " " i
            } else {
                split(substr(line, end + 2), sf, " ")

                ticks = sf[12] + sf[13]
                started = sf[20]

                reused = 0

                if (key in P) {
                    split(P[key], pp, ":")

                    if (pp[1] == pid && pp[2] != started) {
                        reused = 1
                    } else if (pp[1] == pid) {
                        d = ticks - pp[3]

                        if (d >= 0 && dt_all > 0)
                            cpu = fmt(d * 100 / dt_all)

                        if (d >= 0 && dt_ms > 0)
                            core = fmt(d * 100 * 1000 / (hz * dt_ms))
                    }
                }

                if (reused) {
                    lost = lost " " i
                } else {
                    state = state " " key "=" pid ":" started ":" ticks
                    rss = read_rss(pid)
                }
            }
        }

        csv = csv "," cpu "," core "," rss
    }

    # --------------------------------------------------------
    # Next sample is aligned to start + k * interval, so the
    # time spent sampling does not accumulate as drift. If we are
    # too late for the next slot, skip to the one after it.
    # --------------------------------------------------------

    slot = int((now - start) / interval) + 1
    wait = start + slot * interval - now

    if (wait < interval / 5)
        wait += interval

    print (now - start), sprintf("%.3f", wait / 1000) lost
    print (first ? "-" : csv)
    print state
}
'

STATE=""

sample()
{
    RESULT=$(awk \
        -v prev="$STATE" \
        -v cores="$CORES" \
        -v pids="$PIDS" \
        -v gpu="$GPU_PATH" \
        -v hz="$HZ" \
        -v interval="$INTERVAL_MS" \
        "$SAMPLE_AWK" </dev/null)

    case "$RESULT" in
        *"$NL"*"$NL"*) ;;
        *) return 1 ;;
    esac

    CTRL=${RESULT%%"$NL"*}
    REST=${RESULT#*"$NL"}
    LINE=${REST%%"$NL"*}
    STATE=${REST#*"$NL"}

    set -- $CTRL

    ELAPSED="$1"
    SLEEP="$2"
    shift 2

    # Processes that exited (or whose PID was reused) are looked
    # up again before the next sample.
    for I in "$@"; do
        eval "PROCESS=\$PROCESS_NAME_$I"
        eval "PROCESS_PID_$I=0"

        echo "WARNING: Process lost: $PROCESS"
    done

    return 0
}

# ------------------------------------------------------------
# CSV header
# ------------------------------------------------------------

HEADER="time,elapsed_ms,interval_ms,cpu_total_pct"

for C in $CORES; do
    HEADER="$HEADER,cpu${C}_pct"
done

HEADER="$HEADER,ram_used_pct,ram_used_mb,gpu_pct"

I=1

while [ "$I" -le "$PROCESS_COUNT" ]; do
    eval "PROCESS=\$PROCESS_NAME_$I"

    # Keep the CSV valid even if the name contains commas etc.
    SAFE=$(printf '%s' "$PROCESS" | tr -c 'A-Za-z0-9._:-' '_')

    HEADER="$HEADER,${SAFE}_cpu_pct,${SAFE}_cpu_core_pct,${SAFE}_rss_mb"

    I=$((I + 1))
done

if ! echo "$HEADER" > "$OUT"; then
    echo "ERROR: Cannot write to $OUT"
    exit 1
fi

# ------------------------------------------------------------
# Print configuration
# ------------------------------------------------------------

echo "================================"
echo "Performance test"
echo "================================"
echo "Test name : $TEST_NAME"
echo "Duration  : ${DURATION}s"
echo "Interval  : ${INTERVAL_MS}ms"
echo "CPUs      : $CPU_COUNT ($CORES)"
echo "GPU       : ${GPU_PATH:-N/A}"
echo "Output    : $OUT"

if [ "$PROCESS_COUNT" -gt 0 ]; then
    echo "Processes :"

    I=1

    while [ "$I" -le "$PROCESS_COUNT" ]; do
        eval "PROCESS=\$PROCESS_NAME_$I"
        echo "  $PROCESS"
        I=$((I + 1))
    done
fi

echo

# ------------------------------------------------------------
# Baseline snapshot (not written to CSV)
# ------------------------------------------------------------

STOP=0
trap 'STOP=1' INT TERM HUP

resolve_pids

I=1

while [ "$I" -le "$PROCESS_COUNT" ]; do
    eval "PID=\$PROCESS_PID_$I"

    if [ "$PID" -eq 0 ]; then
        eval "PROCESS=\$PROCESS_NAME_$I"
        echo "WARNING: Process not found (will keep looking): $PROCESS"
    fi

    I=$((I + 1))
done

if ! sample; then
    echo "ERROR: Baseline sample failed."
    exit 1
fi

echo
echo "Starting... (Ctrl+C stops early and still prints the summary)"
echo

# ------------------------------------------------------------
# Sampling loop
# ------------------------------------------------------------

DURATION_MS=$((DURATION * 1000))

while [ "$STOP" -eq 0 ]; do

    sleep "$SLEEP"

    [ "$STOP" -eq 1 ] && break

    resolve_pids

    TIME=$(date '+%Y-%m-%d %H:%M:%S')

    if ! sample; then
        # Interrupted in the middle of a sample
        break
    fi

    [ "$STOP" -eq 1 ] && break

    echo "$TIME,$LINE" >> "$OUT"
    echo "$TIME,$LINE"

    if [ $((ELAPSED + INTERVAL_MS / 2)) -ge "$DURATION_MS" ]; then
        break
    fi
done

trap - INT TERM HUP

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

echo
echo "================================"
echo "Summary"
echo "================================"

awk -F',' '
NR == 1 {
    for (i = 1; i <= NF; i++)
        name[i] = $i

    cols = NF
    next
}

{
    n++
    elapsed = $2
    interval_sum += $3

    for (i = 4; i <= cols; i++) {
        if ($i == "N/A" || $i == "")
            continue

        v = $i + 0

        cnt[i]++
        sum[i] += v

        if (cnt[i] == 1 || v < min[i])
            min[i] = v

        if (cnt[i] == 1 || v > max[i])
            max[i] = v
    }
}

END {
    if (n == 0) {
        print "No samples."
        exit
    }

    printf "Samples      : %d\n", n
    printf "Measured     : %.3fs\n", elapsed / 1000
    printf "Avg interval : %.0f ms\n", interval_sum / n
    print ""

    printf "%-40s %9s %9s %9s %8s\n", "metric", "avg", "min", "max", "samples"

    for (i = 4; i <= cols; i++) {
        if (cnt[i] == 0)
            printf "%-40s %9s %9s %9s %8d\n", name[i], "N/A", "N/A", "N/A", 0
        else
            printf "%-40s %9.2f %9.2f %9.2f %8d\n", name[i], \
                sum[i] / cnt[i], min[i], max[i], cnt[i]
    }
}
' "$OUT"

echo
echo "Saved to: $OUT"
