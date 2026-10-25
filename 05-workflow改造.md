## 05 workflow 改造：常驻 runner 上会坏掉的托管假设

本章列出 workflow 里依赖托管 runner 特性的写法，以及在自建常驻 runner 上该怎么改。本章和机器无关，对任何仓库都适用。

托管 runner 给每个 job 分配一台全新的一次性 VM：

- `/tmp` 是空的；
- 容器名没被用过；
- 端口没被占用；
- 磁盘是干净的；
- job 跑完，VM 就销毁。

几乎每个仓库的 workflow 里都积累了一批依赖这些性质的写法。它们在托管 runner 上不会出问题，所以也一直没有暴露出来。

本章用到的几个说法：

- N：全仓库自建 runner 实例的总数，所有机器加起来算，也就是同时最多能跑几个 job。N=1 时所有 job 串行排队。有两台机器、每台一个实例时 N=2，job 能并行了，但同一个 run 的两个 job 仍可能先后落在同一台机器上。
- k：一台机器上跑几个实例。现有脚本和占固定宿主端口的 workflow 都只支持每台 1 个，原因见 10 章 10.6。
- 假绿：检查本该失败，结果却显示通过。

参考项目最初只有一台机器、一个实例（N=1），本章的实测大多是在这个条件下做的。

下面 ①–⑬ 共十三条，每条按「怎么自查、失败是什么样、怎么改」组织。⑫ 是上线一个月后补的，⑬ 是准备加第二台机器时补的。建议把它们当作 checklist，对照你的 workflow 逐条检查。章末有一组汇总命令，改完后用来确认。

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

同一个 run 里的两个 job 用同一个写死的名字时更严重：

- 托管 runner 上，两个 job 在两台独立 VM 上，互不影响。
- N=1 的自建机上，两个 job 在同一台机器上串行。第一个 job 不清理，第二个 job 一定冲突。
- N≥2 时，两个 job 有时分到不同机器，有时落在同一台，冲突时有时无，更难查。

怎么改：

