#!/bin/bash
# =====================================================
# Nezha Toolbox - 生产版（全量修复 + 关闭TSDB + 备份清理 + 跨机迁移）
# 功能：安装、备份、恢复、开启/关闭 TSDB、备份保留策略、一键迁移（导出/导入）
# =====================================================

set -euo pipefail

# ---------- 全局变量 ----------
BASE="/opt/nezha/dashboard"
CONFIG="$BASE/data/config.yaml"
DB="$BASE/data/sqlite.db"
TSDB_DIR="$BASE/data/tsdb"
BACKUP_DIR="/root"
BACKUP_PREFIX="nezha-backup"
BACKUP_LINK="/root/backup.tar.gz"
# 迁移清单（export 时生成，随包打入 /tmp，import 时读取展示）
MIGRATE_MANIFEST="/tmp/nezha-migrate-manifest.txt"
# 备份保留最近 N 份（不含 pre-restore 快照），设为 0 表示不自动清理
KEEP_BACKUPS=5

YES_MODE=0
SUBCMD=""   # install | backup | restore | tsdb | disable-tsdb | export | import

# ---------- 参数解析 ----------
parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --yes|-y)
                YES_MODE=1
                ;;
            install|backup|restore|tsdb|disable-tsdb|export|import)
                if [[ -n "$SUBCMD" ]]; then
                    print_error "只能指定一个子命令，已有: $SUBCMD，又收到: $arg"
                    exit 1
                fi
                SUBCMD="$arg"
                ;;
            -h|--help)
                cat <<EOF
用法: $0 [选项] [子命令]

选项:
  --yes, -y          非交互模式，自动确认所有操作
  -h, --help         显示帮助

子命令:
  install            安装 Nezha
  backup             执行备份（自动清理旧备份，保留最近 ${KEEP_BACKUPS} 份）
  restore            执行恢复
  tsdb               开启 TSDB
  disable-tsdb       关闭 TSDB（移除配置并清理 tsdb 目录）
  export             迁移导出（在旧 VPS 执行：备份数据 + 生成迁移清单）
  import             迁移导入（在新 VPS 执行：装依赖 + 解压恢复 + 启动服务）

无子命令时进入交互菜单。
环境变量 NEZHA_TOOLBOX_YES=1 等同于 --yes。
环境变量 NEZHA_MIGRATE_BUNDLE=<路径或URL> 可指定 import 使用的迁移包。
EOF
                exit 0
                ;;
            *)
                print_error "未知参数: $arg（可用 --help 查看帮助）"
                exit 1
                ;;
        esac
    done
    if [[ "${NEZHA_TOOLBOX_YES:-0}" == "1" ]]; then
        YES_MODE=1
    fi
}

# ---------- 辅助函数 ----------

print_info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
print_warn()  { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
print_error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限，请使用 sudo 运行。"
        exit 1
    fi
}

check_deps() {
    local deps=("docker" "tar" "sqlite3" "curl")
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if ! command -v systemctl &>/dev/null; then
        print_warn "未检测到 systemctl，nginx 启停将跳过。"
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "缺少以下依赖: ${missing[*]}，请安装后再试。"
        exit 1
    fi
}

safe_input() {
    local prompt="$1"
    local input=""
    if [[ -t 0 ]]; then
        read -r -p "$prompt" input || true
    fi
    echo "$input"
}

confirm() {
    local prompt="$1"
    if [[ $YES_MODE -eq 1 ]]; then
        print_info "非交互模式，自动确认: $prompt"
        return 0
    fi
    local answer
    answer=$(safe_input "$prompt (y/n): ")
    answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    [[ "$answer" == "y" || "$answer" == "yes" ]]
}

detect_compose() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null && docker-compose version &>/dev/null; then
        echo "docker-compose"
    else
        print_error "未找到 docker compose 或 docker-compose，请确保 Docker 已安装。"
        exit 1
    fi
}

