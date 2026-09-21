# 自用分支说明（wbxl0 fork）

> 本文件记录本 fork 与上游 [fscarmen2/Argo-Nezha-Service-Container](https://github.com/fscarmen2/Argo-Nezha-Service-Container) 的差异、构建方式与踩坑记录，自用备查。上游通用教程见 [README.md](README.md)。

## 一、这个 fork 是什么

- 容器版兼容哪吒面板 **v0 / v1 / v2**，面板版本用 `DASHBOARD_VERSION` 变量选择
- 以 v2.2.10 为例，三层的构成：
  | 层 | 来源 | 说明 |
  |---|---|---|
  | 后端 | nezhahq/nezha v2.2.10 + grpc-go 1.83.0 | 由 `build-dashboard.sh` 构建，发布到本仓库 `v2.2.10` release；升 grpc-go 是为了修大规模探针周期性批量掉线 |
  | 后台 UI | nezhahq/admin-frontend v2.2.5 + `patches/` 自定义补丁 | 删分组列、操作列 sticky、**默认按名称 A-Z（大小写不敏感）**、删"启用 DDNS"列 |
  | 访客页 | hamster1963/nezha-dash-v2 v2.4.1 | 官方 user-dist，构建时下载预编译产物；**与后台 UI 是两个独立应用**，改后台不影响访客页 |
- 已移除 UUID 代理节点功能（不再下载/运行第三方闭源二进制），`UUID` 环境变量已废弃
- Docker 镜像由本仓库 Actions 自动构建，**镜像名由 Actions Secrets 的 `DOCKER_USERNAME` / `DOCKER_REPO` 决定**（可选 `DOCKER_TAG`，缺省 latest），文档与代码中不落盘

## 二、镜像构建（Build.yml）

- 触发：push 到 main（`*.md` 改动不触发）
- 流程：构建补丁版面板（amd64/arm64）→ `--clobber` 重传 v2.2.10 release 资产 → buildx 推镜像（amd64/arm64/armv7）
- 要点：
  - 固定 `DASHBOARD_VERSION=v2.2.10` 的容器**不会自动更新面板**：每日备份只在 `./app -v` 与固定版本不一致时才替换，版本号相同永远跳过
  - 想覆盖旧镜像标签就别设 `DOCKER_TAG`；想隔离测试就改 `DOCKER_REPO` 换个仓库名
  - 注意：容器 entrypoint 是运行时从 main 拉 `init.sh` 的——**改 init.sh 只要推 main 就生效（重建容器时）**，与镜像新旧无关

## 三、环境变量（fork 特有 / 重点）

| 变量 | 说明 |
|---|---|
| `DASHBOARD_VERSION` | 固定面板版本。填 `v2.2.10` 走本仓库修复版构建；v0 分支规则见 README |
| `AGENT_SECRET_KEY` | **固定探针密钥**（自加功能）：容器重建后 `agent_secret_key` 不变，探针不失联 |
| `BACKUP_NUM` | 备份仓库保留份数，默认 5。**改了要重建容器才生效**（DAYS 是安装时写进 backup.sh 的，renew.sh 只更新模板主体） |
| `BACKUP_TIME` | 备份 cron，默认 `0 4 * * *`；备份窗口顺带重启 caddy 释放内存 |
| `REVERSE_PROXY_MODE` | `caddy`（默认）/ `nginx` / `grpcwebproxy` |
| `MEM_LIMIT_NEZHA` / `MEM_LIMIT_GRPCPROXY` / `MEM_LIMIT_ARGO` / `MEM_LIMIT_AGENT` | 各进程 GOMEMLIMIT，**默认按容器内存上限自动分配**（面板 30% / caddy 26% / cloudflared 16% / 探针 8%），通常不用填；特殊负载可单独覆盖，如 `-e MEM_LIMIT_NEZHA=256MiB` |
| `UUID` | 已废弃，代理节点功能已移除 |
| 其余 `GH_*` / `ARGO_*` / `PRO_PORT` | 同上游，见 README |

## 四、内存参数（GOMEMLIMIT）

supervisor 的 GOMEMLIMIT 按容器内存上限自动分配：面板 30%、caddy 26%、cloudflared 16%、探针 8%
（512MB 容器 → 153/133/81/40MiB；2GB 容器 → 614/532/327/163MiB）。可用 `-e MEM_LIMIT_XXX=` 单独覆盖。

**⚠️ 这是一个踩过的坑**：GOMEMLIMIT 是 Go 的 GC 触发线，不是预留量。
- 设得**远低于**进程实际工作集 → GC 抖动：CPU 飙升、请求停顿、gRPC 流被 CANCEL，表现为**隧道 1033 / 探针集体掉线**（曾用 64MiB 跑 caddy 实际 220MB，CPU 烧到 60%）
- 设得**高于**容器内存上限 → 被 cgroup OOM 杀（退出码 137）
- 所以固定值不可取，必须随容器大小走——这就是自动分配的原因

排查：`docker stats --no-stream`、`ps aux --sort=-rss | head -n 8`；容器内存水位看 `cat /sys/fs/cgroup/memory.current`。

## 五、备份机制要点

- 每天 `BACKUP_TIME` 把 `data/`（**排除 data/tsdb**）打包传 GitHub 私库；仓库 README.md 第一行 = 最新备份文件名；`restore.sh` 每分钟比对本地 `/dashboard/dbfile`，不同名才还原
- **改备份包内容必须同时改备份库 README.md 里的文件名**（或手动 `bash /dashboard/restore.sh f`），同名文件改内容永远不会被重新还原
- v1/v2 的 restore 不做任何密钥对账（v0 才有 sqlite token 重写逻辑），还原前确保备份里 `config.yml` 的 `client_secret` 与面板密钥体系自洽
- 修完配置后手动跑一次 `/dashboard/backup.sh`，把自洽状态固化成新备份

## 六、v2 面板密钥双轨制（重要）

| 密钥 | 存放 | 校验行为 |
|---|---|---|
| 旧版全局密钥 | `config.yaml` 的 `agent_secret_key` | 映射 user 0，**跳过属主校验，接受任何已存在 uuid**；未知 uuid 会自动注册 |
| 用户级密钥 | 数据库（面板 UI"设置"里那把） | 映射到账号，uuid 的属主必须匹配 |

- 两把并存都有效：装新探针用 UI 给的那把；`config.yml` 和 `config.yaml` 各用各的、保持自洽即可
- 认证失败会累计触发 WAF 封 IP（`BlockIDgRPC`）——密钥不对时别反复重试，会连累同边缘节点的其他探针

## 七、后台 UI 魔改流程

1. `patches/admin-frontend-v2.2.5-server.patch` 是对 admin-frontend v2.2.5 的**全部**自定义
2. 流程：clone v2.2.5 → `git apply` 现有补丁 → 改代码 → `git diff` 重新生成补丁 → 拿干净 clone `git apply --check` 验证 → push 触发 CI
3. 已做改动：删分组列、操作列 sticky、标题旁加 **A-Z 排序开关**（默认关闭＝上游原顺序，勾选则按名称大小写不敏感排序，不记忆状态）、删"启用 DDNS"列（编辑服务器里仍可配置）

## 八、踩坑存档

- **探针集体掉线重连**：根因是 v2.2.10 官方锁定的 grpc-go 1.81.1 会周期性重置 gRPC 连接（commit `24792fd`），修复版已升 1.83.0。与 Nginx/Caddy 无关，换反代没用
- **面板鸡不上线**：先查三处——`config.yml` 的 `client_secret`、`config.yaml` 的 `agent_secret_key`、`server:` 是否为当前 Argo 域名；再查 WAF 封禁列表
- **内存顶满**：不是泄漏，但**不要靠压低 GOMEMLIMIT 来解决**——压到低于工作集反而触发 GC 抖动（见第四节）。正解是按容器内存自动分配，或清理僵尸探针
- **隧道静默失效（半开连接）**⚠️ *2026-09-21 发生过一次，观察中*
  - 症状：全站 1033 / 探针集体掉线；但 `ss -tnp` 能看到 cloudflared 的 4 条 TCP **ESTABLISHED**、WARP 正常、容器能出网、`oom_kill 0`、**argo.log 里 6 小时没有任何连接事件**（既无 Unregistered 也无 Lost connection）
  - 根因：容器唯一出口是 WARP（容器内无 IPv6），链路中间某跳静默丢包 → 连接在 CF 边缘侧已死、但本地 socket 与 cloudflared 都不知情（TCP 不主动探测空闲连接）。重启 argo 后日志出现 `already connected to this server, trying another address` = 僵尸连接残留的铁证
  - 处置：`supervisorctl restart argo`（一条命令即恢复，无需重启其他进程）
  - **待办（复发则实施）**：加外部看门狗——每 5 分钟从容器内 `curl https://$ARGO_DOMAIN/api/v1/setting`（走完整链路），连续 2 次失败则 `supervisorctl restart argo`。**不能用 cloudflared 自带的 /ready**，它在这种故障下会误报正常
- **碰到的另一个坑：日志轮转未生效**：运行中容器是手工打的补丁，只有路径没有 `stdout_logfile_maxbytes=2MB`，所以按 supervisord 默认 50MB × 10 份滚动（磁盘占用可达几 GB）。重建容器后即按 2MB × 3 生效

## 九、故障排查入口（2026.9 事故后新增）

日志已落盘（不再丢 `/dev/null`），排查命令：

| 场景 | 命令 |
|---|---|
| 隧道断连 / 1033 | `docker exec nezha_dashboard grep -iE "Registered\|Unregistered\|graceful shutdown" /dashboard/logs/argo.log \| tail -20` |
| 判断是否"僵尸连接" | `docker exec nezha_dashboard ss -tnp \| grep cloudflared`（有 ESTABLISHED 但外部报 1033 = 半开连接，见第八节） |
| 探针掉线（面板侧） | `docker exec nezha_dashboard grep "NEZHA>>" /dashboard/logs/nezha.log \| tail -30` |
| 谁在疯狂重连 | `docker exec nezha_dashboard sh -c "grep -o 'clientID: [0-9]*' /dashboard/logs/nezha.log \| sort \| uniq -c \| sort -rn \| head"` |
| 资源占用 | `docker stats --no-stream`；`uptime` |
| 外部可达性（从本机） | `curl -s -o /dev/null -w "%{http_code}" https://nz.wbxl.dpdns.org/`（530/1033 = 隧道无活跃连接） |

**判读要点**：
- `Initiating graceful shutdown due to signal terminated` = 我们自己重启（配置变更），不是故障
- **面板鸡（本机探针）是最佳对照组**：它走完整链路且路径最短，它稳定就说明面板/隧道侧健康；远端错误多通常是 Serverless（Vercel/Cloudflare/Streamlit）或免费 PaaS 的进程回收特性
- 日志每个程序 2MB × 3 份轮转，`logs/` 不进备份包
