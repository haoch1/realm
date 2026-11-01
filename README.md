# realm

Linux Realm 端口转发管理脚本，提供规则管理、服务控制、核心更新和卸载功能

管理脚本版本：`1.0.11`

## 功能

- TCP、UDP 和 TCP+UDP 转发；新增规则在支持 IPv6 的系统上默认双栈监听，在仅支持 IPv4 的系统上监听 IPv4
- 转发规则的添加、查看、修改、删除和清空
- systemd / OpenRC 服务管理及开机自启
- Realm 核心与管理脚本的独立更新
- 配置校验、事务备份和失败回滚

## 安装

适用于采用 systemd 或 OpenRC 的 Linux 系统，使用 `root` 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/realm/main/realm.sh -o /usr/local/bin/r || wget -q https://raw.githubusercontent.com/haoch1/realm/main/realm.sh -O /usr/local/bin/r) && chmod +x /usr/local/bin/r && r
```

管理命令为 `r`。打开菜单不会安装核心；首次添加规则、启动服务或执行核心更新时安装所需核心。缺少的脚本依赖由系统包管理器安装

## 管理菜单

| 编号 | 操作 |
| --- | --- |
| 1 | 添加转发规则 |
| 2 | 查看转发规则 |
| 3 | 修改转发规则 |
| 4 | 删除转发规则 |
| 5 | 清空所有转发规则 |
| 6 | 启动 Realm |
| 7 | 停止 Realm |
| 8 | 重启 Realm |
| 9 | 安装/更新 Realm |
| 10 | 更新管理脚本 |
| 11 | 一键卸载 |
| 0 | 退出脚本 |

核心更新完成后按回车返回菜单；管理脚本更新完成后按回车加载脚本。交互输入支持 `q` / `Q` 取消，删除和卸载确认支持 `Y` / `N`

## 文件路径

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/r` | 管理脚本 |
| `/root/realm/realm` | 托管核心 |
| `/root/realm/config.json` | 转发配置 |
| `/root/realm/realm.bak` | 核心备份 |
| `/root/realm/config.json.bak` | 配置备份 |
| `/etc/systemd/system/realm.service` | systemd 服务 |
| `/etc/init.d/realm` | OpenRC 服务 |
| `/var/log/realm.log` | OpenRC 日志 |
| `/run/lock/realm-manager.lock` | 管理锁 |

## 命令行

```sh
r                 # 打开管理菜单
r --update        # 安装或更新 Realm 核心
r --update-script # 更新管理脚本
r --version       # 显示管理脚本版本
r --uninstall     # 卸载托管服务、规则和管理脚本
```

## 卸载与维护

卸载前验证当前服务归属并停止服务，清理托管核心、配置、备份、回滚文件、当前 init 的服务及自启文件、独立日志、锁、临时文件和管理命令。清理失败时报告具体路径；管理目录中的未识别文件保留并提示。外部核心、其他项目文件及系统共享依赖保留

OpenRC 日志在脚本启动、服务启动和重启时检查：活动日志超过 10 MiB 时轮转，保留最近 5 MiB 及最多 3 份轮转文件。脚本启动时清理超过 24 小时的已知临时文件，配置与回滚备份不参与自动清理。systemd 日志由 journald 管理，卸载不清理共享 journal
