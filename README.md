Nezha Toolbox

哪吒面板自动化运维工具箱。

集成官方脚本管理、数据备份与恢复、TSDB 开关等常用运维功能，支持一键运行。

功能列表

* 安装/管理哪吒面板（官方脚本）
* 备份哪吒面板数据
* 恢复哪吒面板数据（失败自动回滚）
* 开启 TSDB 历史监控

⸻

使用方法

一键运行（推荐）
```bash
curl -fsSL https://raw.githubusercontent.com/zeyouerxing/nezha-toolbox/main/nezha_tool.sh | bash
```
或
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zeyouerxing/nezha-toolbox/main/nezha_tool.sh)
```
⸻

本地运行

下载脚本：
```bash
wget https://raw.githubusercontent.com/zeyouerxing/nezha-toolbox/main/nezha_tool.sh
```
赋予执行权限：
```bash
chmod +x nezha_tool.sh
```
运行：
```bash
bash nezha_tool.sh
```
⸻

主菜单

==========================================
       哪吒面板 自动化运维工具箱
==========================================
 1. 安装/管理 哪吒面板 (官方脚本)
 2. 备份 哪吒面板数据
 3. 恢复 哪吒面板数据
 4. 开启 TSDB 监控历史
 0. 退出
==========================================

⸻

功能说明

1. 安装/管理 哪吒面板（官方脚本）

调用官方维护脚本，可进行：

* 安装
* 更新
* 重启
* 停止
* 卸载
* 查看状态

兼容以下运行方式：

bash nezha_tool.sh
bash <(curl -fsSL https://raw.githubusercontent.com/zeyouerxing/nezha-toolbox/main/nezha_tool.sh)
curl -fsSL https://raw.githubusercontent.com/zeyouerxing/nezha-toolbox/main/nezha_tool.sh | bash

如果进入官方菜单后无法输入，可选择：

2. 输出官方命令（兼容所有环境）

然后单独执行：

bash <(curl -fsSL https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh)

⸻

2. 备份哪吒面板数据

默认备份以下目录：

/etc/nginx
/opt/nezha
/root/ssl

生成备份文件：

/root/backup.tar.gz

备份过程中会自动：

* 停止 Nginx
* 停止哪吒面板服务
* 优化 SQLite 数据库
* 执行压缩备份
* 自动恢复服务运行

精简备份（推荐）

不备份以下内容（存在时自动跳过）：

* TSDB 历史数据
* 日志文件
* SQLite 临时文件

全量备份

保留所有哪吒数据，仅排除：

* 日志文件
* SQLite 临时文件

说明：

* 如果已开启 TSDB，会一并备份 TSDB 历史数据。
* 如果未开启 TSDB，则不会产生 TSDB 数据目录，脚本会自动跳过。

⸻

3. 恢复哪吒面板数据

恢复前会自动创建安全快照：

/root/before_restore_YYYY-MM-DD.tar.gz

恢复流程：

停止服务
↓
创建恢复前快照
↓
删除旧文件
↓
恢复 backup.tar.gz
↓
恢复成功后删除快照

如果恢复失败：

自动回滚到恢复前状态

恢复完成后会自动：

* 启动哪吒面板
* 启动 Nginx

⸻

4. 开启 TSDB 历史监控

自动修改：

/opt/nezha/dashboard/data/config.yaml

添加或修改：

enabletsdb: true

随后自动重启哪吒面板。

如果已经开启，则不会重复操作。

⸻

文件说明

备份文件：

/root/backup.tar.gz

恢复前安全快照：

/ root/before_restore_YYYY-MM-DD.tar.gz

TSDB 配置文件：

/opt/nezha/dashboard/data/config.yaml

⸻

注意事项

* 建议使用 root 用户运行。
* 恢复操作会覆盖当前数据，请先确认。
* 恢复失败会自动回滚到恢复前状态。
* 精简备份不会备份 TSDB 历史数据（如果存在）。
* 全量备份会保留 TSDB 历史数据（如果已开启）。
* 如果未开启 TSDB，脚本会自动跳过对应目录，不影响备份和恢复。
* 使用 curl | bash 运行时，如果官方脚本无法交互，可使用“输出官方命令”模式单独执行。

免责声明

本工具仅用于简化哪吒面板的日常运维操作。

执行恢复操作前，建议保留额外备份，以防误操作造成数据丢失。
