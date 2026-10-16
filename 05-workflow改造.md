## 05 workflow 改造：常驻 runner 上会坏掉的托管假设

**这一章是整本手册最可迁移的部分。** 前面几章换个云厂商就要调，这一章对任何仓库都成立。

托管 runner 每个 job 一台**全新的一次性 VM**：`/tmp` 是空的、容器名没人用过、端口没人占、
磁盘是干净的、跑完即焚。几乎每个仓库的 workflow 里都沉淀了一批依赖这些性质的写法——
它们在托管上永远不会出问题，**所以也永远不会被发现**。

下面十一条，每条给：**怎么自查 → 失败长什么样 → 怎么改**。
建议直接当 checklist 逐条过一遍你的 workflow。

---

### ① 固定容器名

**自查**
```bash
grep -rn -- '--name ' .github/workflows/ ; grep -rc 'docker rm\|docker stop' .github/workflows/
```
起了容器但 `docker rm` 出现 0 次 = 命中。

**失败长什么样**
```
docker: Error response from daemon: Conflict.
The container name "/minio" is already in use by container "7eb4689c...".
```
**第 2 个 run 就红**，而且报错跟代码毫无关系。

更硬的一种：**同一个 run 里的两个 job 用同一个写死的名字**。托管上它们是两台独立 VM，永不相干；
N=1 的自建机上两个 job 串行同机，第一个不清理 ⇒ 第二个**必然**冲突。这不是概率问题。

**怎么改**
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
- **`--label` 的值必须和 bootstrap.sh 的 `CI_LABEL` 一模一样**，清理钩子第 1 步按它删「上一个 job 没删掉的容器」。
  （本模板原来写的是 `--label ci=1`，跟任何 `CI_LABEL` 都对不上。）
- **`rm -fv` 不是 `rm -f`**：镜像声明了 `VOLUME`（minio、postgres、redis、prometheus 都声明了）就会建匿名卷，
  `-v` 才会连卷一起删。本模板原来写的是 `rm -f`，参考项目照抄后每个 job 漏 1 个卷。
  **`docker run --rm` 救不了**：实测 `run -d --rm` 之后再 `rm -f`（不带 -v），卷照样留下——
  `--rm` 只在容器自己退出或被 `docker stop` 时生效。
- 钩子**不是**只按 label 过滤：第 6 步是一条不带过滤的 `docker volume prune`（本模板原来说「绝不裸 prune」，不对）。
  它是匿名卷的兜底；workflow 侧写对 `-v`，就不必依赖它。service 容器的卷见 ⑫。

---

### ② 服务端口默认绑 `0.0.0.0`

**自查**
```bash
grep -rn "ports:" .github/workflows/ | grep -v "127.0.0.1"
```

**失败长什么样**
不会失败——**这才是问题**。它只是把你的数据库开在公网上。

> **实测**：`ports: ['5433:5432']` + 明文 `POSTGRES_PASSWORD` ⇒
> check-host.net 的四个境外节点**全部成功建立 TCP 连接**并收到 Postgres 认证响应。
> 而宿主的 `ufw` 是 inactive 也无所谓——**Docker 的 DNAT 本来就绕过它**。

**怎么改**
```yaml
services:
  postgres:
    ports: ['127.0.0.1:5433:5432']    # runner 把三段式原样透传给 docker create（已实测）
```
效果：localhost 可连、公网 `Connection refused`。

---

### ③ 固定 `/tmp` 路径

**自查**
```bash
grep -rn '/tmp/' .github/workflows/
```

**失败长什么样**（三种，第三种最危险）
1. **权限**：文件属于别的用户 ⇒ `tee: /tmp/x.log: Permission denied` 硬失败。
2. **并发**：两个 job 写同一路径 ⇒ 断言读到别人的数据。
3. **陈旧读取（静默假绿）**：写文件那步失败了，而**上一次 run 留下的同名文件**里
   恰好有你 grep 的那个字符串 ⇒ 断言**通过**。一条本该发现问题的检查，
   悄悄变成永远绿的摆设。托管上不可能发生，常驻机器上是一句 `rm` 之差。

**怎么改**：一律用 `$RUNNER_TEMP`（runner 每 job 新建并清理，托管与自建行为一致）。
```yaml
- run: mycmd | tee "$RUNNER_TEMP/out.log" && grep -q "expected" "$RUNNER_TEMP/out.log"
```

---

### ④ 依赖预装工具

**自查**
```bash
grep -rhoE '\b(gh|jq|yq|aws|az|gcloud|make|cmake|gcc|zstd|unzip)\b' .github/workflows/ | sort -u
# 然后在 runner 上：for c in <上面这些>; do command -v $c || echo "缺 $c"; done
```

