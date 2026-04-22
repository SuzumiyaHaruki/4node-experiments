#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib-codex")

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager


def load_summaries(group_dir: Path):
    summaries = {}
    if not group_dir.exists():
        return summaries
    for case_dir in sorted(group_dir.iterdir()):
        if not case_dir.is_dir():
            continue
        summary_path = case_dir / "summary.json"
        if not summary_path.exists():
            continue
        with open(summary_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        summaries[data["case_name"]] = data
    return summaries


def pick_font_family():
    preferred = [
        "SimSun",
        "Noto Serif CJK SC",
        "Source Han Serif SC",
        "Songti SC",
        "STSong",
        "AR PL UMing CN",
        "Noto Sans CJK SC",
        "Source Han Sans SC",
    ]

    for name in preferred:
        try:
            font_path = subprocess.check_output(
                ["fc-match", name, "-f", "%{file}\n"],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except Exception:
            font_path = ""

        if font_path and Path(font_path).exists():
            try:
                font_manager.fontManager.addfont(font_path)
                prop = font_manager.FontProperties(fname=font_path)
                resolved_name = prop.get_name()
                if resolved_name:
                    return resolved_name
            except Exception:
                pass

    installed = {f.name for f in font_manager.fontManager.ttflist}
    fallback = [
        "Noto Serif CJK SC",
        "Noto Sans CJK SC",
        "DejaVu Serif",
    ]
    for name in fallback:
        if name in installed:
            return name
    return "DejaVu Serif"


def setup_style():
    font_family = pick_font_family()
    plt.rcParams.update({
        "font.family": font_family,
        "axes.unicode_minus": False,
        "font.size": 11,
        "axes.labelsize": 11,
        "xtick.labelsize": 10,
        "ytick.labelsize": 10,
        "legend.fontsize": 10,
        "figure.dpi": 160,
        "savefig.dpi": 300,
        "axes.edgecolor": "#222222",
        "axes.linewidth": 0.9,
        "grid.color": "#D0D0D0",
        "grid.linewidth": 0.7,
    })


def ensure_dir(path: Path):
    path.mkdir(parents=True, exist_ok=True)


def save_figure(fig, out_path: Path, title_below: str):
    fig.subplots_adjust(bottom=0.22)
    fig.text(
        0.5,
        0.04,
        title_below,
        ha="center",
        va="center",
        fontsize=10.5,
        fontweight="bold",
    )
    fig.savefig(out_path, bbox_inches="tight", facecolor="white")
    plt.close(fig)


def metric_values(cases, summaries, key):
    values = []
    for case in cases:
        value = summaries.get(case, {}).get(key)
        values.append(0 if value is None else value)
    return values


def success_ratio(summary):
    total = summary.get("tx_total", 0) or 0
    ok = summary.get("tx_receipt_count", 0) or 0
    return (ok / total) if total else 0.0


def draw_correctness_figure(summaries, out_dir: Path):
    case_order = [
        "correct_single_keep",
        "correct_single_fail",
        "correct_1keep_1fail_same_block",
        "correct_2keep_1fail_same_block",
        "correct_1keep_2fail_same_block",
    ]
    labels = [
        "Single\nKeep",
        "Single\nFail",
        "1 Keep +\n1 Fail",
        "2 Keep +\n1 Fail",
        "1 Keep +\n2 Fail",
    ]

    keep_retention = []
    fail_drop = []
    for case in case_order:
        summary = summaries.get(case, {})
        keep_retention.append(summary.get("keep_retention_rate") or 0)
        fail_drop.append(summary.get("fail_drop_rate") or 0)

    x = range(len(case_order))
    width = 0.34

    fig, ax = plt.subplots(figsize=(8.6, 4.8))
    ax.bar([i - width / 2 for i in x], keep_retention, width=width, color="#4C78A8", label="Keep retention")
    ax.bar([i + width / 2 for i in x], fail_drop, width=width, color="#9E9E9E", label="Fail drop")

    ax.set_ylim(0, 1.08)
    ax.set_ylabel("Ratio", fontweight="bold")
    ax.set_xlabel("Scenario", fontweight="bold")
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels)
    ax.grid(axis="y", linestyle="--", alpha=0.75)
    ax.legend(frameon=False, loc="upper right")

    save_figure(fig, out_dir / "fig_correctness_semantics.png", "图4-1 正确性实验中的保留与剔除结果")


def draw_performance_keep_only_figure(summaries, out_dir: Path):
    case_order = [
        "perf_baseline_keep_only",
        "perf_remote_keep_only",
    ]
    labels = [
        "Baseline /\nKeep",
        "Remote /\nKeep",
    ]

    avg_vals = metric_values(case_order, summaries, "lat_success_avg_ms")
    p50_vals = metric_values(case_order, summaries, "lat_success_p50_ms")
    p95_vals = metric_values(case_order, summaries, "lat_success_p95_ms")

    x = range(len(case_order))
    width = 0.24

    fig, ax = plt.subplots(figsize=(7.8, 4.8))
    ax.bar([i - width for i in x], avg_vals, width=width, color="#4C78A8", label="Avg")
    ax.bar(list(x), p50_vals, width=width, color="#7F7F7F", label="P50")
    ax.bar([i + width for i in x], p95_vals, width=width, color="#222222", label="P95")

    ax.set_ylabel("Latency (ms)", fontweight="bold")
    ax.set_xlabel("Scenario", fontweight="bold")
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels)
    ax.grid(axis="y", linestyle="--", alpha=0.75)
    ax.legend(frameon=False, loc="upper left")

    save_figure(fig, out_dir / "fig_performance_keep_only_latency.png", "图5-1 Keep-only 场景下的性能对比")


