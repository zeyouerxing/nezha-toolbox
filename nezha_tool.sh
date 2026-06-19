#!/bin/bash
# =============================================================================
# Nezha Toolbox（稳定交互终极版）
# - 无 tty 崩溃
# - curl | bash 兼容
# - menu 不阻塞
# =============================================================================

set -euo pipefail

log() {
    echo "[$(date '+%F %T')] $*"
}

# =========================
# 输入统一处理（终极版）
# =========================
safe_read() {
    local prompt="$1"
    local var

    # 优先使用 tty，否则使用 stdin
    if [ -t 0 ]; then
        read -r -p "$prompt" var
    else
        read -r -p "$prompt" var < /dev/tty 2>/dev/null || {
            echo "非交互环境，无法输入"
            exit 1
        }
    fi

    echo "$var"
}

# =========================
# 强制确认（仅 Y）
# =========================
confirm_y() {
    local input
    input=$(safe_read "$1 (仅 Y 继续): ")

    case "$input" in
        Y) return 0 ;;
        *) echo "已取消"; return 1 ;;
    esac
}

# =========================
# docker compose
# =========================
detect_compose_cmd() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# =========================
# TSDB检测（稳定版）
# =========================
detect_tsdb() {
    local CONFIG="/opt/nezha/dashboard/data/config.yaml"
    local TSDB_DIR="/opt/nezha/dashboard/data/tsdb"

    grep -q '^tsdb:' "$CONFIG" 2>/dev/null && return 0
    [ -d "$TSDB_DIR" ] && return 0

    return 1
}

# =========================
# TSDB回滚
# =========================
rollback_tsdb() {
    local CONFIG="$1"
    local DB="$2"
    local TIME="$3"
    local DIR="$4"
    local CMD="$5"

    log "回滚TSDB..."

    $CMD down 2>/dev/null || true

    [ -f "${CONFIG}.bak.${TIME}" ] && cp -a "${CONFIG}.bak.${TIME}" "$CONFIG"
    [ -f "${DB}.bak.${TIME}" ] && cp -a "${DB}.bak.${TIME}" "$DB"

    rm -rf "$DIR/data/tsdb" 2>/dev/null || true

    $CMD up -d 2>/dev/null || true

    log "回滚完成"
}

# =========================
# TSDB开启（生产稳定版）
# =========================
enable_tsdb() {
    local DIR="/opt/nezha/dashboard"
    local CONFIG="$DIR/data/config.yaml"
    local DB="$DIR/data/sqlite.db"
    local TSDB_DIR="$DIR/data/tsdb"
    local TIME
    TIME=$(date +%F_%H-%M-%S)

    local CMD
    CMD=$(detect_compose_cmd)

    if [ ! -d "$DIR" ] || [ -z "$CMD" ]; then
        log "环境异常"
        return 1
    fi

    if detect_tsdb; then
        log "TSDB已开启"
        return 0
    fi

    if ! confirm_y "开启TSDB（会修改数据并重启服务）"; then
        return 0
    fi

    cd "$DIR"

    log "备份配置"
    cp -a "$CONFIG" "${CONFIG}.bak.${TIME}" 2>/dev/null || true
    cp -a "$DB" "${DB}.bak.${TIME}" 2>/dev/null || true

    log "停止服务"
    $CMD down 2>/dev/null || true

    log "清理历史"
    sqlite3 "$DB" "DELETE FROM service_histories; VACUUM;" 2>/dev/null || true

    log "写入TSDB配置"

    {
        grep -v '^tsdb:' "$CONFIG" 2>/dev/null || true
        echo ""
        echo "tsdb:"
        echo "  data_path: \"/opt/nezha/dashboard/data/tsdb\""
        echo "  retention_days: 30"
        echo "  min_free_disk_space_gb: 1"
        echo "  max_memory_mb: 128"
        echo "  write_buffer_size: 512"
        echo "  write_buffer_flush_interval: 5"
    } > "$CONFIG.tmp"

    mv "$CONFIG.tmp" "$CONFIG"

    log "启动服务"
    $CMD up -d 2>/dev/null || true

    sleep 10

    log "验证"

    if [ ! -d "$TSDB_DIR" ]; then
        log "失败：TSDB未生成"
        rollback_tsdb "$CONFIG" "$DB" "$TIME" "$DIR" "$CMD"
        return 1
    fi

    if ! $CMD ps 2>/dev/null | grep -q "Up"; then
        log "失败：服务异常"
        rollback_tsdb "$CONFIG" "$DB" "$TIME" "$DIR" "$CMD"
        return 1
    fi

    log "TSDB开启成功"
}

# =========================
# 备份
# =========================
do_backup() {
    local BACKUP="/root/backup.tar.gz"
    local CMD
    CMD=$(detect_compose_cmd)

    systemctl stop nginx 2>/dev/null || true
    [ -d /opt/nezha/dashboard ] && cd /opt/nezha/dashboard && $CMD down || true

    tar -czf "$BACKUP" \
        --exclude="data/tsdb" \
        /opt/nezha /etc/nginx /root/ssl 2>/dev/null || true

    [ -d /opt/nezha/dashboard ] && cd /opt/nezha/dashboard && $CMD up -d || true
    systemctl start nginx 2>/dev/null || true

    log "备份完成"
}

# =========================
# 恢复
# =========================
do_restore() {
    local BACKUP="/root/backup.tar.gz"
    local CMD
    CMD=$(detect_compose_cmd)

    [ -f "$BACKUP" ] || return 1

    if ! confirm_y "恢复将覆盖数据"; then
        return 0
    fi

    systemctl stop nginx 2>/dev/null || true
    [ -d /opt/nezha/dashboard ] && cd /opt/nezha/dashboard && $CMD down || true

    tar -xzf "$BACKUP" -C / 2>/dev/null || true

    [ -d /opt/nezha/dashboard ] && cd /opt/nezha/dashboard && $CMD up -d || true
    systemctl start nginx 2>/dev/null || true

    log "恢复完成"
}

# =========================
# 菜单（终极稳定版）
# =========================
menu() {
    echo "===================="
    echo "Nezha Toolbox"
    echo "===================="
    echo "1 安装"
    echo "2 备份"
    echo "3 恢复"
    echo "4 开启TSDB"
    echo "0 退出"

    local c
    c=$(safe_read "选择: ")

    case "$c" in
        1) bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh) ;;
        2) do_backup ;;
        3) do_restore ;;
        4) enable_tsdb ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

# =========================
# 主循环
# =========================
while true; do
    menu
    echo ""
done
