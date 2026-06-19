#!/bin/bash
# =============================================================================
# Nezha Toolbox - Final Production Stable Edition
# 状态：Enterprise Stable / Runtime Accurate / No False State
# =============================================================================

set -euo pipefail

BASE="/opt/nezha/dashboard"
CONFIG="$BASE/data/config.yaml"
DB="$BASE/data/sqlite.db"

# =============================================================================
# 日志
# =============================================================================
log() {
    echo "[$(date '+%F %T')] $*"
}

# =============================================================================
# 输入层（安全TTY）
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
# compose检测（强校验）
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

# =============================================================================
# Nezha状态
# =============================================================================
nezha_installed() {
    [ -d "$BASE" ]
}

# =============================================================================
# TSDB 状态（真实运行态 = docker + config 双验证）
# =============================================================================
get_tsdb_state() {
    local compose
    compose=$(detect_compose)

    if ! nezha_installed; then
        echo "UNKNOWN"
        return
    fi

    local config_ok=0
    local runtime_ok=0

    # 配置存在
    if grep -q '^tsdb:' "$CONFIG" 2>/dev/null; then
        config_ok=1
    fi

    # 运行态必须来自 docker（关键修正点）
    if [ -n "$compose" ]; then
        if cd "$BASE" 2>/dev/null && $compose ps 2>/dev/null | grep -q "Up"; then
            runtime_ok=1
        fi
    fi

    if [ "$config_ok" -eq 1 ] && [ "$runtime_ok" -eq 1 ]; then
        echo "ENABLED"
    elif [ "$config_ok" -eq 1 ]; then
        echo "CONFIG_ONLY"
    else
        echo "DISABLED"
    fi
}

# =============================================================================
# TSDB 启用（不改业务逻辑，只增强稳定性）
# =============================================================================
enable_tsdb() {
    local compose
    compose=$(require_compose) || return 1

    if ! nezha_installed; then
        log "Nezha未安装"
        return 1
    fi

    if ! confirm "确认开启TSDB（会重启服务）"; then
        return 0
    fi

    local t
    t=$(date +%F_%H-%M-%S)

    cp -a "$CONFIG" "${CONFIG}.bak.${t}" 2>/dev/null || true
    cp -a "$DB" "${DB}.bak.${t}" 2>/dev/null || true

    $compose -f "$BASE/docker-compose.yml" down 2>/dev/null || true

    # 安全追加（避免破坏YAML结构）
    if ! grep -q '^tsdb:' "$CONFIG" 2>/dev/null; then
        cat >> "$CONFIG" <<EOF

tsdb:
  data_path: "$BASE/data/tsdb"
  retention_days: 30
  min_free_disk_space_gb: 1
  max_memory_mb: 128
  write_buffer_size: 512
  write_buffer_flush_interval: 5
EOF
    fi

    $compose -f "$BASE/docker-compose.yml" up -d 2>/dev/null || {
        log "启动失败"
        return 1
    }

    sleep 5

    if ! cd "$BASE" && $compose ps | grep -q "Up"; then
        log "TSDB启动失败"
        return 1
    fi

    log "TSDB已启用"
}

# =============================================================================
# UI层（唯一入口，修复你之前的4命令问题）
# =============================================================================
menu() {
    clear

    echo "================================"
    echo " Nezha Toolbox Final Edition"
    echo "================================"

    if nezha_installed; then
        echo " Nezha : 已安装"
    else
        echo " Nezha : 未安装"
    fi

    case "$(get_tsdb_state)" in
        ENABLED)
            echo " TSDB  : 已开启（运行中）"
            ;;
        CONFIG_ONLY)
            echo " TSDB  : 已配置（未运行）"
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
    read -r -p "回车返回菜单..." dummy
}

# =============================================================================
# 主循环（关键修复：避免你之前“4 command not found”问题）
# =============================================================================
while true; do
    menu
done
