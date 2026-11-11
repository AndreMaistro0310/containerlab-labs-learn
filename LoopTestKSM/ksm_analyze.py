#!/usr/bin/env python3
"""Analisis hasil ksm_bench.sh. Pemakaian: python3 ksm_analyze.py <folder_hasil>"""
import sys, os
import numpy as np, pandas as pd
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

d = sys.argv[1]
df = pd.read_csv(os.path.join(d, "data.csv"))
meta = {}
mp = os.path.join(d, "meta.txt")
if os.path.exists(mp):
    for line in open(mp):
        if ":" in line:
            k, v = line.split(":", 1); meta[k.strip()] = v.strip()
tck = float(meta.get("clk_tck", 100))

base = df[df.elapsed_s == -1].set_index(["arm", "rep"]).used_mb.rename("base_mb")
df = df[df.elapsed_s >= 0].join(base, on=["arm", "rep"])
df["lab_mb"] = df.used_mb - df.base_mb            # RAM yang dipakai lab (di atas baseline WSL)
df["saved_mb"] = df.pages_sharing * 4 / 1024
step = max(1, int(round(df.groupby(["arm", "rep"]).elapsed_s.diff().median())))
df["bin"] = (df.elapsed_s / step).round() * step
dur = df.elapsed_s.max()
win = df[df.elapsed_s >= 0.8 * dur]               # jendela steady-state: 20% terakhir

# ---- ringkasan per ulangan
rows = []
for (arm, rep), g in win.groupby(["arm", "rep"]):
    full = df[(df.arm == arm) & (df.rep == rep)]
    dt = (g.elapsed_s.max() - g.elapsed_s.min()) or 1
    rows.append(dict(arm=arm, rep=rep, lab_mb=g.lab_mb.mean(), avail_mb=g.mem_avail_mb.mean(),
        ksmd_cpu_pct=(g.ksmd_ticks.max() - g.ksmd_ticks.min()) / tck / dt * 100,
        sys_cpu_pct=(g.cpu_busy_ticks.max() - g.cpu_busy_ticks.min()) /
                    max(1, (g.cpu_total_ticks.max() - g.cpu_total_ticks.min())) * 100,
        pages_sharing=g.pages_sharing.mean(), ksm_saved_mb=g.saved_mb.mean()))
per = pd.DataFrame(rows).sort_values(["arm", "rep"])
agg = per.groupby("arm").agg(["mean", "std"]).round(1)

off = per[per.arm == "off"].lab_mb; on = per[per.arm == "on"].lab_mb
saving = off.mean() - on.mean(); pct = saving / off.mean() * 100 if off.mean() else float("nan")

# waktu mencapai 90% penghematan
curve = df.groupby(["arm", "bin"]).lab_mb.mean().unstack(0)
t90 = None
if {"on", "off"} <= set(curve.columns) and saving > 0:
    gap = (curve["off"] - curve["on"]).dropna()          # selisih OFF-ON di tiap waktu
    hit = gap.index[gap >= 0.9 * saving]
    t90 = int(hit[0]) if len(hit) else None

lines = ["# Hasil perbandingan KSM OFF vs ON", "",
         f"Sumber: `{d}` | durasi {int(dur)} s | jendela steady-state: {int(0.8*dur)}-{int(dur)} s", "",
         "## Per ulangan (rata-rata di jendela steady-state)", "", per.round(1).to_markdown(index=False), "",
         "## Ringkasan", "",
         f"- RAM lab, KSM OFF : {off.mean():.0f} MB (std {off.std():.0f}, n={len(off)})",
         f"- RAM lab, KSM ON  : {on.mean():.0f} MB (std {on.std():.0f}, n={len(on)})",
         f"- **Penghematan    : {saving:.0f} MB ({pct:.1f}%)**"]
if len(off) > 1 and len(on) > 1:
    se = np.sqrt(off.var() / len(off) + on.var() / len(on))
    lines.append(f"- Perkiraan rentang (±2 SE): {saving - 2*se:.0f} s/d {saving + 2*se:.0f} MB")
if t90 is not None: lines.append(f"- Waktu mencapai 90% penghematan: sekitar {t90} detik setelah deploy")
cp = per.groupby("arm")[["ksmd_cpu_pct", "sys_cpu_pct"]].mean().round(2)
lines += ["", "## Biaya CPU (rata-rata)", "", cp.to_markdown(), "",
          "ksmd_cpu_pct = CPU thread ksmd dalam % satu core; sys_cpu_pct = CPU total WSL (%).", "",
          "Catatan: lab_mb = (MemTotal - MemAvailable) setelah deploy dikurangi baseline sebelum deploy pada arm yang sama."]
open(os.path.join(d, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines))

# ---- grafik
fig, ax = plt.subplots(1, 2, figsize=(12, 4.4))
colr = {"off": "#EF4444", "on": "#0284C7"}; name = {"off": "KSM OFF", "on": "KSM ON"}
for arm in ["off", "on"]:
    g = df[df.arm == arm].groupby("bin").lab_mb.agg(["mean", "min", "max"])
    if g.empty: continue
    ax[0].plot(g.index, g["mean"], color=colr[arm], lw=2, label=name[arm])
    ax[0].fill_between(g.index, g["min"], g["max"], color=colr[arm], alpha=.15)
ax[0].set(title="RAM yang dipakai lab", xlabel="detik sejak deploy", ylabel="MB (di atas baseline)")
ax[0].legend(); ax[0].grid(alpha=.3)
g = df[df.arm == "on"].groupby("bin").saved_mb.mean()
if not g.empty: ax[1].plot(g.index, g.values, color=colr["on"], lw=2)
ax[1].set(title="Penghematan KSM (pages_sharing × 4 KB)", xlabel="detik sejak deploy", ylabel="MB"); ax[1].grid(alpha=.3)
for a in ax: a.spines[["top", "right"]].set_visible(False)
fig.tight_layout(); fig.savefig(os.path.join(d, "ksm_result.png"), dpi=130)
