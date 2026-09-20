# realm

面向 Linux VPS 的轻量 Realm TCP/UDP 端口转发管理脚本，支持规则增删改查、服务管理、核心更新、脚本更新和一键卸载

当前管理脚本版本为 `1.4.1`

## 功能

- TCP、UDP 和 TCP+UDP 端口转发
- 转发规则增删改查和清空
- systemd、OpenRC 服务管理和开机自启
- Realm 核心手动安装与更新
- 管理脚本独立更新
- 配置校验、失败回滚和一键卸载
- Realm 风格单列菜单和统一更新提示

## 一键安装

使用 `root` 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/realm/main/realm.sh -o /usr/local/bin/r || wget -q https://raw.githubusercontent.com/haoch1/realm/main/realm.sh -O /usr/local/bin/r) && chmod +x /usr/local/bin/r && r
```

脚本安装到 `/usr/local/bin/r`，配置和核心使用 Realm 原项目路径。打开菜单不会自动下载核心；首次添加规则、启动服务或选择核心更新时才会安装或更新 Realm

## 管理菜单

```text
端口转发管理（当前规则：0 条）
Realm 状态：未安装
Realm 版本：未安装
管理脚本：v1.4.1

基础功能
[1]  添加转发规则
[2]  查看当前转发规则
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

操作完成后按回车返回主菜单。核心和管理脚本更新完成后也会先等待回车，管理脚本更新确认后才加载新版本。输入 `q` 可取消当前输入，清空规则和卸载确认使用 `(Y/N)`，输入 `Y/y` 确认，输入 `N/n` 或直接回车取消

核心更新结果统一显示为：

```text
[信息] 正在检查 Realm 核心更新
[信息] Realm 核心已是最新版本 vX.Y.Z
[成功] Realm 核心已更新至 vX.Y.Z
[错误] Realm 核心更新失败
```

管理脚本更新使用相同的检查中、已是最新、更新成功和更新失败格式

## 文件路径

| 文件 | 用途 |
| --- | --- |
| `/usr/local/bin/r` | 管理脚本命令 |
| `/root/realm/realm` | Realm 核心 |
| `/root/realm/config.json` | 转发规则配置 |
| `/etc/systemd/system/realm.service` | systemd 服务文件 |
| `/etc/init.d/realm` | OpenRC 服务文件 |
| `/var/log/realm.log` | OpenRC/direct 日志 |

## 命令行

```sh
r                 # 打开菜单
r --update        # 安装或更新 Realm 核心
r --update-script # 更新管理脚本
r --version       # 查看脚本版本
r --uninstall     # 卸载 Realm 和全部规则
```

一键卸载只清理 Realm 自身创建的服务、核心、配置、备份、日志、锁、临时文件和 `/usr/local/bin/r`
