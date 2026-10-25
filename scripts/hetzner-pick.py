#!/usr/bin/env python3
"""hetzner-pick.py —— 在 Hetzner Cloud 上自动「开机 → 验机 → 不合格就删掉重开」，直到开到一台合格的。

为什么要这样：共享 vCPU 的套餐，同一个机型每次开出来的 CPU 型号不一样，单核能差一倍
（2026-10 连开到两台 Intel Skylake，单核耗时是 AMD EPYC-Rome 参考机的 1.7 倍左右）。
CI 里单核受限的 job 会因此超时。验机用同目录的 machine-check.sh，判定规则见它的文件头和 02 章 2.7。

准备：
  1. Hetzner 控制台 → 项目 → Security → API tokens，建一个 Read & Write 的令牌。
  2. 运行脚本的人的 SSH 公钥已经加进这个项目（Security → SSH keys），本机用它能登录。
  3. 本机有 python3 和 ssh（Mac、Linux、Windows 10 以上都自带 ssh）。

用法：
  export HCLOUD_TOKEN=<令牌>                      # 只放环境变量，别写进文件
  python3 hetzner-pick.py --list                  # 看有哪些 x86、≥4 核、≥8 GB 的机型，各机房的价格和能不能买
  python3 hetzner-pick.py --type <机型> --keys "<我的钥匙名>,<还要装的钥匙名>" --ref 2.5

  --keys      建机时装进 root 的 SSH 钥匙（Hetzner 里的名字，逗号分隔）。必须包含运行脚本的人自己的那把。
  --ref       参考机的单核分数（在现有 runner 上跑 machine-check.sh 得到）。
  --locations 只在这些机房里挑，逗号分隔，默认是这个机型当下能买到的全部机房。
  --max-tries 最多开几台，默认 8。   --wait-min / --wait-max  两次之间随机等多少秒，默认 120 到 420。
  --identity  登录用的私钥文件，默认用 ssh 自己的默认钥匙。

结果：合格就停，打印 IP 和验机摘要，服务器打上标签 ci-check=pass；不合格的当场删掉。
每台至少按 Hetzner 的小时价计费（开了马上删，大约是一小时的钱），--list 里有价格。
脚本只删它这次自己建的服务器（带标签 created-by=hetzner-pick）。中途按 Ctrl-C 也会删掉正在测的那台。
"""
import argparse
import datetime
import json
import os
import random
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("HCLOUD_ENDPOINT", "https://api.hetzner.cloud/v1").rstrip("/")
SCRIPT_URL = "https://raw.githubusercontent.com/F-WORKS-FBY/self-hosted-runner-playbook/main/scripts/machine-check.sh"
LABEL = {"created-by": "hetzner-pick"}
UNAVAILABLE = ("resource_unavailable", "placement_error")


def now():
    return datetime.datetime.now().strftime("%H:%M:%S")


def say(msg=""):
    print(f"[{now()}] {msg}" if msg else "", flush=True)


class ApiError(Exception):
    def __init__(self, status, code, message):
        super().__init__(f"HTTP {status} {code}: {message}")
        self.status, self.code = status, code


