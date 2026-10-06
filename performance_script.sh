#!/bin/sh

# Usage:
#   ./performance_script.sh <test_name> <duration_seconds> [process_name ...]
#
# Examples:
#   ./performance_script.sh test_A 10
#   ./performance_script.sh test_A 60 com.example.app
#   ./performance_script.sh login_test 60 com.example.app com.example.service
#
# Environment overrides:
#   GPU_PATH=<file>   skip GPU detection, use the first number in this file
#   NET_IFACES="eth0 wlan0"   network interfaces to track (default: all
#                     non-loopback interfaces that are up and have traffic)
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
#   gpu_pct            GPU load (N/A if no supported GPU counter is readable)
#   temp_max_c         hottest thermal zone
#   temp_cpu_max_c     hottest zone whose type contains "cpu"
#   temp_gpu_max_c     hottest zone whose type contains "gpu"
#   <iface>_rx/tx_mbps network throughput per interface
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
# Detect GPU
#
# Tried in this order; the first GPU found decides the type.
# If nothing usable is found, gpu_pct is simply N/A.
#
#   1. kgsl     Qualcomm Adreno (SM8250, QCM6490, ...)
#               /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage
#   2. galcore  Vivante GPU with NXP driver (i.MX8)
#               /sys/kernel/debug/gc/idle (debugfs, needs root)
#   3. etnaviv  Vivante GPU with mainline driver: no load counter
#   4. none
#
# GPU_PATH=<file> skips detection and uses the first number in
# that file as the load.
# ------------------------------------------------------------

GPU_TYPE="none"
GPU_NOTE=""

gpu_readable()
{
    [ -r "$1" ] && grep -q '[0-9]' "$1" 2>/dev/null
}

detect_gpu()
{
    if [ -n "$GPU_PATH" ]; then
        if gpu_readable "$GPU_PATH"; then
            GPU_TYPE="file"
            GPU_NOTE="$GPU_PATH"
        else
            GPU_NOTE="GPU_PATH not readable: $GPU_PATH"
            GPU_PATH=""
        fi
        return
    fi

    # 1. Qualcomm Adreno
    if [ -d /sys/class/kgsl/kgsl-3d0 ]; then
        F=/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage

        if gpu_readable "$F"; then
            GPU_TYPE="kgsl"
            GPU_PATH="$F"
            GPU_NOTE="$F"
        else
            GPU_NOTE="kgsl found, but $F is not readable (root needed?)"
        fi
        return
    fi

    # 2. Vivante, NXP galcore driver
    if [ -e /dev/galcore ] || [ -d /sys/kernel/debug/gc ]; then
        F=/sys/kernel/debug/gc/idle

        # debugfs is often not mounted by default
        if [ ! -e "$F" ]; then
            mount -t debugfs none /sys/kernel/debug 2>/dev/null
        fi

        if gpu_readable "$F"; then
            GPU_TYPE="galcore"
            GPU_PATH="$F"
            GPU_NOTE="$F"
        else
            GPU_NOTE="galcore found, but $F is not readable (root + debugfs needed)"
        fi
        return
    fi

    # 3. Vivante, mainline etnaviv driver
    for D in /sys/class/drm/card*/device/driver; do
        [ -e "$D" ] || continue

        DRIVER=$(readlink "$D" 2>/dev/null)

        if [ "${DRIVER##*/}" = "etnaviv" ]; then
            GPU_NOTE="etnaviv found, no load counter available"
            return
        fi
    done

    # 4. Nothing known
    GPU_NOTE="no supported GPU found"
}

detect_gpu

# ------------------------------------------------------------
# Detect thermal zones
#
# Zones are grouped by their type name (cpu / gpu / other), so the
# CSV stays small even on SoCs with dozens of zones. Zones that
# cannot be read (disabled sensors) are skipped.
#
# Format passed to the sampler: "<temp_file>:<group> ..."
# ------------------------------------------------------------

THERMAL=""
THERMAL_COUNT=0