def draw_performance_mixed_figure(summaries, out_dir: Path):
    case_order = [
        "perf_remote_mixed_10pct_fail",
        "perf_remote_mixed_30pct_fail",
    ]
    labels = [
        "Remote /\n10% Fail",
        "Remote /\n30% Fail",
    ]

    avg_vals = metric_values(case_order, summaries, "lat_success_avg_ms")
    p50_vals = metric_values(case_order, summaries, "lat_success_p50_ms")
    p95_vals = metric_values(case_order, summaries, "lat_success_p95_ms")
    workload_vals = metric_values(case_order, summaries, "workload_makespan_ms")
    rebuild_vals = metric_values(case_order, summaries, "rebuild_count")
    request_vals = metric_values(case_order, summaries, "remote_request_count")

    fig, axes = plt.subplots(1, 2, figsize=(11.2, 4.8))

    x = range(len(case_order))
    width = 0.24
    axes[0].bar([i - width for i in x], avg_vals, width=width, color="#4C78A8", label="Avg")
    axes[0].bar(list(x), p50_vals, width=width, color="#7F7F7F", label="P50")
    axes[0].bar([i + width for i in x], p95_vals, width=width, color="#222222", label="P95")
    axes[0].set_ylabel("Latency (ms)", fontweight="bold")
    axes[0].set_xlabel("(a) Success latency", fontweight="bold")
    axes[0].set_xticks(list(x))
    axes[0].set_xticklabels(labels)
    axes[0].grid(axis="y", linestyle="--", alpha=0.75)
    axes[0].legend(frameon=False, loc="upper left")

    width2 = 0.22
    axes[1].bar([i - width2 for i in x], workload_vals, width=width2, color="#B0B0B0", label="Workload")
    axes[1].bar(list(x), rebuild_vals, width=width2, color="#4C78A8", label="Rebuilds")
    axes[1].bar([i + width2 for i in x], request_vals, width=width2, color="#222222", label="Req. count")
    axes[1].set_ylabel("Count / Time", fontweight="bold")
    axes[1].set_xlabel("(b) Workload and internal events", fontweight="bold")
    axes[1].set_xticks(list(x))
    axes[1].set_xticklabels(labels)
    axes[1].grid(axis="y", linestyle="--", alpha=0.75)
    axes[1].legend(frameon=False, loc="upper left")

    save_figure(fig, out_dir / "fig_performance_mixed_remote.png", "图5-2 远程背书模式下混合负载的性能对比")


