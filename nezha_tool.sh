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
    log "当前终端已切换回 /root"
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

# ==================== 功能 1 ====================
run_official_script() {
    log "正在调用哪吒面板官方安装脚本..."

    curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh -o /tmp/nezha.sh
    chmod +x /tmp/nezha.sh

    # ===== 核心修复：保证交互 =====
    if command -v script >/dev/null 2>&1; then
        script -q -c "/tmp/nezha.sh" /dev/null
    else
        if [ -t 0 ]; then
            /tmp/nezha.sh
        else
            /tmp/nezha.sh </dev/tty || /tmp/nezha.sh
        fi
    fi
}

# ==================== 功能 2 ====================
run_backup() {
    if [ ! -d "$NEZHA_DIR" ]; then
        log "错误: 未检测到哪吒面板安装目录 ($NEZHA_DIR)，无法执行备份。"
        return 1
    fi

    echo "------------------------------------------"
    echo " 请选择备份类型:"
    echo " 1. 精简备份 (默认: 排除 TSDB 监控历史，体积小速度快)"
    echo " 2. 全量备份 (包含所有历史数据)"
    echo "------------------------------------------"

    backup_type=$(safe_read "请输入选择 [1-2, 默认 1]: " "1")

    type_desc=""
    exclude_args=()

    if [ "$backup_type" = "2" ]; then
        type_desc="全量备份"
        exclude_args=(
            --exclude="/opt/nezha/dashboard/data/*.log"
            --exclude="/opt/nezha/dashboard/data/*.db-wal"
            --exclude="/opt/nezha/dashboard/data/*.db-shm"
            --exclude="/opt/nezha/dashboard/logs"
            --exclude="/opt/nezha/*.log"
        )
    else
        type_desc="精简备份"
        exclude_args=(
            --exclude="/opt/nezha/dashboard/data/tsdb"
            --exclude="/opt/nezha/dashboard/data/*.log"
            --exclude="/opt/nezha/dashboard/data/*.db-wal"
            --exclude="/opt/nezha/dashboard/data/*.db-shm"
            --exclude="/opt/nezha/dashboard/logs"
            --exclude="/opt/nezha/*.log"
        )
    fi

    confirm_action "确定要开始哪吒面板的 [${type_desc}] 吗？" || return 0

    systemctl stop nginx 2>/dev/null || true
    cd /opt/nezha/dashboard 2>/dev/null && docker compose down || true

    if [ -f "$DB" ]; then
        sqlite3 "$DB" "PRAGMA wal_checkpoint(FULL);" || true
        sqlite3 "$DB" "VACUUM;" || true
    fi

    tar -czvf "$BACKUP" "${exclude_args[@]}" /etc/nginx /opt/nezha /root/ssl

    cd /opt/nezha/dashboard 2>/dev/null && docker compose up -d || true
    systemctl start nginx 2>/dev/null || true

    log "完成[${type_desc}]: $BACKUP"
}

# ==================== 功能 3 ====================
run_restore() {
    confirm_action "确定要执行恢复吗？这将覆盖现有数据并重启服务！" || return 0

    if [ ! -f "$BACKUP" ]; then
        log "错误: 备份文件不存在: $BACKUP"
        return 1
    fi

    systemctl stop nginx 2>/dev/null || true
    cd /opt/nezha/dashboard 2>/dev/null && docker compose down || true

    tar -czf "$SNAP" /etc/nginx /opt/nezha /root/ssl 2>/dev/null || true

    if ! tar -xzf "$BACKUP" -C / --same-owner; then
        log "恢复失败，开始回滚..."
        if [ -f "$SNAP" ]; then
            tar -xzf "$SNAP" -C / --same-owner || true
        fi
    fi

    cd /opt/nezha/dashboard 2>/dev/null && docker compose up -d || true
    systemctl start nginx 2>/dev/null || true

    rm -f "$SNAP"
    log "[完成] 恢复成功"
}

# ==================== 功能 4（TSDB 开关，不改语义） ====================
enable_tsdb() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "错误: 未找到配置文件 ($CONFIG_FILE)"
        return 1
    fi

    confirm_action "确定要修改配置并开启 TSDB (启用历史监控图表) 吗？" || return 0

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true

    if grep -q "enablestdb" "$CONFIG_FILE"; then
        sed -i 's/enablestdb:.*/enablestdb: true/' "$CONFIG_FILE"
    else
        echo "enablestdb: true" >> "$CONFIG_FILE"
    fi

    cd /opt/nezha/dashboard 2>/dev/null && docker compose restart || true

    log "TSDB 已更新完成"
}

# ==================== 菜单 ====================
show_menu() {
    clear
    echo "=========================================="
    echo "       哪吒面板 自动化运维工具箱          "
    echo "=========================================="
    echo " 1. 安装/管理 哪吒面板 (官方脚本)"
    echo " 2. 备份 哪吒面板数据 (精简/全量)"
    echo " 3. 恢复 哪吒面板数据"
    echo " 4. 开启/修复 TSDB 监控历史功能"
    echo " 0. 退出脚本"
    echo "=========================================="

    menu_choice=$(safe_read "请输入数字选择功能 [0-4]: " "0")

    case "$menu_choice" in
        1) run_official_script ;;
        2) run_backup ;;
        3) run_restore ;;
        4) enable_tsdb ;;
        0) safe_exit ;;
        *) log "无效输入，请输入 0-4 之间的数字。" ;;
    esac
}

show_menu
safe_exit
