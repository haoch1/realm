# Realm

轻量的 Realm TCP/UDP 端口转发管理脚本，提供规则管理、核心更新、脚本更新、服务自启、运行检查和失败回滚。支持域名、IPv4、IPv6，以及 Debian、Ubuntu、Alpine、LXC 和常见 NAT VPS。

## 一键安装

使用 `root` 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/realm/main/realm.sh -o /usr/local/bin/r || wget -q https://raw.githubusercontent.com/haoch1/realm/main/realm.sh -O /usr/local/bin/r) && chmod +x /usr/local/bin/r && r
```

脚本会自动识别包管理器、安装必要依赖，并在首次运行时下载 Realm 官方最新稳定版。安装包会经过 SHA256 校验，程序版本也必须与官方发布标签一致。Alpine 不需要提前安装 Bash。

以后使用以下命令打开管理菜单：

```sh
r
```

重复执行一键安装命令会更新管理脚本并保留已有规则。Realm 核心需要通过菜单或 `r --update` 单独更新。

## 管理菜单

```text
[1] 添加转发规则
[2] 查看当前转发规则
[3] 修改转发规则
[4] 删除转发规则
[5] 清空所有转发规则
[6] 更新 Realm
[7] 更新管理脚本
[8] 一键卸载
[0] 退出脚本
```

添加规则时依次填写：本机监听端口、目标地址、目标端口、转发协议和备注名称。域名只填写主机名，不要包含 `http://`、`https://` 或路径。

| 选项 | 转发协议 | 示例 |
| --- | --- | --- |
| 1（默认） | TCP | `10001 → example.com:443` |
| 2 | UDP | `1053 → 1.1.1.1:53` |
| 3 | TCP+UDP | 同一端口同时转发两种协议 |

新规则监听 `0.0.0.0`，允许的端口范围是 `1–65535`。同一端口可以分别建立 TCP 和 UDP 规则；协议发生重叠或端口已被其他程序占用时，脚本会拒绝保存。

保存规则后会自动启动 Realm 并设置开机自启。删除最后一条规则或清空全部规则后，服务会停止并取消自启。配置或启动检查失败时会恢复原规则和服务状态。

## 域名解析

脚本将域名原样写入 Realm 配置，DNS 解析由 Realm 内置解析器完成。默认读取系统 `/etc/resolv.conf`，缓存最多 32 条记录，正向解析缓存时间遵循域名 TTL，默认下限为 `0`、上限为 `86400` 秒。

Realm 没有固定轮询周期。TCP 在建立新连接时读取解析结果；缓存过期后，下一次新连接会触发重新查询。已经建立的 TCP 连接会继续使用原 IP，直到连接关闭。UDP 收到数据时也会读取解析结果，并受相同缓存规则约束。

## 交互与单实例

在添加、修改等操作中按 `Ctrl+C`，脚本会提示按任意键返回主菜单。需要结束管理脚本时请选择 `[0] 退出脚本`。

脚本只允许一个管理实例修改配置。如果旧 SSH 窗口丢失，再次运行 `r` 会自动通知旧管理界面退出，等待锁安全释放后接管。旧实例正在执行配置事务时，新实例最多等待 5 秒；事务没有结束则停止接管，避免两个进程同时修改规则。Realm 转发服务不受管理界面接管影响。

## 系统与网络环境

| 系统 | 服务管理 |
| --- | --- |
| Debian / Ubuntu | systemd |
| Alpine | OpenRC |
| RHEL / Rocky Linux / AlmaLinux | systemd |

支持 `x86_64`、`ARM64` 和 `ARMv7` 硬浮点架构。LXC 需要运行 systemd 或 OpenRC；Realm 用户态转发不需要 TUN、`NET_ADMIN` 或内核 IP 转发权限。

NAT VPS 应填写容器内部端口。例如服务商提供 `公网:30001 → 容器:10001`，本机监听端口填写 `10001`，客户端连接公网端口 `30001`。上游端口映射必须包含所选协议；TCP+UDP 需要同时映射两种协议。

## 更新

更新 Realm 核心：

```sh
r --update
```

也可以在菜单选择 `[6] 更新 Realm`。更新过程保留配置并备份旧核心；新版无法运行时会自动恢复。

更新管理脚本：

```sh
r --update-script
```

也可以在菜单选择 `[7] 更新管理脚本`。新脚本下载后会先进行 Bash 语法检查，再原子替换 `/usr/local/bin/r`；按回车后自动重新加载新版菜单，已有规则和 Realm 服务不会改变。

## 卸载

在菜单选择 `[8] 一键卸载`，或者执行：

```sh
r --uninstall
```

确认后会停止服务、取消开机自启，并删除 Realm 核心、全部规则、备份、独立日志和 `r` 命令。卸载不会删除 Bash、curl 等系统共用依赖。

## 文件与日志

- 管理脚本：`/usr/local/bin/r`
- Realm 核心：`/root/realm/realm`
- 转发配置：`/root/realm/config.json`
- 最近备份：对应文件的 `.bak`

| 操作 | systemd | OpenRC |
| --- | --- | --- |
| 查看状态 | `systemctl status realm` | `rc-service realm status` |
| 查看日志 | `journalctl -u realm -n 50 --no-pager` | `tail -n 50 /var/log/realm.log` |
