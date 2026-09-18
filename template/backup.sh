#!/usr/bin/env bash

# backup.sh 传参 a 自动还原； 传参 m 手动还原； 传参 f 强制更新面板 app 文件及 cloudflared 文件，并备份数据至成备份库。
# 如是 IPv6 only 或者大陆机器，需要 Github 加速网，可自行查找放在 GH_PROXY 处 ，如 https://mirror.ghproxy.com/ ，能不用就不用，减少因加速网导致的故障。

GH_PROXY=
GH_PAT=
GH_BACKUP_USER=
GH_EMAIL=
GH_REPO=
SYSTEM=
ARCH=
WORK_DIR=
DAYS=5
IS_DOCKER=
DASHBOARD_VERSION=

########

# version: 2026.02.16

warning() { echo -e "\033[31m\033[01m$*\033[0m"; }  # 红色
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色

cmd_systemctl() {
  local ENABLE_DISABLE=$1
  if [ "$ENABLE_DISABLE" = 'enable' ]; then
    if [ "$SYSTEM" = 'Alpine' ]; then
      local TRY=5
      until [ $(systemctl is-active nezha-dashboard) = 'active' ]; do
        systemctl stop nezha-dashboard; sleep 1
        systemctl start nezha-dashboard
        ((TRY--))
        [ "$TRY" = 0 ] && break
      done
      cat > /etc/local.d/nezha-dashboard.start << ABC
#!/usr/bin/env bash

systemctl start nezha-dashboard
ABC
      chmod +x /etc/local.d/nezha-dashboard.start
      rc-update add local >/dev/null 2>&1
    else
      systemctl enable --now nezha-dashboard
    fi

  elif [ "$ENABLE_DISABLE" = 'disable' ]; then
    if [ "$SYSTEM" = 'Alpine' ]; then
      systemctl stop nezha-dashboard
      rm -f /etc/local.d/nezha-dashboard.start
    else
      systemctl disable --now nezha-dashboard
    fi
  fi
}

# 运行备份脚本时，自锁一定时间以防 Github 缓存的原因导致数据马上被还原
touch $(awk -F '=' '/NO_ACTION_FLAG/{print $2; exit}' $WORK_DIR/restore.sh)1

# 手自动标志
[ "$1" = 'a' ] && WAY=Scheduled || WAY=Manualed
[ "$1" = 'f' ] && WAY=Manualed && FORCE_UPDATE=true

