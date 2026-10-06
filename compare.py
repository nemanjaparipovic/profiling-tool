#!/usr/bin/env python3
"""
Compare results of performance_script.sh: baseline (A) vs candidate (B).

Usage:
    compare.py A.csv B.csv
    compare.py -a off_1.csv off_2.csv -b on_1.csv on_2.csv
    compare.py -a 'call_off_*.csv' -b 'call_on_*.csv' --labels "no session" "session"

Options:
    --skip SEC          drop the first SEC seconds of every run (warm-up)
    --labels A B        names for the two groups in the output
    --csv FILE          also write the comparison table to FILE
    --all               also show metrics that are 0 in every sample

Each group can hold several runs of the same test case. The group value
is the average of the per-run averages, so every run counts the same.
With 2+ runs per group, a difference smaller than the spread between
runs of the same group is marked "~noise".
"""

import argparse
import csv
import glob
import re
import sys

NON_METRIC = {"time", "elapsed_ms", "interval_ms"}

# Start temperatures further apart than this make the comparison unfair
TEMP_WARN_C = 3.0

# Durations differing more than this (relative) get a warning
DURATION_WARN = 0.2

PROCESS_SUFFIXES = ("_cpu_core_pct", "_cpu_pct", "_rss_mb")


# ------------------------------------------------------------
# Loading
# ------------------------------------------------------------

class Run:
    def __init__(self, path, skip_s):
        self.path = path
        self.columns = []
        self.values = {}
        self.samples = 0
        self.duration_s = 0.0
        self.avg_interval_ms = None

        with open(path, newline="") as f:
            reader = csv.reader(f)
            header = next(reader, None)

            if not header:
                raise ValueError("empty file")

            self.columns = [c for c in header if c not in NON_METRIC]
            self.values = {c: [] for c in self.columns}

            # Old script versions had no interval_ms and used elapsed_ms
            # for the interval; fall back to 1 sample = 1 second there.
            new_format = "interval_ms" in header

            elapsed_first = None
            elapsed_last = None
            intervals = []

            for index, row in enumerate(reader):
                if len(row) != len(header):
                    continue

                record = dict(zip(header, row))

                if new_format:
                    elapsed = to_float(record.get("elapsed_ms"))
                    elapsed_s = elapsed / 1000 if elapsed is not None else index + 1
                else:
                    elapsed_s = index + 1

                if elapsed_s <= skip_s:
                    continue

                if elapsed_first is None:
                    elapsed_first = elapsed_s
                elapsed_last = elapsed_s

                if new_format:
                    interval = to_float(record.get("interval_ms"))
                    if interval is not None:
                        intervals.append(interval)

                for c in self.columns:
                    v = to_float(record[c])
                    if v is not None:
                        self.values[c].append(v)

                self.samples += 1

            if self.samples:
                # Each sample covers the interval before it
                first_interval = intervals[0] / 1000 if intervals else 1.0
                self.duration_s = elapsed_last - elapsed_first + first_interval

            if intervals:
                self.avg_interval_ms = sum(intervals) / len(intervals)

    def first(self, column):
        values = self.values.get(column)
        return values[0] if values else None


def to_float(text):
    if text is None:
        return None

    text = text.strip()

    if text in ("", "N/A", "-"):
        return None

    try:
        return float(text)
    except ValueError:
        return None


def expand(patterns):
    paths = []

    for p in patterns:
        matches = sorted(glob.glob(p))
        paths.extend(matches if matches else [p])

    return paths


def load_group(patterns, skip_s):
    runs = []

    for path in expand(patterns):
        try:
            run = Run(path, skip_s)
        except (OSError, ValueError) as e:
            sys.exit("ERROR: cannot read %s: %s" % (path, e))

        if run.samples == 0:
            print("WARNING: no samples left in %s (after --skip)" % path,
                  file=sys.stderr)
            continue

        runs.append(run)

    return runs


# ------------------------------------------------------------
# Statistics
# ------------------------------------------------------------

def mean(values):
    return sum(values) / len(values)


def percentile(values, pct):
    data = sorted(values)

    if len(data) == 1:
        return data[0]

    pos = (len(data) - 1) * pct / 100
    low = int(pos)
    high = min(low + 1, len(data) - 1)

    return data[low] + (data[high] - data[low]) * (pos - low)


