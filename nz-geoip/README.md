# nz-geoip：面板国旗（GeoIP）的维护说明

这个目录只干一件事：**让面板显示的国家跟着最新数据走**，顺带记录为什么必须这么做、以及日常怎么更新。

## 一、先搞清楚国旗是怎么来的

- 探针**不上报**国家，只上报 IP
- 面板拿到 IP，去查一份**编译进 dashboard 二进制**的国家库（ipinfo 的 `country.mmdb`，`go:embed` 进去的）
- 所以国旗只跟"这份二进制是哪天构建的"有关：
  - 官方 release 的 v2.2.10 是 2026-07 构建的，库就停在 7 月
  - 数据后来被 ipinfo 改过，面板却不会知道

实际撞到的例子：`13.140.248.54`（Contabo Asia / 东京）

| 来源 | 结果 |
|---|---|
| ip-api / ipinfo API / ip.sb | JP |
| MaxMind GeoLite2 | `country=JP`，`registered_country=DE` |
| ip2location | DE |
| **官方 v2.2.10 二进制里的库（2026-07）** | **DE** → 面板显示 🇩🇪 |
| **今天从 ipinfo 现下的库** | **JP** |

结论：不是探针上报错，也不是数据要我们自己维护——是**二进制太旧**。

## 二、这个镜像做了什么

`nz-geoip/Dockerfile` 是叠在正式面板镜像上的一层，只改 `/app/start.sh` 两处：

- dashboard 下载地址：`github.com/nezhahq/nezha` → `github.com/wbxl0/Argo-Nezha-Service-Container`
- 对应的 sha256 校验目标（`verify_asset` 的仓库名）一起改

其余全部照旧：nginx 基座、`/app` 下的 start/backup/restore/watchdog 脚本、entrypoint 都没动。

容器**每次启动**都会重新下载 dashboard 并校验 sha256，所以：

> 只要本仓库的 release 资产是新的，重启一次面板就用上新库。

## 三、日常维护：库怎么更新（最常见的操作）

1. Actions → **Build and push images** → Run workflow（分支 `main`）
2. 等 10~15 分钟。构建脚本会现下最新的 `ipinfo.io/data/free/country.mmdb`，产出新的 `dashboard-linux-*.zip` 并覆盖 release `v2.2.10` 的资产
3. 重启面板：`aoi675145/Unikraft-Aoi` → **原地升级** → `config-nz-sfo.env` + `sfo`
4. 容器启动时自动下载新二进制并校验，面板起来即是新数据

**不需要重建 nz-geoip 镜像，不需要改任何代码。** 建议频率：想起来了就刷一次，或者季度一次。

## 四、什么时候才需要重建镜像

只有面板正式镜像本身变了（换了基座、`/app/start.sh` 路径/函数名变了）才需要：

Actions → **Push geoip overlay image** → Run workflow

它会把 overlay 重新构建并推到 Docker Hub 的 `wbxl0/nz:geoip`。

## 五、升级 nezha 版本

1. `build-dashboard.sh` 里 `DASHBOARD_VERSION` / `ADMIN_FRONTEND_VERSION` 改成新版本
2. 检查 `patches/admin-frontend-*.patch` 是否还打得进去（打不上就对着新版本重做）
3. 跑 `Build.yml`，再重启面板实例

`nz-geoip` 镜像本身不用跟着改——它只认 `/app/start.sh` 里那两处替换。

## 六、回滚

`aoi675145/Unikraft-Aoi` → `config-nz-sfo.env` 的 `IMAGE_REF` 改回：

```
IMAGE_REF=ghcr.io/aoi675145/nz-aoi:latest
```

再跑一次「原地升级」。1 分钟回到官方二进制（国旗也会回到旧数据的表现）。

## 七、为什么要发到 Docker Hub

- 用 workflow 的 `GITHUB_TOKEN` 推 ghcr，会新建一个**私有**包，而这个仓库对不是自己创建的包没有写权限
- GitHub 没有改包可见性的 API，Unikraft 的镜像转换拉不了私有包（报 `❌ 拉取失败`）
- Docker Hub 的仓库默认公开，转换器匿名就能拉 → 所以推 `wbxl0/nz:geoip` 这个额外 tag

## 八、排查

| 现象 | 看哪里 / 怎么办 |
|---|---|
| 面板起不来 | Unikraft-Aoi → 运维工具 → 实例日志，看 `3/6 下载 dashboard` 那步：sha256 校验失败会直接 `exit 1`，通常是 release 资产正在被覆盖，重跑一次 Build.yml |
| 国旗还是旧的 | 先确认实例日志里下载成功；再用 `curl -s https://ipinfo.io/<ip>/json` 确认上游确实改过归属 |
| 转换报「拉取失败」 | 镜像是不是私有（ghcr 新建包默认私有），换 Docker Hub |
| 想验证 overlay 对不对 | 拉镜像最后一层，`grep releases/download app/start.sh`，应该指向本仓库 |
