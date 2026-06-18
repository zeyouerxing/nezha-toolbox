#!/bin/bash

set -euo pipefail

BACKUP="/root/backup.tar.gz"
DB="/opt/nezha/dashboard/data/sqlite.db"
NEZHA_DIR="/opt/nezha"
CONFIG_FILE="/opt/nezha/dashboard/data/config.yaml"
DATE=$(date +%F)
SNAP="/root/before_restore_${DATE}.tar.gz"

log() { echo "[$(date '+%F %T')] $*"; }

safe_read() {
    local prompt="$1"
    local default="${2:-}"
    local var

    read -r -p "$prompt" var || true
    var="${var:-$default}"
    echo "$var"
}

safe_exit() {
    set +euo pipefail
    cd /root 2>/dev/null || true
    log "已返回 /root"
    exit 0
}

confirm_action() {
    local msg="$1"
    local choice

    choice=$(safe_read "$msg [Y/n]: " "Y")

    if [[ "$choice" =~ ^[Nn]$ ]]; then
        log "已取消"
        return 1
    fi

    return 0
}

run_official_script() {
    log "调用官方脚本..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o /tmp/nezha.sh
    bash /tmp/nezha.sh
}

run_backup() {
    if [ ! -d "$NEZHA_DIR" ]; then
        log "未检测到安装目录"
        return 1
    fi

    echo "1. 精简备份"
    echo "2. 全量备份"

    backup_type=$(safe_read "选择 [1-2]: " "1")

    confirm_action "确认执行备份?" || return 0

    systemctl stop nginx 2>/dev/null || true
    cd /opt/nezha/dashboard 2>/dev/null && docker compose down || true

    if [ "$backup_type" = "1" ]; then
        tar -czf "$BACKUP" \
            --exclude="/opt/nezha/dashboard/data/tsdb" \
            --exclude="*.log" \
            /etc/nginx /opt/nezha /root/ssl
    else
        tar -czf "$BACKUP" \
            --exclude="*.log" \
            /etc/nginx /opt/nezha /root/ssl
    fi

    cd /opt/nezha/dashboard 2>/dev/null && docker compose up -d || true
    systemctl start nginx 2>/dev/null || true

    log "备份完成: $BACKUP"
}

run_restore() {
    confirm_action "恢复会覆盖数据，继续?" || return 0

    if [ ! -f "$BACKUP" ]; then
        log "备份不存在"
        return 1
    fi

    systemctl stop nginx 2>/dev/null || true
    cd /opt/nezha/dashboard 2>/dev/null && docker compose down || true

    tar -czf "$SNAP" /etc/nginx /opt/nezha /root/ssl 2>/dev/null || true

    if ! tar -xzf "$BACKUP" -C / --same-owner; then
        log "恢复失败，回滚..."
        tar -xzf "$SNAP" -C / --same-owner || true
    fi

    cd /opt/nezha/dashboard 2>/dev/null && docker compose up -d || true
    systemctl start nginx 2>/dev/null || true

    rm -f "$SNAP"
    log "恢复完成"
}

enable_tsdb() {
    confirm_action "开启 TSDB?" || return 0

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true

    if grep -q "enablestdb" "$CONFIG_FILE"; then
        sed -i 's/enablestdb:.*/enablestdb: true/' "$CONFIG_FILE"
    else
        echo "enablestdb: true" >> "$CONFIG_FILE"
    fi

    cd /opt/nezha/dashboard 2>/dev/null && docker compose restart || true
    log "TSDB 已启用"
}

show_menu() {
    echo "=================================="
    echo "  哪吒面板工具箱"
    echo "=================================="
    echo "1. 安装官方"
    echo "2. 备份"
    echo "3. 恢复"
    echo "4. TSDB修复"
    echo "0. 退出"
    echo "=================================="

    choice=$(safe_read "选择 [0-4]: " "0")

    case "$choice" in
        1) run_official_script ;;
        2) run_backup ;;
        3) run_restore ;;
        4) enable_tsdb ;;
        0) safe_exit ;;
        *) log "无效输入" ;;
    esac
}

show_menu
safe_exit
