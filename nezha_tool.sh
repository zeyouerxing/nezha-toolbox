#!/bin/bash
# =====================================================
# Nezha Toolbox - 生产版
# 功能：安装、备份、恢复、开启 TSDB
# 特性：严格错误处理、依赖检查、Root 权限要求
# =====================================================

set -euo pipefail

# ---------- 全局变量 ----------
BASE="/opt/nezha/dashboard"
CONFIG="$BASE/data/config.yaml"
DB="$BASE/data/sqlite.db"
BACKUP_FILE="/root/backup.tar.gz"   # 固定名称（按需求保留）

# ---------- 辅助函数 ----------

# 打印带颜色的信息
print_info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
print_warn()  { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
print_error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

# 检查是否以 root 运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限，请使用 sudo 运行。"
        exit 1
    fi
}

# 检查依赖命令是否存在
check_deps() {
    local deps=("docker" "tar" "sqlite3" "curl" "systemctl")
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "缺少以下依赖: ${missing[*]}，请安装后再试。"
        exit 1
    fi
}

# 安全输入函数（非交互环境返回空字符串，不退出）
safe_input() {
    local prompt="$1"
    local input=""
    if [[ -t 0 ]]; then
        read -r -p "$prompt" input || true
    fi
    echo "$input"
}

# 确认函数（返回 0 表示 yes，1 表示 no）
confirm() {
    local prompt="$1"
    local answer
    answer=$(safe_input "$prompt (y/n): ")
    answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    [[ "$answer" == "y" || "$answer" == "yes" ]]
}

# 检测 docker compose 命令（优先 v2）
detect_compose() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    elif docker-compose version &>/dev/null; then
        echo "docker-compose"
    else
        print_error "未找到 docker compose 或 docker-compose 命令，请确保 Docker 已安装。"
        exit 1
    fi
}

# 检查 Nezha 是否已安装（通过目录存在性）
nezha_installed() {
    [[ -d "$BASE" ]]
}

# 检查 TSDB 是否已启用（检查配置文件是否存在 tsdb: 行）
tsdb_enabled() {
    [[ -f "$CONFIG" ]] && grep -q '^tsdb:' "$CONFIG" 2>/dev/null
}

# ---------- 核心功能函数 ----------

# 安装 Nezha（不询问，直接执行）
install_nezha() {
    print_info "正在调用官方脚本安装 Nezha..."
    bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh)
    print_info "安装完成。"
}

# 备份
do_backup() {
    local compose
    compose=$(detect_compose)

    confirm "确认执行备份" || { print_info "已取消备份。"; return 0; }

    print_info "开始备份..."

    # 停止服务（允许失败）
    systemctl stop nginx 2>/dev/null || print_warn "停止 nginx 失败（可能未运行）"
    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose down 2>/dev/null || print_warn "停止容器失败（可能未运行）"
    fi

    # 执行打包（严格检查）
    print_info "正在打包数据..."
    if ! tar -czvf "$BACKUP_FILE" \
        --ignore-failed-read \
        --exclude="/opt/nezha/dashboard/data/tsdb" \
        --exclude="/opt/nezha/dashboard/data/*.log" \
        --exclude="/opt/nezha/dashboard/data/*.db-wal" \
        --exclude="/opt/nezha/dashboard/data/*.db-shm" \
        --exclude="/opt/nezha/dashboard/logs" \
        /etc/nginx /opt/nezha /root/ssl 2>&1; then
        print_error "打包失败，请检查日志。"
        exit 1
    fi

    # 重启服务（允许失败）
    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose up -d 2>/dev/null || print_warn "启动容器失败，请手动检查"
    fi
    systemctl start nginx 2>/dev/null || print_warn "启动 nginx 失败，请手动检查"

    print_info "▶ 备份完成！文件保存在: $BACKUP_FILE"
}

# 恢复
do_restore() {
    local compose
    compose=$(detect_compose)

    if [[ ! -f "$BACKUP_FILE" ]]; then
        print_error "未找到备份文件 $BACKUP_FILE"
        return 0
    fi

    confirm "确认执行恢复操作（将覆盖现有数据）" || { print_info "已取消恢复。"; return 0; }

    print_info "开始恢复..."

    # 停止服务（允许失败）
    systemctl stop nginx 2>/dev/null || print_warn "停止 nginx 失败"
    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose down 2>/dev/null || print_warn "停止容器失败"
    fi

    # 解压（严格检查）
    print_info "正在解压备份..."
    if ! tar -xzvf "$BACKUP_FILE" -C / 2>&1; then
        print_error "解压失败，请检查备份文件完整性。"
        exit 1
    fi

    # 重启服务（允许失败）
    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose up -d 2>/dev/null || print_warn "启动容器失败，请手动检查"
    fi
    systemctl start nginx 2>/dev/null || print_warn "启动 nginx 失败，请手动检查"

    print_info "▶ 恢复完成！"
}

# 开启 TSDB
enable_tsdb() {
    local compose
    compose=$(detect_compose)

    if tsdb_enabled; then
        print_info "TSDB 已经开启，无需重复操作。"
        return 0
    fi

    confirm "确认开启 TSDB？（将清理 service_histories 历史记录）" || { print_info "已取消。"; return 0; }

    print_info "正在配置 TSDB..."

    # 停止服务（允许失败）
    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose down 2>/dev/null || print_warn "停止容器失败"
    fi

    # 清理 SQLite 历史数据（仅当数据库存在）
    if [[ -f "$DB" ]]; then
        print_info "正在清理 SQLite 历史数据..."
        if ! sqlite3 "$DB" "DELETE FROM service_histories; VACUUM;" 2>&1; then
            print_error "SQLite 操作失败，请检查数据库文件。"
            exit 1
        fi
    else
        print_warn "数据库文件不存在，跳过清理。"
    fi

    # 追加 TSDB 配置（严格判断避免重复）
    if ! grep -q '^tsdb:' "$CONFIG" 2>/dev/null; then
        print_info "正在写入 TSDB 配置..."
        cat >> "$CONFIG" <<'EOF'

tsdb:
  data_path: "/opt/nezha/dashboard/data/tsdb"
  retention_days: 30
  min_free_disk_space_gb: 1
  max_memory_mb: 128
  write_buffer_size: 512
  write_buffer_flush_interval: 5
EOF
    else
        print_warn "配置中已存在 tsdb 项，但未被检测启用，可能是格式问题，请手动检查。"
    fi

    # 重启服务（允许失败）
    if [[ -d "$BASE" ]]; then
        cd "$BASE"
        $compose up -d 2>/dev/null || print_warn "启动容器失败，请手动检查"
    fi

    print_info "▶ TSDB 开启成功！"
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

    echo "================================"
    echo " 1) 安装"
    echo " 2) 备份"
    echo " 3) 恢复"
    echo " 4) TSDB"
    echo " 0) 退出"
    echo "================================"

    local choice
    choice=$(safe_input "选择 [0-4]: ")

    case "$choice" in
        1) install_nezha ;;
        2) do_backup ;;
        3) do_restore ;;
        4) enable_tsdb ;;
        0) print_info "退出脚本。"; exit 0 ;;
        *) print_warn "无效选项，请重新选择。" ;;
    esac

    echo ""
    read -r -p "按回车继续..." _ || true
}

# ---------- 主流程 ----------
main() {
    check_root
    check_deps
    # 可选：捕获错误行号（调试用）
    trap 'print_error "脚本在第 $LINENO 行发生错误，退出。"' ERR
    while true; do
        menu
    done
}

main "$@"