wait_compose_up() {
    local compose="$1"
    local timeout="${2:-60}"
    local i
    for ((i = 1; i <= timeout; i++)); do
        if (cd "$BASE" && $compose ps -q 2>/dev/null) | grep -q .; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# 0=成功  1=明确失败  2=超时/不确定
check_tsdb_initialized() {
    local compose="$1"
    local timeout="${2:-45}"
    local i log
    for ((i = 1; i <= timeout; i++)); do
        log=$(cd "$BASE" && $compose logs --tail=80 2>/dev/null || true)
        if echo "$log" | grep -qiE 'TSDB initialized successfully|TSDB opened at|TSDB is (now )?enabled'; then
            return 0
        fi
        if echo "$log" | grep -qiE 'TSDB is disabled \(tsdb\.data_path not configured\)|failed to (open|init).*TSDB|TSDB.*error'; then
            return 1
        fi
        sleep 1
    done
    return 2
}

rollback_tsdb() {
    local compose="$1"
    local config_bak="$2"
    local db_bak="$3"
    print_error "检测到 TSDB 开启失败，正在自动回滚..."
    if [[ -n "$config_bak" && -f "$config_bak" ]]; then
        cp -f "$config_bak" "$CONFIG"
        print_info "已恢复 config.yaml"
    fi
    if [[ -n "$db_bak" && -f "$db_bak" ]]; then
        cp -f "$db_bak" "$DB"
        print_info "已恢复 sqlite.db"
    fi
    rm -rf "$TSDB_DIR"
    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose up -d 2>/dev/null || print_warn "回滚后启动容器失败，请手动检查"
    fi
    print_info "回滚完成。"
}

append_config_block() {
    local block="$1"
    if [[ ! -s "$CONFIG" ]]; then
        print_warn "配置文件为空或不存在，跳过追加。"
        return 0
    fi
    local last
    last=$(tail -c1 "$CONFIG" 2>/dev/null || true)
    if [[ -n "$last" ]]; then
        printf '\n' >> "$CONFIG"
    fi
    printf '%s\n' "$block" >> "$CONFIG"
}

# 写入完整 tsdb 配置块
write_tsdb_config() {
    local tmp
    tmp=$(mktemp)
    if [[ -f "$CONFIG" ]]; then
        awk '
            BEGIN { skip=0 }
            /^tsdb:[[:space:]]*/ { skip=1; next }
            /^[a-zA-Z0-9_]+:/ && skip { skip=0 }
            !skip { print }
        ' "$CONFIG" > "$tmp"
        mv "$tmp" "$CONFIG"
    else
        touch "$CONFIG"
    fi

    local block
    block=$(cat <<'EOF'
tsdb:
  data_path: "data/tsdb"
  retention_days: 30
  min_free_disk_space_gb: 1
  max_memory_mb: 256
  write_buffer_size: 512
  write_buffer_flush_interval: 5
EOF
)
    append_config_block "$block"
}

# 移除整个 tsdb 配置块（关闭时用）
remove_tsdb_config() {
    local tmp
    tmp=$(mktemp)
    if [[ -f "$CONFIG" ]]; then
        awk '
            BEGIN { skip=0 }
            /^tsdb:[[:space:]]*/ { skip=1; next }
            /^[a-zA-Z0-9_]+:/ && skip { skip=0 }
            !skip { print }
        ' "$CONFIG" > "$tmp"
        mv "$tmp" "$CONFIG"
    fi
}

nezha_installed() {
    [[ -d "$BASE" ]]
}

tsdb_enabled() {
    [[ -f "$CONFIG" ]] || return 1
    grep -qE '^\s*data_path:\s*["'\'']?[^"'\''[:space:]]+' "$CONFIG" 2>/dev/null
}

# 清理旧备份，只保留最近 KEEP_BACKUPS 份（不含 pre-restore-）
cleanup_old_backups() {
    if [[ "$KEEP_BACKUPS" -le 0 ]]; then
        return 0
    fi
    local files=() sorted=""
    # 按时间倒序，跳过前 KEEP_BACKUPS 个，删除其余
    # 用变量中转代替进程替换，兼容 /dev/fd 不可用的环境
    sorted=$(ls -1t "${BACKUP_DIR}/${BACKUP_PREFIX}"-*.tar.gz 2>/dev/null || true)
    [[ -z "$sorted" ]] && return 0
    mapfile -t files <<<"$sorted"
    local total=${#files[@]}
    if [[ $total -le $KEEP_BACKUPS ]]; then
        return 0
    fi
    local i
    for ((i = KEEP_BACKUPS; i < total; i++)); do
        print_info "清理旧备份: ${files[$i]}"
        rm -f "${files[$i]}"
    done
    # 若软链接指向已删文件，重新指向最新
    if [[ -L "$BACKUP_LINK" ]]; then
        local latest
        latest=$(ls -1t "${BACKUP_DIR}/${BACKUP_PREFIX}"-*.tar.gz 2>/dev/null | head -1 || true)
        if [[ -n "$latest" ]]; then
            ln -sfn "$latest" "$BACKUP_LINK"
        else
            rm -f "$BACKUP_LINK"
        fi
    fi
}

# ---------- 核心功能 ----------

install_nezha() {
    print_info "即将调用官方安装脚本（https://github.com/nezhahq/scripts）"
    print_info "该脚本为交互式，请根据提示完成安装。"
    echo ""
    if ! bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh); then
        print_error "官方安装脚本执行失败。"
        return 1
    fi
    if nezha_installed; then
        print_info "✅ Nezha 安装成功！"
    else
        print_error "❌ 安装未完成或已被取消。"
    fi
}

do_backup() {
    local extra_tar_paths="${1:-}"
    local compose
    compose=$(detect_compose)

    confirm "确认执行备份" || { print_info "已取消备份。"; return 0; }

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/${BACKUP_PREFIX}-${ts}.tar.gz"

    print_info "开始备份 → $backup_file"

    if command -v systemctl &>/dev/null; then
        systemctl stop nginx 2>/dev/null || print_warn "停止 nginx 失败（可能未运行）"
    fi
    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose down 2>/dev/null || print_warn "停止容器失败（可能未运行）"
    fi

    print_info "正在打包数据..."
    if ! tar -czf "$backup_file" \
        --ignore-failed-read \
        --exclude='opt/nezha/dashboard/data/tsdb' \
        --exclude='opt/nezha/dashboard/data/*.log' \
        --exclude='opt/nezha/dashboard/data/*.db-wal' \
        --exclude='opt/nezha/dashboard/data/*.db-shm' \
        --exclude='opt/nezha/dashboard/logs' \
        -C / \
        etc/nginx \
        opt/nezha \
        root/ssl \
        $extra_tar_paths 2>/dev/null; then
        print_error "打包失败。"
        if [[ -d "$BASE" ]]; then
            cd "$BASE" && $compose up -d 2>/dev/null || true
        fi
        if command -v systemctl &>/dev/null; then
            systemctl start nginx 2>/dev/null || true
        fi
        exit 1
    fi

    ln -sfn "$backup_file" "$BACKUP_LINK"
    print_info "已更新软链接: $BACKUP_LINK → $backup_file"

    # 自动清理旧备份
    cleanup_old_backups

    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose up -d 2>/dev/null || print_warn "启动容器失败，请手动检查"
    fi
    if command -v systemctl &>/dev/null; then
        systemctl start nginx 2>/dev/null || print_warn "启动 nginx 失败，请手动检查"
    fi

    print_info "▶ 备份完成！文件: $backup_file（保留最近 ${KEEP_BACKUPS} 份）"
}

do_restore() {
    local compose
    compose=$(detect_compose)

    local restore_file=""
    if [[ -L "$BACKUP_LINK" || -f "$BACKUP_LINK" ]]; then
        restore_file=$(readlink -f "$BACKUP_LINK" 2>/dev/null || echo "$BACKUP_LINK")
    fi
    if [[ -z "$restore_file" || ! -f "$restore_file" ]]; then
        restore_file=$(ls -1t "${BACKUP_DIR}/${BACKUP_PREFIX}"-*.tar.gz 2>/dev/null | head -1 || true)
    fi
    if [[ -z "$restore_file" || ! -f "$restore_file" ]]; then
        print_error "未找到备份文件（$BACKUP_LINK 或 ${BACKUP_DIR}/${BACKUP_PREFIX}-*.tar.gz）"
        return 0
    fi

    print_info "将使用备份: $restore_file"

    print_info "正在校验备份包完整性..."
    if ! tar -tzf "$restore_file" >/dev/null 2>&1; then
        print_error "备份包损坏或不是有效的 gzip tar 文件，已中止恢复。"
        return 1
    fi
    print_info "备份包校验通过。"

    confirm "确认执行恢复操作（将覆盖现有数据）" || { print_info "已取消恢复。"; return 0; }

    local pre_ts
    pre_ts=$(date +%Y%m%d-%H%M%S)
    local pre_backup="${BACKUP_DIR}/pre-restore-${pre_ts}.tar.gz"
    print_info "恢复前自动备份当前状态 → $pre_backup"
    tar -czf "$pre_backup" --ignore-failed-read -C / opt/nezha etc/nginx 2>/dev/null || \
        print_warn "恢复前备份失败，继续恢复..."

    print_info "开始恢复..."

    if command -v systemctl &>/dev/null; then
        systemctl stop nginx 2>/dev/null || print_warn "停止 nginx 失败"
    fi
    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose down 2>/dev/null || print_warn "停止容器失败"
    fi

    print_info "正在解压备份..."
    if ! tar -xzf "$restore_file" -C /; then
        print_error "解压失败，请检查备份文件。"
        print_warn "正在尝试恢复服务到恢复前状态..."
        if [[ -d "$BASE" ]]; then
            cd "$BASE" && $compose up -d 2>/dev/null || true
        fi
        if command -v systemctl &>/dev/null; then
            systemctl start nginx 2>/dev/null || true
        fi
        exit 1
    fi

    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose up -d 2>/dev/null || print_warn "启动容器失败，请手动检查"
    fi
    if command -v systemctl &>/dev/null; then
        systemctl start nginx 2>/dev/null || print_warn "启动 nginx 失败，请手动检查"
    fi

    print_info "▶ 恢复完成！（恢复前状态已备份至 $pre_backup）"
}

enable_tsdb() {
    local compose
    compose=$(detect_compose)

    if ! nezha_installed; then
        print_error "Nezha 尚未安装，请先执行安装。"
        return 1
    fi

    if tsdb_enabled; then
        print_info "TSDB 已经开启（检测到有效 data_path），无需重复操作。"
        return 0
    fi

    confirm "确认开启 TSDB？（将清理 service_histories 历史记录，且官方会 drop 该表）" || {
        print_info "已取消。"
        return 0
    }

    print_info "正在配置 TSDB..."

    local config_bak db_bak
    config_bak=$(mktemp)
    db_bak=""
    cp -f "$CONFIG" "$config_bak" 2>/dev/null || true
    if [[ -f "$DB" ]]; then
        db_bak=$(mktemp)
        cp -f "$DB" "$db_bak"
    fi

    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose down 2>/dev/null || print_warn "停止容器失败"
    fi

    if [[ -f "$DB" ]]; then
        print_info "正在清理 SQLite service_histories..."
        if ! sqlite3 "$DB" "DELETE FROM service_histories; VACUUM;" 2>&1; then
            print_error "SQLite 操作失败。"
            rollback_tsdb "$compose" "$config_bak" "$db_bak"
            rm -f "$config_bak" ${db_bak:+"$db_bak"}
            exit 1
        fi
    else
        print_warn "数据库文件不存在，跳过清理。"
    fi

    print_info "正在写入 TSDB 配置..."
    write_tsdb_config
    mkdir -p "$TSDB_DIR"

    print_info "正在启动服务并验证 TSDB..."
    cd "$BASE"
    if ! $compose up -d; then
        print_error "启动容器失败。"
        rollback_tsdb "$compose" "$config_bak" "$db_bak"
        rm -f "$config_bak" ${db_bak:+"$db_bak"}
        exit 1
    fi

    if ! wait_compose_up "$compose" 60; then
        print_error "容器未能在超时内启动。"
        rollback_tsdb "$compose" "$config_bak" "$db_bak"
        rm -f "$config_bak" ${db_bak:+"$db_bak"}
        exit 1
    fi

    local check_result=0
    check_tsdb_initialized "$compose" 45 || check_result=$?

    case $check_result in
        0)
            print_info "▶ TSDB 开启成功！"
            rm -f "$config_bak" ${db_bak:+"$db_bak"}
            ;;
        1)
            print_error "TSDB 明确未启用（日志显示 disabled 或错误）。"
            rollback_tsdb "$compose" "$config_bak" "$db_bak"
            rm -f "$config_bak" ${db_bak:+"$db_bak"}
            exit 1
            ;;
        2)
            print_warn "超时未在日志中匹配到明确成功/失败关键词。"
            if [[ $YES_MODE -eq 1 ]]; then
                print_error "非交互模式：按失败处理并回滚。"
                rollback_tsdb "$compose" "$config_bak" "$db_bak"
                rm -f "$config_bak" ${db_bak:+"$db_bak"}
                exit 1
            fi
            if confirm "日志未确认成功，是否仍视为成功并保留当前配置？"; then
                print_info "已按用户确认保留配置。请手动检查日志确认 TSDB 状态。"
                rm -f "$config_bak" ${db_bak:+"$db_bak"}
            else
                rollback_tsdb "$compose" "$config_bak" "$db_bak"
                rm -f "$config_bak" ${db_bak:+"$db_bak"}
                exit 1
            fi
            ;;
    esac
}

