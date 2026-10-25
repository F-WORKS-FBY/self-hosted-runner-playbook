#!/usr/bin/env bash
# step.sh <名字> <命令...>：把命令放进 ci.slice 下单独的 scope 里跑，每 100ms 采一次 cgroup 内存。
# 内存只含这条命令拉起的进程，不含 docker 容器和 docker build 的 RUN 步骤（它们归 dockerd 管）。
# CPU 核秒读的是整机 /proc/stat，量的时候机器上不要跑别的东西。要 root 运行；结果追加到 $CI_DATA_DIR/steps.psv。
NAME="$1"; shift
DATA="${CI_DATA_DIR:-./data}"; CG=/sys/fs/cgroup/ci.slice
SCOPE="ci-$(echo "$NAME" | tr -c 'a-zA-Z0-9' '-')-$$"
( PEAK=0
  while :; do
    m=$(cat "$CG/memory.current" 2>/dev/null || echo 0)
    [ "$m" -gt "$PEAK" ] 2>/dev/null && { PEAK=$m; echo "$PEAK" > "/tmp/$SCOPE.peak"; }
    sleep 0.1
  done ) & SAMPLER=$!
echo 0 > "/tmp/$SCOPE.peak"
s=$(date +%s.%N); c0=$(awk '/^cpu /{print $2+$3+$4}' /proc/stat); st0=$(awk '/^cpu /{print $9}' /proc/stat)
d0=$(df --output=used -BM / | tail -1 | tr -dc 0-9)
systemd-run --quiet --scope --slice=ci.slice --unit="$SCOPE" \
  --working-directory="${CI_WORK_DIR:-/tmp/ci-step}" bash -lc "$*"; rc=$?
e=$(date +%s.%N); c1=$(awk '/^cpu /{print $2+$3+$4}' /proc/stat); st1=$(awk '/^cpu /{print $9}' /proc/stat)
d1=$(df --output=used -BM / | tail -1 | tr -dc 0-9)
sleep 0.3; kill $SAMPLER 2>/dev/null; peak=$(cat "/tmp/$SCOPE.peak"); rm -f "/tmp/$SCOPE.peak"
HZ=$(getconf CLK_TCK)
awk -v n="$NAME" -v s="$s" -v e="$e" -v p="$peak" -v rc="$rc" -v c0="$c0" -v c1="$c1" -v hz="$HZ" \
    -v st0="$st0" -v st1="$st1" -v d0="$d0" -v d1="$d1" \
  'BEGIN{w=e-s; cs=(c1-c0)/hz; sts=(st1-st0)/hz;
   printf "%s|%.2f|%.0f|%.2f|%.2f|%.2f|%.2f|%d|%d\n", n,w,p/1048576,cs,(w>0?cs/w:0),sts,(cs>0?100*sts/(cs+sts):0),d1-d0,rc}' >> "$DATA/steps.psv"
echo ">>> $NAME wall=$(awk -v s=$s -v e=$e 'BEGIN{printf "%.1fs",e-s}') peak=$(awk -v p=$peak 'BEGIN{printf "%.0fMB",p/1048576}') steal=$(awk -v a=$st0 -v b=$st1 -v h=$HZ 'BEGIN{printf "%.2fs",(b-a)/h}') disk=+$((d1-d0))MB rc=$rc"
exit $rc
