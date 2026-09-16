# Realm TCP 转发管理

用于 Linux 服务器的 TCP 端口转发管理工具。通过 `rt` 统一管理转发规则，支持域名、IPv4 和 IPv6 目标，自动配置 systemd 或 OpenRC 服务。

## 一键安装

使用 **root** 执行：

```sh
sh -c 's=$(curl -fsSL "$1" 2>/dev/null || wget -qO- "$1") && exec sh -c "$s"' sh https://raw.githubusercontent.com/haoch1/realm-tcp/main/install.sh
```

安装入口兼容 POSIX `sh`，自动识别 `apt-get`、`apk`、`dnf` 或 `yum`，按需安装 Bash 和其他依赖。系统需具备 curl 或 wget 任一下载工具。

安装完成后自动进入管理菜单。再次打开只需输入：

```sh
rt
```

普通用户使用 `sudo rt`。通过非交互方式安装时，不自动打开菜单。

## 使用说明

```text
[1] 添加转发规则
[2] 查看当前转发规则
[3] 修改转发规则
[4] 删除转发规则
[5] 清空所有转发规则
[0] 退出脚本
```

添加规则时依次填写本机监听端口、目标 IP/域名、目标端口。例如：

| 字段 | 示例 |
| --- | --- |
| 本机监听端口 | `10001` |
| 目标 IP/域名 | `example.com` |
| 目标端口 | `443` |

域名不需要填写 `https://` 或路径。新规则监听 `0.0.0.0`，编辑已有规则时保留原监听地址。端口范围为 `1–65535`；重复或已被其他进程占用的监听端口会被拒绝。

新增规则后启用服务及开机自启。删除最后一条规则或清空规则后停止服务并取消自启。修改规则会重启 Realm，已有 TCP 连接可能中断。

## 系统支持

| 系统 | 包管理器 | 服务管理 |
| --- | --- | --- |
| Debian / Ubuntu | apt-get | systemd |
| Alpine | apk | OpenRC |
| RHEL 系，包括 Rocky Linux / AlmaLinux | dnf / yum | systemd |

支持 `x86_64`、`ARM64`、`ARMv7` 硬浮点架构，使用 Realm 官方 musl 构建。运行环境需要已有并运行 systemd 或 OpenRC；LXC 中也需满足这一条件。

本工具仅管理 **TCP** 转发。服务器需能解析目标域名并连接目标端口；监听端口还需由系统防火墙和云安全组放行。

## NAT / LXC 配置

Realm 使用普通 TCP 连接，不需要 TUN、`NET_ADMIN` 或内核 IP 转发权限。NAT 环境的公网访问依赖宿主机或服务商提供的端口映射。

例如已有映射：

```text
公网地址:30001 → 容器内网地址:10001
```

在 `rt` 中填写监听端口 **10001**，客户端连接 **公网地址:30001**。公网端口和容器端口可以不同；没有上游映射的端口无法通过脚本直接暴露到公网。

## 更新

首次添加规则时自动获取 Realm 最新稳定版，并按架构选择安装包、校验 SHA256。更新 Realm 核心：

```sh
rt --update
```

更新管理脚本时，重新执行一键安装命令即可。两种更新均保留已有转发规则。

核心升级会保留原服务运行状态；下载、校验或启动检查失败时停止更新，必要时恢复原程序。更新依赖官方当前的发布格式与配置兼容性。

## 文件与服务

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/rt` | 管理命令 |
| `/root/realm/realm` | Realm 核心程序 |
| `/root/realm/config.json` | 转发规则 |
| `/root/realm/realm.bak` | 上一次升级前的核心程序 |
| `/root/realm/config.json.bak` | 上一次修改前的转发规则 |

支持导入简单的 `/root/realm/config.toml` 配置，保留原文件。遇到不支持的自定义字段时停止导入，提示手动处理。

| 操作 | systemd | OpenRC |
| --- | --- | --- |
| 查看状态 | `systemctl status realm` | `rc-service realm status` |
| 查看日志 | `journalctl -u realm -n 50 --no-pager` | `tail -n 50 /var/log/realm.log` |
| 重启服务 | `systemctl restart realm` | `rc-service realm restart` |

## 开发验证

测试需要 Bash、Node.js、jq、tar 和 coreutils；Node.js 仅用于开发测试。

```sh
node tests/setup.mjs
sh -n install.sh
bash -n realm.sh
bash tests/install.test.sh
bash tests/test.sh systemd
bash tests/test.sh openrc
```

测试覆盖安装入口、配置迁移、规则增删改、端口冲突、升级和失败回滚。包管理器和服务操作使用替身，测试不会安装软件或修改本机服务；真实 Alpine/LXC 环境的部署与公网连通性需另行验证。
