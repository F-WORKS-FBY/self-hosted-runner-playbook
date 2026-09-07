#!/usr/bin/env bash
# Connectivity probe: per-endpoint TCP connect / TLS / TTFB sampling.
# Fresh connection every sample (no keepalive reuse) so connect_time is real.
# Usage: netprobe.sh <samples> <sleep_between_rounds_sec> <outfile>
N="${1:-100}"; GAP="${2:-1}"; OUT="${3:-${CI_DATA_DIR:-./data}/netprobe.csv}"

declare -A URLS=(
  [github.com]="https://github.com/"
  [api.github.com]="https://api.github.com/"
  [ghcr.io]="https://ghcr.io/v2/"
  [registry.npmjs.org]="https://registry.npmjs.org/"
  [dockerhub-registry]="https://registry-1.docker.io/v2/"
  [dockerhub-auth]="https://auth.docker.io/token?service=registry.docker.io"
)
ORDER=(github.com api.github.com ghcr.io registry.npmjs.org dockerhub-registry dockerhub-auth)

echo "ts,endpoint,exitcode,http_code,dns_ms,connect_ms,tls_ms,ttfb_ms,total_ms" > "$OUT"
for i in $(seq 1 "$N"); do
  for ep in "${ORDER[@]}"; do
    url="${URLS[$ep]}"
    r=$(curl -4 -s -o /dev/null --max-time 20 --no-keepalive \
        -A "ci-runner-probe/1.0" \
        -w "%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}" \
        "$url" 2>/dev/null)
    ec=$?
    if [ $ec -ne 0 ] || [ -z "$r" ]; then
      echo "$(date +%s),$ep,$ec,000,,,,," >> "$OUT"
    else
      read -r code tdns tcon tapp tstart ttot <<< "$r"
      awk -v ts="$(date +%s)" -v ep="$ep" -v ec="$ec" -v code="$code" \
          -v d="$tdns" -v c="$tcon" -v a="$tapp" -v s="$tstart" -v t="$ttot" \
          'BEGIN{printf "%s,%s,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f\n", ts,ep,ec,code, d*1000,(c-d)*1000,(a-c)*1000,s*1000,t*1000}' >> "$OUT"
    fi
  done
  sleep "$GAP"
done
echo "DONE $(date -Is)"