class GroupStat:
    """Statistics of one metric over all runs of one group."""

    def __init__(self, runs, column):
        run_means = []
        pooled = []

        for run in runs:
            values = run.values.get(column)
            if values:
                run_means.append(mean(values))
                pooled.extend(values)

        self.present = any(column in run.values for run in runs)
        self.has_data = bool(pooled)

        if self.has_data:
            self.avg = mean(run_means)
            self.p95 = percentile(pooled, 95)
            self.max = max(pooled)
            self.all_zero = all(v == 0 for v in pooled)
            self.spread = (max(run_means) - min(run_means)
                           if len(run_means) >= 2 else None)
        else:
            self.avg = self.p95 = self.max = self.spread = None
            self.all_zero = True


# ------------------------------------------------------------
# Grouping metrics into sections
# ------------------------------------------------------------

def classify(column):
    """Return (section, display name) for a CSV column."""

    if re.match(r"^(cpu_total_pct|cpu\d+_pct|total_cpu|cpu\d+)$", column):
        return "CPU", column

    if column.startswith("ram_"):
        return "Memory", column

    if column.startswith("gpu_"):
        return "GPU", column

    if column.startswith("temp_"):
        return "Temperature", column

    if re.search(r"_(rx|tx)_mbps$", column):
        return "Network", column

    for suffix in PROCESS_SUFFIXES:
        if column.endswith(suffix):
            return "Process: " + column[:-len(suffix)], suffix[1:]

    # Old script versions: process_<name>
    if column.startswith("process_"):
        return "Process: " + column[len("process_"):], "cpu_pct"

    return "Other", column


SECTION_ORDER = ["CPU", "Memory", "GPU", "Temperature", "Network"]


def section_key(section):
    if section in SECTION_ORDER:
        return (SECTION_ORDER.index(section), "")
    if section.startswith("Process: "):
        return (len(SECTION_ORDER), section)
    return (len(SECTION_ORDER) + 1, section)


# ------------------------------------------------------------
# Output
# ------------------------------------------------------------

def decimals(column):
    return 3 if column.endswith("_mbps") else 2


def fmt(value, digits, sign=False):
    if value is None:
        return "-"
    # Avoid "-0.000"
    if round(value, digits) == 0:
        value = 0.0
    return ("%+.*f" if sign else "%.*f") % (digits, value)


def print_runs(label, runs, temp_column):
    print("%s: %d run(s)" % (label, len(runs)))

    for run in runs:
        start_temp = run.first(temp_column) if temp_column else None
        interval = ("%.0f ms" % run.avg_interval_ms
                    if run.avg_interval_ms is not None else "-")

        print("    %-40s %4d samples  %7.1f s  interval %-7s  start temp %s"
              % (run.path, run.samples, run.duration_s, interval,
                 fmt(start_temp, 1) + " C" if start_temp is not None else "-"))


def check_fairness(runs_a, runs_b, temp_column):
    warnings = []

    if temp_column:
        temps_a = [run.first(temp_column) for run in runs_a]
        temps_b = [run.first(temp_column) for run in runs_b]
        temps_a = [t for t in temps_a if t is not None]
        temps_b = [t for t in temps_b if t is not None]

        if temps_a and temps_b:
            diff = mean(temps_b) - mean(temps_a)

            if abs(diff) > TEMP_WARN_C:
                warnings.append(
                    "start temperature differs by %.1f C (A %.1f, B %.1f): "
                    "let the device cool down between runs"
                    % (diff, mean(temps_a), mean(temps_b)))

    dur_a = mean([run.duration_s for run in runs_a])
    dur_b = mean([run.duration_s for run in runs_b])

    if max(dur_a, dur_b) > 0 and \
            abs(dur_a - dur_b) / max(dur_a, dur_b) > DURATION_WARN:
        warnings.append("run durations differ (A %.0f s, B %.0f s)"
                        % (dur_a, dur_b))

    return warnings


