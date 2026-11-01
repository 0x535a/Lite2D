#!/usr/bin/env python3
"""Summarize completed benchmark scenarios, keeping incomplete ones explicit."""
import argparse
import json
from pathlib import Path
import statistics

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", nargs="?", type=Path, default=root / ".local/verification/performance")
args = parser.parse_args()
lines = ["| 实例 | 时长 s | 静止 CPU % | 移动目标 CPU % | 常驻 MiB | 物理占用 MiB | 各实例实际 FPS |",
         "|---:|---:|---:|---:|---:|---:|---|"]
results = []
for count in range(5):
    directory = args.directory / str(count)
    if not (directory / "summary.json").exists():
        lines.append(f"| {count} | 未完成 | — | — | — | — | — |")
        continue
    summary = json.loads((directory / "summary.json").read_text())
    samples = json.loads((directory / "samples.json").read_text())
    def mean(key, phase=None):
        values = [sample[key] for sample in samples if phase is None or sample["phase"] == phase]
        return statistics.mean(values) if values else None
    static_cpu = mean("cpuPercentOneCore100", "stationary-target")
    moving_cpu = mean("cpuPercentOneCore100", "moving-target")
    rss = mean("residentBytes") / 1048576
    footprint = mean("physicalFootprintBytes") / 1048576
    fps = ", ".join(f"{item['actualFPS']:.2f}" for item in summary["frames"]) or "—"
    lines.append(f"| {count} | {summary['durationSeconds']:.1f} | {static_cpu:.2f} | {moving_cpu:.2f} | {rss:.1f} | {footprint:.1f} | {fps} |")
    results.append(dict(instances=count, durationSeconds=summary["durationSeconds"], staticCPU=static_cpu,
                        movingCPU=moving_cpu, residentMiB=rss, footprintMiB=footprint,
                        fps=[item["actualFPS"] for item in summary["frames"]]))
text = "\n".join(lines) + "\n"
args.directory.mkdir(parents=True, exist_ok=True)
(args.directory / "summary.md").write_text(text)
(args.directory / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
print(text)
