#!/bin/bash

set -euo pipefail

BACKUP="/root/backup.tar.gz"
DB="/opt/nezha/dashboard/data/sqlite.db"
NEZHA_DIR="/opt/nezha"
CONFIG_FILE="/opt/nezha/dashboard/data/config.yaml"
DATE=$(date +%F)
SNAP="/root/before_restore_${DATE}.tar.gz"

log() { echo "[$(date '+%F %T')] $*"; }

# ==================== 核心兼容性修复 ====================
safe_read() {
    local prompt="$1"
    local default="${2:-}"
    local var

    set +e
    read -r -p "$prompt" var </dev/tty
    set -e
    var="${var:-$default}"
    echo "$var"
}

safe_exit() {
    set +euo pipefail
    cd /root 2>/dev/null || true
    log "当前终端已切换回 /root，脚本已安全退出。"
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

# ==================== 功能 1：优化版官方脚本调用 ====================
run_official_script() {
    log "正在下载并调用哪吒面板官方安装脚本..."

    curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh -o /tmp/nezha.sh
    chmod +x /tmp/nezha.sh

    echo "──────────────────────────────────────────"
    log "即将进入【官方哪吒安装菜单】"
    log "请直接输入数字选项并按回车"
    echo "──────────────────────────────────────────"

    # 多种方式尝试，确保交互正常
    if command -v script >/dev/null 2>&1; then
        script -q -c "/tmp/nezha.sh" /dev/null
    elif [ -t 0 ]; then
        /tmp/nezha.sh
    else
        # 最终兜底方案
        /tmp/nezha.sh </dev/tty || {
            echo "当前环境交互受限，推荐使用以下命令单独运行官方脚本："
            echo "bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh)"
        }
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

    local backup_type
    backup_type=$(safe_read "请输入选择 [1-2, 默认 1]: " "1")

    local type_desc=""
    local exclude_args=()

    if [ "$backup_type" = "2" ]; then
        type_desc="全量备份"
        exclude_args=(--exclude="opt/nezha/dashboard/data/*.log" --exclude="opt/nezha/dashboard/data/*.db-wal" --exclude="opt/nezha/dashboard/data/*.db-shm" --exclude="opt/nezha/dashboard/logs" --exclude="opt/nezha/*.log")
    else
        type_desc="精简备份"
        exclude_args=(--exclude="opt/nezha/dashboard/data/tsdb" --exclude="opt/nezha/dashboard/data/*.log" --exclude="opt/nezha/dashboard/data/*.db-wal" --exclude="opt/nezha/dashboard/data/*.db-shm" --exclude="opt/nezha/dashboard/logs" --exclude="opt/nezha/*.log")
    fi

    confirm_action "确定要开始哪吒面板的 [${type_desc}] 吗？" || return 0

    log "正在停止相关服务..."
    systemctl stop nginx 2>/dev/null || true
    if [ -d "/opt/nezha/dashboard" ]; then
        (cd /opt/nezha/dashboard && docker compose down) || true
        sleep 2
    fi

    if [ -f "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
        log "正在优化 SQLite 数据库..."
        sqlite3 "$DB" "PRAGMA wal_checkpoint(FULL);" || true
        sqlite3 "$DB" "VACUUM;" || true
    fi

    log "正在打包备份文件..."
    cd /
    tar -czvf "$BACKUP" "${exclude_args[@]}" etc/nginx opt/nezha root/ssl || true

    log "正在恢复服务运行..."
    if [ -d "/opt/nezha/dashboard" ]; then
        (cd /opt/nezha/dashboard && docker compose up -d) || true
    fi
    systemctl start nginx 2>/dev/null || true

    log "完成[${type_desc}]: $BACKUP"
}

# ==================== 功能 3 ====================
run_restore() {
    if [ ! -f "$BACKUP" ]; then
        log "错误: 备份文件不存在: $BACKUP"
        return 1
    fi

    confirm_action "确定要执行恢复吗？这将覆盖现有数据并重启服务！" || return 0

    log "正在停止当前服务并创建临时快照..."
    systemctl stop nginx 2>/dev/null || true
    if [ -d "/opt/nezha/dashboard" ]; then
        (cd /opt/nezha/dashboard && docker compose down) || true
        sleep 2
    fi

    cd /
    tar -czf "$SNAP" etc/nginx opt/nezha root/ssl 2>/dev/null || true

    log "正在清理旧数据并解压备份..."
    rm -rf /etc/nginx /opt/nezha /root/ssl

    if tar -xzf "$BACKUP" -C / --same-owner; then
        log "[完成] 恢复成功"
        rm -f "$SNAP"
    else
        log "错误: 解压失败，开始执行回滚..."
        rm -rf /etc/nginx /opt/nezha /root/ssl
        if [ -f "$SNAP" ]; then
            tar -xzf "$SNAP" -C / --same-owner || true
            log "已回滚至修改前状态。"
        fi
    fi

    log "正在重启服务..."
    if [ -d "/opt/nezha/dashboard" ]; then
        (cd /opt/nezha/dashboard && docker compose up -d) || true
    fi
    systemctl start nginx 2>/dev/null || true
}

# ==================== 功能 4 ====================
enable_tsdb() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "错误: 未找到配置文件 ($CONFIG_FILE)"
        return 1
    fi

    if grep -E -q "enabletsdb:\s*true" "$CONFIG_FILE"; then
        log "提示: TSDB 监控历史功能已经是【开启】状态，无需重复操作。"
        return 0
    fi

    confirm_action "确定要修改配置并开启 TSDB (启用历史监控图表) 吗？" || return 0

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true

    if grep -q "enabletsdb:" "$CONFIG_FILE"; then
        sed -i 's/enabletsdb:.*/enabletsdb: true/' "$CONFIG_FILE"
    else
        echo "" >> "$CONFIG_FILE"
        echo "enabletsdb: true" >> "$CONFIG_FILE"
    fi

    log "正在重启面板以应用配置..."
    if [ -d "/opt/nezha/dashboard" ]; then
        (cd /opt/nezha/dashboard && docker compose restart) || true
    fi

    log "TSDB 配置已更新并重启完成。"
}

# ==================== 菜单循环 ====================
show_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "       哪吒面板 自动化运维工具箱 v1.1       "
        echo "=========================================="
        echo " 1. 安装/管理 哪吒面板 (官方脚本)"
        echo " 2. 备份 哪吒面板数据 (精简/全量)"
        echo " 3. 恢复 哪吒面板数据"
        echo " 4. 开启/修复 TSDB 监控历史功能"
        echo " 0. 退出脚本"
        echo "=========================================="

        local menu_choice
        menu_choice=$(safe_read "请输入数字选择功能 [0-4]: " "0")

        case "$menu_choice" in
            1) run_official_script ;;
            2) run_backup ;;
            3) run_restore ;;
            4) enable_tsdb ;;
            0) safe_exit ;;
            *) log "无效输入，请输入 0-4 之间的数字。" ;;
        esac
        
        echo ""
        safe_read "按回车键返回主菜单..." ""
    done
}

clear
show_menu
