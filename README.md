# Nezha Toolbox

Nezha 面板管理工具箱（TSDB + 备份恢复 + 安全回滚）

------------------------------------------------------------------------

## 功能

-   安装官方 Nezha 面板
-   一键备份 / 恢复
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
    0 退出

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