**失败长什么样**——**分两级，第二级更麻烦**：
- 命令**没有** `||` 兜底 ⇒ 硬失败（`bash -e`），至少你看得见。
- 命令**有** `|| fallback` ⇒ **静默降级**。路径门控退化成全跑、定时任务恒跑、某个检出被跳过。
  **你会以为门禁还在跑，其实已经不在了。**

**怎么改**：装上；并把工具清单写进你的 bootstrap，别靠记忆。

---

### ⑤ 依赖「全新文件系统」的缓存语义反转

**自查**：workflow 里有 `actions/cache` 或 `setup-*` 的 `cache:` 选项。

**在托管上**它是必需的（VM 每次都是空的）。
**在常驻机器上**它变成**净负担**——把本地已经有的东西传到云上再传回来。

> **实测**：`actions/setup-node` 的 `cache: pnpm` 每 run 从 GitHub 缓存服务恢复 **~218 MB**，
> setup-node 步骤 **11–12 秒**；去掉后 **1 秒**，而 `pnpm install` 仍是 6 秒（本地 store 常驻）。
> 净省约 10 秒/run + 218 MB 流量。

**怎么改**——但先想清楚回退：
去掉它，回落托管时每个 job 要多付一次冷装（~52 秒）。想两头兼得的条件写法是**做不成的**：

```yaml
cache: ${{ vars.CI_RUNNER && '' || 'pnpm' }}     # ❌ 不成立
# GitHub 表达式里 && / || 返回操作数的值，而空串是 falsy：
# CI_RUNNER 已设 → (CI_RUNNER && '') = '' → '' 是 falsy → ('' || 'pnpm') = 'pnpm'
# 永远产出 'pnpm'。写 'none' 之类会让 setup-node 直接报错。
```
所以：**要么接受 10 秒，要么接受回退时慢**。参考项目选了保留（10 秒占单 run 的 3%）。

---

### ⑥ 清理钩子在 job 被取消时不执行

见 04 章 4.4。这里只强调自查点：**你的 workflow 里有 `cancel-in-progress: true` 吗？**
有的话，任何写在最后一步的清理都会被跳过。用 `if: always()`，并在 runner 侧挂 `JOB_STARTED` 钩子兜底。

---

### ⑦ `timeout-minutes` 的语义反转

**托管上**它是「这个 job 最多烧多少钱」，跑飞了只烧自己那台一次性 VM。
**N=1 的自建 runner 上**它变成「**全组 CI 停摆的上界**」——一个卡死的 job 独占唯一的 runner，
后面所有 PR 一起等。

**自查**
```bash
grep -rn "timeout-minutes" .github/workflows/    # 对照你的实测时长
```

> **参考项目**：现值是实测时长的 **8–150 倍**
> （lint 15 min / 实测 22 s = 41×；build 30 min / 实测 12–70 s = 26–150×）。
> 一次 ci run 最坏占用 15+15+30+30 = **90 分钟**。按「实测 p95 × 4」重设后是 **29 分钟**。

⚠️ `timeout-minutes` **只从 job 开始执行才计时，排队不计**——它管不了「机器宕机导致排队 24 小时」，
那是哨兵的活（06 章）。

---

### ⑧ job 级并行的假设

**托管上**多个 job 并行免费（各自一台 VM）。**N=1 上它们串行排队**，
每多一个 job 就多付一次脚手架。

但**别急着合并 job**。先量两个数：

```
每 job 脚手架 = Set up job + checkout + setup-* + install + post cleanup
```
> **参考项目**：托管上脚手架 ≈ **52 秒/job**（合并 4→1 省 156 秒）；
> 自建机上只有 ≈ **16 秒/job**（合并只省 48 秒）——因为常驻机器上依赖早就在盘上了。
> **收益缩水 3 倍**，而代价（文档同步、required check 粒度、回退时降级）一点没少。

**判断方法**：用真实事件时间戳做排队仿真（08 章），比较「合并 job」与「别的提速手段」的实际收益。
参考项目的结论是：合并 job 与「修 Dockerfile 层序 + 去 cache」**等效**（最忙那天 11.7 vs 11.2 分钟），
而后者不动一行文档。**先做后者。**

---

### ⑨ 孤儿进程导致的假绿（最阴的一条）

**自查**：workflow / 测试代码里有没有「起一个后台进程 → 轮询它的健康端点 → 跑测试」这个模式？
如果就绪判据只是 `curl <url>`，而**不校验回答者是不是自己刚起的那个进程**，就命中。

**失败长什么样**
```
[api:err] Error: listen EADDRINUSE: address already in use 0.0.0.0:3100   ← 只在 stderr 留一行，不失败
 Test Files  1 failed | 8 passed (9)
      Tests  1 failed | 220 passed (221)                                  ← 220 个测试跑在**孤儿**上
```
> **实测**：用一个孤儿进程占住端口后跑 e2e，**221 条里 220 条通过**，
> 唯一那条红叉还指向认证代码而非真实病因。换一个状态不敏感的孤儿就是**全绿**。
> 也就是说：**整套 e2e 跑在上一次 run 的代码上，而 CI 是绿的。**