# 关闭 TSDB：移除配置 + 删除数据目录 + 重启
disable_tsdb() {
    local compose
    compose=$(detect_compose)

    if ! nezha_installed; then
        print_error "Nezha 尚未安装。"
        return 1
    fi

    if ! tsdb_enabled; then
        print_info "TSDB 当前未开启，无需操作。"
        return 0
    fi

    confirm "确认关闭 TSDB？（将删除 tsdb 数据目录，历史指标不可恢复）" || {
        print_info "已取消。"
        return 0
    }

    print_info "正在关闭 TSDB..."

    # 备份配置以便万一需要手动恢复
    local config_bak
    config_bak=$(mktemp)
    cp -f "$CONFIG" "$config_bak" 2>/dev/null || true

    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose down 2>/dev/null || print_warn "停止容器失败"
    fi

    print_info "移除 tsdb 配置块..."
    remove_tsdb_config

    print_info "删除 TSDB 数据目录: $TSDB_DIR"
    rm -rf "$TSDB_DIR"

    print_info "正在重启服务..."
    cd "$BASE"
    if ! $compose up -d; then
        print_error "启动容器失败，配置已修改，请手动检查。"
        print_info "原配置备份在: $config_bak"
        exit 1
    fi

    if wait_compose_up "$compose" 60; then
        print_info "▶ TSDB 已关闭。"
        rm -f "$config_bak"
    else
        print_warn "容器启动超时，请手动检查。原配置备份: $config_bak"
    fi
}