# 检查更新面板主程序 app 及 cloudflared
if [ -z "$DASHBOARD_VERSION" ]; then
  cd $WORK_DIR
  DASHBOARD_NOW=$(./app -v)
  DASHBOARD_LATEST=$(wget -qO- https://api.github.com/repos/naiba/nezha/releases/latest | awk -F '"' '/tag_name/{print $4}')
  [ "v${DASHBOARD_NOW}" != "$DASHBOARD_LATEST" ] && DASHBOARD_UPDATE=true
elif [[ "$DASHBOARD_VERSION" =~ [0-2]\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
  cd $WORK_DIR
  DASHBOARD_NOW=$(./app -v)
  DASHBOARD_LATEST=$(sed 's/v//; s/^/v&/' <<< "$DASHBOARD_VERSION")
  [ "v${DASHBOARD_NOW}" != "$DASHBOARD_LATEST" ] && DASHBOARD_UPDATE=true
else
  error "The DASHBOARD_VERSION variable should be in a format like v0.00.00, please check."
fi

CLOUDFLARED_NOW=$(./cloudflared -v | awk '{for (i=0; i<NF; i++) if ($i=="version") {print $(i+1)}}')
CLOUDFLARED_LATEST=$(wget -qO- ${GH_PROXY}https://api.github.com/repos/cloudflare/cloudflared/releases/latest | awk -F '"' '/tag_name/{print $4}')
[[ "$CLOUDFLARED_LATEST" =~ ^20[0-9]{2}\.[0-9]{1,2}\.[0-9]+$ && "$CLOUDFLARED_NOW" != "$CLOUDFLARED_LATEST" ]] && CLOUDFLARED_UPDATE=true

# 检测是否有设置备份数据
if [[ -n "$GH_REPO" && -n "$GH_BACKUP_USER" && -n "$GH_PAT" ]]; then
  IS_PRIVATE="$(wget -qO- --header="Authorization: token $GH_PAT" ${GH_PROXY}https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO | sed -n '/"private":/s/.*:[ ]*\([^,]*\),/\1/gp')"
  if [ "$?" != 0 ]; then
    warning "\n Could not connect to Github. Stop backup. \n"
  elif [ "$IS_PRIVATE" != true ]; then
    warning "\n This is not exist nor a private repository. \n"
  else
    IS_BACKUP=true
  fi
fi

# 分步骤处理
if [[ "${DASHBOARD_UPDATE}${CLOUDFLARED_UPDATE}${IS_BACKUP}${FORCE_UPDATE}" =~ true ]]; then
  # 更新面板主程序
  if [[ "${DASHBOARD_UPDATE}${FORCE_UPDATE}" =~ 'true' ]]; then
    VERSION_NUM=${DASHBOARD_LATEST#v}  # 去掉 v 前缀
    hint "\n Renew dashboard app to $DASHBOARD_LATEST \n"
    if [ "$VERSION_NUM" = "0.20.13" ]; then
      # 版本 = 0.20.13：从 nap0o/nezha-dashboard 下载
      wget -O /tmp/dashboard.zip ${GH_PROXY}https://github.com/nap0o/nezha-dashboard/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip
    elif [[ "$DASHBOARD_VERSION" =~ 0\.[0-9]{1,2}\.[0-9]{1,2}$ ]] && [ "$(printf '%s\n%s' "$VERSION_NUM" "0.20.13" | sort -V | tail -n1)" = "$VERSION_NUM" ]; then
      # v0且版本 > 0.20.13：从 railzen/nezha-zero 下载
      wget -O /tmp/dashboard.zip ${GH_PROXY}https://github.com/railzen/nezha-zero/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip
    elif [[ "$DASHBOARD_LATEST" = 'v2.2.10' && "$ARCH" =~ ^(amd64|arm64)$ ]]; then
      # v2.2.10：从本仓库 workflow 构建的修复版 Dashboard 下载，与 init.sh 保持一致
      wget -O /tmp/dashboard.zip ${GH_PROXY}https://github.com/wbxl0/Argo-Nezha-Service-Container/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip
    else
      # 版本 < 0.20.13或者v1：从 naiba/nezha 下载
      wget -O /tmp/dashboard.zip ${GH_PROXY}https://github.com/naiba/nezha/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip
    fi
    unzip -o /tmp/dashboard.zip -d /tmp
    chmod +x /tmp/dashboard-linux-$ARCH
    if [ -s /tmp/dashboard-linux-$ARCH ]; then
      info "\n Restart Nezha Dashboard \n"
      if [ "$IS_DOCKER" = 1 ]; then
        supervisorctl stop nezha >/dev/null 2>&1
        sleep 10
        mv -f /tmp/dashboard-linux-$ARCH $WORK_DIR/app
        supervisorctl start nezha >/dev/null 2>&1
      else
        cmd_systemctl disable >/dev/null 2>&1
        sleep 10
        mv -f /tmp/dashboard-linux-$ARCH $WORK_DIR/app
        cmd_systemctl enable >/dev/null 2>&1
      fi
    fi
    rm -rf /tmp/dist /tmp/dashboard.zip
  fi

  # 更新 cloudflared
  if [[ "${CLOUDFLARED_UPDATE}${FORCE_UPDATE}" =~ 'true' ]]; then
    hint "\n Renew Cloudflared to $CLOUDFLARED_LATEST \n"
    wget -O /tmp/cloudflared ${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH && chmod +x /tmp/cloudflared
    if [ -s /tmp/cloudflared ]; then
      info "\n Restart Argo \n"
      if [ "$IS_DOCKER" = 1 ]; then
        supervisorctl stop argo >/dev/null 2>&1
        mv -f /tmp/cloudflared $WORK_DIR/
        supervisorctl start argo >/dev/null 2>&1
      else
        cmd_systemctl disable >/dev/null 2>&1
        mv -f /tmp/cloudflared $WORK_DIR/
        cmd_systemctl enable >/dev/null 2>&1
      fi
    fi
  fi

  # 通过 GitHub API 上传备份并对 main 分支强制覆盖（不克隆仓库、不留提交历史）
  # 在线热备：SQLite VACUUM INTO 一致性快照，面板全程运行，无需停机
  if [ "$IS_BACKUP" = 'true' ]; then
    # 检查 wget 是否支持自定义 HTTP 方法（需要 GNU Wget >= 1.21）
    if ! wget --help 2>&1 | grep -q -- '--method'; then
      error "The wget in use has no --method support. Need GNU Wget >= 1.21; please install GNU wget (or curl) and retry."
    fi

    # 检查并安装 sqlite3 依赖
    if ! command -v sqlite3 &> /dev/null; then
      echo "SQLite3 not found. Installing SQLite3..."
      case "$SYSTEM" in
        "Debian"|"Ubuntu")
          apt-get update && apt-get -y install sqlite3
          ;;
        "CentOS")
          yum update -y && yum install -y sqlite
          ;;
        "Arch")
          pacman -Sy --noconfirm sqlite
          ;;
        "Alpine")
          apk add --no-cache sqlite
          ;;
        *)
          error "Unsupported system: $SYSTEM. Only support Debian, Ubuntu, CentOS, Arch, Alpine."
          ;;
      esac
    fi

    # 1. 在线备份数据库：VACUUM INTO 生成一致性快照（失败回退 .backup），线上库零改动
    TRANSFERS_KEEP_DAYS=7
    BAK_TMP="/tmp/nezha-backup-$$"
    rm -rf "$BAK_TMP"; mkdir -p "$BAK_TMP/data"
    if [ -f "data/sqlite.db" ]; then
      sqlite3 "data/sqlite.db" "PRAGMA wal_checkpoint(PASSIVE);" >/dev/null 2>&1 || true
      if sqlite3 "data/sqlite.db" ".timeout 60000" "VACUUM INTO '$BAK_TMP/data/sqlite.db'" 2>/dev/null; then
        info "Database hot-backup OK (VACUUM INTO)"
      elif sqlite3 "data/sqlite.db" ".timeout 60000" ".backup '$BAK_TMP/data/sqlite.db'" 2>/dev/null; then
        info "Database hot-backup OK (.backup)"
      else
        error "Database hot-backup failed!"
      fi
      # 2. 在副本上清理过期 transfers 流量记录并压缩（不动线上库，备份体积长期受控）
      sqlite3 "$BAK_TMP/data/sqlite.db" ".timeout 60000" \
        "DELETE FROM transfers WHERE created_at < date('now','-$TRANSFERS_KEEP_DAYS days');" >/dev/null 2>&1 || true
      sqlite3 "$BAK_TMP/data/sqlite.db" 'VACUUM;' >/dev/null 2>&1 || true
    else
      hint "\n No sqlite.db found, skip database backup. \n"
    fi

    # 3. 复制 data 其余文件（排除 tsdb / WAL / SHM，陈旧 WAL 配还原库是损坏经典来源）
    for item in data/*; do
      [ -e "$item" ] || continue
      case "$(basename "$item")" in
        sqlite.db|sqlite.db-wal|sqlite.db-shm|tsdb) ;;
        *) cp -R "$item" "$BAK_TMP/data/" 2>/dev/null || true ;;
      esac
    done

    # 4. resource/ 下自定义主题目录一并打包
    if [ -d "resource" ]; then
      find resource/ -type d -name "*custom*" > "$BAK_TMP/custom.list" || true
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        mkdir -p "$BAK_TMP/$(dirname "$d")"
        cp -R "$d" "$BAK_TMP/${d%/}"
      done < "$BAK_TMP/custom.list"
    fi

    # 5. 打包（文件名用下划线：冒号在 Windows 下载时会被改写，曾导致指针与文件名错位）
    TIME=$(date "+%Y-%m-%d-%H_%M_%S")
    echo "↓↓↓↓↓↓↓↓↓↓ dashboard-$TIME.tar.gz list ↓↓↓↓↓↓↓↓↓↓"
    tar czvf /tmp/dashboard-$TIME.tar.gz -C "$BAK_TMP" data/ 2>/dev/null
    rm -rf "$BAK_TMP"
    echo -e "↑↑↑↑↑↑↑↑↑↑ dashboard-$TIME.tar.gz list ↑↑↑↑↑↑↑↑↑↑\n\n"

    # 更新备份 Github 库：仅保留最近 $DAYS 个备份，其余随本次提交一同删除；全程通过 GitHub API，不克隆、不留历史
    if [ ! -s /tmp/dashboard-$TIME.tar.gz ]; then
      rm -f $(awk -F '=' '/NO_ACTION_FLAG/{print $2; exit}' $WORK_DIR/restore.sh)*
      hint "\n Failed to create the backup files dashboard-$TIME.tar.gz. \n"
    else
      # 1. 上传新备份包的 blob（base64 编码为 GitHub Git Database API 接口要求）
      base64 /tmp/dashboard-$TIME.tar.gz | tr -d '\n' > /tmp/backup.b64
      # 体积预检：base64 后超 47MB 会超过 GitHub API 上限，主动跳过并提示
      B64_SIZE=$(wc -c < /tmp/backup.b64 | tr -d ' ')
      if [ "$B64_SIZE" -gt 47000000 ]; then
        rm -f $(awk -F '=' '/NO_ACTION_FLAG/{print $2; exit}' $WORK_DIR/restore.sh)*
        hint "\n Backup too large after base64 ( $B64_SIZE bytes > 47MB ), upload skipped. Prune old data and retry. \n"
        exit 0
      fi
      { printf '{"content":"'; cat /tmp/backup.b64; printf '","encoding":"base64"}'; } > /tmp/blob_backup.json
      BLOB_SHA=$(wget -t 3 -T 30 -qO- --method=POST --header="Authorization: token $GH_PAT" --header="Accept: application/vnd.github+json" --body-file=/tmp/blob_backup.json ${GH_PROXY}https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO/git/blobs | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)

      # 2. 上传 README 的 blob：首行为最新备份文件名（restore.sh 依赖首行），附还原说明便于人工阅读
      BACKUP_SIZE=$(du -h "/tmp/dashboard-$TIME.tar.gz" | cut -f1)
      printf 'dashboard-%s.tar.gz\n\n- 备份时间: %s\n- 大小: %s\n- transfers 保留: 最近 %s 天\n\n## 手动触发备份\n将本文件内容改为 backup 后提交。\n\n## 指定还原\n将首行改为要恢复的备份文件名（须存在于本仓库），提交后自动还原。\n' \
        "$TIME" "$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')" "$BACKUP_SIZE" "$TRANSFERS_KEEP_DAYS" | base64 | tr -d '\n' > /tmp/readme.b64
      { printf '{"content":"'; cat /tmp/readme.b64; printf '","encoding":"base64"}'; } > /tmp/blob_readme.json
      README_SHA=$(wget -qO- --method=POST --header="Authorization: token $GH_PAT" --header="Accept: application/vnd.github+json" --body-file=/tmp/blob_readme.json ${GH_PROXY}https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO/git/blobs | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)

      # 3. 列出现有备份；本次新的一份必留，旧备份最多保留最近 $((DAYS-1)) 个，更旧的从新树中剔除（即删除）
      OLD_KEEP=
      OLD_LIST=$(wget -qO- --header="Authorization: token $GH_PAT" ${GH_PROXY}https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO/contents/)
      OLD_PAIRS=$(printf '%s' "$OLD_LIST" | awk '
        /"name": *"dashboard-.*\.tar\.gz"/{ n=$0; sub(/.*"name": *"/,"",n); sub(/".*/,"",n); name=n; have=1; next }
        /"sha":/ && have{ s=$0; sub(/.*"sha": *"/,"",s); sub(/".*/,"",s); print name, s; have=0 }
      ')
      [ -n "$OLD_PAIRS" ] && OLD_KEEP=$(printf '%s\n' "$OLD_PAIRS" | sort -k1,1r | head -n $((DAYS-1)))

      # 4. 重建整棵 tree：新备份 + 保留的旧备份 + README（过期的备份不进入新树，等价于删除）
      TREE_ITEMS='[{"path":"dashboard-'"$TIME"'.tar.gz","mode":"100644","type":"blob","sha":"'"$BLOB_SHA"'"}'
      while read NAME SHA; do
        [ -z "$NAME" ] && continue
        TREE_ITEMS="$TREE_ITEMS,{\"path\":\"$NAME\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"$SHA\"}"
      done <<< "$OLD_KEEP"
      TREE_ITEMS="$TREE_ITEMS,{\"path\":\"README.md\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"$README_SHA\"}]"
      printf '{"tree":%s}' "$TREE_ITEMS" > /tmp/tree.json
      NEW_TREE_SHA=$(wget -qO- --method=POST --header="Authorization: token $GH_PAT" --header="Accept: application/vnd.github+json" --body-file=/tmp/tree.json ${GH_PROXY}https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO/git/trees | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)

      # 5. 新建 root commit（父提交为空），使 main 被覆盖后始终是单提交，不累积历史
      printf '{"message":"%s backup at %s","tree":"%s","parents":[]}' "$WAY" "$TIME" "$NEW_TREE_SHA" > /tmp/commit.json
      COMMIT_SHA=$(wget -qO- --method=POST --header="Authorization: token $GH_PAT" --header="Accept: application/vnd.github+json" --body-file=/tmp/commit.json ${GH_PROXY}https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO/git/commits | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)

      # 6. 强制将 main 分支指向该 commit，完成上传与旧备份的删除
      printf '{"sha":"%s","force":true}' "$COMMIT_SHA" > /tmp/ref.json
      REF_RESP=$(wget -qO- --method=PATCH --header="Authorization: token $GH_PAT" --header="Accept: application/vnd.github+json" --body-file=/tmp/ref.json ${GH_PROXY}https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO/git/refs/heads/main)

      # 清理临时文件
      rm -f /tmp/backup.b64 /tmp/readme.b64 /tmp/blob_backup.json /tmp/blob_readme.json /tmp/tree.json /tmp/commit.json /tmp/ref.json /tmp/dashboard-$TIME.tar.gz

      if [ -n "$COMMIT_SHA" ] && printf '%s' "$REF_RESP" | grep -q '"ref":'; then
        echo "dashboard-$TIME.tar.gz" > $WORK_DIR/dbfile
        info "\n Succeed to upload the backup files dashboard-$TIME.tar.gz to Github.\n"
      else
        rm -f $(awk -F '=' '/NO_ACTION_FLAG/{print $2; exit}' $WORK_DIR/restore.sh)*
        hint "\n Failed to upload the backup files dashboard-$TIME.tar.gz to Github.\n"
      fi
    fi
  fi
fi

if [ "$IS_DOCKER" = 1 ]; then
  supervisorctl start nezha >/dev/null 2>&1
  [ $(supervisorctl status all | grep -c "RUNNING") = $(grep -c '\[program:.*\]' /etc/supervisor/conf.d/damon.conf) ] && info "\n All programs started! \n" || error "\n Failed to start program! \n"
else
  cmd_systemctl enable >/dev/null 2>&1
  [ "$(systemctl is-active nezha-dashboard)" = 'active' ] && info "\n Nezha dashboard started! \n" || error "\n Failed to start Nezha dashboard! \n"
fi