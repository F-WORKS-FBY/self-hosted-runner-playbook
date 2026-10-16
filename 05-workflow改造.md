## 05 workflow 改造：常驻 runner 上会坏掉的托管假设

本章列出 workflow 里依赖托管 runner 特性的写法，以及在自建常驻 runner 上该怎么改。这是整本手册里最可迁移的部分：前面几章的内容换个云厂商就要调整，本章的内容对任何仓库都适用。

托管 runner 给每个 job 分配一台全新的一次性 VM：

- `/tmp` 是空的；
- 容器名没被用过；
- 端口没被占用；
- 磁盘是干净的；
- job 跑完，VM 就销毁。

几乎每个仓库的 workflow 里都积累了一批依赖这些性质的写法。它们在托管 runner 上不会出问题，所以也一直没有暴露出来。

本章用到的两个说法：

- N=1：只有一台自建 runner，所有 job 在这台机器上串行排队。
- 假绿：检查本该失败，结果却显示通过。

下面 ①–⑪ 共十一条，每条按「怎么自查 → 失败是什么样 → 怎么改」组织；⑫ 是上线一个月后补充的。建议把它们当作 checklist，对照你的 workflow 逐条检查。章末有一组汇总命令，改完后用来确认。

---

### ① 固定容器名

workflow 里用写死的名字起容器、又没有删掉它时，在常驻机器上第 2 个 run 就会因为重名而失败。

自查：

```bash
grep -rn -- '--name ' .github/workflows/ ; grep -rc 'docker rm\|docker stop' .github/workflows/
```

起了容器、但 `docker rm` 出现 0 次，就是命中。

失败时的报错：

```text
docker: Error response from daemon: Conflict.
The container name "/minio" is already in use by container "7eb4689c...".
```

第 2 个 run 就会失败，而且报错和代码改动无关。

同一个 run 里的两个 job 用同一个写死的名字时更严重，冲突是必然的，与概率无关：

- 托管 runner 上，两个 job 在两台独立 VM 上，互不影响。
- N=1 的自建机上，两个 job 在同一台机器上串行。第一个 job 不清理，第二个 job 一定冲突。

怎么改：

```yaml
env:
  # 唯一到 run × attempt × job 三级：
  #  · run_attempt 是真判据 —— re-run 时 run_id 不变
  #  · github.job 不可省 —— 同一个 run 里的两个 job 只到 run 级仍会自撞
  SVC_NAME: myservice-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}
  CI_LABEL: com.myorg.ci=1          # 与 bootstrap.sh 的 CI_LABEL 完全一致
steps:
  - run: |
      docker rm -fv "$SVC_NAME" 2>/dev/null || true     # 起前幂等
      docker run -d --name "$SVC_NAME" --label "$CI_LABEL" ...
  - if: always()                                         # 取消/失败也要清
    run: docker rm -fv "$SVC_NAME" 2>/dev/null || true
```

要点：

- **`--label` 的值必须和 bootstrap.sh 里的 `CI_LABEL` 完全一致。** 清理钩子第 1 步按这个 label 删除上一个 job 没删掉的容器。本模板原来写的是 `--label ci=1`，和任何 `CI_LABEL` 都对不上。
- 删除容器用 `rm -fv`，不用 `rm -f`。镜像声明了 `VOLUME` 时（minio、postgres、redis、prometheus 都声明了），Docker 会建匿名卷，带 `-v` 才会连卷一起删。本模板原来写的是 `rm -f`，参考项目沿用了这个模板，原来每个起 minio 的 job 漏 1 个卷（10-16 已改，见 ⑫）。
- `docker run --rm` 解决不了漏卷。实测 `run -d --rm` 之后再 `rm -f`（不带 -v），卷照样留下。`--rm` 只在容器自己退出或被 `docker stop` 时生效。
- `rm -fv` 只在清理步骤真的跑了时有用。runner 进程被杀时 `if: always()` 也不执行，容器留给钩子删。更稳的是在镜像的 VOLUME 路径挂 tmpfs，一开始就不建卷，写法和注意事项见 ⑫。
- 清理钩子并非只按 label 过滤。它的第 6 步是一条不带过滤的 `docker volume prune`，用来兜底回收匿名卷（本模板原来说「绝不裸 prune」，这个说法不对）。workflow 里写对了，就不必依赖它。service 容器的卷见 ⑫。

---

### ② 服务端口默认绑 `0.0.0.0`