# ---------- 迁移功能 ----------

detect_pkg_mgr() {
    if command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v apk &>/dev/null; then echo "apk"
    else echo "unknown"
    fi
}

# 配置 nginx 官方源（nginx.org）
# 返回 0=已配置官方源，1=配置失败（调用方回退发行版自带源）
remove_nginx_official_repo() {
    rm -f /etc/apt/sources.list.d/nginx.list /etc/yum.repos.d/nginx.repo
    if [[ -f /etc/apk/repositories ]]; then
        grep -v 'nginx.org/packages/alpine' /etc/apk/repositories > /tmp/apk.repositories.tmp 2>/dev/null \
            && mv /tmp/apk.repositories.tmp /etc/apk/repositories || true
    fi
}

setup_nginx_official_repo() {
    local mgr="$1"
    print_info "正在配置 nginx 官方源（nginx.org）..."
    case "$mgr" in
        apt)
            local dist_id codename url_base keyring list_file
            dist_id=$(. /etc/os-release 2>/dev/null; echo "${ID:-debian}")
            codename=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
            [[ -z "$codename" ]] && codename=$(lsb_release -cs 2>/dev/null || true)
            if [[ -z "$codename" ]]; then
                print_warn "无法识别发行版代号，跳过官方源配置。"
                return 1
            fi
            if [[ "$dist_id" == "ubuntu" ]]; then
                url_base="http://nginx.org/packages/ubuntu"
            else
                url_base="http://nginx.org/packages/debian"
            fi
            apt-get install -y gnupg2 2>/dev/null || apt-get install -y gnupg 2>/dev/null || true
            keyring=/usr/share/keyrings/nginx-archive-keyring.gpg
            list_file=/etc/apt/sources.list.d/nginx.list
            mkdir -p /usr/share/keyrings
            mkdir -p "$(dirname "$list_file")"
            if curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o "$keyring" 2>/dev/null; then
                echo "deb [signed-by=$keyring] $url_base $codename nginx" > "$list_file"
            else
                print_warn "签名键获取失败，改用 trusted=yes 方式添加官方源。"
                echo "deb [trusted=yes] $url_base $codename nginx" > "$list_file"
            fi
            if apt-get update -y >/dev/null 2>&1; then
                print_info "nginx 官方源已配置: $url_base $codename"
                return 0
            fi
            print_warn "apt update 失败，移除官方源回退发行版源。"
            remove_nginx_official_repo
            apt-get update -y >/dev/null 2>&1 || true
            return 1
            ;;
        dnf|yum)
            local rel base osid
            rel=$(rpm -E '%{rhel}' 2>/dev/null | head -1 || true)
            if [[ -z "$rel" || "$rel" == "%{rhel}" ]]; then
                local vid
                vid=$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")
                rel="${vid%%.*}"
            fi
            if [[ -z "$rel" ]]; then
                print_warn "无法识别系统主版本，跳过官方源配置。"
                return 1
            fi
            osid=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
            if [[ "$osid" == "rhel" ]]; then
                base="http://nginx.org/packages/rhel/${rel}/\$basearch/"
            else
                base="http://nginx.org/packages/centos/${rel}/\$basearch/"
            fi
            mkdir -p /etc/yum.repos.d
            cat > /etc/yum.repos.d/nginx.repo <<EOF
