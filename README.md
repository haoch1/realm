# Realm

轻量的 Realm 转发管理脚本。支持 **TCP、UDP、TCP+UDP**，目标可填写域名、IPv4 或 IPv6；兼容 Debian、Ubuntu、Alpine 和常见 LXC / NAT 环境。

## 一键安装

以 **root** 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/realm/main/realm.sh -o /usr/local/bin/realm || wget -q https://raw.githubusercontent.com/haoch1/realm/main/realm.sh -O /usr/local/bin/realm) && chmod +x /usr/local/bin/realm && realm
```

自动识别系统并安装依赖，完成后直接进入菜单。Alpine 无需提前安装 Bash；首次下载需要系统已有 curl 或 wget。

以后直接运行：

```sh
realm
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

添加规则依次填写 **本机监听端口 → 目标地址 → 目标端口 → 转发协议 → 备注名称**。域名不要带 `https://` 或路径。

| 协议选项 | 转发方式 | 示例 |
| --- | --- | --- |
| 1（默认） | 仅 TCP | `10001 → example.com:443` |
| 2 | 仅 UDP | `1053 → 1.1.1.1:53` |
| 3 | TCP+UDP | 同一端口同时转发两种协议 |

查看规则会显示备注、监听地址、目标和协议。修改时回车保留原值，选择规则时输入 `0` 取消。

新规则监听 `0.0.0.0`，端口范围为 `1–65535`。同一端口的 TCP 和 UDP 可以分别指向不同目标；同协议重复占用会被拒绝。

添加规则后自动启动并设置开机自启；删除最后一条或清空规则后停止服务并取消自启。保存修改会重启 Realm，现有连接或 UDP 会话可能中断；启动检查失败会回滚。

## 支持环境

| 系统 | 服务管理 |
| --- | --- |
| Debian / Ubuntu | systemd |
| Alpine | OpenRC |
| RHEL / Rocky Linux / AlmaLinux | systemd |

支持 `x86_64`、`ARM64`、`ARMv7` 硬浮点架构。LXC 中需运行 systemd 或 OpenRC，不需要 TUN、NET_ADMIN 或内核 IP 转发权限。

**NAT 示例：** 服务商提供 `公网:30001 → 容器:10001`，脚本监听填 `10001`，客户端连接公网 `30001`。防火墙与上游映射必须放行所选协议；TCP+UDP 需要两种协议都映射。脚本不会代替宿主机或服务商创建公网映射。

## 更新

首次添加规则时自动安装 Realm 最新稳定版，并校验 SHA256。以后在菜单选择 **[6] 更新 Realm**，也可直接执行：

```sh
realm --update
```

更新管理脚本，重新执行一键安装命令即可；已有转发规则会保留。

## 卸载

在菜单选择 **[7] 一键卸载**，确认后停止服务、取消开机自启，并删除服务文件、核心程序、全部规则与备份、独立日志及 `realm` 命令。也可执行 `realm --uninstall`。

卸载后规则无法恢复。Bash、curl 等共用依赖及 systemd 的共享日志保留，避免影响其他程序。

## 配置与日志

- 管理命令：`/usr/local/bin/realm`
- 核心程序：`/root/realm/realm`
- 转发规则：`/root/realm/config.json`
- 最近一次备份：对应文件的 `.bak`

| 操作 | systemd | OpenRC |
| --- | --- | --- |
| 查看状态 | `systemctl status realm` | `rc-service realm status` |
| 查看日志 | `journalctl -u realm -n 50 --no-pager` | `tail -n 50 /var/log/realm.log` |
