#!/usr/bin/env bash
OUT="${1:-${CI_DATA_DIR:-./data}/sysmon.csv}"
echo "ts,cpu_user,cpu_nice,cpu_sys,cpu_idle,cpu_iowait,cpu_irq,cpu_softirq,cpu_steal,mem_total_mb,mem_avail_mb,mem_used_mb,load1,root_avail_gb,procs_running" > "$OUT"
prev=""
while true; do
  cur=$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
  if [ -n "$prev" ]; then
    read -r pu pn ps pi pw pq pf px <<< "$prev"; read -r u n s i w q f x <<< "$cur"
    tot=$(( (u-pu)+(n-pn)+(s-ps)+(i-pi)+(w-pw)+(q-pq)+(f-pf)+(x-px) ))
    [ "$tot" -le 0 ] && tot=1
    mt=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    ma=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    l1=$(cut -d' ' -f1 /proc/loadavg); pr=$(cut -d' ' -f4 /proc/loadavg)
    da=$(df --output=avail -BM / | tail -1 | tr -dc 0-9)
    awk -v ts="$(date +%s)" -v t="$tot" -v du=$((u-pu)) -v dn=$((n-pn)) -v ds=$((s-ps)) -v di=$((i-pi)) \
        -v dw=$((w-pw)) -v dq=$((q-pq)) -v df2=$((f-pf)) -v dx=$((x-px)) -v mt="$mt" -v ma="$ma" -v l1="$l1" -v da="$da" -v pr="$pr" \
      'BEGIN{printf "%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%s,%.2f,%s\n", ts,100*du/t,100*dn/t,100*ds/t,100*di/t,100*dw/t,100*dq/t,100*df2/t,100*dx/t,mt,ma,mt-ma,l1,da/1024,pr}' >> "$OUT"
  fi
  prev="$cur"; sleep 5
done