[nginx-stable]
name=nginx stable repo
baseurl=$base
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
            if "$mgr" makecache -y >/dev/null 2>&1 || "$mgr" makecache >/dev/null 2>&1; then
                print_info "nginx 官方源已配置: $base"
                return 0
            fi
            print_warn "官方源 makecache 失败，移除回退发行版源。"
            remove_nginx_official_repo
            return 1
            ;;
        apk)
            local aver arepo
            aver=$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")
            aver=$(echo "$aver" | grep -oE '^[0-9]+\.[0-9]+' || true)
            if [[ -z "$aver" ]]; then
                print_warn "无法识别 Alpine 版本，跳过官方源配置。"
                return 1
            fi
            arepo="http://nginx.org/packages/alpine/v${aver}/main"
            if ! grep -qF "$arepo" /etc/apk/repositories 2>/dev/null; then
                echo "$arepo" >> /etc/apk/repositories
            fi
            if apk update >/dev/null 2>&1; then
                print_info "nginx 官方源已配置: $arepo"
                return 0
            fi
            print_warn "apk update 失败，移除官方源回退发行版源。"
            remove_nginx_official_repo
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# 执行一次 nginx 安装（mgr 由 install_migrate_deps 定义，bash 动态作用域可见）
try_install_nginx() {
    case "$mgr" in
        apt)      apt-get install -y nginx ;;
        dnf)      dnf install -y nginx ;;
        yum)      yum install -y nginx ;;
        apk)      apk add --no-cache nginx ;;
        *)        return 1 ;;
    esac
}

# nginx 安装：优先官方源，安装失败自动回退发行版源，发行版源也失败才算失败
install_nginx() {
    if command -v nginx &>/dev/null; then
        print_info "nginx 已安装（$(nginx -v 2>&1 | head -1)），跳过安装。"
        return 0
    fi
    local official_ok=0
    if setup_nginx_official_repo "$mgr"; then
        official_ok=1
    fi
    if try_install_nginx; then
        print_info "nginx 安装完成（$(nginx -v 2>&1 | head -1)），来源: $([[ $official_ok -eq 1 ]] && echo 官方源 || echo 发行版源)。"
        return 0
    fi
    if [[ $official_ok -eq 1 ]]; then
        print_warn "官方源安装 nginx 失败，回退发行版自带源重试..."
        remove_nginx_official_repo
        if try_install_nginx; then
            print_info "nginx 安装完成（发行版源）。"
            return 0
        fi
    fi
    print_error "nginx 安装失败，请检查网络后手动安装。"
    return 1
}

