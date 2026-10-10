# Nezha Toolbox

Nezha 面板管理工具箱（TSDB + 备份恢复 + 安全回滚 + 跨机一键迁移）

------------------------------------------------------------------------

## 功能

-   安装官方 Nezha 面板
-   一键备份 / 恢复
-   **跨机一键迁移**（旧 VPS 导出 → 新 VPS 导入，自动装 docker/nginx、恢复反代与证书）
-   TSDB 开启（Nezha v1 兼容）
-   TSDB 自动回滚（失败恢复 config + sqlite）
-   docker compose 自动识别
-   强制确认（仅 Y 执行）

------------------------------------------------------------------------

## 使用方式

### 方式1（推荐）

``` bash
bash <(curl -fsSL https://raw.githubusercontent.com/zeyouerxing/nezha-toolbox/main/nezha_tool.sh)
```

### 方式2

``` bash
curl -fsSL https://raw.githubusercontent.com/zeyouerxing/nezha-toolbox/main/nezha_tool.sh | bash
```

------------------------------------------------------------------------

## 菜单功能

    1 安装 Nezha
    2 备份 / 恢复
    3 开启 TSDB
    6 迁移导出（旧 VPS）
    7 迁移导入（新 VPS）
    0 退出

------------------------------------------------------------------------

## 一键迁移（换 VPS）

**旧 VPS 上：**

    bash nezha_tool.sh export        # 或菜单选 6

生成 `/root/nezha-backup-<时间戳>.tar.gz`，内含 Nezha 数据、nginx
反代配置、`/root/ssl` 证书及环境清单。

**传到新 VPS：**

    scp /root/nezha-backup-*.tar.gz root@新IP:/root/

**新 VPS 上（全新系统即可）：**

    bash nezha_tool.sh import        # 或菜单选 7

导入流程会自动：

1.  安装依赖（docker、docker compose、**nginx（nginx.org 官方源优先，签名键校验）**、sqlite3、curl）
    官方源配置失败时自动回退发行版自带源，两级都失败才报错
2.  校验迁移包并展示环境清单（导出主机、时间、系统版本）
3.  解压恢复 `/opt/nezha`、`/etc/nginx`、`/root/ssl`
4.  收紧证书权限（私钥 600）
5.  拉取镜像并启动 Nezha 容器（等待就绪，超时提示排查命令）
6.  `nginx -t` 校验通过后启动并设置开机自启

导入完成后请手动确认：DNS A 记录指向新 IP、防火墙放行面板端口。

非交互 / 自动化：

    NEZHA_TOOLBOX_YES=1 NEZHA_MIGRATE_BUNDLE=/root/nezha-backup-xxx.tar.gz \
        bash nezha_tool.sh import

`NEZHA_MIGRATE_BUNDLE` 也支持 http(s) URL，脚本会先下载再导入。

------------------------------------------------------------------------

## TSDB 说明

开启 TSDB 时会执行：

-   停止服务
-   清理 service_histories
-   写入 tsdb 配置
-   重启服务
-   验证 tsdb 目录生成

失败自动回滚：

-   恢复 config.yaml
-   恢复 sqlite.db
-   删除 tsdb 数据
-   重启服务

------------------------------------------------------------------------

## 风险说明

-   会修改 /opt/nezha 数据目录
-   会重启 docker 服务
-   建议执行前做好备份

------------------------------------------------------------------------

## 兼容

-   Nezha v1 Dashboard
-   Docker Compose / docker-compose
-   Linux (Debian / Ubuntu / CentOS)

------------------------------------------------------------------------

## 许可证

MIT
