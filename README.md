# realm

面向 Linux VPS 的轻量 Realm TCP/UDP 端口转发管理脚本，支持规则管理、服务管理和核心更新

当前管理脚本版本：`1.0.7`

## 功能

- TCP、UDP 和 TCP+UDP 端口转发
- 新增规则默认监听 IPv4 和 IPv6，旧的 `0.0.0.0:端口` 规则首次运行时自动迁移为 `[::]:端口`
- 添加、查看、修改、删除和清空转发规则
- 支持 systemd、OpenRC 服务管理及开机自启
- Realm 核心安装更新和管理脚本更新
- 配置校验、失败回滚和一键卸载
- OpenRC 文件日志按需轮转，启动时清理过期临时文件

## 安装

使用 `root` 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/realm/main/realm.sh -o /usr/local/bin/r || wget -q https://raw.githubusercontent.com/haoch1/realm/main/realm.sh -O /usr/local/bin/r) && chmod +x /usr/local/bin/r && r
```

脚本安装到 `/usr/local/bin/r`，配置和核心使用 `/root/realm`。打开菜单不会自动下载核心，首次添加规则、启动服务或选择核心更新时才会安装或更新 Realm

## 管理菜单

```text
端口转发管理（当前规则：0 条）
Realm 状态：未安装
Realm 版本：未安装
管理脚本：v1.0.7

基础功能
[1]  添加转发规则
[2]  查看转发规则
[3]  修改转发规则
[4]  删除转发规则
[5]  清空所有转发规则

服务管理
[6]  启动 Realm
[7]  停止 Realm
[8]  重启 Realm

更新与卸载
[9]  安装/更新 Realm
[10] 更新管理脚本
[11] 一键卸载

[0]  退出脚本
```

操作完成后按回车返回主菜单。核心和管理脚本更新完成后也会等待回车，输入 `q` 可取消当前输入，清空规则和卸载确认使用 `(Y/N)`

## 主要路径

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/r` | 管理脚本命令 |
| `/root/realm/realm` | Realm 核心 |
| `/root/realm/config.json` | 转发规则配置 |
| `/etc/systemd/system/realm.service` | systemd 服务文件 |
| `/etc/init.d/realm` | OpenRC 服务文件 |
| `/var/log/realm.log` | OpenRC 日志 |

## 命令行

```sh
r                 # 打开管理菜单
r --update        # 安装或更新 Realm 核心
r --update-script # 更新管理脚本
r --version       # 查看管理脚本版本
r --uninstall     # 卸载 Realm 和转发规则
```

一键卸载只清理 Realm 自身创建的服务、核心、配置、备份、日志、锁、临时文件和管理命令
