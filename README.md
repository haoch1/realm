# Realm TCP 转发

单文件 TCP 转发管理脚本，支持域名、IPv4 / IPv6 目标，以及 Debian、Ubuntu、Alpine 和常见 LXC / NAT 环境。

## 一键安装

以 **root** 执行：

```sh
mkdir -p /usr/local/bin && (curl -LfsS https://raw.githubusercontent.com/haoch1/realm-tcp/main/realm.sh -o /usr/local/bin/rt || wget -q https://raw.githubusercontent.com/haoch1/realm-tcp/main/realm.sh -O /usr/local/bin/rt) && chmod +x /usr/local/bin/rt && rt
```

自动识别系统并安装依赖，完成后直接进入菜单。Alpine 无需提前安装 Bash；首次下载需要系统已有 curl 或 wget。

以后直接运行：

```sh
rt
```

## 转发管理

```text
[1] 添加转发规则
[2] 查看当前转发规则
[3] 修改转发规则
[4] 删除转发规则
[5] 清空所有转发规则
[6] 更新 Realm
[7] 一键卸载
[0] 退出脚本
```

添加规则时填写 **本机监听端口 → 目标 IP/域名 → 目标端口**。例如 `10001 → example.com → 443`，域名不要带协议或路径。

新规则监听 `0.0.0.0`，支持端口范围 `1–65535`。添加规则后启用服务及开机自启；清空规则后停止服务并取消自启。修改规则会重启服务，已有连接可能中断。

## 支持环境

| 系统 | 服务管理 |
| --- | --- |
| Debian / Ubuntu | systemd |
| Alpine | OpenRC |
| RHEL / Rocky Linux / AlmaLinux | systemd |

支持 `x86_64`、`ARM64`、`ARMv7` 硬浮点架构。LXC 中需运行 systemd 或 OpenRC。仅转发 TCP，不需要 TUN、NET_ADMIN 或内核 IP 转发权限。

**NAT 示例：** 服务商提供 `公网:30001 → 容器:10001`，脚本监听填 `10001`，客户端连接公网 `30001`。上游端口映射、防火墙放行和目标网络连通性需要事先具备。

## 更新

首次添加规则时自动安装 Realm 最新稳定版，并校验 SHA256。以后在菜单选择 **[6] 更新 Realm**，也可直接执行：

```sh
rt --update
```

更新管理脚本，重新执行一键安装命令即可；已有转发规则会保留。

## 卸载

在菜单选择 **[7] 一键卸载**，确认后停止服务、取消开机自启，并删除服务文件、核心程序、全部规则与备份、独立日志及 `rt` 命令。也可执行 `rt --uninstall`。

卸载后规则无法恢复。Bash、curl 等共用依赖及 systemd 的共享日志保留，避免影响其他程序。

## 配置与日志

- 管理命令：`/usr/local/bin/rt`
- 核心程序：`/root/realm/realm`
- 转发规则：`/root/realm/config.json`
- 最近一次备份：对应文件的 `.bak`

| 操作 | systemd | OpenRC |
| --- | --- | --- |
| 查看状态 | `systemctl status realm` | `rc-service realm status` |
| 查看日志 | `journalctl -u realm -n 50 --no-pager` | `tail -n 50 /var/log/realm.log` |