# 在新 VPS 上安装迁移所需依赖：docker + docker compose + nginx（官方源优先）+ sqlite3 + curl + tar
install_migrate_deps() {
    local mgr
    mgr=$(detect_pkg_mgr)
    print_info "检测到包管理器: $mgr，开始安装依赖（nginx / sqlite3 / curl / tar / ca-certificates）..."

    case "$mgr" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || print_warn "apt-get update 失败，继续尝试安装..."
            apt-get install -y sqlite3 curl tar ca-certificates || {
                print_error "依赖安装失败，请检查网络或手动安装。"
                return 1
            }
            ;;
        dnf)
            dnf install -y sqlite curl tar ca-certificates || {
                print_error "依赖安装失败，请检查网络或手动安装。"
                return 1
            }
            ;;
        yum)
            yum install -y epel-release 2>/dev/null || true
            yum install -y sqlite curl tar ca-certificates || {
                print_error "依赖安装失败，请检查网络或手动安装。"
                return 1
            }
            ;;
        apk)
            apk add --no-cache sqlite curl tar ca-certificates || {
                print_error "依赖安装失败，请检查网络或手动安装。"
                return 1
            }
            ;;
        *)
            print_error "无法识别的发行版，请手动安装 docker、docker compose、nginx、sqlite3、curl、tar 后重试。"
            return 1
            ;;
    esac

    # nginx：优先官方源（nginx.org）
    install_nginx || return 1

    if ! command -v docker &>/dev/null; then
        print_info "Docker 未安装，使用官方脚本安装（https://get.docker.com）..."
        if ! curl -fsSL https://get.docker.com | sh; then
            print_error "Docker 安装失败。"
            return 1
        fi
    fi
    if command -v systemctl &>/dev/null; then
        systemctl enable docker 2>/dev/null || print_warn "docker 开机自启设置失败（可忽略）"
        systemctl start docker 2>/dev/null || print_warn "docker 启动失败，请手动检查"
    fi

    # compose 插件兜底
    if ! docker compose version &>/dev/null && ! command -v docker-compose &>/dev/null; then
        print_info "安装 docker compose 插件..."
        case "$mgr" in
            apt)   apt-get install -y docker-compose-plugin 2>/dev/null || print_warn "compose 插件安装失败，请手动安装" ;;
            dnf)   dnf install -y docker-compose-plugin 2>/dev/null || print_warn "compose 插件安装失败，请手动安装" ;;
            yum)   yum install -y docker-compose-plugin 2>/dev/null || print_warn "compose 插件安装失败，请手动安装" ;;
            *)     print_warn "请手动安装 docker compose（https://docs.docker.com/compose/install/）" ;;
        esac
    fi
}

# 迁移导出：在旧 VPS 执行。生成环境清单 + 复用 do_backup 打包全部数据。
do_migrate_export() {
    if ! nezha_installed; then
        print_error "Nezha 尚未安装（$BASE 不存在），无法导出。"
        return 1
    fi

    confirm "确认导出迁移包（包含 nezha 数据 + nginx 配置 + /root/ssl 证书）" || {
        print_info "已取消导出。"
        return 0
    }

    print_info "正在生成迁移清单..."
    {
        echo "nezha-migrate-manifest v1"
        echo "export_time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "hostname: $(hostname 2>/dev/null || echo unknown)"
        echo "public_ip: $(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo unknown)"
        echo "os: $( ( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" ) || echo unknown)"
        echo "kernel: $(uname -r 2>/dev/null || echo unknown)"
        echo "docker: $(docker --version 2>/dev/null || echo none)"
        echo "nginx: $( (nginx -v 2>&1 | head -1) || echo none)"
        echo "nezha_base: $BASE"
    } > "$MIGRATE_MANIFEST" || print_warn "清单生成失败，继续备份..."

    # 复用备份逻辑；清单文件以相对 / 的路径打入包内（恢复后落在 /tmp 下）
    local rc=0
    do_backup "tmp/nezha-migrate-manifest.txt" || rc=$?
    rm -f "$MIGRATE_MANIFEST"

    if [[ $rc -eq 0 ]]; then
        echo ""
        print_info "▶ 迁移包已生成: $(ls -1t "${BACKUP_DIR}/${BACKUP_PREFIX}"-*.tar.gz 2>/dev/null | head -1)"
        print_info "下一步："
        print_info "  1. 把迁移包传到新 VPS，例如: scp ${BACKUP_DIR}/${BACKUP_PREFIX}-*.tar.gz root@新IP:/root/"
        print_info "  2. 在新 VPS 上执行: bash nezha_tool.sh import"
    fi
    return $rc
}

