#!/bin/bash
# =============================================================================
# 哪吒面板工具箱（生产版融合TSDB + 回滚 + 安全执行）
# =============================================================================

set -euo pipefail

# =========================
# 兼容 curl | bash
# =========================
exec 0</dev/tty 2>/dev/null || true
INPUT_FD="/dev/stdin"

log() {
    echo "[$(date '+%F %T')] $*"
}

# =========================
# 强制确认（仅 Y）
# =========================
confirm_y() {
    local prompt="$1"
    local input

    read -r -p "$prompt (仅 Y 继续): " input < "$INPUT_FD" || true

    case "$input" in
        Y) return 0 ;;
        *) echo "已取消"; return 1 ;;
    esac
}

# =========================
# docker compose 兼容
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
# TSDB检测（Nezha v1真实逻辑）
# =========================
detect_tsdb() {
    local CONFIG="/opt/nezha/dashboard/data/config.yaml"
    local TSDB_DIR="/opt/nezha/dashboard/data/tsdb"

    if [ -f "$CONFIG" ] && grep -q '^tsdb:' "$CONFIG"; then
        return 0
    fi

    if [ -d "$TSDB_DIR" ]; then
        return 0
    fi

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

    log "执行回滚..."

    $CMD down 2>/dev/null || true

    [ -f "${CONFIG}.bak.${TIME}" ] && cp -a "${CONFIG}.bak.${TIME}" "$CONFIG"
    [ -f "${DB}.bak.${TIME}" ] && cp -a "${DB}.bak.${TIME}" "$DB"

    rm -rf "$DIR/data/tsdb" 2>/dev/null || true

    $CMD up -d 2>/dev/null || true

    sleep 5

    if $CMD ps 2>/dev/null | grep -q "Up"; then
        log "回滚成功"
    else
        log "回滚后服务异常，请手动检查"
    fi
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

    if ! confirm_y "开启TSDB（将修改数据并重启服务）"; then
        return 0
    fi

    cd "$DIR"

    log "创建快照"
    cp -a "$CONFIG" "${CONFIG}.bak.${TIME}" 2>/dev/null || true
    cp -a "$DB" "${DB}.bak.${TIME}" 2>/dev/null || true

    log "停止服务"
    $CMD down 2>/dev/null || true

    log "清理历史数据"
    sqlite3 "$DB" "DELETE FROM service_histories; VACUUM;" 2>/dev/null || true

    log "写入TSDB配置"

    if grep -q '^tsdb:' "$CONFIG"; then
        awk '
        BEGIN{skip=0}
        /^tsdb:/ {skip=1; next}
        /^[^[:space:]]/ && skip==1 {skip=0}
        skip==0 {print}
        END {
            print "tsdb:"
            print "  data_path: \"/opt/nezha/dashboard/data/tsdb\""
            print "  retention_days: 30"
            print "  min_free_disk_space_gb: 1"
            print "  max_memory_mb: 128"
            print "  write_buffer_size: 512"
            print "  write_buffer_flush_interval: 5"
        }' "$CONFIG" > "$CONFIG.tmp"
    else
        {
            cat "$CONFIG"
            echo ""
            echo "tsdb:"
            echo "  data_path: \"/opt/nezha/dashboard/data/tsdb\""
            echo "  retention_days: 30"
            echo "  min_free_disk_space_gb: 1"
            echo "  max_memory_mb: 128"
            echo "  write_buffer_size: 512"
            echo "  write_buffer_flush_interval: 5"
        } > "$CONFIG.tmp"
    fi

    mv "$CONFIG.tmp" "$CONFIG"

    log "启动服务"
    $CMD up -d 2>/dev/null || true

    sleep 10

    log "验证TSDB"

    if [ ! -d "$TSDB_DIR" ]; then
        log "TSDB未生成 → 回滚"
        rollback_tsdb "$CONFIG" "$DB" "$TIME" "$DIR" "$CMD"
        return 1
    fi

    if ! $CMD ps 2>/dev/null | grep -q "Up"; then
        log "容器异常 → 回滚"
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
        --ignore-failed-read \
        --exclude="data/tsdb" \
        /etc/nginx /opt/nezha /root/ssl 2>/dev/null || true

    [ -d /opt/nezha/dashboard ] && cd /opt/nezha/dashboard && $CMD up -d || true
    systemctl start nginx 2>/dev/null || true

    log "备份完成: $BACKUP"
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
# 菜单
# =========================
menu() {
    echo "=================="
    echo "Nezha 工具箱"
    echo "=================="
    echo "1 安装"
    echo "2 备份"
    echo "3 恢复"
    echo "4 开启TSDB"
    echo "0 退出"

    read -r -p "选择: " c < "$INPUT_FD" || true

    case "$c" in
        1) bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh) ;;
        2) do_backup ;;
        3) do_restore ;;
        4) enable_tsdb ;;
        0) exit 0 ;;
    esac
}

while true; do
    menu
    echo
done
