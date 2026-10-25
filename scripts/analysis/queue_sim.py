"""单 runner 排队仿真：用真实 run 创建时间戳 + 本机实测服务时长。
限制：只模拟一个 runner；下面四个 workflow 名和它们的 concurrency 规则是按参考项目写死的，
事件里出现别的 workflow 名会在 CANCEL_RUNNING[wf] 处报 KeyError。用到别的仓库，先改 CANCEL_RUNNING 和 group()。
参考项目各 workflow 的 concurrency 设置：
  ci.yml            group=ci-<ref>,        cancel-in-progress=true  -> 同分支新 run 取消【排队中 + 正在跑】的旧 run
  main-post-merge   group=main-post-merge, cancel-in-progress=false -> 新 run 顶掉【排队中】的旧 run，不动正在跑的
  pr-meta           group=pr-meta-<PR>,    cancel-in-progress=true  -> 同分支同上
  nightly           group=nightly,         cancel-in-progress=false -> 同 main-post-merge
"""
import json, datetime as dt, heapq
def ts(x): return dt.datetime.fromisoformat(x.replace('Z','+00:00'))
CANCEL_RUNNING = {'ci': True, 'pr-meta': True, 'main-post-merge': False, 'nightly': False}
def group(wf, br): return f"{wf}|{br}" if wf in ('ci','pr-meta') else wf

def simulate(events, svc):
    events = sorted(events, key=lambda e: e[0])
    q = []                      # [(enqueue_time, wf, br)]
    running = None              # (enqueue_time, wf, br, start_time)
    free_at = None
    waits = []; done = 0; cancelled_q = 0; cancelled_run = 0
    i = 0
    while i < len(events) or q or running:
        nxt = events[i][0] if i < len(events) else None
        # runner 先完成
        if running and (nxt is None or free_at <= nxt):
            clock = free_at
            waits.append(((clock - running[3]).total_seconds(), (running[3] - running[0]).total_seconds()))
            running = None; free_at = None; done += 1
        elif nxt is not None:
            clock = nxt
            while i < len(events) and events[i][0] == clock:
                t, wf, br = events[i]; i += 1
                g = group(wf, br)
                before = len(q); q = [x for x in q if group(x[1], x[2]) != g]; cancelled_q += before - len(q)
                if running and CANCEL_RUNNING[wf] and group(running[1], running[2]) == g:
                    running = None; free_at = None; cancelled_run += 1
                q.append((t, wf, br))
        else:
            break
        if not running and q:
            t, wf, br = q.pop(0)
            running = (t, wf, br, clock); free_at = clock + dt.timedelta(seconds=svc[wf])
    return dict(done=done, cancelled_q=cancelled_q, cancelled_run=cancelled_run,
                waits=sorted(w[1] for w in waits))

def report(label, events, svc):
    r = simulate(events, svc)
    w = r['waits']
    if not w: print(f"  {label}: 无完成的 run"); return
    p = lambda q: w[min(len(w)-1, int(q*(len(w)-1)))]
    print(f"  {label}")
    print(f"     完成 {r['done']:>3} | 排队中被顶掉 {r['cancelled_q']:>3} | 跑到一半被取消 {r['cancelled_run']:>3}"
          f" | 等待 中位 {p(.5)/60:5.1f}min  p90 {p(.9)/60:5.1f}min  最长 {max(w)/60:5.1f}min")
