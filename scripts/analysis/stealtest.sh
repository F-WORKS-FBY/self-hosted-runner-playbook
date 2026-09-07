#!/usr/bin/env bash
# Sustained full-load CPU steal measurement
OUT="${CI_DATA_DIR:-./data}/steal.csv"
DUR=${1:-600}
echo "ts,window_s,user_pct,sys_pct,idle_pct,iowait_pct,steal_pct,total_jiffies" > "$OUT"
stress-ng --cpu 4 --cpu-method matrixprod --timeout ${DUR}s --metrics-brief > "${CI_DATA_DIR:-./data}/stress.log" 2>&1 &
SPID=$!
prev=$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
for i in $(seq 1 $((DUR/10))); do
  sleep 10
  cur=$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
  read -r pu pn ps pi pw pq pf px <<< "$prev"; read -r u n s ii w q f x <<< "$cur"
  tot=$(( (u-pu)+(n-pn)+(s-ps)+(ii-pi)+(w-pw)+(q-pq)+(f-pf)+(x-px) )); [ "$tot" -le 0 ] && tot=1
  awk -v ts="$(date +%s)" -v t="$tot" -v du=$((u-pu)) -v ds=$((s-ps)) -v di=$((ii-pi)) -v dw=$((w-pw)) -v dx=$((x-px)) \
    'BEGIN{printf "%s,10,%.2f,%.2f,%.2f,%.2f,%.2f,%d\n", ts,100*du/t,100*ds/t,100*di/t,100*dw/t,100*dx/t,t}' >> "$OUT"
  prev="$cur"
done
wait $SPID
echo "STEAL TEST DONE"
