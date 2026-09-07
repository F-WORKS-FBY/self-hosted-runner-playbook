import csv, sys, statistics as st
from collections import defaultdict
path = sys.argv[1]
rows = defaultdict(list); fails = defaultdict(int); total = defaultdict(int); codes = defaultdict(lambda: defaultdict(int))
with open(path) as f:
    for r in csv.DictReader(f):
        ep = r['endpoint']; total[ep] += 1
        codes[ep][r['http_code']] += 1
        ok = r['exitcode'] == '0' and r['http_code'] not in ('000','')
        if not ok: fails[ep] += 1; continue
        try: rows[ep].append((float(r['dns_ms']), float(r['connect_ms']), float(r['tls_ms']), float(r['ttfb_ms'])))
        except ValueError: fails[ep] += 1
def pct(v, p):
    v = sorted(v)
    if not v: return float('nan')
    k = (len(v)-1)*p/100.0; lo, hi = int(k), min(int(k)+1, len(v)-1)
    return v[lo] + (v[hi]-v[lo])*(k-lo)
C5 = []
print(f"{'endpoint':<22}{'n':>5}{'succ%':>8}{'conn p50':>10}{'conn p95':>10}{'ttfb p50':>10}{'ttfb p95':>10}{'ttfb p99':>10}{'jit=p95/p50':>13}  verdict")
print("-"*112)
for ep in sorted(total):
    n = total[ep]; ok = n - fails[ep]; sr = 100.0*ok/n
    conn = [r[1] for r in rows[ep]]; ttfb = [r[3] for r in rows[ep]]
    cp95 = pct(conn,95); tp50 = pct(ttfb,50); tp95 = pct(ttfb,95); tp99 = pct(ttfb,99)
    jit = tp95/tp50 if tp50 else float('nan')
    checks = {'succ>=98%': sr>=98.0, 'conn_p95<300ms': cp95<300, 'ttfb_p95<1500ms': tp95<1500, 'jitter<3': jit<3}
    verdict = 'PASS' if all(checks.values()) else 'FAIL: ' + ','.join(k for k,v in checks.items() if not v)
    C5.append((ep, sr, cp95, tp95, jit, verdict))
    print(f"{ep:<22}{n:>5}{sr:>8.2f}{pct(conn,50):>10.1f}{cp95:>10.1f}{tp50:>10.1f}{tp95:>10.1f}{tp99:>10.1f}{jit:>13.2f}  {verdict}")
print("-"*112)
print("HTTP codes:", {ep: dict(codes[ep]) for ep in sorted(codes)})
print()
print("C5 verdict:", "ALL PASS" if all(v[5]=='PASS' for v in C5) else "SOME FAIL")
