#!/bin/bash

# 开启严格模式：任何命令失败、变量未定义、管道失败都会立即退出脚本
set -euo pipefail

# 统一变量定义
BACKUP="/root/backup.tar.gz"
DB="/opt/nezha/dashboard/data/sqlite.db"
NEZHA_DIR="/opt/nezha"
CONFIG_FILE="/opt/nezha/dashboard/data/config.yaml"
DATE=$(date +%F)
SNAP="/root/before_restore_${DATE}.tar.gz"

log() { echo "[$(date '+%F %T')] $*"; }

# 优雅的退出函数，防止关闭当前终端
safe_exit() {
    set +euo pipefail
    cd /root 2>/dev/null || true
    log "当前终端已切换回 /root"
    return 0 2>/dev/null || exit 0
}

# 确认交互函数 (回车或y/Y通过，n/N或其它取消)
confirm_action() {
    local prompt_msg="$1"
    local choice
    read -r -p "$prompt_msg [Y/n]: " choice </dev/tty || choice="Y"
    
    if [ -z "$choice" ] || [[ "$choice" =~ ^[Yy]$ ]]; then
        return 0
    else
        log "操作已取消。"
        return 1
    fi
}

# ==================== 功能 1: 哪吒官方脚本 ====================
run_official_script() {
    log "正在调用哪吒面板官方安装脚本..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh && chmod +x nezha.sh && ./nezha.sh
}

# ==================== 功能 2: 备份流程 ====================
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
    read -r -p "请输入选择 [1-2, 默认 1]: " backup_type </dev/tty || backup_type="1"
    [ -z "$backup_type" ] && backup_type="1"

    local type_desc=""
    local exclude_args=()

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

    log "1. 停止服务"
    systemctl stop nginx 2>/dev/null || true
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        docker compose down || true
    fi

    log "2. SQLite 安全处理"
    if [ -f "$DB" ]; then
        sqlite3 "$DB" "PRAGMA wal_checkpoint(FULL);" || true
        log "检查 service_histories 是否存在"
        TABLE_CHECK=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='service_histories';" 2>/dev/null | grep "service_histories" || true)
        if [ -n "$TABLE_CHECK" ]; then
            if [ "$backup_type" = "1" ]; then
                log "精简备份：清空 service_histories"
                sqlite3 "$DB" "DELETE FROM service_histories;" || true
            else
                log "全量备份：保留 service_histories 历史数据"
            fi
            sqlite3 "$DB" "VACUUM;" || true
        else
            log "service_histories 不存在，跳过清理"
        fi
    fi

    log "3. 创建备份 (${type_desc})"
    tar -czvf "$BACKUP" "${exclude_args[@]}" /etc/nginx /opt/nezha /root/ssl

    log "4. 启动服务"
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        docker compose up -d || true
    fi
    systemctl start nginx 2>/dev/null || true

    log "5. 服务检查"
    sleep 3
    if curl -fs http://127.0.0.1 >/dev/null 2>&1; then
        log "服务正常"
    else
        log "警告: 服务状态异常，请检查 docker compose logs"
    fi

    log "完成[${type_desc}]: $BACKUP"
}