def draw_threshold_normal_figure(summaries, out_dir: Path):
    case_order = [
        "threshold_normal_2of3",
        "threshold_normal_3of3",
    ]
    labels = [
        "2-of-3 /\nNormal",
        "3-of-3 /\nNormal",
    ]

    avg_vals = metric_values(case_order, summaries, "lat_success_avg_ms")
    p50_vals = metric_values(case_order, summaries, "lat_success_p50_ms")
    p95_vals = metric_values(case_order, summaries, "lat_success_p95_ms")

    x = range(len(case_order))
    width = 0.24

    fig, ax = plt.subplots(figsize=(7.8, 4.8))
    ax.bar([i - width for i in x], avg_vals, width=width, color="#4C78A8", label="Avg")
    ax.bar(list(x), p50_vals, width=width, color="#7F7F7F", label="P50")
    ax.bar([i + width for i in x], p95_vals, width=width, color="#222222", label="P95")

    ax.set_ylabel("Latency (ms)", fontweight="bold")
    ax.set_xlabel("Scenario", fontweight="bold")
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels)
    ax.grid(axis="y", linestyle="--", alpha=0.75)
    ax.legend(frameon=False, loc="upper left")

    save_figure(fig, out_dir / "fig_threshold_normal_latency.png", "图5-3 不同阈值配置下正常场景的时延对比")


def draw_threshold_partial_reject_figure(summaries, out_dir: Path):
    case_order = [
        "threshold_partial_reject_2of3",
        "threshold_partial_reject_3of3",
    ]
    labels = [
        "2-of-3 /\nPartial reject",
        "3-of-3 /\nPartial reject",
    ]

    success_rates = [success_ratio(summaries.get(case, {})) for case in case_order]
    success_counts = metric_values(case_order, summaries, "tx_receipt_count")
    rebuild_vals = metric_values(case_order, summaries, "rebuild_count")

    fig, axes = plt.subplots(1, 2, figsize=(10.6, 4.8))
    x = range(len(case_order))

    axes[0].bar(list(x), success_rates, color=["#4C78A8", "#222222"], width=0.48)
    axes[0].set_ylim(0, 1.08)
    axes[0].set_ylabel("Success ratio", fontweight="bold")
    axes[0].set_xlabel("(a) Final acceptance", fontweight="bold")
    axes[0].set_xticks(list(x))
    axes[0].set_xticklabels(labels)
    axes[0].grid(axis="y", linestyle="--", alpha=0.75)

    axes[1].bar([i - 0.16 for i in x], success_counts, width=0.32, color="#7F7F7F", label="Success count")
    axes[1].bar([i + 0.16 for i in x], rebuild_vals, width=0.32, color="#4C78A8", label="Rebuilds")
    axes[1].set_ylabel("Count", fontweight="bold")
    axes[1].set_xlabel("(b) Outcome statistics", fontweight="bold")
    axes[1].set_xticks(list(x))
    axes[1].set_xticklabels(labels)
    axes[1].grid(axis="y", linestyle="--", alpha=0.75)
    axes[1].legend(frameon=False, loc="upper right")

    save_figure(fig, out_dir / "fig_threshold_partial_reject.png", "图5-4 部分拒签场景下不同阈值配置的结果对比")


