#!/usr/bin/env bash
# ksm_bench.sh - Bandingkan pemakaian RAM lab containerlab: KSM OFF vs ON
#
# Pemakaian:
#   sudo ./ksm_bench.sh <topologi.clab.yml> [durasi_detik=900] [interval_detik=15] [ulangan=3]
#
# Cara kerja:
#   - Variabel yang dibedakan HANYA /sys/kernel/mm/ksm/run (0 = OFF, 1 = ON).
#     MemoryKSM=yes pada containerd dibiarkan aktif di kedua arm; dengan run=0
#     ksmd tidak memindai, jadi tidak ada penggabungan.
#   - Tiap arm dimulai dari lab yang bersih (destroy -> settle -> drop cache -> baseline -> deploy).
#   - Urutan arm bergantian tiap ulangan (OFF,ON lalu ON,OFF, ...) untuk menetralkan drift.
#
# PERINGATAN: skrip ini MENGHANCURKAN dan men-deploy ulang lab. Simpan config dulu:
#   sudo containerlab save -t <topologi.clab.yml>

set -uo pipefail
KSM=/sys/kernel/mm/ksm
SETTLE="${SETTLE:-45}"

log(){ echo "[$(date +%H:%M:%S)] $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

mem_kb(){ awk -v k="$1:" '$1==k {print $2}' /proc/meminfo; }
ksm_val(){ cat "$KSM/$1" 2>/dev/null || echo 0; }
ksmd_ticks(){
  local pid; pid=$(pgrep -x ksmd | head -n1 || true)
  if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then awk '{print $14+$15}' "/proc/$pid/stat"; else echo 0; fi
}
cpu_ticks(){ awk '/^cpu /{idle=$5+$6; tot=0; for(i=2;i<=NF;i++) tot+=$i; print tot-idle, tot}' /proc/stat; }

# arm rep elapsed -> satu baris CSV
sample(){
  local total avail anon cpu
  total=$(mem_kb MemTotal); avail=$(mem_kb MemAvailable); anon=$(mem_kb AnonPages)
  cpu=$(cpu_ticks)
  echo "$1,$2,$3,$((total/1024)),$((avail/1024)),$(((total-avail)/1024)),$((anon/1024)),$(ksm_val pages_shared),$(ksm_val pages_sharing),$(ksm_val pages_unshared),$(ksm_val pages_volatile),$(ksm_val full_scans),$(ksmd_ticks),${cpu// /,}"
}

[ "$(id -u)" -eq 0 ] || die "jalankan dengan sudo"
[ -d "$KSM" ] || die "$KSM tidak ada: kernel tidak mendukung KSM"

if [ "${1:-}" = "--selftest" ]; then
  echo "arm,rep,elapsed_s,mem_total_mb,mem_avail_mb,used_mb,anon_mb,pages_shared,pages_sharing,pages_unshared,pages_volatile,full_scans,ksmd_ticks,cpu_busy_ticks,cpu_total_ticks"
  sample test 0 0; exit 0
fi

TOPO="${1:?pemakaian: sudo $0 <topologi.clab.yml> [durasi=900] [interval=15] [ulangan=3]}"
DURATION="${2:-900}"; INTERVAL="${3:-15}"; REPEATS="${4:-3}"
[ -f "$TOPO" ] || die "file topologi tidak ditemukan: $TOPO"
command -v containerlab >/dev/null || die "containerlab tidak ditemukan"

OUT="ksm_bench_$(date +%Y%m%d_%H%M%S)"; mkdir -p "$OUT"
ORIG_RUN=$(cat "$KSM/run")
# ksmtuned / ksm.service dapat menyalakan KSM sendiri saat RAM menipis, sehingga arm OFF tidak benar-benar OFF.
# Hentikan selama benchmark, lalu hidupkan lagi di akhir.
STOPPED_SVCS=""
for svc in ksmtuned ksm; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then systemctl stop "$svc" && STOPPED_SVCS="$STOPPED_SVCS $svc"; fi
done
WARN_FILE=$(mktemp)
cleanup(){
  containerlab destroy -t "$TOPO" --cleanup >/dev/null 2>&1
  for svc in $STOPPED_SVCS; do systemctl start "$svc" 2>/dev/null; done
  # kembalikan nilai run awal hanya jika tidak ada layanan yang menyetelnya sendiri
  [ -z "$STOPPED_SVCS" ] && echo "$ORIG_RUN" > "$KSM/run" 2>/dev/null
  rm -f "$WARN_FILE"
}
trap cleanup EXIT

{
  echo "tanggal: $(date -Is)"; echo "kernel: $(uname -r)"; echo "topologi: $TOPO"
  echo "durasi_s: $DURATION"; echo "interval_s: $INTERVAL"; echo "ulangan: $REPEATS"
  echo "clk_tck: $(getconf CLK_TCK)"
  echo "pages_to_scan: $(ksm_val pages_to_scan)"; echo "sleep_millisecs: $(ksm_val sleep_millisecs)"
  echo "memoryksm_containerd: $(systemctl show containerd -p MemoryKSM 2>/dev/null)"
} > "$OUT/meta.txt"
echo "arm,rep,elapsed_s,mem_total_mb,mem_avail_mb,used_mb,anon_mb,pages_shared,pages_sharing,pages_unshared,pages_volatile,full_scans,ksmd_ticks,cpu_busy_ticks,cpu_total_ticks" > "$OUT/data.csv"
echo "arm,rep,deploy_seconds" > "$OUT/deploy_seconds.csv"

run_arm(){
  local arm=$1 rep=$2 t0 now el d0 dep
  log "== ulangan $rep/$REPEATS | KSM=$arm =="
  containerlab destroy -t "$TOPO" --cleanup >/dev/null 2>&1 || true
  if [ "$arm" = on ]; then echo 1 > "$KSM/run"; else echo 0 > "$KSM/run"; fi
  sleep "$SETTLE"; sync; echo 3 > /proc/sys/vm/drop_caches; sleep 5
  sample "$arm" "$rep" -1 >> "$OUT/data.csv"            # baseline sebelum deploy
  d0=$(date +%s)
  containerlab deploy -t "$TOPO" > "$OUT/deploy_${arm}_${rep}.log" 2>&1 || die "deploy gagal, lihat $OUT/deploy_${arm}_${rep}.log"
  dep=$(( $(date +%s) - d0 )); echo "$arm,$rep,$dep" >> "$OUT/deploy_seconds.csv"
  t0=$(date +%s)
  while :; do
    now=$(date +%s); el=$((now - t0))
    if [ "$arm" = off ] && [ "$(cat "$KSM/run")" != 0 ]; then
      echo 0 > "$KSM/run"; echo x >> "$WARN_FILE"; log "PERINGATAN: run berubah dari 0 saat arm OFF (dikembalikan ke 0)"
    fi
    sample "$arm" "$rep" "$el" >> "$OUT/data.csv"
    [ "$el" -ge "$DURATION" ] && break
    sleep "$INTERVAL"
  done
  containerlab destroy -t "$TOPO" --cleanup >/dev/null 2>&1 || true
}

for rep in $(seq 1 "$REPEATS"); do
  if [ $((rep % 2)) -eq 1 ]; then ORDER="off on"; else ORDER="on off"; fi
  for arm in $ORDER; do run_arm "$arm" "$rep"; done
done

NW=$(wc -l < "$WARN_FILE" | tr -d ' ')
echo "peringatan_run_berubah_di_arm_off: $NW" >> "$OUT/meta.txt"
[ "$NW" -gt 0 ] && log "PERHATIAN: arm OFF terganggu $NW kali. Hasil OFF tidak sepenuhnya valid."
log "Selesai. Data: $OUT/data.csv  -> analisis: python3 ksm_analyze.py $OUT"