`ports:` 只写 `宿主端口:容器端口` 时，端口绑在 `0.0.0.0` 上，服务会直接暴露到公网。

自查：

```bash
grep -rn "ports:" .github/workflows/ | grep -v "127.0.0.1"
```

失败是什么样：CI 不会失败，所以也不会提醒你。它只是把你的数据库开放到了公网上。

> 实测：`ports: ['5433:5432']` 加明文 `POSTGRES_PASSWORD`，check-host.net 的四个境外节点全部成功建立 TCP 连接，并收到 Postgres 的认证响应。当时宿主的 `ufw` 是 inactive，但这不影响结论：Docker 的 DNAT 本来就绕过 ufw。

怎么改：

```yaml
services:
  postgres:
    ports: ['127.0.0.1:5433:5432']    # runner 把三段式原样透传给 docker create（已实测）
```

确认：localhost 可以连上，从公网连接返回 `Connection refused`。

---

### ③ 固定 `/tmp` 路径

写死的 `/tmp/...` 路径在常驻机器上会被多个 job 共用，会出三类问题。

自查：

```bash
grep -rn '/tmp/' .github/workflows/
```

失败是什么样（第三种最危险）：

1. 权限：文件属于别的用户，`tee: /tmp/x.log: Permission denied`，步骤直接失败。
2. 并发：两个 job 写同一个路径，断言读到别的 job 的数据。
3. 读到陈旧文件，静默假绿：写文件那一步失败了，但上一次 run 留下的同名文件里恰好有你要 grep 的字符串，断言因此通过。这条检查本该发现问题，结果变成永远通过的摆设。托管 runner 上不可能发生；在常驻机器上，只差一句 `rm`。

怎么改：一律用 `$RUNNER_TEMP`。runner 为每个 job 新建并清理这个目录，托管和自建的行为一致。

```yaml
- run: mycmd | tee "$RUNNER_TEMP/out.log" && grep -q "expected" "$RUNNER_TEMP/out.log"
```

---

### ④ 依赖预装工具

workflow 里用到的命令行工具，自建机上不一定装了。

自查：

```bash
grep -rhoE '\b(gh|jq|yq|aws|az|gcloud|make|cmake|gcc|zstd|unzip)\b' .github/workflows/ | sort -u
# 然后在 runner 上：for c in <上面这些>; do command -v $c || echo "缺 $c"; done
```

失败分两级，第二级更麻烦：

- 命令后面没有 `||` 兜底：步骤直接失败（`bash -e`），至少能看到。
- 命令后面有 `|| fallback`：静默降级。表现为路径门控退化成全跑、定时任务每次都跑、某个检出被跳过。**门禁看起来还在跑，实际已经失效。**

怎么改：把缺的工具装上，并把工具清单写进你的 bootstrap，不要靠记忆。

---

### ⑤ 依赖「全新文件系统」的缓存：在常驻机器上变成负担

常驻机器上，缓存从必需变成了净负担；但去掉它会让回退到托管 runner 时变慢，需要取舍。

自查：workflow 里有 `actions/cache`，或者 `setup-*` 的 `cache:` 选项。

为什么会这样：

- 托管 runner 上缓存是必需的，因为 VM 每次都是空的。
- 常驻机器上它是净负担：把本地已经有的东西传到云上，再传回来。

> 实测：`actions/setup-node` 的 `cache: pnpm` 每个 run 从 GitHub 缓存服务恢复约 218 MB，setup-node 步骤耗时 11–12 秒。去掉后是 1 秒，`pnpm install` 仍是 6 秒（本地 store 常驻）。每个 run 净省约 10 秒和 218 MB 流量。

怎么改：先想清楚回退。去掉缓存后，回落到托管 runner 时每个 job 要多付一次冷装（约 52 秒）。想用条件表达式两头兼顾，做不到：

```yaml
cache: ${{ vars.CI_RUNNER && '' || 'pnpm' }}     # ❌ 不成立
# GitHub 表达式里 && / || 返回操作数的值，而空串是 falsy：
# CI_RUNNER 已设 → (CI_RUNNER && '') = '' → '' 是 falsy → ('' || 'pnpm') = 'pnpm'
# 永远产出 'pnpm'。写 'none' 之类会让 setup-node 直接报错。
```

所以只能二选一：要么接受每个 run 多 10 秒，要么接受回退时变慢。参考项目选择保留缓存（10 秒占单个 run 的 3%）。

---

### ⑥ workflow 最后一步的清理在 job 被取消时不执行