孤儿从哪来：`teardown` 只有一行 `proc.kill()`，而 job 被取消时它**不执行**；
runner 的 `KillMode=process` 也不杀子进程。

**怎么改**（三层，至少做前两层）
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
```bash
# ② runner 的 JOB_STARTED 钩子里清孤儿
fuser -k 3100/tcp 3101/tcp 2>/dev/null || true
```
③ 云防火墙挡住这些宿主端口（它们不是容器，`-p 127.0.0.1` 管不到）。

---

### ⑩ 宿主进程绑 `0.0.0.0`

②只管容器。**测试直接 spawn 起来的应用进程是宿主进程**，没有 `-p` 可以绑。

**自查**：`grep -rn "0\.0\.0\.0\|listen(" <你的应用入口>`

**怎么改**：优先靠**云防火墙**（04 章 4.7）——因为它不走 DOCKER 链，主机/云防火墙对它有效。
改应用代码的绑定地址也行，但要先确认不会破坏容器形态（容器内必须绑 `0.0.0.0`
才能被发布端口触达），并且别和仓库已有的绑定地址约定打架。

---

### ⑪ 供应链：爆炸半径变了

**自查**
```bash
grep -rhoE 'uses: [^ ]+' .github/workflows/ | sort -u    # 有几个钉在浮动 major tag 上
grep -rn 'image:' .github/workflows/ | grep -v '@sha256'  # 有几个镜像没钉 digest
```

**为什么在自建上更要紧**：同一个「上游 tag 被重指向」事故，
在托管上是**泄露一台一次性 VM**，在你的机器上是**宿主 root**（因为 runner 在 `docker` 组）。

**怎么改**：action 钉 commit SHA + 开 dependabot；镜像钉 digest。

### ⑫ 匿名卷：service 容器和自己起的容器都会留（上线一个月后补）

**自查**
```bash
docker volume ls -q | wc -l                       # 在一台常驻 runner 上看；钩子没在跑的话会一直涨
grep -rn 'docker rm -f ' .github/workflows/ tools/ | grep -v -- '-fv'   # 应为空
```

**机制**：镜像声明了 `VOLUME`、启动时又没挂 `-v`/`--mount`/`--tmpfs`，Docker 就建一个匿名卷；
删容器时不带 `-v` 卷就留下。两处来源：

| 来源 | 谁删容器 | workflow 能改吗 |
|---|---|---|
| `services:` 里的 postgres / redis | **runner 自己**，`docker rm --force`，不带 `-v` | 能，挂 tmpfs（见下） |
| 步骤里 `docker run -d` 起的（minio、prometheus…） | workflow 的 `docker rm -f` | 能，改 `rm -fv`（见 ①） |

参考项目每个用到数据库的 job 漏 3 个卷（postgres + redis + minio），约 70 MB，大头是 PGDATA。
清理钩子的 `docker volume prune` 每个 job 前后都在回收，所以那台机器上卷数始终是 0——
**但这是钩子在兜底，不是 workflow 写对了**。换一台没装钩子的常驻 runner，卷数就会一直涨。

**怎么改**：给 service 容器挂 tmpfs，卷从源头就不产生（2026-10-16 在参考机上实测：postgres 正常启动、
`docker inspect` 的 Mounts 为空、删容器后新增卷 0 个）：
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
⚠️ **tmpfs 的路径必须是镜像声明的 VOLUME 路径**，用 `docker image inspect <镜像> --format '{{json .Config.Volumes}}'` 查。
postgres 18 的镜像声明的是 `/var/lib/postgresql`，**不是**大家熟悉的 `/var/lib/postgresql/data`（那是 16 及以前的）。
写错了不报错，只是卷照样建、照样漏。tmpfs 占内存（参考项目约 50–120 MB/job），记在容器的 cgroup 上，
不在 runner 的 MemoryMax 里，但没有 swap 的机器上它占的是真内存，`size=` 必须写。

**顺带**：`docker build` 也打上 `--label "$CI_LABEL"`，清理钩子才能删掉过期的 CI 镜像（不打标时那条匹配 0 个）。

---

### 改造完的自查

```bash
grep -rn -- '--name '        .github/workflows/ | grep -v 'run_id'      # 应为空
grep -rn 'ports:'            .github/workflows/ | grep -v '127.0.0.1'  # 应为空
grep -rn '/tmp/'             .github/workflows/                        # 应为空或已确认无害
grep -rc 'if: always()'      .github/workflows/*.yml                   # 清理步骤应该有
grep -rn 'docker rm -f '     .github/workflows/ | grep -v -- '-fv'      # 应为空（⑫）
```

---

**上一章** ← [04 加固](04-加固.md) ｜ **下一章** → [06 接线与回退](06-接线与回退.md)