def draw_fault_latency_figure(summaries, out_dir: Path):
    case_order = [
        "fault_remote_normal",
        "fault_delay_100ms",
        "fault_delay_300ms",
        "fault_delay_500ms",
        "fault_down_1_degraded",
        "fault_down_1_slowhang",
    ]
    labels = [
        "Normal",
        "Delay-\n100ms",
        "Delay-\n300ms",
        "Delay-\n500ms",
        "One-Down\nDegraded",
        "One-Down\nSlowhang",
    ]

    avg_vals = metric_values(case_order, summaries, "lat_success_avg_ms")
    p95_vals = metric_values(case_order, summaries, "lat_success_p95_ms")

    fig, ax = plt.subplots(figsize=(10.2, 4.8))
    x = list(range(len(case_order)))
    width = 0.34
    ax.bar([i - width / 2 for i in x], avg_vals, width=width, color="#4C78A8", label="Avg")
    ax.bar([i + width / 2 for i in x], p95_vals, width=width, color="#222222", label="P95")
    ax.set_ylabel("Latency (ms)", fontweight="bold")
    ax.set_xlabel("Fault scenario", fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.grid(axis="y", linestyle="--", alpha=0.75)
    ax.legend(frameon=False, loc="upper left")

    save_figure(fig, out_dir / "fig_fault_latency.png", "图5-5 不同故障场景下的时延变化")


def draw_fault_correctness_figure(summaries, out_dir: Path):
    case_order = [
        "fault_remote_normal",
        "fault_delay_100ms",
        "fault_delay_300ms",
        "fault_delay_500ms",
        "fault_down_1_degraded",
        "fault_down_1_slowhang",
        "fault_down_2_unavailable",
    ]
    labels = [
        "Normal",
        "Delay-\n100ms",
        "Delay-\n300ms",
        "Delay-\n500ms",
        "One-Down\nDegraded",
        "One-Down\nSlowhang",
        "Two-Down\nUnavailable",
    ]

    success_rates = [success_ratio(summaries.get(case, {})) for case in case_order]
    keep_retention = []
    for case in case_order:
        keep_retention.append(summaries.get(case, {}).get("keep_retention_rate") or 0)

    x = range(len(case_order))
    width = 0.34

    fig, ax = plt.subplots(figsize=(11.2, 4.8))
    ax.bar([i - width / 2 for i in x], success_rates, width=width, color="#4C78A8", label="Success ratio")
    ax.bar([i + width / 2 for i in x], keep_retention, width=width, color="#9E9E9E", label="Keep retention")
    ax.set_ylim(0, 1.08)
    ax.set_ylabel("Ratio", fontweight="bold")
    ax.set_xlabel("Fault scenario", fontweight="bold")
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels)
    ax.grid(axis="y", linestyle="--", alpha=0.75)
    ax.legend(frameon=False, loc="upper right")

    save_figure(fig, out_dir / "fig_fault_correctness.png", "图5-6 不同故障场景下的可用性结果")


def main():
    parser = argparse.ArgumentParser(description="Generate thesis figures from experiment summaries.")
    parser.add_argument("--results-dir", default="results", help="Experiment results root directory")
    parser.add_argument("--out-dir", default="figures", help="Output directory for generated figures")
    args = parser.parse_args()

    setup_style()

    results_dir = Path(args.results_dir)
    out_dir = Path(args.out_dir)
    ensure_dir(out_dir)

    correctness = load_summaries(results_dir / "correctness")
    performance = load_summaries(results_dir / "performance")
    threshold = load_summaries(results_dir / "threshold")
    fault = load_summaries(results_dir / "fault")

    if correctness:
        draw_correctness_figure(correctness, out_dir)
    if performance:
        draw_performance_keep_only_figure(performance, out_dir)
        draw_performance_mixed_figure(performance, out_dir)
    if threshold:
        draw_threshold_normal_figure(threshold, out_dir)
        draw_threshold_partial_reject_figure(threshold, out_dir)
    if fault:
        draw_fault_latency_figure(fault, out_dir)
        draw_fault_correctness_figure(fault, out_dir)

    print(f"figures written to: {out_dir}")


if __name__ == "__main__":
    main()