for ZONE in /sys/class/thermal/thermal_zone*; do
    grep -q '[0-9]' "$ZONE/temp" 2>/dev/null || continue

    TYPE=$(cat "$ZONE/type" 2>/dev/null)

    case "$TYPE" in
        *[Cc][Pp][Uu]*) GROUP=cpu ;;
        *[Gg][Pp][Uu]*) GROUP=gpu ;;
        *)              GROUP=other ;;
    esac

    THERMAL="$THERMAL $ZONE/temp:$GROUP"
    THERMAL_COUNT=$((THERMAL_COUNT + 1))
done

# ------------------------------------------------------------
# Detect network interfaces
#
# Default: every interface except lo that has already seen traffic
# and is not down. This skips the many unused virtual interfaces
# on Android (dummy0, sit0, ip6tnl0, ...).
# ------------------------------------------------------------

if [ -z "$NET_IFACES" ]; then
    for IFACE in $(awk '
        {
            c = index($0, ":")

            if (c == 0)
                next

            name = substr($0, 1, c - 1)
            gsub(/ /, "", name)

            split(substr($0, c + 1), f, " ")

            if (name != "lo" && f[1] + f[9] > 0)
                print name
        }
    ' /proc/net/dev 2>/dev/null); do

        STATE=$(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null)

        if [ "$STATE" != "down" ]; then
            NET_IFACES="$NET_IFACES $IFACE"
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
# /proc/uptime, /proc/stat, /proc/meminfo, the GPU file, thermal
# zones, /proc/net/dev and
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
#        p<I>=<pid>:<starttime>:<ticks> n<I>=<rx>:<tx>
#        g=<start>:<on>:<total> (galcore)
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

# galcore /sys/kernel/debug/gc/idle lists how long the GPU spent in
# each power state:
#   Start: <t>  End: <t>  On: <t>  Off: <t>  Idle: <t>  Suspend: <t>
# Load = On / (On + Off + Idle + Suspend).
#
# Depending on the driver version the counters either restart on
# every read or keep growing. If "Start" stays the same between two
# reads they keep growing and the difference is used; otherwise the
# values already cover just the last interval.
#
# Without a "Start" line, nanoseconds are assumed: values that add up
# to more than 3 intervals are treated as growing counters.

function galcore_pct(    line, key, num, g_start, g_on, g_total, pv, d_on, d_total, growing)
{
    g_start = ""
    g_on = 0
    g_total = 0

    while ((getline line < gpu) > 0) {
        if (!match(line, /[0-9]+/))
            continue

        num = substr(line, RSTART, RLENGTH) + 0

        key = line
        sub(/:.*/, "", key)
        gsub(/[ \t]/, "", key)

        if (key == "Start")
            g_start = num
        else if (key == "On") {
            g_on = num
            g_total += num
        } else if (key == "Off" || key == "Idle" || key == "Suspend")
            g_total += num
    }

    close(gpu)

    if (g_total <= 0)
        return "N/A"

    state = state " g=" g_start ":" g_on ":" g_total

    if (first)
        return "N/A"

    if (g_start != "")
        growing = (("g" in P) && index(P["g"], g_start ":") == 1)
    else
        growing = (g_total > 3 * dt_ms * 1000000)

    if (!growing)
        return fmt(g_on * 100 / g_total)

    if (!("g" in P))
        return "N/A"

    split(P["g"], pv, ":")

    d_on = g_on - pv[2]
    d_total = g_total - pv[3]

    if (d_total <= 0 || d_on < 0)
        return "N/A"

    return fmt(d_on * 100 / d_total)
}

# Returns "<max>,<cpu max>,<gpu max>" in degrees C.
# Most kernels report millidegrees, some report degrees.

function read_temps(    nt, tz, i, c, file, grp, line, v, t_max, t_cpu, t_gpu)
{
    t_max = t_cpu = t_gpu = -999

    nt = split(thermal, tz, " ")

    for (i = 1; i <= nt; i++) {
        c = index(tz[i], ":")
        file = substr(tz[i], 1, c - 1)
        grp = substr(tz[i], c + 1)

        line = read_line(file)

        if (line !~ /^-?[0-9]+/)
            continue

        v = line + 0

        if (v > 1000 || v < -1000)
            v = v / 1000

        # Disconnected sensors often report nonsense values
        if (v < -40 || v > 200)
            continue

        if (v > t_max)
            t_max = v

        if (grp == "cpu" && v > t_cpu)
            t_cpu = v

        if (grp == "gpu" && v > t_gpu)
            t_gpu = v
    }

    return temp_fmt(t_max) "," temp_fmt(t_cpu) "," temp_fmt(t_gpu)
}

function temp_fmt(v)
{
    return v == -999 ? "N/A" : sprintf("%.1f", v)
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
    if (only_temps) {
        print read_temps()
        exit
    }

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

    if (gpu_type == "galcore") {
        gpu_val = galcore_pct()
    } else if (gpu != "") {
        line = read_line(gpu)

        if (match(line, /[0-9]+(\.[0-9]+)?/))
            gpu_val = substr(line, RSTART, RLENGTH)
    }

    csv = csv "," gpu_val

    # --------------------------------------------------------
    # Temperature
    # --------------------------------------------------------

    csv = csv "," read_temps()

    # --------------------------------------------------------
    # Network
    #
    # /proc/net/dev: "<iface>: rx_bytes ... (8 fields) tx_bytes ..."
    # Old kernels may omit the space after the colon.
    # --------------------------------------------------------

    while ((getline line < "/proc/net/dev") > 0) {
        c = index(line, ":")

        if (c == 0)
            continue

        name = substr(line, 1, c - 1)
        gsub(/ /, "", name)

        split(substr(line, c + 1), f, " ")

        RX[name] = f[1]
        TX[name] = f[9]
    }

    close("/proc/net/dev")

    ni = split(ifaces, if_list, " ")

    for (i = 1; i <= ni; i++) {
        name = if_list[i]
        key = "n" i

        rx = "N/A"
        tx = "N/A"

        if (name in RX) {
            if (!first && (key in P) && dt_ms > 0) {
                split(P[key], pv, ":")

                # Negative difference: counter reset or wrapped
                if (RX[name] >= pv[1])
                    rx = sprintf("%.3f", (RX[name] - pv[1]) * 8 / (dt_ms * 1000))

                if (TX[name] >= pv[2])
                    tx = sprintf("%.3f", (TX[name] - pv[2]) * 8 / (dt_ms * 1000))
            }

            state = state " " key "=" RX[name] ":" TX[name]
        }

        csv = csv "," rx "," tx
    }

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
        -v gpu_type="$GPU_TYPE" \
        -v thermal="$THERMAL" \
        -v ifaces="$NET_IFACES" \
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
HEADER="$HEADER,temp_max_c,temp_cpu_max_c,temp_gpu_max_c"

for IFACE in $NET_IFACES; do
    HEADER="$HEADER,${IFACE}_rx_mbps,${IFACE}_tx_mbps"
done

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
echo "GPU       : $GPU_TYPE ($GPU_NOTE)"
echo "Network   : ${NET_IFACES:- none}"

if [ "$THERMAL_COUNT" -gt 0 ]; then
    TEMPS=$(awk -v only_temps=1 -v thermal="$THERMAL" "$SAMPLE_AWK" </dev/null)

    echo "Thermal   : $THERMAL_COUNT zones"
    echo "Temp now  : max ${TEMPS%%,*} C (cpu/gpu max: $(echo "${TEMPS#*,}" | tr ',' '/') C)"
else
    echo "Thermal   : none"
fi

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

        if (cnt[i] == 1) {
            min[i] = v
            first[i] = v
        }

        last[i] = v

        if (v < min[i])
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

    # first/last show the trend, e.g. start vs end temperature
    printf "%-40s %9s %9s %9s %9s %9s %8s\n", \
        "metric", "avg", "min", "max", "first", "last", "samples"

    for (i = 4; i <= cols; i++) {
        if (cnt[i] == 0)
            printf "%-40s %9s %9s %9s %9s %9s %8d\n", name[i], \
                "N/A", "N/A", "N/A", "N/A", "N/A", 0
        else
            printf "%-40s %9.2f %9.2f %9.2f %9.2f %9.2f %8d\n", name[i], \
                sum[i] / cnt[i], min[i], max[i], first[i], last[i], cnt[i]
    }
}
' "$OUT"

echo
echo "Saved to: $OUT"
