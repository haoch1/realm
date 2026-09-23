# Realm 管理脚本说明

## 定位

`realm.sh` 是面向 Linux VPS 的单文件 Realm TCP/UDP 转发管理脚本，负责规则配置、systemd/OpenRC 服务、Realm 核心更新、脚本更新及卸载。脚本在 POSIX 启动段完成 Bash 检测，随后由 Bash 执行完整管理逻辑。

## 行为边界

对外接口包括 `r`、`r --update`、`r --update-script`、`r --version` 和 `r --uninstall`，以及菜单中的规则和服务操作。配置文件仍为 `/root/realm/config.json`，规则字段、端口协议映射、服务单元路径、日志路径、退出码和错误处理保持现有行为。

脚本只管理 `/root/realm/realm`。检测到系统已有外部 Realm 核心或使用其他配置的服务时，不接管、不覆盖，也不在卸载时删除。

## 内部实现

临时文件清理将同一目录的文件名模式合并为一次 `find` 遍历，减少启动期间的目录扫描和进程创建；匹配模式、保留时间、删除方式和清理目录保持不变。服务就绪检查流式读取 `ss` 输出，在一次 `awk` 扫描中核对全部端口，避免将完整套接字列表复制到 Bash 变量。规则变更仍按备份、写入、服务验证、失败回滚的顺序执行，核心更新仍验证下载包、版本和 SHA256 摘要。

脚本不增加第三方运行时依赖，继续使用现有的 Bash、curl、jq、tar、sha256sum、timeout、flock、ss、pgrep 和 getent 等系统工具。

## 数据与服务策略

新增第一条规则时按原流程创建服务、开启自启并启动 Realm；删除全部规则时停止服务并关闭自启。systemd 日志由 journald 管理，OpenRC/direct 日志按既有阈值轮转。更新失败会尝试恢复旧核心、配置和服务状态，并保留必要的备份以便排查。
