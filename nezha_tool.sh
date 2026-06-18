#!/bin/bash
# =============================================================================
# 哪吒面板管理工具箱
# 功能：安装、备份/恢复、开启 TSDB
# 支持 curl ... | bash 一键执行
# 仓库：https://github.com/zeyouerxing/nezha-toolbox
# =============================================================================

set -euo pipefail

# ---------- 兼容管道执行（curl | bash） ----------
if [ ! -t 0 ]; then
    exec < /dev/tty
fi

# ---------- 全局日志函数 ----------
log() { echo "[$(date '+%F %T')] $*"; }

# ---------- 检测 docker compose 命令 ----------
detect_compose_cmd() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# ---------- 安装官方哪吒面板 ----------
install_nezha() {
    log "开始执行官方安装脚本..."
    curl -L https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh -o /tmp/nezha.sh
    chmod +x /tmp/nezha.sh
    sudo /tmp/nezha.sh
    log "安装脚本执行完毕（可能已退出）"
}

# ---------- 备份 ----------
do_backup() {
    local BACKUP="/root/backup.tar.gz"
    local DB="/opt/nezha/dashboard/data/sqlite.db"
    local COMPOSE_CMD
    COMPOSE_CMD=$(detect_compose_cmd)
    if [ -z "$COMPOSE_CMD" ]; then
        log "错误：未找到 docker compose 或 docker-compose 命令，无法操作服务。"
        return 1
    fi

    log "1. 停止服务"
    systemctl stop nginx 2>/dev/null || true
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        $COMPOSE_CMD down || true
    fi

    log "2. SQLite 安全处理（兼容 TSDB）"
    if [ -f "$DB" ]; then
        sqlite3 "$DB" "PRAGMA wal_checkpoint(FULL);" || true
        TABLE_CHECK=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='service_histories';" 2>/dev/null | grep "service_histories" || true)
        if [ -n "$TABLE_CHECK" ]; then
            log "清空 service_histories"
            sqlite3 "$DB" "DELETE FROM service_histories;" || true
            sqlite3 "$DB" "VACUUM;" || true
        else
            log "service_histories 不存在，跳过清理（TSDB 模式正常）"
        fi
    fi

    log "3. 创建备份（忽略缺失目录）"
    tar -czvf "$BACKUP" \
        --ignore-failed-read \
        --exclude="/opt/nezha/dashboard/data/tsdb" \
        --exclude="/opt/nezha/dashboard/data/*.log" \
        --exclude="/opt/nezha/dashboard/data/*.db-wal" \
        --exclude="/opt/nezha/dashboard/data/*.db-shm" \
        --exclude="/opt/nezha/dashboard/logs" \
        --exclude="/opt/nezha/*.log" \
        /etc/nginx \
        /opt/nezha \
        /root/ssl 2>/dev/null || true

    log "4. 启动服务"
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        $COMPOSE_CMD up -d || true
    fi
    systemctl start nginx 2>/dev/null || true

    log "5. 检查容器状态"
    sleep 5
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        if $COMPOSE_CMD ps --status running | grep -q "Up"; then
            log "容器运行正常"
        else
            log "容器未完全启动，请检查 $COMPOSE_CMD logs"
        fi
    else
        log "哪吒面板目录不存在，跳过容器检查"
    fi

    log "完成备份: $BACKUP"
    cd /root
}

# ---------- 恢复 ----------
do_restore() {
    local BACKUP="/root/backup.tar.gz"
    local COMPOSE_CMD
    COMPOSE_CMD=$(detect_compose_cmd)
    if [ -z "$COMPOSE_CMD" ]; then
        log "错误：未找到 docker compose 或 docker-compose 命令，无法操作服务。"
        return 1
    fi

    if [ ! -f "$BACKUP" ]; then
        log "错误：备份文件 $BACKUP 不存在，无法恢复。"
        return 1
    fi

    log "警告：恢复操作将覆盖当前 /etc/nginx、/opt/nezha 和 /root/ssl 目录，且会停止服务。"
    read -p "确认继续？(输入 y 确认，其他取消): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "恢复已取消。"
        return 0
    fi

    log "1. 停止服务"
    systemctl stop nginx 2>/dev/null || true
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        $COMPOSE_CMD down || true
    fi

    log "2. 恢复文件（覆盖方式）"
    cd /
    tar -xzvf "$BACKUP" -C / 2>/dev/null || true

    log "3. 启动服务"
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        $COMPOSE_CMD up -d || true
    fi
    systemctl start nginx 2>/dev/null || true

    log "4. 检查容器状态"
    sleep 5
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        if $COMPOSE_CMD ps --status running | grep -q "Up"; then
            log "容器恢复后运行正常"
        else
            log "容器未完全启动，请检查 $COMPOSE_CMD logs"
        fi
    else
        log "哪吒面板目录不存在，跳过容器检查"
    fi

    log "恢复完成（从 $BACKUP）"
    cd /root
}

