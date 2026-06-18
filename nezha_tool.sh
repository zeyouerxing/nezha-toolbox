#!/bin/bash

set -euo pipefail

BACKUP="/root/backup.tar.gz"
DB="/opt/nezha/dashboard/data/sqlite.db"
NEZHA_DIR="/opt/nezha"
CONFIG_FILE="/opt/nezha/dashboard/data/config.yaml"
DATE=$(date +%F)
SNAP="/root/before_restore_${DATE}.tar.gz"

log() { echo "[$(date '+%F %T')] $*"; }

# ==================== 基础函数 ====================
safe_read() {
    local prompt="$1"
    local default="${2:-}"
    local var
    read -r -p "$prompt" var
    var="${var:-$default}"
    echo "$var"
}

safe_exit() {
    cd /root 2>/dev/null || true
    log "脚本已退出。"
    exit 0
}

confirm_action() {
    local prompt_msg="$1"
    local choice
    choice=$(safe_read "$prompt_msg [Y/n]: " "Y")
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        log "操作已取消。"
        return 1
    fi
    return 0
}

# ==================== 功能 1：官方脚本（最简单方式） ====================
run_official_script() {
    log "正在下载哪吒面板官方安装脚本..."
    
    curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh -o /tmp/nezha.sh
    chmod +x /tmp/nezha.sh

    echo "──────────────────────────────────────────"
    echo "即将运行官方哪吒安装脚本..."
    echo "如果出现无法输入的情况，请按几次回车，或直接复制下面命令单独运行："
    echo "bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh)"
    echo "──────────────────────────────────────────"

    # 最简单直接的方式
    /tmp/nezha.sh
}

# ==================== 功能 2：备份 ====================
run_backup() {
    if [ ! -d "$NEZHA_DIR" ]; then
        log "错误: 未检测到哪吒面板安装目录，无法备份。"
        return 1
    fi

    echo "------------------------------------------"
    echo " 请选择备份类型:"
    echo " 1. 精简备份 (推荐)"
    echo " 2. 全量备份"
    echo "------------------------------------------"

    local backup_type=$(safe_read "请输入选择 [1-2, 默认 1]: " "1")

    local type_desc="精简备份"
    local exclude_args=(--exclude="opt/nezha/dashboard/data/tsdb" --exclude="opt/nezha/dashboard/data/*.log" --exclude="opt/nezha/dashboard/data/*.db-wal" --exclude="opt/nezha/dashboard/data/*.db-shm" --exclude="opt/nezha/dashboard/logs" --exclude="opt/nezha/*.log")

    if [ "$backup_type" = "2" ]; then
        type_desc="全量备份"
        exclude_args=(--exclude="opt/nezha/dashboard/data/*.log" --exclude="opt/nezha/dashboard/data/*.db-wal" --exclude="opt/nezha/dashboard/data/*.db-shm" --exclude="opt/nezha/dashboard/logs" --exclude="opt/nezha/*.log")
    fi

    confirm_action "确定开始 [${type_desc}] 吗？" || return 0

    log "停止服务..."
    systemctl stop nginx 2>/dev/null || true
    if [ -d "/opt/nezha/dashboard" ]; then
        (cd /opt/nezha/dashboard && docker compose down) || true
    fi

    if [ -f "$DB" ] && command -v sqlite3 >/dev/null; then
        log "优化 SQLite 数据库..."
        sqlite3 "$DB" "PRAGMA wal_checkpoint(FULL); VACUUM;" || true
    fi

    log "开始备份..."
    cd /
    tar -czvf "$BACKUP" "${exclude_args[@]}" etc/nginx opt/nezha root/ssl || true

    log "启动服务..."
    if [ -d "/opt/nezha/dashboard" ]; then
        (cd /opt/nezha/dashboard && docker compose up -d) || true
    fi
    systemctl start nginx 2>/dev/null || true

    log "备份完成: $BACKUP"
}

# ==================== 功能 3：恢复 ====================
run_restore() {
    if [ ! -f "$BACKUP" ]; then
        log "错误: 备份文件不存在 ($BACKUP)"
        return 1
    fi

    confirm_action "确定要恢复吗？此操作会覆盖当前数据！" || return 0

    log "停止服务并创建快照..."
    systemctl stop nginx 2>/dev/null || true
    if [ -d "/opt/nezha/dashboard" ]; then
        (cd /opt/nezha/dashboard && docker compose down) || true
    fi

    cd /
    tar -czf "$SNAP" etc/nginx opt/nezha root/ssl 2>/dev/null || true

    log "正在恢复..."
    rm -rf /etc/nginx /opt/nezha /root/ssl

    if tar -xzf "$BACKUP" -C / --same-owner; then
        log "恢复成功！"
        rm -f "$SNAP"
    else
        log "恢复失败，正在回滚..."
        rm -rf /etc/nginx /opt/nezha /root/ssl
        tar -xzf "$SNAP" -C / --same-owner || true
    fi

    log "重启服务..."
    if [ -d "/opt/nezha/dashboard" ]; then
        (cd /opt/nezha/dashboard && docker compose up -d) || true
    fi
    systemctl start nginx 2>/dev/null || true
}

# ==================== 功能 4：TSDB ====================
enable_tsdb() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "错误: 未找到配置文件"
        return 1
    fi

    if grep -qiE 'enable(tsdb|_tsdb)' "$CONFIG_FILE" && grep -qiE 'enable(tsdb|_tsdb)\s*:\s*(true|on|yes|1)' "$CONFIG_FILE"; then
        log "TSDB 已经是开启状态。"
        return 0
    fi

    confirm_action "确定开启 TSDB 历史监控功能吗？" || return 0

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" || true

    if grep -qi 'enable.*tsdb' "$CONFIG_FILE"; then
        sed -i 's/enable[_]*tsdb.*/enabletsdb: true/i' "$CONFIG_FILE"
    else
        echo -e "\n# TSDB\nenabletsdb: true" >> "$CONFIG_FILE"
    fi

    log "正在重启面板..."
    if [ -d "/opt/nezha/dashboard" ]; then
        (cd /opt/nezha/dashboard && docker compose restart) || true
    fi

    log "TSDB 已开启并重启完成。"
}

# ==================== 主菜单 ====================
show_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "       哪吒面板 自动化运维工具箱         "
        echo "=========================================="
        echo " 1. 安装/管理 哪吒面板 (官方脚本)"
        echo " 2. 备份 哪吒面板数据"
        echo " 3. 恢复 哪吒面板数据"
        echo " 4. 开启 TSDB 监控历史"
        echo " 0. 退出"
        echo "=========================================="

        local choice
        choice=$(safe_read "请输入数字 [0-4]: " "0")

        case "$choice" in
            1) run_official_script ;;
            2) run_backup ;;
            3) run_restore ;;
            4) enable_tsdb ;;
            0) safe_exit ;;
            *) echo "输入错误，请输入 0-4" ;;
        esac

        echo ""
        read -r -p "按回车键返回主菜单..." 
    done
}

clear
show_menu