job 被取消时，写在最后一步、又没带 `if: always()` 的清理步骤会被跳过。

自查：你的 workflow 里有没有 `cancel-in-progress: true`？有的话，检查清理步骤是否带了 `if: always()`。

怎么改：

- 清理步骤加 `if: always()`。
- 在 runner 侧挂 `JOB_STARTED` 钩子兜底。

说明：runner 侧的 `JOB_COMPLETED` 钩子在 job 被取消时其实会执行。它跑不到的情况有两种：job 在初始化阶段就被取消；runner 服务被停掉。详见 04 章 4.4。

---

### ⑦ `timeout-minutes` 的含义变了

在 N=1 的自建 runner 上，`timeout-minutes` 决定了一个卡死的 job 最多能让全组 CI 停多久，所以要对照实测时长重新检查。

| 环境 | `timeout-minutes` 的含义 | job 跑飞的后果 |
|---|---|---|
| 托管 runner | 这个 job 最多烧多少钱 | 只烧掉自己那台一次性 VM |
| N=1 自建 runner | 全组 CI 停摆的上界 | 独占唯一的 runner，后面所有 PR 一起等 |

自查：

```bash
grep -rn "timeout-minutes" .github/workflows/    # 对照你的实测时长
```

> 参考项目：现值是实测时长的 8–150 倍（lint 15 min / 实测 22 s = 41×；build 30 min / 实测 12–70 s = 26–150×）。一次 ci run 最坏占用 15+15+30+30 = 90 分钟。按「实测 p95 × 4」重设后是 29 分钟。

注意：`timeout-minutes` 从 job 开始执行才计时，排队时间不算。机器宕机导致排队 24 小时这种情况它管不了，要靠哨兵（06 章 6.4）。

---

### ⑧ job 级并行的假设

要不要为 N=1 合并 job，先量再决定：合并 job 在自建机上的收益比在托管上小得多。

- 托管 runner 上，多个 job 并行是免费的（各自一台 VM）。
- N=1 上，它们串行排队，每多一个 job 就多付一次脚手架。

不要急着合并 job。先量两个数，即托管和自建机上各自的每 job 脚手架时间：

```text
每 job 脚手架 = Set up job + checkout + setup-* + install + post cleanup
```

> 参考项目：托管上脚手架约 52 秒/job（合并 4→1 省 156 秒）；自建机上只有约 16 秒/job（合并只省 48 秒），因为常驻机器上依赖早就在盘上了。收益缩水 3 倍，而代价（文档同步、required check 粒度、回退时降级）一点没少。

判断方法：用真实事件时间戳做排队仿真（08 章 8.1），比较「合并 job」和其他提速手段的实际收益。

参考项目的结论：合并 job 与「修 Dockerfile 层序 + 去 cache」效果相当（最忙那天 11.7 vs 11.2 分钟），而后者不用改任何文档。**先做后者。**

---

### ⑨ 孤儿进程导致的假绿

测试依赖的后台进程如果是上一次 run 遗留的孤儿进程，测试会跑在旧代码上，CI 却可能显示通过。

自查：workflow 或测试代码里有没有「起一个后台进程 → 轮询它的健康端点 → 跑测试」这个模式？如果就绪判据只是 `curl <url>`，不校验应答的是不是自己刚起的那个进程，就是命中。

失败是什么样：

```text
[api:err] Error: listen EADDRINUSE: address already in use 0.0.0.0:3100   ← 只在 stderr 留一行，不失败
 Test Files  1 failed | 8 passed (9)
      Tests  1 failed | 220 passed (221)                                  ← 220 个测试跑在**孤儿**上
```

> 实测：用一个孤儿进程占住端口后跑 e2e，221 条里 220 条通过，唯一失败的那条还指向认证代码，而不是真实原因。换一个对状态不敏感的孤儿进程，结果就是全绿。

**也就是说，整套 e2e 跑在上一次 run 的代码上，而 CI 是绿的。**

孤儿进程的来源：

- `teardown` 只有一行 `proc.kill()`，而 job 被取消时它不执行。
- runner 的 `KillMode=process` 也不杀子进程。

怎么改：分三层，至少做前两层。

第一层（代码注释中的 ①）：起进程之前，先确认端口没被占用。