# 迁移导入：在新 VPS 执行。装依赖 → 解压恢复 → 启动 docker 服务 → 启动 nginx → 验证。
do_migrate_import() {
    local bundle="${NEZHA_MIGRATE_BUNDLE:-}"

    # 未指定时自动探测本地备份
    if [[ -z "$bundle" ]]; then
        local candidate=""
        if [[ -L "$BACKUP_LINK" || -f "$BACKUP_LINK" ]]; then
            candidate=$(readlink -f "$BACKUP_LINK" 2>/dev/null || echo "$BACKUP_LINK")
        fi
        if [[ -z "$candidate" || ! -f "$candidate" ]]; then
            candidate=$(ls -1t "${BACKUP_DIR}/${BACKUP_PREFIX}"-*.tar.gz 2>/dev/null | head -1 || true)
        fi
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            bundle="$candidate"
            print_info "自动探测到备份包: $bundle"
        elif [[ -t 0 ]]; then
            bundle=$(safe_input "未找到本地备份，请输入迁移包路径或下载 URL: ")
        fi
    fi

    if [[ -z "${bundle:-}" ]]; then
        print_error "未指定迁移包。请设置 NEZHA_MIGRATE_BUNDLE=<路径或URL> 或将包放到 /root/ 下。"
        return 1
    fi

    # 支持 URL 下载
    if [[ "$bundle" == http://* || "$bundle" == https://* ]]; then
        local fname
        fname=$(basename "${bundle%%\?*}")
        local dest="${BACKUP_DIR}/${fname}"
        print_info "正在下载迁移包 → $dest"
        if ! curl -fL --progress-bar -o "$dest" "$bundle"; then
            print_error "下载失败，请检查 URL 或网络。"
            rm -f "$dest"
            return 1
        fi
        bundle="$dest"
    fi

    if [[ ! -f "$bundle" ]]; then
        print_error "迁移包不存在: $bundle"
        return 1
    fi

    print_info "正在校验迁移包完整性..."
    if ! tar -tzf "$bundle" >/dev/null 2>&1; then
        print_error "迁移包损坏或不是有效的 gzip tar 文件，已中止导入。"
        return 1
    fi
    # 先取完整文件列表再判断：避免 pipefail 下 grep -q 提前退出导致 tar 被 SIGPIPE 误判
    local listing
    listing=$(tar -tzf "$bundle" 2>/dev/null || true)
    if ! grep -q '^opt/nezha/' <<<"$listing"; then
        print_error "迁移包中未找到 opt/nezha 目录，可能不是本工具生成的包，已中止导入。"
        return 1
    fi
    print_info "迁移包校验通过。"

    # 展示迁移清单（如果有）
    if grep -q '^tmp/nezha-migrate-manifest.txt$' <<<"$listing"; then
        print_info "----- 迁移清单 -----"
        tar -xzOf "$bundle" tmp/nezha-migrate-manifest.txt 2>/dev/null || true
        print_info "---------------------"
    fi

    if [[ "$YES_MODE" -eq 1 ]]; then
        print_info "非交互模式，自动确认导入"
    else
        confirm "确认导入？（将安装依赖，并覆盖 /opt/nezha、/etc/nginx、/root/ssl）" || {
            print_info "已取消导入。"
            return 0
        }
    fi

    install_migrate_deps || return 1

    # 依赖复检
    local need=()
    local c
    for c in docker tar sqlite3 curl; do
        command -v "$c" &>/dev/null || need+=("$c")
    done
    if [[ ${#need[@]} -gt 0 ]]; then
        print_error "以下依赖仍未就绪: ${need[*]}，请手动安装后重新执行 import。"
        return 1
    fi
    local compose
    compose=$(detect_compose)

    print_info "停止现有服务（避免覆盖冲突）..."
    if command -v systemctl &>/dev/null; then
        systemctl stop nginx 2>/dev/null || print_warn "停止 nginx 失败（可能未运行）"
    fi
    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose down 2>/dev/null || print_warn "停止容器失败（可能未运行）"
    fi

    print_info "正在解压迁移包到 / ..."
    if ! tar -xzf "$bundle" -C /; then
        print_error "解压失败！正在尝试启动原有服务..."
        if [[ -d "$BASE" ]]; then
            cd "$BASE" && $compose up -d 2>/dev/null || true
        fi
        if command -v systemctl &>/dev/null; then
            systemctl start nginx 2>/dev/null || true
        fi
        exit 1
    fi
    print_info "数据恢复完成。"

    # 证书目录权限收紧（如果存在）：私钥一律 600（覆盖 *.key / privkey.pem 等常见命名）
    if [[ -d /root/ssl ]]; then
        chmod 700 /root/ssl 2>/dev/null || true
        find /root/ssl -type f \( -name '*.key' -o -name 'privkey*' -o -name '*_key*' \) -exec chmod 600 {} + 2>/dev/null || true
    fi

    print_info "启动 Nezha 面板容器..."
    if [[ ! -d "$BASE" ]]; then
        print_error "恢复后未找到 $BASE，迁移包可能不完整。"
        return 1
    fi
    cd "$BASE"
    if [[ ! -f docker-compose.yml && ! -f docker-compose.yaml && ! -f compose.yml && ! -f compose.yaml ]]; then
        print_error "未找到 compose 文件（docker-compose.yml 等），无法启动面板。"
        return 1
    fi
    $compose pull || print_warn "镜像拉取出现异常，继续尝试启动..."
    if ! $compose up -d; then
        print_error "容器启动失败，请检查 docker 与 $BASE/docker-compose.yml"
        return 1
    fi
    if wait_compose_up "$compose" 90; then
        print_info "Nezha 容器已启动。"
    else
        print_warn "容器启动超时，请手动检查: cd $BASE && $compose logs"
    fi

    print_info "启动并配置 nginx..."
    if ! command -v nginx &>/dev/null; then
        print_error "nginx 未安装，反代无法启动（请检查依赖安装日志）。"
        return 1
    fi
    if [[ -f /etc/nginx/nginx.conf ]]; then
        if nginx -t 2>/dev/null; then
            print_info "nginx 配置校验通过。"
        else
            print_warn "nginx -t 校验失败（可能引用了本机不存在的证书/路径），跳过自动启动，请手动修复。"
            nginx -t || true
            print_info "迁移包中的 nginx 配置在 /etc/nginx，证书在 /root/ssl。"
            return 1
        fi
        if command -v systemctl &>/dev/null; then
            systemctl enable nginx 2>/dev/null || true
            systemctl start nginx 2>/dev/null || print_warn "nginx 启动失败，请手动检查"
        else
            nginx -s reload 2>/dev/null || nginx 2>/dev/null || print_warn "nginx 启动失败，请手动检查"
        fi
    else
        print_warn "未找到 /etc/nginx/nginx.conf（迁移包中无 nginx 配置），跳过反代启动。"
    fi

    echo ""
    print_info "▶ 迁移导入完成！"
    print_info "请确认以下事项："
    print_info "  1. DNS：把面板域名的 A 记录指向新 VPS 的 IP"
    print_info "  2. 防火墙：放行 80/443（Web 面板）及 5555/8008 等面板端口"
    print_info "  3. 证书：已随包恢复到 /root/ssl；若更换域名需重新签发"
    print_info "  4. 监控 Agent：若原来通过域名连接，无需改动；若用 IP 连接需更新"
    return 0
}

# ---------- 菜单 ----------
menu() {
    clear
    echo "================================"
    echo "       Nezha Toolbox"
    echo "================================"

    if nezha_installed; then
        echo " Nezha : 已安装"
    else
        echo " Nezha : 未安装"
    fi

    if tsdb_enabled; then
        echo " TSDB  : 已开启"
    else
        echo " TSDB  : 未开启"
    fi

    if [[ $YES_MODE -eq 1 ]]; then
        echo " 模式  : 非交互 (--yes)"
    fi
    echo " 备份保留: 最近 ${KEEP_BACKUPS} 份"

    echo "================================"
    echo " 1) 安装"
    echo " 2) 备份"
    echo " 3) 恢复"
    echo " 4) 开启 TSDB"
    echo " 5) 关闭 TSDB"
    echo " 6) 迁移导出（旧 VPS → 生成迁移包）"
    echo " 7) 迁移导入（新 VPS → 装依赖并恢复）"
    echo " 0) 退出"
    echo "================================"

    local choice
    choice=$(safe_input "选择 [0-7]: ")

    case "$choice" in
        1) install_nezha ;;
        2) do_backup ;;
        3) do_restore ;;
        4) enable_tsdb ;;
        5) disable_tsdb ;;
        6) do_migrate_export ;;
        7) do_migrate_import ;;
        0) print_info "退出脚本。"; exit 0 ;;
        *) print_warn "无效选项，请重新选择。" ;;
    esac

    echo ""
    if [[ -t 0 ]]; then
        local press_key
        read -r -p "按回车继续..." press_key || true
    else
        sleep 1
    fi
}

# ---------- 主流程 ----------
main() {
    parse_args "$@"

    check_root
    # import 在全新 VPS 上执行时依赖由迁移流程自行安装，跳过入口依赖检查
    if [[ "$SUBCMD" != "import" ]]; then
        check_deps
    fi
    trap 'print_error "脚本在第 $LINENO 行发生错误，退出。"; exit 1' ERR

    case "$SUBCMD" in
        install)       install_nezha; exit $? ;;
        backup)        do_backup; exit $? ;;
        restore)       do_restore; exit $? ;;
        tsdb)          enable_tsdb; exit $? ;;
        disable-tsdb)  disable_tsdb; exit $? ;;
        export)
            local rc=0
            do_migrate_export || rc=$?
            exit "$rc"
            ;;
        import)
            # 全新 VPS 上 docker/nginx 等可能缺失，依赖由迁移流程自行安装
            local rc=0
            do_migrate_import || rc=$?
            exit "$rc"
            ;;
        "")            ;;  # 进入菜单
    esac

    while true; do
        menu
    done
}

main "$@"
