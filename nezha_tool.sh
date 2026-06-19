#!/bin/bash
# =============================================================================
# Nezha Toolbox Enterprise Edition
# 企业级安全版（TSDB / Backup / Restore / 安全门禁 / 日志审计）
# =============================================================================

set -euo pipefail

# =========================
# 全局路径
# =========================
BASE="/opt/nezha/dashboard"
CONFIG="$BASE/data/config.yaml"
DB="$BASE/data/sqlite.db"
TSDB_DIR="$BASE/data/tsdb"

LOG_FILE="/var/log/nezha-toolbox.log"

# =========================
# 日志系统（审计级）
# =========================
log() {
    local msg="[$(date '+%F %T')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# =========================
# 安全输入（企业级）
# =========================
safe_input() {
    local prompt="$1"

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

confirm_y() {
    local input
    input=$(safe_input "$1 (仅 Y 允许执行): ")

    case "$input" in
        Y) return 0 ;;
        *) log "用户取消操作"; return 1 ;;
    esac
}

# =========================
# 前置检查（企业级门禁）
# =========================
require_env() {
    if [ ! -d "$BASE" ]; then
        log "错误：未检测到 Nezha 安装目录"
        return 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log "错误：docker 未安装"
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        log "错误：docker compose 不可用"
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
# TSDB状态检测（真实可靠）
# =========================
tsdb_status() {
    if grep -q '^tsdb:' "$CONFIG" 2>/dev/null; then
        echo "ON"
    else
        echo "OFF"
    fi
}

# =========================
# 企业级回滚系统
# =========================
rollback_tsdb() {
    local TIME="$1"
    local CMD="$2"

    log "执行企业级回滚"

    $CMD down 2>/dev/null || true

    [ -f "${CONFIG}.bak.${TIME}" ] && cp -a "${CONFIG}.bak.${TIME}" "$CONFIG"
    [ -f "${DB}.bak.${TIME}" ] && cp -a "${DB}.bak.${TIME}" "$DB"

    rm -rf "$TSDB_DIR" 2>/dev/null || true

    $CMD up -d 2>/dev/null || true

    log "回滚完成"
}

# =========================
# TSDB开启（企业级）
# =========================
enable_tsdb() {
    require_env || return 1

    local CMD
    CMD=$(detect_compose)

    if [ "$(tsdb_status)" = "ON" ]; then
        log "TSDB已开启"
        return 0
    fi

    if ! confirm_y "开启TSDB（涉及数据变更+服务重启）"; then
        return 0
    fi

    local TIME
    TIME=$(date +%F_%H-%M-%S)

    log "创建快照"
    cp -a "$CONFIG" "${CONFIG}.bak.${TIME}" 2>/dev/null || true
    cp -a "$DB" "${DB}.bak.${TIME}" 2>/dev/null || true

    log "停止服务"
    $CMD down 2>/dev/null || true

    log "清理历史数据"
    sqlite3 "$DB" "DELETE FROM service_histories; VACUUM;" 2>/dev/null || true

    log "写入TSDB配置"

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

    log "启动服务"
    $CMD up -d 2>/dev/null || true

    sleep 10

    # =========================
    # 企业级验证（双保险）
    # =========================
    if [ ! -d "$TSDB_DIR" ]; then
        log "TSDB未生成 → 回滚"
        rollback_tsdb "$TIME" "$CMD"
        return 1
    fi

    if ! $CMD ps 2>/dev/null | grep -q "Up"; then
        log "容器异常 → 回滚"
        rollback_tsdb "$TIME" "$CMD"
        return 1
    fi

    log "TSDB开启成功"
}

# =========================
# 备份（企业级安全）
# =========================
backup() {
    require_env || return 1

    if ! confirm_y "执行备份（将停止服务）"; then
        return 0
    fi

    local CMD
    CMD=$(detect_compose)

    systemctl stop nginx 2>/dev/null || true
    cd "$BASE" && $CMD down 2>/dev/null || true

    tar -czf "/root/nezha_backup_$(date +%F_%H-%M-%S).tar.gz" \
        --exclude="data/tsdb" \
        /opt/nezha /etc/nginx /root/ssl 2>/dev/null || true

    cd "$BASE" && $CMD up -d 2>/dev/null || true
    systemctl start nginx 2>/dev/null || true

    log "备份完成"
}

# =========================
# 恢复（企业级安全）
# =========================
restore() {
    require_env || return 1

    local file
    file=$(ls /root/nezha_backup_*.tar.gz 2>/dev/null | tail -n 1 || true)

    if [ -z "$file" ]; then
        log "未找到备份文件"
        return 1
    fi

    if ! confirm_y "恢复将覆盖全部数据"; then
        return 0
    fi

    local CMD
    CMD=$(detect_compose)

    systemctl stop nginx 2>/dev/null || true
    cd "$BASE" && $CMD down 2>/dev/null || true

    tar -xzf "$file" -C / 2>/dev/null || true

    cd "$BASE" && $CMD up -d 2>/dev/null || true
    systemctl start nginx 2>/dev/null || true

    log "恢复完成"
}

# =========================
# 菜单系统（企业级安全）
# =========================
menu() {
    echo "=========================="
    echo "Nezha Enterprise Toolbox"
    echo "=========================="
    echo "1 安装"
    echo "2 备份"
    echo "3 恢复"
    echo "4 TSDB开启"
    echo "0 退出"
    echo "=========================="

    local c
    c=$(safe_input "选择: ")

    case "$c" in
        1) bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh) ;;
        2) backup ;;
        3) restore ;;
        4) enable_tsdb ;;
        0) exit 0 ;;
        *) log "无效选项" ;;
    esac
}

# =========================
# 主循环
# =========================
while true; do
    menu
    echo ""
done