```ts
// ① 起之前先确认端口没被占 —— 用裸 TCP 连接，不依赖对方回什么
async function assertPortFree(port: number) {
  const busy = await new Promise<boolean>((res) => {
    const s = connect({ port, host: '127.0.0.1' });
    const done = (v: boolean) => { s.destroy(); res(v); };
    s.setTimeout(2000);
    s.once('connect', () => done(true));
    s.once('timeout', () => done(false));
    s.once('error',   () => done(false));
  });
  if (busy) throw new Error(`端口 ${port} 已被占用——多半是上一次 run 的孤儿进程。先清掉再跑。`);
}
```

第二层（代码注释中的 ②）：在 runner 的 `JOB_STARTED` 钩子里清掉孤儿进程。

```bash
# ② runner 的 JOB_STARTED 钩子里清孤儿
fuser -k 3100/tcp 3101/tcp 2>/dev/null || true
```

第三层：用云防火墙挡住这些宿主端口。它们不是容器，`-p 127.0.0.1` 管不到。

---

### ⑩ 宿主进程绑 `0.0.0.0`

② 只管容器。测试直接 spawn 起来的应用进程是宿主进程，没有 `-p` 可以绑，需要另外处理。

自查：`grep -rn "0\.0\.0\.0\|listen(" <你的应用入口>`

怎么改：

- 优先靠云防火墙（04 章 4.7）。宿主进程不走 DOCKER 链，所以主机防火墙和云防火墙对它都有效。
- 也可以改应用代码的绑定地址，但要先确认两点：不会破坏容器形态（容器内必须绑 `0.0.0.0` 才能被发布端口访问到）；不和仓库已有的绑定地址约定冲突。

---

### ⑪ 供应链：爆炸半径变了

同样的供应链事故，在自建 runner 上的影响范围比托管大得多，所以 action 和镜像都要钉死。

自查：

```bash
grep -rhoE 'uses: [^ ]+' .github/workflows/ | sort -u    # 有几个钉在浮动 major tag 上
grep -rn 'image:' .github/workflows/ | grep -v '@sha256'  # 有几个镜像没钉 digest
```

为什么在自建上更要紧：同样是「上游 tag 被重新指向」的事故，在托管 runner 上泄露的是一台一次性 VM，在你的机器上泄露的是宿主 root（因为 runner 在 `docker` 组里）。

怎么改：

- action 钉 commit SHA，并开启 dependabot。
- 镜像钉 digest。

---

### ⑫ 匿名卷：service 容器和自己起的容器都会留（上线一个月后补）

常驻机器上，CI 容器留下的匿名卷如果没有清理钩子兜底，会不断累积。凡是镜像声明了 VOLUME 的容器，都在那个路径挂 tmpfs；自己起的容器删除时再用 `rm -fv`。

自查：

```bash
docker volume ls -q | wc -l                       # 在一台常驻 runner 上看；钩子没在跑的话会一直涨
grep -rn 'docker rm -f ' .github/workflows/ tools/ | grep -v -- '-fv'   # 应为空
```

机制：镜像声明了 `VOLUME`、启动时又没挂 `-v`/`--mount`/`--tmpfs`，Docker 就建一个匿名卷；删容器时不带 `-v`，卷就留下。卷有两处来源：

| 来源 | 谁删容器 | workflow 能改吗 |
|---|---|---|
| `services:` 里的 postgres / redis | runner 自己，`docker rm --force`，不带 `-v` | 能，挂 tmpfs（见下） |
| 步骤里 `docker run -d` 起的（minio、prometheus…） | workflow 的 `docker rm -f` | 能，挂 tmpfs，删除时用 `rm -fv`（见 ①） |

参考项目里，每个用到数据库的 job 原来漏 3 个卷（postgres + redis + minio），约 70 MB，大头是 PGDATA；跑了监控冒烟的 build job 还会给 prometheus 漏 1 个（改了监控配置时跑；碰到 packages/、lockfile、根 package.json 等共享面，或手动触发时也全跑）。那台机器上卷数始终是 0，因为清理钩子的 `docker volume prune` 在每个 job 前后都在回收。这是钩子在兜底，workflow 本身并没有写对。换一台没装钩子的常驻 runner，卷数就会一直涨。

参考项目 2026-10-16 按下面的写法改完（metta-app #269）：postgres、redis、minio、prometheus 都挂 tmpfs，起这些容器的 job 都在起完后核对没挂卷。合并前在 runner 上记了约 15 分钟 `docker events`，覆盖 nightly 的两个 job 和 build job 的两个冒烟，这些容器照常建了又删，期间没有新建卷。

怎么改：给 service 容器挂 tmpfs，从源头上不产生卷。2026-10-16 在参考机上实测：postgres 正常启动，`docker inspect` 的 Mounts 为空，删容器后新增卷 0 个。