```yaml
env:
  # 名字要唯一到 run、attempt、job 三级：
  #   run_attempt 不能省，re-run 时 run_id 不变
  #   github.job 不能省，同一个 run 里的两个 job 只唯一到 run 级仍会撞名
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

- `--label` 的值必须和 bootstrap.sh 里的 `CI_LABEL` 完全一致。清理钩子第 1 步按这个 label 删除上一个 job 没删掉的容器。bootstrap 的默认值是 `com.ci.selfhosted=1`，上面的 `com.myorg.ci=1` 是示例，两边写成同一个就行。
- 删除容器用 `rm -fv`，不用 `rm -f`。镜像声明了 `VOLUME` 时（minio、postgres、redis、prometheus 都声明了），Docker 会建匿名卷，带 `-v` 才会连卷一起删。参考项目原来用 `rm -f`，每个起 minio 的 job 漏 1 个卷，见 ⑫。
- `docker run --rm` 解决不了漏卷。实测 `run -d --rm` 之后再 `rm -f`（不带 -v），卷照样留下。`--rm` 只在容器自己退出或被 `docker stop` 时生效。
- `rm -fv` 只在清理步骤真的跑了时有用。runner 进程被杀时 `if: always()` 也不执行，容器留给钩子删。更稳的是在镜像的 VOLUME 路径挂 tmpfs，一开始就不建卷，写法和注意事项见 ⑫。
- 清理钩子并非只按 label 过滤。它的第 6 步是一条不带过滤的 `docker volume prune`，用来兜底回收匿名卷。workflow 里写对了，就不必依赖它。service 容器的卷见 ⑫。

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

上面的 `5433` 是固定的宿主端口。每台机器只跑一个 runner 实例时没有问题，机器再多也一样，每台各有一套端口。一台机器跑多个实例时，两个 job 会抢同一个宿主端口，后起的 service 起不来。到那一步有两种改法：

- 让 Docker 随机分配宿主端口：写成 `ports: ['127.0.0.1::5432']`，job 里用 `${{ job.services.postgres.ports['5432'] }}` 读出实际端口。runner 能不能正确处理这种写法，参考项目没有实测，先在测试分支上验证。
- job 跑在 `container:` 里，用服务名直连（`postgres:5432`），不发布宿主端口。

测试在宿主上起的进程（⑨ 里的 API）也一样，每个实例要用不同的端口。不占固定宿主端口是一台机器跑多个实例的前提之一，其余几条见 10 章 10.6。

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
- 命令后面有 `|| fallback`：静默降级。表现为路径门控退化成全跑、定时任务每次都跑、某个检出被跳过。门禁看起来还在跑，实际已经失效。

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
cache: ${{ vars.CI_RUNNER && '' || 'pnpm' }}     # 错误写法，不成立
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

在自建 runner 上，`timeout-minutes` 决定了一个卡死的 job 最多能占住一个实例多久。N=1 时，这就是全组 CI 最多停多久，所以要对照实测时长重新检查。

| 环境 | `timeout-minutes` 的含义 | job 跑飞的后果 |
|---|---|---|
| 托管 runner | 这个 job 最多烧多少钱 | 只烧掉自己那台一次性 VM |
| 自建 runner，共 N 个实例 | 一个实例最多被占住多久，N=1 时就是全组 CI 停摆的上界 | 少一个可用实例，排队变长；N=1 时后面所有 PR 一起等 |

自查：

```bash
grep -rn "timeout-minutes" .github/workflows/    # 对照你的实测时长
```

> 参考项目：现值是实测时长的 8–150 倍（lint 15 min / 实测 22 s = 41×；build 30 min / 实测 12–70 s = 26–150×）。一次 ci run 最坏占用 15+15+30+30 = 90 分钟。按「实测 p95 × 4」重设后是 29 分钟。

实测时长要记下是在哪台机器上量的。换到单核更慢的机器，同样的 `timeout-minutes` 余量会缩水，单核受限的 job（限了 1 个 CPU 的测试容器、单线程的类型检查）最先超时。加机器或换机器之前，按 02 章 2.7 核对：最长实测耗时 × R ≤ timeout-minutes × 2/3，R 是新机器和参考机的耗时比。

注意：`timeout-minutes` 从 job 开始执行才计时，排队时间不算。机器宕机导致排队 24 小时这种情况它管不了，要靠哨兵（06 章 6.4）。

---

### ⑧ job 级并行的假设

要不要为 N=1 合并 job，先量再决定：合并 job 在自建机上的收益比在托管上小得多。

- 托管 runner 上，多个 job 并行是免费的（各自一台 VM）。
- N=1 上，它们串行排队，每多一个 job 就多付一次脚手架。
- N≥2 时，同一个 run 的 job 又能分到几个实例上并行，合并的收益比 N=1 时更小。

不要急着合并 job。先量两个数，即托管和自建机上各自的每 job 脚手架时间：

```text
每 job 脚手架 = Set up job + checkout + setup-* + install + post cleanup
```

> 参考项目：托管上脚手架约 52 秒/job（合并 4→1 省 156 秒）；自建机上只有约 16 秒/job（合并只省 48 秒），因为常驻机器上依赖早就在盘上了。收益缩水 3 倍，而代价（文档同步、required check 粒度、回退时降级）一点没少。

判断方法：用真实事件时间戳做排队仿真（08 章 8.1），比较「合并 job」和其他提速手段的实际收益。现有的仿真脚本只模拟一个 runner，也就是 N=1 的情况。

参考项目的结论：合并 job 与「修 Dockerfile 层序 + 去 cache」效果相当（最忙那天 11.7 vs 11.2 分钟），而后者不用改任何文档，所以先做后者。

---

### ⑨ 孤儿进程导致的假绿

测试依赖的后台进程如果是上一次 run 遗留的孤儿进程，测试会跑在旧代码上，CI 却可能显示通过。

自查：workflow 或测试代码里有没有「起一个后台进程 → 轮询它的健康端点 → 跑测试」这个模式？如果就绪判据只是 `curl <url>`，不校验应答的是不是自己刚起的那个进程，就是命中。

失败是什么样：

```text
[api:err] Error: listen EADDRINUSE: address already in use 0.0.0.0:3100   ← 只在 stderr 留一行，不失败
 Test Files  1 failed | 8 passed (9)
      Tests  1 failed | 220 passed (221)                                  ← 220 个测试跑在孤儿进程上