def main():
    parser = argparse.ArgumentParser(
        description="Compare performance_script.sh CSV results (A = baseline, B = candidate).")
    parser.add_argument("files", nargs="*",
                        help="shortcut for one run per group: A.csv B.csv")
    parser.add_argument("-a", nargs="+", default=[], metavar="CSV",
                        help="baseline runs (files or glob patterns)")
    parser.add_argument("-b", nargs="+", default=[], metavar="CSV",
                        help="candidate runs (files or glob patterns)")
    parser.add_argument("--skip", type=float, default=0, metavar="SEC",
                        help="drop the first SEC seconds of every run")
    parser.add_argument("--labels", nargs=2, default=["A", "B"],
                        metavar=("A", "B"), help="names of the two groups")
    parser.add_argument("--csv", metavar="FILE",
                        help="also write the comparison table to FILE")
    parser.add_argument("--all", action="store_true",
                        help="also show metrics that are 0 in every sample")
    args = parser.parse_args()

    patterns_a = list(args.a)
    patterns_b = list(args.b)

    if args.files:
        if len(args.files) != 2 or patterns_a or patterns_b:
            parser.error("use either 'A.csv B.csv' or -a ... -b ...")
        patterns_a = [args.files[0]]
        patterns_b = [args.files[1]]

    if not patterns_a or not patterns_b:
        parser.error("need baseline (A) and candidate (B) runs")

    runs_a = load_group(patterns_a, args.skip)
    runs_b = load_group(patterns_b, args.skip)

    if not runs_a or not runs_b:
        sys.exit("ERROR: one of the groups has no usable runs")

    label_a, label_b = args.labels

    # Union of columns, in order of first appearance
    columns = []
    for run in runs_a + runs_b:
        for c in run.columns:
            if c not in columns:
                columns.append(c)

    temp_column = next((c for c in ("temp_max_c", "temp_cpu_max_c")
                        if c in columns), None)

    # --------------------------------------------------------
    # Header
    # --------------------------------------------------------

    print("A = %s" % label_a)
    print("B = %s" % label_b)
    if args.skip:
        print("Skipped first %g s of every run" % args.skip)
    print()
    print_runs("A", runs_a, temp_column)
    print_runs("B", runs_b, temp_column)

    for label, runs in ((label_a, runs_a), (label_b, runs_b)):
        for run in runs[1:]:
            if run.columns != runs[0].columns:
                print("WARNING: %s: %s has different columns than %s "
                      "(different processes, interfaces or script version?)"
                      % (label, run.path, runs[0].path))

    for w in check_fairness(runs_a, runs_b, temp_column):
        print("WARNING: " + w)

    # --------------------------------------------------------
    # Rows
    # --------------------------------------------------------

    sections = {}
    hidden = 0

    for column in columns:
        a = GroupStat(runs_a, column)
        b = GroupStat(runs_b, column)

        if not args.all and a.all_zero and b.all_zero:
            hidden += 1
            continue

        diff = diff_pct = None
        note = ""

        if not a.present:
            note = "only in B"
        elif not b.present:
            note = "only in A"
        elif a.has_data and b.has_data:
            diff = b.avg - a.avg

            if abs(a.avg) >= 0.01:
                diff_pct = diff * 100 / abs(a.avg)

            spreads = [s for s in (a.spread, b.spread) if s is not None]
            if spreads and abs(diff) <= max(spreads):
                note = "~noise"

        section, name = classify(column)
        sections.setdefault(section, []).append(
            (column, name, a, b, diff, diff_pct, note))

    name_width = max([len("metric")] +
                     [len(r[1]) for rows in sections.values() for r in rows])

    headers = ["avg " + "A", "avg " + "B", "diff", "diff %",
               "p95 A", "p95 B", "max A", "max B"]
    line_fmt = "  %-*s" + " %9s" * len(headers) + "  %s"

    out_rows = []

    for section in sorted(sections, key=section_key):
        print()
        print(section)
        print(line_fmt % ((name_width, "metric") + tuple(headers) + ("",)))

        for column, name, a, b, diff, diff_pct, note in sections[section]:
            d = decimals(column)

            cells = (fmt(a.avg, d), fmt(b.avg, d),
                     fmt(diff, d, sign=True),
                     fmt(diff_pct, 1, sign=True) + ("%" if diff_pct is not None else ""),
                     fmt(a.p95, d), fmt(b.p95, d),
                     fmt(a.max, d), fmt(b.max, d))

            print(line_fmt % ((name_width, name) + cells + (note,)))

            out_rows.append([section, column, fmt(a.avg, d), fmt(b.avg, d),
                             fmt(diff, d), fmt(diff_pct, 1),
                             fmt(a.p95, d), fmt(b.p95, d),
                             fmt(a.max, d), fmt(b.max, d), note])

    print()
    print("diff = B - A (positive: B uses more).")

    if hidden:
        print("%d metric(s) hidden because they are 0 everywhere (--all shows them)."
              % hidden)

    if len(runs_a) < 2 or len(runs_b) < 2:
        print("Tip: with 2+ runs per group, differences within the run-to-run "
              "spread are marked ~noise.")

    if args.csv:
        with open(args.csv, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["section", "metric", "avg_a", "avg_b", "diff",
                             "diff_pct", "p95_a", "p95_b", "max_a", "max_b",
                             "note"])
            writer.writerows(out_rows)

        print("Saved to: %s" % args.csv)


if __name__ == "__main__":
    main()
