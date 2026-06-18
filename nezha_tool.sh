# ==================== 功能 1：官方脚本调用（最终加强版） ====================
run_official_script() {
    log "正在下载哪吒面板官方安装脚本..."

    curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh -o /tmp/nezha.sh
    chmod +x /tmp/nezha.sh

    echo "──────────────────────────────────────────"
    log "即将进入官方哪吒安装菜单"
    log "如果下面输入无效，请直接按几次回车或重新选择"
    echo "──────────────────────────────────────────"

    # 多种方式依次尝试，确保最大兼容性
    if command -v script >/dev/null 2>&1; then
        echo "使用 script 模式运行..."
        script -q -c "/tmp/nezha.sh" /dev/null
    elif [ -t 1 ]; then
        echo "使用标准终端模式运行..."
        /tmp/nezha.sh
    else
        echo "使用强制 tty 模式运行..."
        /tmp/nezha.sh </dev/tty || {
            echo ""
            log "⚠️  交互模式仍然受限，推荐使用以下命令单独运行官方脚本："
            echo "   bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh)"
            echo ""
        }
    fi
}
