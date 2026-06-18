🧰 哪吒面板自动化运维工具箱（Nezha Toolbox）

一个专为 哪吒面板（Nezha Dashboard） 设计的自动化运维工具箱，提供备份、恢复、修复等常用能力。脚本采用严格模式编写，强调稳定性、安全性与异常容错能力，支持远程一键执行。

⸻

✨ 功能模块

🔧 官方联动管理

* 一键调用哪吒面板官方安装与管理脚本
* 简化日常运维操作流程

⸻

📂 智能备份

精简备份（默认）

* 自动清理并压缩 SQLite 数据库
* 排除 TSDB 历史数据以减少体积
* 适用于日常备份与迁移

全量备份

* 保留全部监控历史数据
* 包含 TSDB 时序数据库
* 适用于完整迁移与长期归档

⸻

🛡️ 安全恢复机制

* 恢复前自动生成“兜底快照”
* 恢复失败自动回滚
* 防止因异常操作导致面板不可用

⸻

📈 TSDB 修复工具

* 自动检测并修复 config.yaml
* 一键开启 TSDB 监控图表功能
* 自动重启服务生效

⸻

## 🚀 一键运行（无需下载）

### ✔ 推荐方式（通用 / GitHub 标准）

```bash
curl -fsSL https://raw.githubusercontent.com/zeyouerxing/nezha-toolbox/main/nezha_tool.sh | bash
```

- GitHub README 最常用写法
- 兼容性最好
- 无需 bash 特殊语法
- 推荐优先使用

---

### ✔ 备用方式（bash 专用，更稳定）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zeyouerxing/nezha-toolbox/main/nezha_tool.sh)
```

- 依赖 bash（不支持 sh / dash）
- 采用“临时文件执行”机制
- 在部分复杂脚本场景更稳定
- 作为备用执行方式使用
⸻

📋 使用说明

* 支持 y/N 交互输入
* 兼容管道执行环境（curl | bash）
* 执行完成后自动停留在 /root
* 推荐使用 root 用户运行

⸻

⚠️ 注意事项

* 请确保服务器已安装 curl
* 建议执行前进行数据备份
* 恢复功能具备自动回滚机制，但仍建议谨慎操作

⸻

📦 项目地址

* GitHub：https://github.com/zeyouerxing/nezha-toolbox

⸻

📄 License

仅用于学习与运维用途，使用风险自负。