```

> 实测：用一个孤儿进程占住端口后跑 e2e，221 条里 220 条通过，唯一失败的那条还指向认证代码，而不是真实原因。换一个对状态不敏感的孤儿进程，结果就是全绿。

也就是说，整套 e2e 跑在上一次 run 的代码上，CI 却是绿的。

孤儿进程的来源：

- `teardown` 只有一行 `proc.kill()`，而 job 被取消时它不执行。
- runner 自己的兜底没有接住。job 结束时，runner 会杀掉环境变量里带本 job `RUNNER_TRACKING_ID` 的进程，日志里显示为 `Cleaning up orphan processes`。有几种情况它认不出来：测试代码 spawn 子进程时传了一份新的 env，没继承这个变量；workflow 把这个变量设成了空串；runner 进程本身被杀了。参考项目当时的孤儿属于哪一种，没有核对过。
- runner 服务的 `KillMode=process` 只决定停服务时杀不杀子进程，和 job 结束没有关系。

怎么改：分三层，至少做前两层。

第一层（代码注释中的 ①）：起进程之前，先确认端口没被占用。

```ts
// ① 起之前先确认端口没被占。用裸 TCP 连接，不依赖对方回什么
async function assertPortFree(port: number) {
  const busy = await new Promise<boolean>((res) => {
    const s = connect({ port, host: '127.0.0.1' });
    const done = (v: boolean) => { s.destroy(); res(v); };
    s.setTimeout(2000);
    s.once('connect', () => done(true));
    s.once('timeout', () => done(false));
    s.once('error',   () => done(false));
  });
  if (busy) throw new Error(`端口 ${port} 已被占用，多半是上一次 run 的孤儿进程，先清掉再跑。`);
}
```

第二层（代码注释中的 ②）：在 runner 的 `JOB_STARTED` 钩子里清掉孤儿进程。

```bash
# ② runner 的 JOB_STARTED 钩子里清孤儿
# 3100、3101 是参考项目 e2e 的端口，换成你的 CI_APP_PORTS（03 章 3.1）
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
grep -rn 'docker rm -f ' .github/workflows/ <CI 用的脚本目录> | grep -v -- '-fv'   # 应为空
```

机制：镜像声明了 `VOLUME`、启动时又没挂 `-v`/`--mount`/`--tmpfs`，Docker 就建一个匿名卷；删容器时不带 `-v`，卷就留下。卷有两处来源：

| 来源 | 谁删容器 | workflow 能改吗 |
|---|---|---|
| `services:` 里的 postgres / redis | runner 自己，`docker rm --force`，不带 `-v` | 能，挂 tmpfs（见下） |
| 步骤里 `docker run -d` 起的（minio、prometheus…） | workflow 的 `docker rm -f` | 能，挂 tmpfs，删除时用 `rm -fv`（见 ①） |

参考项目里，每个用到数据库的 job 原来漏 3 个卷（postgres、redis、minio，约 70 MB，大头是 PGDATA），跑监控冒烟的 job 还会给 prometheus 漏 1 个。那台机器上卷数始终是 0，是因为清理钩子的 `docker volume prune` 在每个 job 前后都在回收，workflow 本身并没有写对。换一台没装钩子的常驻 runner，卷数就会一直涨。

参考项目 2026-10-16 按下面的写法改完：postgres、redis、minio、prometheus 都挂 tmpfs，起这些容器的 job 都在起完后核对没挂卷。合并前在 runner 上记了约 15 分钟 `docker events`，期间跑了几个起这些容器的 job，容器照常建了又删，没有新建卷。

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
- tmpfs 占内存（参考项目约 50–120 MB/job）。它记在容器的 cgroup 上，不在 runner 的 MemoryMax 里；但在没有 swap 的机器上它占的是真内存，所以 `size=` 必须写，量单 job 整机峰值 J 时也要把它算进去（10 章 10.1）。
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

### ⑬ 容器写进工作区的文件，runner 删不掉（准备加第二台机器时补）

常驻机器上工作区跨 job 复用，下一个 job 的 checkout 要先删掉上一次留下的文件。CI 容器往挂进去的工作区写文件时，文件属主是容器里进程的 uid。这个 uid 和 runner 用户对不上，runner 就删不掉这些文件。托管 runner 每个 job 都是新 VM，碰不到这个问题。

自查：

```bash
# 在每台 runner 上跑。runner 和 /opt/actions-runner 按你的 RUNNER_USER、RUNNER_HOME 换
id -u runner                                              # 各台机器应该相同
find /opt/actions-runner/_work -not -user runner | head   # 应为空
```

失败是什么样：`actions/checkout` 清理工作区时报 `EACCES: permission denied`，job 在第一步就失败，和代码改动无关（09 章 A19）。

文件归谁，看容器以哪个用户运行：

- node 官方镜像默认以 root 运行，只是自带一个 uid 1000 的 `node` 用户，要用 `--user node` 才会切过去。很多镜像里的普通用户也是 uid 1000。
- 以 root 运行的容器写下的文件属于 uid 0，runner 是哪个 uid 都删不掉。
- job 用 `container:` 跑时，步骤在容器里以镜像的默认用户执行，常常是 root，写进工作区的文件也归 root。

怎么改：

- 所有 runner 机器上 runner 用户的 uid 保持一致，参考项目用 1000。bootstrap 按 `RUNNER_UID` 建用户；装机顺序，以及云镜像自带 uid 1000 用户时怎么处理，见 03 章 3.3。
- 自己 `docker run` 又挂了工作区的容器，用 runner 的身份运行：`docker run --user "$(id -u):$(id -g)" -v "$GITHUB_WORKSPACE:/w" ...`。这样文件直接归 runner，不依赖镜像里有没有 uid 1000 的用户。
- 必须以 root 运行的容器，在 `if: always()` 的清理步骤里把属主改回来：`docker run --rm -v "$GITHUB_WORKSPACE:/w" <同一个镜像> chown -R "$(id -u):$(id -g)" /w`。runner 进程被杀时这一步也不会执行，下一个 job 会在 checkout 失败，这时要登上机器用 root 删掉那些文件。

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
grep -rnE '127\.0\.0\.1:[0-9]+:' .github/workflows/                    # 一台机器跑多个实例时应为空（②）
find /opt/actions-runner/_work -not -user runner | head                # 在每台 runner 上跑，应为空（⑬）
```

---

**上一章** ← [04 加固](04-加固.md) ｜ **下一章** → [06 接线与回退](06-接线与回退.md)
