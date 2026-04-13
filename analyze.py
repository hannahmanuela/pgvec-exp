import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt
import numpy as np
import os
from pathlib import Path
import argparse
import sys


bin_size = 1  # 100 milliseconds

plt.rcParams['font.size'] = 18

parser = argparse.ArgumentParser(description="Compare client mean latency across multiple runs.")
parser.add_argument("dirs", nargs="+", help="Run directories (e.g., 'out/exp1/run1 out/exp2/run2')")
parser.add_argument("--mean-bars", action="store_true", help="Show horizontal mean latency bars before/after BG start")
parser.add_argument("--no-cpu", action="store_true", help="Only show the top latency graph, omit the CPU utilization graph")
args = parser.parse_args()

warmup_s = 12.0

def draw_single(grouped, resize_times, place_to_save, bg_start_since, cpu_usage, cpu_util, mean_bars=False, no_cpu=False):
    if no_cpu:
        fig, ax1 = plt.subplots(1, 1, figsize=(12, 6))
        ax2 = None
    else:
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8), sharex=True, gridspec_kw={'height_ratios': [3, 1]})

    sns.lineplot(ax=ax1, data=grouped, x='time_bin', y='mean_latency', label='Mean Latency', alpha=0.4)
    sns.lineplot(ax=ax1, data=grouped, x='time_bin', y='p99_latency', label='99th Percentile Latency')
    if bg_start_since > 0:
        ax1.axvline(x=bg_start_since, color='red', linestyle='--', label='BG Start')
        if mean_bars:
            before = grouped[grouped['time_bin'] < bg_start_since]
            after = grouped[grouped['time_bin'] >= bg_start_since]
            if not before.empty:
                mean_before = before['mean_latency'].mean()
                ax1.hlines(mean_before, before['time_bin'].min(), bg_start_since, colors='darkred', linestyles='dotted', linewidth=2.5)
                ax1.text(before['time_bin'].min(), mean_before, f' {mean_before:.2f} ms', fontsize=18, fontweight='bold', color='darkred', va='bottom')
            if not after.empty:
                mean_after = after['mean_latency'].mean()
                ax1.hlines(mean_after, bg_start_since, after['time_bin'].max(), colors='darkred', linestyles='dotted', linewidth=2.5)
                ax1.text(after['time_bin'].max(), mean_after, f'{mean_after:.2f} ms ', fontsize=18, fontweight='bold', color='darkred', va='bottom', ha='right')
    ax1.set_ylabel('Latency (ms)')
    ax1.set_title(f'Latency (Grouped by {bin_size} s)')
    ax1.legend()
    ax1.set_ylim(bottom=0)

    if ax2 is not None and not cpu_util.empty:
        cpu_cols = [c for c in cpu_util.columns if c.startswith('cpu')]
        cpu_util_binned = cpu_util.copy()
        cpu_util_binned['time_bin'] = (cpu_util_binned['time_since_start'] // bin_size) * bin_size
        cpu_util_binned = cpu_util_binned.groupby('time_bin')[cpu_cols].mean().reset_index()
        cpu_util_binned['cpu_mean'] = cpu_util_binned[cpu_cols].mean(axis=1)
        ax2.plot(cpu_util_binned['time_bin'], cpu_util_binned['cpu_mean'], label='Mean CPU', linewidth=1.2)
        if bg_start_since > 0:
            ax2.axvline(x=bg_start_since, color='red', linestyle='--', label='BG Start')
        ax2.set_ylim(0, 105)
        ax2.set_ylabel('CPU %')
        ax2.set_xlabel('Time Since Start (s)')
        ax2.set_title('Mean CPU Utilization')

    if ax2 is None:
        ax1.set_xlabel('Time Since Start (s)')
    ax1.set_xlim(left=warmup_s)

    plt.tight_layout()
    plt.savefig(place_to_save)
    plt.close()

def run_on_path(run_dir_path):

    data = pd.read_csv(f'{run_dir_path}/srv_times.txt')
    data['time'] = pd.to_datetime(data['sent_at_unix_ns'], unit='ns')
    time_start = data['time'].min()
    data['time_since_start'] = (data['time'] - time_start).dt.total_seconds()
    data['time_bin'] = (data['time_since_start'] // bin_size) * bin_size
    data['latency_ms'] = data['latency_us'] / 1000.0

    grouped = data.groupby('time_bin')['latency_ms'].agg(
        mean_latency='mean',
        p99_latency=lambda x: x.quantile(0.99)
    ).reset_index()

    # Background start
    bg_start_path = f'{run_dir_path}/bg_start.txt'
    if os.path.exists(bg_start_path):
        with open(bg_start_path, 'r') as f:
            bg_start_us = int(f.readline().strip())
        bg_start_dt = pd.to_datetime(bg_start_us, unit='us')
        bg_start_since = (bg_start_dt - time_start).total_seconds()
    else:
        bg_start_since = 0.0

    # Before/after bg_start analysis (exclude warmup)
    if bg_start_since > 0:
        before = data[(data['time_since_start'] >= warmup_s) & (data['time_since_start'] < bg_start_since)]
        after = data[data['time_since_start'] >= bg_start_since]
        print(f"\n=== {run_dir_path} ===")
        print(f"BG start at {bg_start_since:.2f}s")
        for label, subset in [("BEFORE bg_start", before), ("AFTER bg_start", after)]:
            if subset.empty:
                print(f"\n  {label}: no data")
                continue
            print(f"\n  {label} (n={len(subset)}):")
            print(f"    Latency:")
            print(f"      mean={subset['latency_ms'].mean():.2f}ms  median={subset['latency_ms'].median():.2f}ms  "
                  f"p95={subset['latency_ms'].quantile(0.95):.2f}ms  p99={subset['latency_ms'].quantile(0.99):.2f}ms  max={subset['latency_ms'].max():.2f}ms")

    # Resize times
    file_path = f'{run_dir_path}/bg_times.txt'
    if os.path.exists(file_path):
        resize_times = pd.read_csv(file_path, header=None, names=["time"])
    else:
        resize_times = pd.DataFrame([], columns=["time"])
    resize_times["time"] = pd.to_datetime(resize_times["time"], unit='us')
    resize_times["time_since_start"] = (resize_times["time"] - time_start).dt.total_seconds()
    # Cut off bg times after srv_times stop
    srv_end = data['time_since_start'].max()
    resize_times = resize_times[resize_times['time_since_start'] <= srv_end]

    # cpu usage
    cpu_usage_path = f'{run_dir_path}/cpu_usage.txt'
    if os.path.exists(cpu_usage_path):
        cpu_usage = pd.read_csv(cpu_usage_path, header=None, names=["time", "tid", "usage"])
    else:
        cpu_usage = pd.DataFrame([], columns=["time", "usage"])
    cpu_usage["time"] = pd.to_datetime(cpu_usage["time"], unit='us')
    cpu_usage["time_since_start"] = (cpu_usage["time"] - time_start).dt.total_seconds()

    # cpu utilization (per-cpu)
    cpu_util_path = f'{run_dir_path}/utils.txt'
    if os.path.exists(cpu_util_path):
        cpu_util = pd.read_csv(cpu_util_path)
        cpu_util["timestamp"] = pd.to_datetime(cpu_util["timestamp"], unit='us')
        cpu_util["time_since_start"] = (cpu_util["timestamp"] - time_start).dt.total_seconds()
    else:
        cpu_util = pd.DataFrame()

    # Exclude warmup from graph data
    grouped = grouped[grouped['time_bin'] >= warmup_s]
    resize_times = resize_times[resize_times['time_since_start'] >= warmup_s]
    cpu_usage = cpu_usage[cpu_usage['time_since_start'] >= warmup_s]
    if not cpu_util.empty:
        cpu_util = cpu_util[cpu_util['time_since_start'] >= warmup_s]

    draw_single(grouped, resize_times, f'{run_dir_path}/out.png', bg_start_since, cpu_usage, cpu_util, mean_bars=args.mean_bars, no_cpu=args.no_cpu)

    return grouped, bg_start_since


def draw_comparison(all_results, save_path):
    """Draw overlaid comparison of client mean latency across multiple runs."""
    fig, ax = plt.subplots(figsize=(14, 7))

    palette = sns.color_palette("tab10", n_colors=len(all_results))

    unique_bg_starts = []
    for color, (label, (grouped_clnt, bg_start_since)) in zip(palette, all_results.items()):
        ax.plot(grouped_clnt['time_bin'], grouped_clnt['mean_latency'],
                label=f'{label} mean', color=color, linestyle='-')
        ax.plot(grouped_clnt['time_bin'], grouped_clnt['p99_latency'],
                label=f'{label} p99', color=color, linestyle='--')
        if bg_start_since > 0 and not any(np.isclose(bg_start_since, v, atol=0.005) for v, _ in unique_bg_starts):
            unique_bg_starts.append((bg_start_since, label))

    for idx, (start_val, label) in enumerate(unique_bg_starts):
        start_label = 'BG start' if len(unique_bg_starts) == 1 else f'BG start ({label})'
        ax.axvline(x=start_val, color='red', linestyle=':', alpha=0.7,
                   label=start_label if idx == 0 else None)

    ax.set_ylabel('Latency (ms)')
    ax.set_xlabel('Time Since Start (s)')
    ax.set_title(f'Mean Latency Comparison (Grouped by {bin_size} s)')
    ax.legend()
    ax.set_ylim(bottom=0)
    ax.set_xlim(left=warmup_s)

    plt.tight_layout()
    plt.savefig(save_path)
    plt.close()
    print(f"\nComparison plot saved to {save_path}")


def is_run_dir(path):
    """Check if a directory is a run directory (contains srv_times.txt)."""
    return (Path(path) / 'srv_times.txt').exists()


def process_dir(p):
    """Analyze p if it's a run dir; otherwise find run subdirs and compare them.
    Non-run subdirs are recursed into (handles arbitrary nesting like out/<exp>/<run>/)."""
    if is_run_dir(p):
        run_on_path(str(p))
        return

    run_subdirs = sorted([d for d in p.iterdir() if d.is_dir() and is_run_dir(d)])
    non_run_subdirs = sorted([d for d in p.iterdir() if d.is_dir() and not is_run_dir(d)])

    if run_subdirs:
        all_results = {}
        for sub in run_subdirs:
            grouped_clnt, bg_start_since = run_on_path(str(sub))
            all_results[sub.name] = (grouped_clnt, bg_start_since)
        if len(all_results) >= 2:
            draw_comparison(all_results, str(p / 'comparison.png'))
        else:
            print(f"Only one run found in {p}, skipping comparison plot")

    for sub in non_run_subdirs:
        process_dir(sub)

    if not run_subdirs and not non_run_subdirs:
        print(f"No run directories found in {p}")


for run_dir in args.dirs:
    p = Path(run_dir)
    if not p.is_dir():
        continue
    process_dir(p)
