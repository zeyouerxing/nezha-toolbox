#!/bin/bash
# =============================================================================
# Nezha Toolbox Enterprise Standard Layer + UI
# =============================================================================

set -euo pipefail

# =========================
# 基础路径
# =========================
BASE="/opt/nezha/dashboard"
CONFIG="$BASE/data/config.yaml"
DB="$BASE/data/sqlite.db"
TSDB_DIR="$BASE/data/tsdb"

LOG_FILE="/var/log/nezha-toolbox.log"

# =========================
# 日志
# =========================
log() {
    local msg="[$(date '+%F %T')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# =========================
# 安全输入层
# =========================
safe_input() {
    local prompt="$1"
    local input

    if [ -t 0 ]; then
        read -r -p "$prompt" input
    else
        read -r input < /dev/tty 2>/dev/null || {
            log "非交互环境，终止"
            exit 1
        }
    fi

    echo "$input"
}

# =========================
# 交互规范层（核心）
# =========================
norm_input() {
    echo "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]'
}

is_yes() {
    local v
    v=$(norm_input "$1")
    [[ "$v" == "y" || "$v" == "yes" ]]
}

is_no() {
    local v
    v=$(norm_input "$1")
    [[ "$v" == "n" || "$v" == "no" ]]
}

confirm() {
    local input
    input=$(safe_input "$1 (y/n): ")
    is_yes "$input"
}

ui_return() {
    echo "返回上级..."
    return 0
}

ui_exit() {
    echo "退出..."
    exit 0
}

ui_error() {
    echo "[ERROR] $1"
}

# =========================
# 环境检查
# =========================
require_env() {
    if [ ! -d "$BASE" ]; then
        ui_error "未检测到Nezha"
        return 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        ui_error "docker未安装"
        return 1
    fi

    return 0
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        echo "docker-compose"
    fi
}

# =========================
# TSDB检测
# =========================
detect_tsdb() {
    grep -q '^tsdb:' "$CONFIG" 2>/dev/null && return 0
    [ -d "$TSDB_DIR" ] && return 0
    return 1
}

# =========================
# TSDB回滚
# =========================
rollback_tsdb() {
    local TIME="$1"
    local CMD="$2"

    log "TSDB回滚"

    $CMD down 2>/dev/null || true

    [ -f "${CONFIG}.bak.${TIME}" ] && cp -a "${CONFIG}.bak.${TIME}" "$CONFIG"
    [ -f "${DB}.bak.${TIME}" ] && cp -a "${DB}.bak.${TIME}" "$DB"

    rm -rf "$TSDB_DIR" 2>/dev/null || true

    $CMD up -d 2>/dev/null || true

    log "回滚完成"
}

# =========================
# TSDB开启
# =========================
enable_tsdb() {
    require_env || return 1

    local CMD
    CMD=$(detect_compose)

    if detect_tsdb; then
        log "TSDB已开启"
        return 0
    fi

    if ! confirm "确认开启TSDB"; then
        return 0
    fi

    local TIME
    TIME=$(date +%F_%H-%M-%S)

    cp -a "$CONFIG" "${CONFIG}.bak.${TIME}" 2>/dev/null || true
    cp -a "$DB" "${DB}.bak.${TIME}" 2>/dev/null || true

    $CMD down 2>/dev/null || true

    sqlite3 "$DB" "DELETE FROM service_histories; VACUUM;" 2>/dev/null || true

    {
        grep -v '^tsdb:' "$CONFIG" 2>/dev/null || true
        echo ""
        echo "tsdb:"
        echo "  data_path: \"$TSDB_DIR\""
        echo "  retention_days: 30"
        echo "  min_free_disk_space_gb: 1"
        echo "  max_memory_mb: 128"
        echo "  write_buffer_size: 512"
        echo "  write_buffer_flush_interval: 5"
    } > "$CONFIG.tmp"

    mv "$CONFIG.tmp" "$CONFIG"

    $CMD up -d 2>/dev/null || true

    sleep 10

    if [ ! -d "$TSDB_DIR" ]; then
        rollback_tsdb "$TIME" "$CMD"
        return 1
    fi

    if ! $CMD ps 2>/dev/null | grep -q "Up"; then
        rollback_tsdb "$TIME" "$CMD"
        return 1
    fi

    log "TSDB成功"
}

# =========================
# 备份（原逻辑+UI封装）
# =========================
do_backup() {
    require_env || return 1

    if ! confirm "执行备份"; then
        return 0
    fi

    local CMD
    CMD=$(detect_compose)

    systemctl stop nginx 2>/dev/null || true
    cd "$BASE" && $CMD down 2>/dev/null || true

    tar -czvf "/root/backup.tar.gz" \
        --ignore-failed-read \
        --exclude="/opt/nezha/dashboard/data/tsdb" \
        --exclude="/opt/nezha/dashboard/data/*.log" \
        --exclude="/opt/nezha/dashboard/data/*.db-wal" \
        --exclude="/opt/nezha/dashboard/data/*.db-shm" \
        --exclude="/opt/nezha/dashboard/logs" \
        /etc/nginx /opt/nezha /root/ssl 2>/dev/null || true

    cd "$BASE" && $CMD up -d 2>/dev/null || true
    systemctl start nginx 2>/dev/null || true

    log "备份完成"
}

# =========================
# 恢复（原逻辑+UI封装）
# =========================
do_restore() {
    require_env || return 1

    if [ ! -f "/root/backup.tar.gz" ]; then
        ui_error "备份不存在"
        return 1
    fi

    if ! confirm "确认恢复"; then
        return 0
    fi

    local CMD
    CMD=$(detect_compose)

    systemctl stop nginx 2>/dev/null || true
    cd "$BASE" && $CMD down 2>/dev/null || true

    tar -xzvf "/root/backup.tar.gz" -C / 2>/dev/null || true

    cd "$BASE" && $CMD up -d 2>/dev/null || true
    systemctl start nginx 2>/dev/null || true

    log "恢复完成"
}

# =========================
# UI菜单（统一规范）
# =========================
menu() {
    clear
    echo "=========================="
    echo " Nezha Toolbox Enterprise"
    echo "=========================="
    echo "1 安装"
    echo "2 备份"
    echo "3 恢复"
    echo "4 TSDB"
    echo "0 退出"
    echo "=========================="

    local c
    c=$(safe_input "选择: ")

    case "$c" in
        1) bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh) ;;
        2) do_backup ;;
        3) do_restore ;;
        4) enable_tsdb ;;
        0) ui_exit ;;
        *) ui_error "无效选项" ;;
    esac

    echo ""
    read -r -p "回车返回菜单..." dummy
}

# =========================
# 主循环
# =========================
while true; do
    menu
done
