# ==================== 功能 1：官方脚本（兼容两种运行模式） ====================
run_official_script() {
    while true; do
        clear

        echo "=========================================="
        echo "       哪吒官方脚本运行模式"
        echo "=========================================="
        echo " 1. 内置运行 (推荐)"
        echo " 2. 输出官方命令 (兼容所有环境)"
        echo " 0. 返回主菜单"
        echo "=========================================="

        local mode
        mode=$(safe_read "请输入数字 [0-2]: " "0")

        case "$mode" in

            1)
                log "正在下载哪吒官方脚本..."

                local TMP_SCRIPT="/tmp/nezha_install.sh"

                curl -fsSL \
                https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh \
                -o "$TMP_SCRIPT"

                chmod +x "$TMP_SCRIPT"

                echo ""
                echo "──────────────────────────────────────────"
                echo "即将进入官方脚本..."
                echo "如果菜单无法输入，请返回并选择："
                echo "【2. 输出官方命令】"
                echo "──────────────────────────────────────────"
                echo ""

                if [ -e /dev/tty ]; then
                    bash "$TMP_SCRIPT" </dev/tty >/dev/tty 2>&1
                else
                    bash "$TMP_SCRIPT"
                fi

                rm -f "$TMP_SCRIPT"

                return
                ;;

            2)

                clear

                echo "=========================================="
                echo "当前环境建议单独运行官方脚本"
                echo "=========================================="
                echo ""
                echo "请复制执行："
                echo ""

                echo "bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh)"

                echo ""
                echo "=========================================="

                read -r -p "按回车返回..." _
                return
                ;;

            0)
                return
                ;;

            *)
                echo "输入错误，请输入 0-2"
                sleep 1
                ;;

        esac
    done
}