# ==================== 功能 3: 恢复流程 ====================
run_restore() {
    confirm_action "确定要执行恢复吗？这将覆盖现有数据并重启服务！" || return 0

    log "[1] 校验备份包"
    if [ ! -f "$BACKUP" ]; then
        echo "[错误] 备份文件不存在: $BACKUP"
        return 1
    fi
    tar -tzf "$BACKUP" >/dev/null 2>&1 || {
        echo "[错误] 备份文件损坏"
        return 1
    }
    log "备份包校验通过"

    log "[2] 删除上一次兜底快照（如果存在）"
    PREV_DATE=$(date -d "yesterday" +%F 2>/dev/null || true)
    if [ -n "$PREV_DATE" ]; then
        PREV_SNAP="/root/before_restore_${PREV_DATE}.tar.gz"
        if [ -f "$PREV_SNAP" ]; then
            rm -f "$PREV_SNAP"
            log "已删除旧兜底快照: $PREV_SNAP"
        fi
    fi

    log "[3] 停止服务"
    systemctl stop nginx 2>/dev/null || true
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        docker compose down || true
    fi

    log "[4] 创建本地数据兜底快照: $SNAP"
    rm -f "$SNAP"
    tar -czf "$SNAP" \
        --exclude="/opt/nezha/dashboard/data/tsdb" \
        --exclude="/opt/nezha/dashboard/data/*.log" \
        /etc/nginx /opt/nezha /root/ssl 2>/dev/null || true

    log "[5] 正式恢复"
    tar -xzf "$BACKUP" -C / --same-owner || {
        echo "[错误] 恢复失败，开始触发自动回滚..."
        systemctl stop nginx 2>/dev/null || true
        if [ -d /opt/nezha/dashboard ]; then
            cd /opt/nezha/dashboard
            docker compose down || true
        fi

        if [ -f "$SNAP" ]; then
            tar -xzf "$SNAP" -C / --same-owner || {
                echo "[致命] 快照回滚失败"
                return 1
            }
        fi

        if [ -d /opt/nezha/dashboard ]; then
            cd /opt/nezha/dashboard
            docker compose up -d || true
        fi
        nginx -t && systemctl start nginx 2>/dev/null || true
        return 1
    }

    log "[6] 启动服务"
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        docker compose up -d || {
            echo "[错误] Docker 服务启动失败"
            return 1
        }
    fi
    nginx -t 2>/dev/null && systemctl start nginx 2>/dev/null || echo "[警告] Nginx 启动失败"

    log "[7] 清理本次兜底快照"
    rm -f "$SNAP"

    log "[8] 检查 TSDB 状态"
    if [ -d /opt/nezha/dashboard/data/tsdb ]; then
        echo "[OK] TSDB 已存在 (当前为全量恢复数据)"
    else
        echo "[提示] TSDB 未恢复（当前为轻量/精简恢复）"
    fi

    log "=========================================="
    log "[完成] 恢复成功"
    log "=========================================="
}

# ==================== 功能 4: 开启/修复 TSDB 功能 ====================
enable_tsdb() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "错误: 未找到哪吒配置文件 ($CONFIG_FILE)，请确保面板已正确安装。"
        return 1
    fi

    confirm_action "确定要修改配置并开启 TSDB (启用历史监控图表) 吗？" || return 0

    log "1. 正在备份当前配置文件..."
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    log "2. 正在修改配置文件开启 TSDB..."
    # 使用 sed 检测并修改，如果不存在 enablestdb 字段，则追加；如果存在，则修改为 true
    if grep -q "enablestdb:" "$CONFIG_FILE"; then
        # 针对老版本或特定配置文件的 enablestdb 字段
        sed -i 's/enablestdb:.*/enablestdb: true/g' "$CONFIG_FILE"
    elif grep -q "disable_periodic_task:" "$CONFIG_FILE"; then
        # 针对部分版本可能通过禁用周期任务关闭监控的情况
        sed -i 's/disable_periodic_task:.*/disable_periodic_task: false/g' "$CONFIG_FILE"
    else
        # 如果文件中完全没有配置项，直接在末尾追加默认开启项
        echo "enablestdb: true" >> "$CONFIG_FILE"
    fi

    log "3. 重启哪吒面板使配置生效..."
    if [ -d /opt/nezha/dashboard ]; then
        cd /opt/nezha/dashboard
        docker compose restart || docker compose up -d
    fi

    log "[完成] TSDB 配置已调整，面板已重启。请刷新网页检查历史图表是否恢复。"
}

# ==================== 主菜单交互逻辑 ====================
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
    
    local menu_choice
    read -r -p "请输入数字选择功能 [0-4]: " menu_choice </dev/tty || menu_choice="0"
    
    case "$menu_choice" in
        1)
            run_official_script
            ;;
        2)
            run_backup
            ;;
        3)
            run_restore
            ;;
        4)
            enable_tsdb
            ;;
        0)
            log "退出脚本。"
            safe_exit
            ;;
        *)
            log "无效输入，请输入 0-4 之间的数字。"
            sleep 2
            show_menu
            ;;
    esac
}

# 启动菜单
show_menu
safe_exit
