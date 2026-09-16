# Realm TCP 转发管理

基于 [jinqians/realm](https://github.com/jinqians/realm/blob/ca33b85a391dd1e854cb4780681cc894288a6ff6/realm.sh) 改造，菜单参考 [advanced_relay.sh](https://github.com/0xdabiaoge/singbox-lite/blob/main/advanced_relay.sh) 的端口转发部分。只保留 Realm 和 TCP；运行脚本直接显示：

```text
[1] 添加转发规则
[2] 查看当前转发规则
[3] 修改转发规则
[4] 删除转发规则
[5] 清空所有转发规则
[0] 退出脚本
```

## 使用

把 `realm.sh` 上传到服务器，在所在目录以 root 运行：

```sh
bash realm.sh
```

Alpine 首次使用先安装 Bash：

```sh
apk add --no-cache bash
bash realm.sh
```

其余依赖由脚本自动安装。支持使用 systemd 的 Debian、Ubuntu、RHEL 系发行版，以及使用 OpenRC 的 Alpine。需要系统已有并运行相应的服务管理器；不支持只有 `/bin/sh` 作为 PID 1 的裸容器。使用 `sudo` 的系统可执行 `sudo bash realm.sh`。

第一次添加规则时，自动从 [Realm 官方最新稳定版](https://github.com/zhboner/realm/releases/latest) 下载对应架构的 musl 程序并校验 SHA256。支持 x86_64、ARM64 和 ARMv7 硬浮点，不写死版本号。已有程序时打开菜单不检查更新，需要升级时执行：

```sh
bash realm.sh --update
```

升级保留规则和原服务运行状态；新版本启动或监听失败时尝试恢复旧程序。下载失败、架构不支持、发布包或校验信息不符合预期时停止更新。此机制适配当前官方发布格式，不保证未来破坏性配置变更仍兼容。

## Alpine、LXC 和 NAT VPS

Realm 使用普通 TCP 连接，不依赖容器的 `NET_ADMIN`、nftables、TUN 或 IP 转发权限。LXC 容器内以 root 运行，具备 systemd 或 OpenRC、可写文件系统、可用监听端口和到目标的网络连接即可。脚本不会修改防火墙、宿主机 NAT 或内核参数。

例如服务商提供：

```text
公网地址:30001 → 容器内网地址:10001
```

在脚本中填写监听端口 **10001**，再填写目标 IP/域名和目标端口；客户端连接 **公网地址:30001**。如果服务商分配的是端口范围，只能使用范围内对应的端口。没有上游映射的端口，脚本无法自行开放到公网。

新规则监听 `0.0.0.0`，可转发到 IPv4、域名或 IPv6 目标。编辑旧规则保留原监听地址。容器无法访问的目标，或被系统防火墙、云安全组拦截的端口，仍需先解决网络连通性。

## 配置与服务

- 程序：`/root/realm/realm`；规则：`/root/realm/config.json`，直接使用 Realm 原生配置。
- 自动导入原脚本的简单 `/root/realm/config.toml`，保留原文件。含未知自定义选项的旧配置会提示手动处理，避免丢失设置。
- 规则修改及核心升级保留最近一次 `.bak` 备份。修改规则会重启服务，已有 TCP 连接可能中断。
- systemd：`systemctl status realm`；日志：`journalctl -u realm -n 50`。
- OpenRC：`rc-service realm status`；日志：`/var/log/realm.log`。
- 添加规则后启用开机自启；清空或删除最后一条规则后停止服务并取消自启。

## 验证

`tests/test.sh` 在独立目录内验证配置迁移、规则增删改、端口冲突、升级及失败回滚，服务和监听查询使用替身，不会操作本机服务。可分别执行：

```sh
node tests/setup.mjs
bash -n realm.sh
bash tests/test.sh systemd
bash tests/test.sh openrc
```

Linux 测试环境需预装 Bash、jq、tar 和 coreutils；Windows 开发验证使用 Git Bash、Node.js 和自动下载的官方 jq。Windows 测试不覆盖 Linux 权限、真实 init 系统、容器限制和上游 NAT 映射。

2026-09-16 验证结果：Bash 语法检查通过；systemd 与 OpenRC 各 21 项行为检查通过。已使用官方 v2.9.6 发布元数据验证架构和安装包选择；尚未在真实 Alpine/LXC 上部署验证。

实际部署只需 `realm.sh`，项目来源见本文开头的链接。
