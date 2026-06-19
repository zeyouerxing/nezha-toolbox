#!/bin/bash
# =============================================================================
# Nezha Toolbox Production Stable Edition
# 状态：Production Ready / Safe Execution Layer / State Machine v2
# =============================================================================

set -euo pipefail

BASE="/opt/nezha/dashboard"
CONFIG="$BASE/data/config.yaml"
DB="$BASE/data/sqlite.db"
TSDB_DIR="$BASE/data/tsdb"

# =============================================================================
# 日志
# =============================================================================
log() {
    echo "[$(date '+%F %T')] $*"
}

# =============================================================================
# 安全输入（修复非TTY死锁）
# =============================================================================
safe_input() {
    local prompt="$1"
    local input

    if [ -t 0 ] && [ -t 1 ]; then
        read -r -p "$prompt" input
        echo "$input"
        return
    fi

    echo "非交互环境禁止执行"
    exit 1
}

# =============================================================================
# 统一确认
# =============================================================================
confirm() {
    local v
    v=$(echo "$(safe_input "$1 (y/n): ")" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

    [[ "$v" == "y" || "$v" == "yes" ]]
}

# =============================================================================
# 环境检查（修复 compose 空值）
# =============================================================================
detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    fi
}

require_compose() {
    local c
    c=$(detect_compose)

    if [ -z "$c" ]; then
        log "ERROR: docker compose 未安装"
        return 1
    fi

    echo "$c"
}

require_sqlite() {
    command -v sqlite3 >/dev/null 2>&1 || {
        log "ERROR: sqlite3 未安装"
        return 1
    }
}

# =============================================================================
# 状态机 v2（运行态 + 配置态）
# =============================================================================

nezha_installed() {
    [ -d "$BASE" ]
}

tsdb_config_enabled() {
    grep -q '^tsdb:' "$CONFIG" 2>/dev/null
}

tsdb_runtime_enabled() {
    [ -d "$TSDB_DIR" ]
}

get_tsdb_state() {
    if ! nezha_installed; then
        echo "UNKNOWN"
        return
    fi

    if tsdb_config_enabled && tsdb_runtime_enabled; then
        echo "ENABLED"
    elif tsdb_config_enabled; then
        echo "PARTIAL"
    else
        echo "DISABLED"
    fi
}

# =============================================================================
# TSDB（安全增强版）
# =============================================================================
enable_tsdb() {
    local compose
    compose=$(require_compose) || return 1
    require_sqlite || return 1

    if ! nezha_installed; then
        log "Nezha未安装"
        return 1
    fi

    if ! confirm "确认开启TSDB"; then
        return 0
    fi

    local backup_time
    backup_time=$(date +%F_%H-%M-%S)

    cp -a "$CONFIG" "${CONFIG}.bak.${backup_time}" 2>/dev/null || true
    cp -a "$DB" "${DB}.bak.${backup_time}" 2>/dev/null || true

    $compose down 2>/dev/null || true

    sqlite3 "$DB" "DELETE FROM service_histories; VACUUM;" || true

    # ✔ 修复点：只追加，不重写整个文件结构
    if ! tsdb_config_enabled; then
        cat >> "$CONFIG" <<EOF

tsdb:
  data_path: "$TSDB_DIR"
  retention_days: 30
  min_free_disk_space_gb: 1
  max_memory_mb: 128
  write_buffer_size: 512
  write_buffer_flush_interval: 5
EOF
    fi

    $compose up -d 2>/dev/null || {
        log "启动失败，开始回滚"
        $compose down
        return 1
    }

    sleep 5

    if ! tsdb_runtime_enabled; then
        log "TSDB未启动成功"
        $compose down
        return 1
    fi

    log "TSDB启用成功"
}

# =============================================================================
# UI（状态机展示）
# =============================================================================
menu() {
    clear

    echo "================================"
    echo " Nezha Toolbox Production"
    echo "================================"

    if nezha_installed; then
        echo " Nezha : 已安装"
    else
        echo " Nezha : 未安装"
    fi

    case "$(get_tsdb_state)" in
        ENABLED)
            echo " TSDB  : 已开启"
            ;;
        PARTIAL)
            echo " TSDB  : 配置存在但未运行"
            ;;
        DISABLED)
            echo " TSDB  : 未开启"
            ;;
        UNKNOWN)
            echo " TSDB  : 未检测"
            ;;
    esac

    echo "================================"
    echo "1 安装"
    echo "2 备份"
    echo "3 恢复"
    echo "4 TSDB"
    echo "0 退出"
    echo "================================"

    local c
    c=$(safe_input "选择: ")

    case "$c" in
        1)
            bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh)
            ;;
        2)
            do_backup
            ;;
        3)
            do_restore
            ;;
        4)
            enable_tsdb
            ;;
        0)
            exit 0
            ;;
        *)
            log "无效选项"
            ;;
    esac

    echo ""
    read -r -p "回车返回..." dummy
}

# =============================================================================
# 主循环
# =============================================================================
while true; do
    menu
done