# ---------- 备份与恢复子菜单 ----------
backup_restore_menu() {
    echo "--------------------------"
    echo "  备份与恢复子菜单"
    echo "--------------------------"
    echo "1. 执行备份（含清空历史）"
    echo "2. 从备份恢复（覆盖数据）"
    echo "3. 返回主菜单"
    echo "--------------------------"
    read -p "请选择 [1-3]: " sub_choice
    case $sub_choice in
        1) do_backup ;;
        2) do_restore ;;
        3) return 0 ;;
        *) echo "无效选项，返回主菜单。" ;;
    esac
}

# ---------- 开启 TSDB（安全模式：仅检测 + 手动指引）----------
enable_tsdb() {
    local DASHBOARD_DIR="/opt/nezha/dashboard"
    local COMPOSE_FILE="$DASHBOARD_DIR/docker-compose.yml"
    local CONFIG_FILE="$DASHBOARD_DIR/data/config.yaml"

    if [ ! -d "$DASHBOARD_DIR" ]; then
        log "错误：哪吒面板目录 $DASHBOARD_DIR 不存在，请先安装。"
        return 1
    fi

    # ----- 检测是否已开启 -----
    local tsdb_enabled=false

    # 1) 检查 config.yaml
    if [ -f "$CONFIG_FILE" ] && grep -qE '^\s*tsdb\s*:\s*true' "$CONFIG_FILE"; then
        tsdb_enabled=true
        log "检测到 config.yaml 中 tsdb: true，TSDB 已开启。"
    fi

    # 2) 检查运行容器环境变量（通过 docker inspect）
    if [ "$tsdb_enabled" = false ] && command -v docker &>/dev/null; then
        # 查找可能的容器名或镜像名
        local containers
        containers=$(docker ps --format '{{.Names}}' | grep -i nezha || true)
        if [ -z "$containers" ]; then
            containers=$(docker ps --filter "ancestor=ghcr.io/nezhahq/nezha-dashboard" --format '{{.Names}}' || true)
        fi
        for c in $containers; do
            if docker inspect "$c" | grep -q 'TSDB=true'; then
                tsdb_enabled=true
                log "检测到容器 $c 环境变量 TSDB=true，TSDB 已开启。"
                break
            fi
        done
    fi

    if [ "$tsdb_enabled" = true ]; then
        log "TSDB 已开启，无需重复操作。"
        return 0
    fi

    # ----- 未开启，给出操作指引 -----
    log "当前 TSDB 未开启。"
    log "请手动编辑 $COMPOSE_FILE，在 dashboard 服务的 environment 部分添加："
    echo "  environment:"
    echo "    - TSDB=true"
    log "然后执行以下命令："
    local COMPOSE_CMD
    COMPOSE_CMD=$(detect_compose_cmd)
    if [ -n "$COMPOSE_CMD" ]; then
        echo "  cd $DASHBOARD_DIR && $COMPOSE_CMD down && $COMPOSE_CMD up -d"
    else
        echo "  cd $DASHBOARD_DIR && docker compose down && docker compose up -d"
    fi
    log "完成后可再次运行本选项以验证是否生效。"
    return 1
}

# ---------- 主菜单 ----------
show_menu() {
    echo "=========================="
    echo "   哪吒面板管理菜单"
    echo "=========================="
    echo "1. 安装官方哪吒面板"
    echo "2. 备份与恢复（子菜单）"
    echo "3. 开启 TSDB（检测是否已开启）"
    echo "0. 退出"
    echo "=========================="
    read -p "请输入选项 [0-3]: " choice
    case $choice in
        1) install_nezha ;;
        2) backup_restore_menu ;;
        3) enable_tsdb ;;
        0) log "退出脚本。"; exit 0 ;;
        *) echo "无效选项，请重新输入。" ;;
    esac
}

# ---------- 主循环 ----------
while true; do
    show_menu
    echo ""
done
