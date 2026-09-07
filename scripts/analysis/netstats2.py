import csv, sys
from collections import defaultdict
def pct(v,p):
    v=sorted(v)
    if not v: return float('nan')
    k=(len(v)-1)*p/100.0; lo=int(k); hi=min(lo+1,len(v)-1)
    return v[lo]+(v[hi]-v[lo])*(k-lo)
for path in sys.argv[1:]:
    print(f"\n########## {path} ##########")
    rows=defaultdict(list); tot=defaultdict(int); transport_fail=defaultdict(int); http5=defaultdict(int); http4=defaultdict(int)
    tls=defaultdict(list)
    with open(path) as f:
        for r in csv.DictReader(f):
            ep=r['endpoint']; tot[ep]+=1
            if r['exitcode']!='0' or r['http_code'] in ('000',''):
                transport_fail[ep]+=1; continue
            c=r['http_code']
            if c.startswith('5'): http5[ep]+=1
            elif c.startswith('4'): http4[ep]+=1
            rows[ep].append((float(r['connect_ms']), float(r['ttfb_ms'])))
            tls[ep].append(float(r['tls_ms']))
    hdr=f"{'endpoint':<21}{'n':>5}{'succ%(传输)':>12}{'succ%(排除5xx)':>15}{'conn p95':>10}{'ttfb p95':>10}{'ttfb max':>10}{'抖动比':>8}  判定"
    print(hdr); print("-"*len(hdr))
    allpass=True
    for ep in sorted(tot):
        n=tot[ep]; tf=transport_fail[ep]; f5=http5[ep]
        s_transport=100*(n-tf)/n
        s_strict=100*(n-tf-f5)/n
        conn=[x[0] for x in rows[ep]]; ttfb=[x[1] for x in rows[ep]]
        cp95=pct(conn,95); t50=pct(ttfb,50); t95=pct(ttfb,95); jit=t95/t50 if t50 else float('nan')
        ck={'succ':s_strict>=98.0,'conn':cp95<300,'ttfb':t95<1500,'jit':jit<3}
        v='PASS' if all(ck.values()) else 'FAIL:'+','.join(k for k,x in ck.items() if not x)
        if not all(ck.values()): allpass=False
        print(f"{ep:<21}{n:>5}{s_transport:>12.2f}{s_strict:>15.2f}{cp95:>10.1f}{t95:>10.1f}{max(ttfb):>10.1f}{jit:>8.2f}  {v}")
    print(f"\n  5xx: {dict(http5)}   传输层失败: {dict(transport_fail)}")
    print(f"  TLS 握手 max: " + ", ".join(f"{e}={max(v):.0f}ms" for e,v in sorted(tls.items()) if v))
    print(f"  ==> {'全部 PASS' if allpass else '有 FAIL'}（succ 用严格口径：5xx 计为失败）")
