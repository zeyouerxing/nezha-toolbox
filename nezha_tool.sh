#!/bin/bash
# =====================================================
# Nezha Toolbox - 生产版（全量修复 + 关闭TSDB + 备份清理）
# 功能：安装、备份、恢复、开启/关闭 TSDB、备份保留策略
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
# 备份保留最近 N 份（不含 pre-restore 快照），设为 0 表示不自动清理
KEEP_BACKUPS=5

YES_MODE=0
SUBCMD=""   # install | backup | restore | tsdb | disable-tsdb

# ---------- 参数解析 ----------
parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --yes|-y)
                YES_MODE=1
                ;;
            install|backup|restore|tsdb|disable-tsdb)
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

无子命令时进入交互菜单。
环境变量 NEZHA_TOOLBOX_YES=1 等同于 --yes。
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
    local files
    # 按时间倒序，跳过前 KEEP_BACKUPS 个，删除其余
    mapfile -t files < <(ls -1t "${BACKUP_DIR}/${BACKUP_PREFIX}"-*.tar.gz 2>/dev/null || true)
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
        root/ssl 2>/dev/null; then
        print_error "打包失败。"
        if [[ -d "$BASE" ]]; then
            cd "$BASE" && $compose up -d 2>/dev/null || true
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
    echo " 0) 退出"
    echo "================================"

    local choice
    choice=$(safe_input "选择 [0-5]: ")

    case "$choice" in
        1) install_nezha ;;
        2) do_backup ;;
        3) do_restore ;;
        4) enable_tsdb ;;
        5) disable_tsdb ;;
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
    check_deps
    trap 'print_error "脚本在第 $LINENO 行发生错误，退出。"; exit 1' ERR

    case "$SUBCMD" in
        install)       install_nezha; exit $? ;;
        backup)        do_backup; exit $? ;;
        restore)       do_restore; exit $? ;;
        tsdb)          enable_tsdb; exit $? ;;
        disable-tsdb)  disable_tsdb; exit $? ;;
        "")            ;;  # 进入菜单
    esac

    while true; do
        menu
    done
}

main "$@"