```yaml
services:
  postgres:
    image: pgvector/pgvector:0.8.7-pg18@sha256:...
    options: >-
      --tmpfs /var/lib/postgresql:size=1g
      --health-cmd "pg_isready -U app" ...
  redis:
    image: redis:7-alpine
    options: --tmpfs /data:size=64m
```

注意：**tmpfs 的路径必须是镜像声明的 VOLUME 路径**，用 `docker image inspect <镜像> --format '{{json .Config.Volumes}}'` 查。

- postgres 18 的镜像声明的是 `/var/lib/postgresql`，不是常见的 `/var/lib/postgresql/data`。后者是 17 及以前的路径；18 起 PGDATA 在 `/var/lib/postgresql/<大版本>/docker`。
- 路径写错不会报错，只是卷照样建、照样漏。
- tmpfs 占内存（参考项目约 50–120 MB/job）。它记在容器的 cgroup 上，不在 runner 的 MemoryMax 里；但在没有 swap 的机器上它占的是真内存，所以 `size=` 必须写。
- 镜像以非 root 用户运行时，tmpfs 要加 `mode=1777`。prometheus 以 nobody 运行，不加的话报 `/prometheus/queries.active: permission denied`，起不来。postgres、redis 的入口脚本会先以 root 改属主，不用加。
- 步骤里起的容器同样挂：`docker run -d ... --tmpfs /data:size=256m <minio 镜像> server /data`。参考机上实测 minio 在 tmpfs 上写 20 MB 对象、读回逐字节一致。

钩子每个 job 都清卷，tmpfs 路径写错、漏了卷也看不出来。所以在起完容器后加一步核对，有 `volume` 类型的挂载就让 job 失败：

```yaml
- name: 容器没有挂卷
  env:
    IDS: ${{ job.services.postgres.id }} ${{ job.services.redis.id }}
  run: |
    out=$(docker inspect -f '{{.Name}}{{range .Mounts}}{{if eq .Type "volume"}} {{.Destination}}{{end}}{{end}}' $IDS "$SVC_NAME")
    echo "$out"
    if [ "$(wc -l <<<"$out")" -ne 3 ]; then echo "::error::应核对 3 个容器"; exit 1; fi
    if grep -q ' ' <<<"$out"; then echo "::error::上面带路径的容器挂了 docker 卷"; exit 1; fi
```

数量也要核：service 改了名字时 `job.services.<名字>.id` 是空串，少核一个容器也不会报错。

另外，`docker build` 也要打上 `--label "$CI_LABEL"`，清理钩子才能删掉过期的 CI 镜像；不打标签时，钩子里那条清理匹配到 0 个镜像。标签漏打也不报错，参考项目让每个 build 带 `--iidfile "$RUNNER_TEMP/ci-images/<名字>"`（先 `mkdir -p "$RUNNER_TEMP/ci-images"`），再加一步遍历这些文件核对标签。

参考项目还在 job 末尾的 `if: always()` 清理里加了一条 `docker image prune -f --filter "label=$CI_LABEL"`（不带 `-a`，只删悬空的，带 tag 的当前版本留着），防的是固定 tag 重建后旧版本变成悬空镜像。这是经典镜像存储的行为；Docker 29 + containerd 快照器上带 `-t` 重建，旧版本直接被删、不留悬空镜像（02 章 2.6 实测，10-16 复测相同），所以在这类机器上这一条只是保险。

---

### 改造完的自查

改完后跑下面这组命令确认，每行末尾的注释是期望结果。

```bash
grep -rn -- '--name '        .github/workflows/ | grep -v 'run_id'      # 应为空
grep -rn 'ports:'            .github/workflows/ | grep -v '127.0.0.1'  # 应为空
grep -rn '/tmp/'             .github/workflows/                        # 应为空或已确认无害
grep -rc 'if: always()'      .github/workflows/*.yml                   # 清理步骤应该有
grep -rn 'docker rm -f '     .github/workflows/ | grep -v -- '-fv'      # 应为空（⑫）
grep -rn -- '--tmpfs'        .github/workflows/                        # 每个声明了 VOLUME 的镜像都应有一条（⑫）
grep -rn '容器没有挂卷'       .github/workflows/                        # 起了这些容器的 job 都应有这一步（⑫）
```

---

**上一章** ← [04 加固](04-加固.md) ｜ **下一章** → [06 接线与回退](06-接线与回退.md)