def api(method, path, body=None):
    token = os.environ.get("HCLOUD_TOKEN", "")
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(5):
        req = urllib.request.Request(API + path, data=data, method=method, headers={
            "Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            try:
                err = json.loads(e.read() or b"{}").get("error", {})
            except ValueError:
                err = {}
            if e.code == 429 or err.get("code") == "rate_limit_exceeded":
                time.sleep(10 * (attempt + 1))
                continue
            raise ApiError(e.code, err.get("code", "?"), err.get("message", ""))
        except urllib.error.URLError as e:
            if attempt == 4:
                raise
            say(f"连不上 Hetzner API（{e.reason}），10 秒后重试")
            time.sleep(10)
    raise ApiError(429, "rate_limit_exceeded", "重试多次仍被限流")


def server_types():
    out, page = [], 1
    while True:
        r = api("GET", f"/server_types?per_page=50&page={page}")
        out += r.get("server_types", [])
        if not (r.get("meta", {}).get("pagination", {}) or {}).get("next_page"):
            return out
        page += 1


def price(t, loc):
    for p in t.get("prices", []):
        if p.get("location") == loc:
            return float(p["price_hourly"]["gross"]), float(p["price_monthly"]["gross"])
    return None, None


def available_locations(t):
    return [l["name"] for l in t.get("locations", []) if l.get("available", True) and not l.get("deprecation")]


def cmd_list():
    rows = [t for t in server_types() if t.get("architecture") == "x86" and t["cores"] >= 4
            and t["memory"] >= 8 and not t.get("deprecated")]
    rows.sort(key=lambda t: (t["cores"], t["memory"], t["name"]))
    say("x86、≥4 核、≥8 GB 的机型（价格含税，欧元；只列当下能买的机房）：")
    for t in rows:
        locs = available_locations(t)
        desc = f"{t['name']:<8} {t['cores']:>2} 核 {t['memory']:>4.0f} GB 盘 {t['disk']:>4} GB  {t.get('cpu_type', '?')}  {t.get('description', '')}"
        print("  " + desc)
        for loc in locs:
            h, m = price(t, loc)
            print(f"      {loc:<6} 每小时 {h:.4f}  每月 {m:.2f}" if h is not None else f"      {loc}")
        if not locs:
            print("      （当下没有机房能买）")
    print("\n注意：cpu_type=shared 的套餐 CPU 型号不固定，正是要用本脚本筛的那种。")


def ssh_base(args, known_hosts):
    base = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30",
            "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={known_hosts}"]
    if args.identity:
        base += ["-i", os.path.expanduser(args.identity), "-o", "IdentitiesOnly=yes"]
    return base


def wait_running(sid, timeout=600):
    end = time.time() + timeout
    while time.time() < end:
        s = api("GET", f"/servers/{sid}")["server"]
        if s["status"] == "running":
            return s
        time.sleep(5)
    raise TimeoutError("服务器 10 分钟内没进入 running 状态")


def wait_ssh(base, ip, timeout=420):
    end = time.time() + timeout
    while time.time() < end:
        if subprocess.run(base + [f"root@{ip}", "true"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0:
            return True
        time.sleep(10)
    return False


def run_check(base, ip, args):
    # 先等首次开机的 cloud-init（会跑 apt）结束，免得它抢 CPU 把分数拉低。
    # 先下载成文件再跑：写成 curl | bash 的话，下载失败时 bash 读到空脚本、以 0 退出，会被当成合格。
    remote = (f"cloud-init status --wait >/dev/null 2>&1; sleep 15; "
              f"curl -fsSL {args.script_url} -o /root/machine-check.sh && REF={args.ref} bash /root/machine-check.sh")
    p = subprocess.run(base + [f"root@{ip}", remote], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, encoding="utf-8", errors="replace")
    return p.returncode, p.stdout


def brief(output):
    keep = []
    for line in output.splitlines():
        s = line.strip()
        if s.startswith(("CPU：", "单核分数", "== 和参考机比", "✗", "!", "摘要：")):
            keep.append(s)
    return keep


def delete_server(sid, created):
    if sid not in created:
        say(f"拒绝删除 {sid}：不是本次运行建的")
        return
    s = api("GET", f"/servers/{sid}")["server"]
    if (s.get("labels") or {}).get("created-by") != LABEL["created-by"]:
        say(f"拒绝删除 {sid}：标签不对")
        return
    api("DELETE", f"/servers/{sid}")
    created.discard(sid)
    say(f"已删除服务器 {s['name']}（{sid}）")


def _stop(signum, frame):
    raise KeyboardInterrupt


def main():
    # Ctrl-C、kill、关掉终端窗口都走同一条清理路径，别让正在测的机器留着计费。
    # SIGINT 也显式设一次：从非交互 shell 后台启动时它会被继承成「忽略」。
    for name in ("SIGINT", "SIGTERM", "SIGHUP"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), _stop)
    ap = argparse.ArgumentParser(description="Hetzner：开机验机，不合格删掉重开，直到合格")
    ap.add_argument("--list", action="store_true", help="列出可选机型和价格")
    ap.add_argument("--type", help="机型名，例如 --list 里看到的 cx33")
    ap.add_argument("--keys", help="建机时装的 SSH 钥匙名，逗号分隔，必须含自己的")
    ap.add_argument("--ref", type=float, help="参考机单核分数")
    ap.add_argument("--locations", default="", help="只在这些机房挑，逗号分隔")
    ap.add_argument("--image", default="ubuntu-24.04")
    ap.add_argument("--max-tries", type=int, default=8)
    ap.add_argument("--wait-min", type=int, default=120)
    ap.add_argument("--wait-max", type=int, default=420)
    ap.add_argument("--identity", default="", help="登录用的私钥文件")
    ap.add_argument("--name-prefix", default="ci-runner")
    ap.add_argument("--script-url", default=SCRIPT_URL)
    args = ap.parse_args()

    if not os.environ.get("HCLOUD_TOKEN"):
        sys.exit("先 export HCLOUD_TOKEN=<Hetzner 项目的 Read & Write 令牌>")
    if args.list:
        cmd_list()
        return 0
    if not (args.type and args.keys and args.ref):
        sys.exit("要给 --type、--keys、--ref（先用 --list 看机型）")
    if args.wait_max < args.wait_min:
        sys.exit("--wait-max 不能小于 --wait-min")

    types = {t["name"]: t for t in server_types()}
    t = types.get(args.type)
    if not t:
        sys.exit(f"没有机型 {args.type}，用 --list 看可选的")
    if t.get("architecture") != "x86" or t["cores"] < 4 or t["memory"] < 8:
        sys.exit(f"{args.type} 是 {t.get('architecture')} {t['cores']} 核 {t['memory']} GB，不满足 x86、≥4 核、≥8 GB")
    locs = available_locations(t)
    if args.locations:
        want = [x.strip() for x in args.locations.split(",") if x.strip()]
        locs = [l for l in want if l in locs]
    if not locs:
        sys.exit(f"{args.type} 在指定机房里当下都买不到")
    keys = [k.strip() for k in args.keys.split(",") if k.strip()]
    for k in keys:
        if not api("GET", f"/ssh_keys?name={urllib.parse.quote(k)}").get("ssh_keys"):
            sys.exit(f"Hetzner 项目里没有叫「{k}」的 SSH 钥匙")
    h, _ = price(t, locs[0])
    say(f"机型 {args.type}（{t['cores']} 核 {t['memory']:.0f} GB），机房 {','.join(locs)}，参考分数 {args.ref}，"
        f"最多 {args.max_tries} 台，每台约 {h:.4f} 欧元起" if h else f"机型 {args.type}，机房 {','.join(locs)}")

    created, attempts = set(), []
    known_hosts = tempfile.NamedTemporaryFile(prefix="hetzner-pick-known-", delete=False).name
    base = ssh_base(args, known_hosts)
    stamp = datetime.datetime.now().strftime("%m%d-%H%M")
    current = None
    try:
        unavailable = set()
        for n in range(1, args.max_tries + 1):
            # 刚开不出来的机房先跳过；全都开不出来过，就清空重来
            pool = [l for l in locs if l not in unavailable] or locs
            if len(pool) == len(locs):
                unavailable.clear()
            loc = random.choice(pool)
            name = f"{args.name_prefix}-{stamp}-{n}"
            say(f"第 {n}/{args.max_tries} 台：在 {loc} 开 {name}")
            try:
                r = api("POST", "/servers", {
                    "name": name, "server_type": args.type, "image": args.image, "location": loc,
                    "ssh_keys": keys, "start_after_create": True,
                    "labels": dict(LABEL, **{"ci-check": "testing"}),
                    "public_net": {"enable_ipv4": True, "enable_ipv6": True}})
            except ApiError as e:
                if e.code in UNAVAILABLE:
                    unavailable.add(loc)
                    say(f"  {loc} 现在开不出来（{e.code}），换个机房")
                    attempts.append((name, loc, "开不出来", ""))
                    continue
                raise
            current = r["server"]["id"]
            created.add(current)
            s = wait_running(current)
            ip = s["public_net"]["ipv4"]["ip"]
            say(f"  已开机：{ip}，等 SSH 能登录")
            if not wait_ssh(base, ip):
                say("  7 分钟内登不进去（钥匙不对或机器有问题），删掉换下一台")
                attempts.append((name, loc, "登不进去", ip))
                delete_server(current, created)
                current = None
            else:
                say("  开始验机（约 2 分钟）")
                rc, out = run_check(base, ip, args)
                if rc == 2:
                    say("  有保留，3 分钟后复测一次")
                    time.sleep(180)
                    rc, out = run_check(base, ip, args)
                for line in brief(out):
                    say("    " + line)
                if rc == 0 and "摘要：合格" not in out:
                    rc = 3   # 退出码是 0 却没有合格的摘要，按没跑完处理，不冒险
                if rc == 0:
                    api("PUT", f"/servers/{current}", {"labels": dict(LABEL, **{"ci-check": "pass"})})
                    attempts.append((name, loc, "合格", ip))
                    current = None
                    say("")
                    say(f"合格：{name}  IP {ip}  机房 {loc}")
                    say(f"装在 root 上的钥匙：{', '.join(keys)}。服务器已打标签 ci-check=pass，保留不删。")
                    return 0
                verdict = {1: "不合格", 2: "复测仍有保留"}.get(rc, f"验机没跑完（退出码 {rc}）")
                attempts.append((name, loc, verdict, ip))
                say(f"  {verdict}，删掉")
                delete_server(current, created)
                current = None
            if n < args.max_tries:
                wait = random.randint(args.wait_min, args.wait_max)
                say(f"  随机等 {wait} 秒（到 {(datetime.datetime.now() + datetime.timedelta(seconds=wait)).strftime('%H:%M:%S')}）再开下一台")
                time.sleep(wait)
        say("")
        say(f"试了 {args.max_tries} 台都不合格：")
        for a in attempts:
            say(f"  {a[0]}  {a[1]}  {a[2]}  {a[3]}")
        return 1
    except KeyboardInterrupt:
        say("收到中断信号，清理正在测的服务器")
        return 130
    finally:
        if current is not None:
            # 清理期间再按 Ctrl-C 也别打断删除
            for name in ("SIGINT", "SIGTERM", "SIGHUP"):
                if hasattr(signal, name):
                    signal.signal(getattr(signal, name), signal.SIG_IGN)
            try:
                delete_server(current, created)
            except Exception as e:  # 清理失败要大声说，别让一台机器悄悄留着计费
                say(f"！！删除 {current} 失败：{e}。请到 Hetzner 控制台手动删掉标签 created-by=hetzner-pick、ci-check=testing 的服务器")
        try:
            os.unlink(known_hosts)
        except OSError:
            pass


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ApiError as e:
        hint = "令牌不对，或者不是 Read & Write 权限" if e.status in (401, 403) else "看上面的信息"
        sys.exit(f"Hetzner API 返回错误：{e}（{hint}）")
