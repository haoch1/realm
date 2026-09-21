#!/bin/sh
# Realm 端口转发管理。首次需要核心时安装最新版；r --update 安装或更新核心。

# POSIX 启动段：Alpine 没有 Bash 时先安装，再交给 Bash 运行。
install_packages() {
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash ca-certificates curl jq tar coreutils flock iproute2-ss procps musl-utils
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash ca-certificates curl jq tar coreutils util-linux iproute2 procps libc-bin
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bash ca-certificates curl jq tar coreutils util-linux iproute procps-ng glibc-common
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bash ca-certificates curl jq tar coreutils util-linux iproute procps-ng glibc-common
    else
        printf '无法识别包管理器，需要 apt-get、apk、dnf 或 yum\n' >&2
        return 1
    fi
}

if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        [ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] || {
            printf '请在 Linux 服务器上以 root 运行\n' >&2
            exit 1
        }
        install_packages || exit 1
    fi
    exec bash "$0" "$@"
fi

DIR=/root/realm
SCRIPT_VERSION=1.0.4
MANAGED_BIN=$DIR/realm
BIN=$MANAGED_BIN
SYSTEM_REALM=''
CONF=$DIR/config.json
UNIT=/etc/systemd/system/realm.service
INIT=systemd
RUNLEVEL=/etc/runlevels/default
RT=/usr/local/bin/r
LOG=/var/log/realm.log
LOG_MAX_BYTES=10485760
LOG_KEEP_BYTES=5242880
LOG_ROTATIONS=3
TEMP_RETENTION_MINUTES=1440
LOCK=/run/lock/realm-manager.lock
API=https://api.github.com/repos/zhboner/realm/releases/latest
SCRIPT_URL=https://raw.githubusercontent.com/haoch1/realm/main/realm.sh
BLUE=$'\033[1;36m' GREEN=$'\033[0;32m' RED=$'\033[0;31m' YELLOW=$'\033[0;33m' NC=$'\033[0m'
# Endpoint 的非空设置覆盖全局值；显式 false 也必须保留。
JQ_PROTOCOL='def protocol($global):
    ($global + ((.network // {}) | with_entries(select(.value != null)))) as $n
    | if $n.no_tcp == true then (if $n.use_udp == true then "udp" else "" end)
      elif $n.use_udp == true then "tcp+udp" else "tcp" end;'

fail() { printf '  %s[错误] %s%s\n' "$RED" "$*" "$NC" >&2; return 1; }
info() { printf '  %s[信息] %s%s\n' "$BLUE" "$*" "$NC"; }
warn() { printf '  %s[注意] %s%s\n' "$YELLOW" "$*" "$NC"; }
success() { printf '  %s[成功] %s%s\n' "$GREEN" "$*" "$NC"; }
interrupt_exit() { printf '\n'; exit 130; }

clear_terminal() {
    [[ -t 1 ]] || return 0
    command -v clear >/dev/null 2>&1 && clear 2>/dev/null || true
    printf '\033[3J\033[2J\033[H\033[0m'
}

file_size_bytes() {
    local file=$1 size
    size=$(stat -c '%s' "$file" 2>/dev/null || true)
    if [[ $size =~ ^[0-9]+$ ]]; then
        printf '%s' "$size"
    else
        wc -c < "$file" 2>/dev/null | tr -d '[:space:]' || printf '0'
    fi
}

rotate_file_log() {
    local file=$1 size temp index
    [[ -f $file ]] || return 0
    size=$(file_size_bytes "$file")
    [[ $size =~ ^[0-9]+$ ]] || return 0
    (( size > LOG_MAX_BYTES )) || return 0
    rm -f -- "$file.$((LOG_ROTATIONS + 1))"
    for (( index=LOG_ROTATIONS; index > 1; index-- )); do
        [[ -e "$file.$((index - 1))" ]] && mv -f -- "$file.$((index - 1))" "$file.$index" 2>/dev/null || true
    done
    cp -p -- "$file" "$file.1" 2>/dev/null || return 0
    temp=$(mktemp "${file}.trim.XXXXXX") || return 0
    if tail -c "$LOG_KEEP_BYTES" "$file" > "$temp" 2>/dev/null && cat "$temp" > "$file"; then
        chmod 640 "$file" 2>/dev/null || true
    fi
    rm -f -- "$temp"
}

cleanup_stale_temp_files() {
    local directory=$1 pattern
    shift
    [[ -d $directory ]] || return 0
    for pattern in "$@"; do
        find "$directory" -mindepth 1 -maxdepth 1 -name "$pattern" -mmin +"$TEMP_RETENTION_MINUTES" -exec rm -rf -- {} + 2>/dev/null || true
    done
}

maintenance_cleanup() {
    [[ $INIT == systemd ]] || rotate_file_log "$LOG"
    cleanup_stale_temp_files "$DIR" '.download.*' '.change.*' '.rules.*'
    cleanup_stale_temp_files "${RT%/*}" '.realm-manager.*'
}

read_input() {
    local destination=$1 prompt=$2 reply='' status=0
    read -r -p "$prompt" reply || status=$?
    (( status == 130 )) && return 130
    if (( status != 0 )); then
        INPUT_EOF=1
        return "$status"
    fi
    if [[ $reply == [qQ] ]]; then
        MENU_CANCELLED=1
        return 1
    fi
    printf -v "$destination" '%s' "$reply"
}
pause_enter() {
    local prompt=${1:-'  按回车返回主菜单...'} status=0
    read -r -p "$prompt" _ || status=$?
    (( status == 130 )) && interrupt_exit
    (( status != 0 )) && INPUT_EOF=1
    return 0
}
get() { curl -fLsS --retry 2 --connect-timeout 15 --max-time 180 --proto '=https' --proto-redir '=https' "$1" -o "$2"; } 9>&-
version() {
    local output
    output=$(timeout 10 "$1" --version 2>&1) || { printf '%s\n' "$output" >&2; return 1; }
    if [[ $output =~ ^[Rr]ealm[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '无法识别版本输出：%s\n' "$output" >&2
        return 1
    fi
}

configured_core() {
    local path=''
    if [[ $INIT == systemd && -f $UNIT ]]; then
        path=$(awk '/^ExecStart=/{sub(/^ExecStart=/, ""); sub(/[[:space:]].*$/, ""); print; exit}' "$UNIT")
    elif [[ $INIT == openrc && -f $UNIT ]]; then
        path=$(awk -F'"' '/^command=/{print $2; exit}' "$UNIT")
    fi
    [[ $path == /* && -x $path ]] || return 1
    printf '%s\n' "$path"
}

service_command() {
    local command=''
    if [[ $INIT == systemd ]]; then
        if [[ -f $UNIT ]]; then
            command=$(awk '/^ExecStart=/{sub(/^ExecStart=/, ""); print; exit}' "$UNIT")
        else
            command=$(systemctl show realm -p ExecStart --value 2>/dev/null || true)
        fi
    elif [[ -f $UNIT ]]; then
        local path args
        path=$(awk -F'"' '/^command=/{print $2; exit}' "$UNIT")
        args=$(awk -F'"' '/^command_args=/{print $2; exit}' "$UNIT")
        [[ -n $path ]] && command="$path${args:+ $args}"
    fi
    printf '%s\n' "$command"
}

service_config_path() {
    local command=$1 path=''
    if [[ $command =~ (^|[[:space:]])-c[[:space:]]+([^[:space:];]+) ]]; then
        path=${BASH_REMATCH[2]}
    fi
    printf '%s\n' "$path"
}

foreign_service() {
    local command=$1 path
    path=$(service_config_path "$command")
    if [[ -n $path && $path != "$CONF" ]]; then
        fail '检测到现有 Realm 服务使用其他配置文件：'
        printf '  %s\n' "$path"
    else
        fail '检测到现有 Realm 服务使用外部 Realm 核心或其他启动方式'
        printf '  配置文件：%s\n' "${path:-未识别}"
    fi
    printf '  为避免覆盖现有转发规则，本脚本不会自动接管\n'
    return 1
}

resolve_core() {
    local candidate discovered=''
    BIN=$MANAGED_BIN
    SYSTEM_REALM=''
    [[ -x $BIN ]] && return 0
    if discovered=$(configured_core 2>/dev/null); then
        [[ $discovered != "$MANAGED_BIN" && -x $discovered ]] && SYSTEM_REALM=$discovered
    fi
    if [[ -z $SYSTEM_REALM ]] && discovered=$(command -v realm 2>/dev/null); then
        [[ $discovered != "$MANAGED_BIN" && $discovered == /* && -x $discovered ]] && SYSTEM_REALM=$discovered
    fi
    for candidate in /usr/local/bin/realm /usr/bin/realm /usr/local/sbin/realm /usr/sbin/realm; do
        [[ -n $SYSTEM_REALM ]] && break
        [[ $candidate != "$MANAGED_BIN" && -x $candidate ]] && SYSTEM_REALM=$candidate
    done
    return 1
}

dependencies() {
    local cmd missing=0
    local -a required=(curl jq tar sha256sum timeout flock ss pgrep getent)
    for cmd in "${required[@]}"; do command -v "$cmd" >/dev/null || missing=1; done
    (( missing )) || return 0
    install_packages || return 1
    for cmd in "${required[@]}"; do command -v "$cmd" >/dev/null || return 1; done
}

is_manager_pid() {
    local pid=$1 interpreter script
    [[ -r /proc/$pid/cmdline ]] || return 1
    { IFS= read -r -d '' interpreter && IFS= read -r -d '' script; } < "/proc/$pid/cmdline" || return 1
    [[ ${interpreter##*/} == bash || ${interpreter##*/} == sh ]] || return 1
    [[ $script == "$RT" || ${script##*/} == realm.sh ]] || return 1
    [[ /proc/$pid/fd/9 -ef $LOCK ]] || return 1
    grep -q '^lock:.* FLOCK ' "/proc/$pid/fdinfo/9" 2>/dev/null
}

lock_holder_pid() {
    local pid fd
    pid=$(cat "$LOCK" 2>/dev/null) || pid=''
    if [[ $pid =~ ^[1-9][0-9]*$ ]] && (( pid != $$ )) && kill -0 "$pid" 2>/dev/null && is_manager_pid "$pid"; then
        printf '%s\n' "$pid"
        return 0
    fi

    # fdinfo 属于持锁的文件描述符，可排除只打开了锁文件的等待进程。
    for fd in /proc/[0-9]*/fd/9; do
        [[ $fd -ef $LOCK ]] || continue
        pid=${fd#/proc/}
        pid=${pid%%/*}
        [[ $pid =~ ^[1-9][0-9]*$ ]] && (( pid != $$ )) && is_manager_pid "$pid" || continue
        printf '%s\n' "$pid"
        return 0
    done
    return 1
}

stop_manager() {
    local pid=$1 child
    local -a children=()
    # 旧版输入辅助进程也可能持锁；仅通知同一脚本的 Bash/sh，不终止服务进程。
    if [[ -r /proc/$pid/task/$pid/children ]]; then
        read -r -a children < "/proc/$pid/task/$pid/children" || true
    fi
    for child in "${children[@]}"; do
        if is_manager_pid "$child"; then stop_manager "$child"; fi
    done
    kill -TERM "$pid" 2>/dev/null || true
}

acquire_lock() {
    local holder attempt
    exec 9>>"$LOCK" || { fail '无法打开管理锁'; return 1; }
    if flock -n 9; then
        printf '%s\n' "$$" > "$LOCK"
        return 0
    fi

    holder=$(lock_holder_pid 2>/dev/null) || holder=''
    if [[ $holder =~ ^[1-9][0-9]*$ ]] && kill -0 "$holder" 2>/dev/null && is_manager_pid "$holder"; then
        info '检测到旧的管理界面，正在自动接管...'
        stop_manager "$holder"
        for (( attempt=0; attempt<50; attempt++ )); do
            if flock -n 9; then
                printf '%s\n' "$$" > "$LOCK"
                success '已关闭旧管理界面'
                return 0
            fi
            sleep 0.1
        done
        fail "旧管理脚本仍在执行操作，请稍后重试（PID: $holder）"
        return 1
    fi

    fail "管理锁被其他进程占用${holder:+（PID: $holder）}，请稍后重试"
}

detect_init() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
        INIT=systemd; UNIT=/etc/systemd/system/realm.service
    elif command -v rc-service >/dev/null && command -v rc-update >/dev/null && command -v supervise-daemon >/dev/null; then
        INIT=openrc; UNIT=/etc/init.d/realm
    else
        fail '需要 systemd 或 OpenRC；无 init 的容器请先配置服务管理'; return 1
    fi
}

# 只抽象必要的服务动作；转发不使用 nftables、IP forwarding 或特权网络接口。
svc() {
    case "$1" in
        start|restart) [[ $INIT == systemd ]] || rotate_file_log "$LOG" ;;
    esac
    if [[ $INIT == systemd ]]; then
        case "$1" in
            active) systemctl is-active --quiet realm ;;
            enabled) systemctl is-enabled --quiet realm ;;
            pid) systemctl show realm -p MainPID --value ;;
            reload) systemctl daemon-reload ;;
            reset) systemctl reset-failed realm ;;
            *) systemctl "$1" realm ;;
        esac
    else
        case "$1" in
            active) rc-service realm status >/dev/null 2>&1 ;;
            enabled) [[ -e $RUNLEVEL/realm ]] ;;
            pid) pgrep -f -x "$BIN -c ${CONF//./\\.}" ;;
            enable) rc-update add realm default ;;
            disable) rc-update del realm default ;;
            reload|reset) : ;;
            *) rc-service realm "$1" ;;
        esac
    fi
} 9>&-

check_service() {
    local path command config_path
    if [[ $INIT == openrc ]]; then
        [[ ! -f $UNIT ]] && return 0
        command=$(service_command)
        [[ "$command" == "$MANAGED_BIN -c $CONF" ]] || {
            foreign_service "$command"
            return 1
        }
        return 0
    fi
    path=$(systemctl show realm -p FragmentPath --value 2>/dev/null) || return 1
    [[ -z $path ]] && return 0
    command=$(service_command)
    config_path=$(service_config_path "$command")
    if [[ $path == "$UNIT" && "$command" == "$MANAGED_BIN -c $CONF" ]]; then
        return 0
    fi
    if [[ -n $config_path ]]; then
        foreign_service "$command"
    else
        fail '检测到现有 Realm 服务，但无法确认其配置文件，本脚本不会自动接管'
    fi
    return 1
}

write_unit() {
    if [[ $INIT == openrc ]]; then
        cat > "$UNIT" <<EOF
#!/sbin/openrc-run
description="Realm port forwarding"
command="$BIN"
command_args="-c $CONF"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
output_log="$LOG"
error_log="$LOG"
depend() {
    use net
}
EOF
        chmod 755 "$UNIT"
        return
    fi
    cat > "$UNIT" <<EOF
[Unit]
Description=Realm port forwarding
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$BIN -c $CONF
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$UNIT" && svc reload
}

init_config() {
    if [[ -f $CONF ]]; then
        jq -e '
            def network_ok:
                . == null or (type == "object" and
                    all(.no_tcp, .use_udp; . == null or type == "boolean"));
            type == "object" and (.network | network_ok) and
            (.endpoints | type == "array" and all(.[];
                type == "object" and (.listen | type == "string") and
                (.remote | type == "string") and (.network | network_ok) and
                (.name == null or (.name | type == "string"))))
        ' "$CONF" >/dev/null || { fail '配置文件格式无效，请检查 /root/realm/config.json'; return 1; }
        return 0
    fi
    printf '{"endpoints":[]}\n' > "$CONF"
}

select_asset() {
    local json=$1 arch=$2 target release
    case "$arch" in
        x86_64|amd64) target=x86_64-unknown-linux-musl ;;
        aarch64|arm64) target=aarch64-unknown-linux-musl ;;
        armv7l|armv7) target=armv7-unknown-linux-musleabihf ;;
        *) fail "暂不支持架构：$arch"; return 1 ;;
    esac
    local name="realm-$target.tar.gz"
    release=$(jq -er --arg name "$name" '
        select(.draft == false and .prerelease == false) | .tag_name as $tag
        | .assets[] | select(.name == $name)
        | [$tag, .browser_download_url, .digest] | @tsv' "$json") || return 1
    [[ $release != *$'\n'* ]] || { fail '安装包信息重复'; return 1; }
    IFS=$'\t' read -r TAG URL HASH <<< "$release"
    [[ $TAG =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail '无法识别稳定版标签'; return 1; }
    [[ $URL == "https://github.com/zhboner/realm/releases/download/$TAG/$name" && $HASH =~ ^sha256:[a-f0-9]{64}$ ]] || {
        fail '安装包地址或 SHA256 摘要无效'; return 1;
    }
}

ready() {
    local attempt pid sockets expected proto found port
    expected=$(jq -r "$JQ_PROTOCOL"'
        .network as $g | .endpoints[] | .listen as $listen
        | protocol($g) | if length==0 then error("规则未启用 TCP 或 UDP") else split("+")[] end
        | [., ($listen | split(":") | last)] | @tsv' "$CONF") || return 1
    for attempt in 1 2 3 4 5; do
        sleep 0.4
        svc active || continue
        pid=$(svc pid) || continue
        [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
        sockets=$(ss -H -lntup) || continue
        found=1
        while IFS=$'\t' read -r proto port; do
            [[ -n $proto ]] || continue
            if ! awk -v proto="$proto" -v port="$port" -v pid="pid=$pid," \
                '$1==proto && $5 ~ (":" port "$") && index($0,pid) {ok=1} END {exit !ok}' <<< "$sockets"; then found=0; break; fi
        done <<< "$expected"
        (( found )) && return 0
    done
    fail 'Realm 启动失败或端口未监听。systemd 查看 journalctl -u realm；OpenRC 查看 /var/log/realm.log'
}

service_state() {
    local result=$1 value
    resolve_core >/dev/null 2>&1 || true
    if [[ ! -x $BIN ]]; then
        value='未安装'
    elif svc active 2>/dev/null; then
        value='运行中'
    else
        value='已停止'
    fi
    printf -v "$result" '%s' "$value"
}

core_version() {
    local result=$1 value external_version
    resolve_core >/dev/null 2>&1 || true
    if [[ ! -x $BIN ]]; then
        if [[ -n $SYSTEM_REALM ]] && external_version=$(version "$SYSTEM_REALM" 2>/dev/null); then
            value="外部 v$external_version"
        else
            value='未安装'
        fi
    elif value=$(version "$BIN" 2>/dev/null); then
        value="v$value"
    else
        value='未知'
    fi
    printf -v "$result" '%s' "$value"
}

ensure_core() {
    resolve_core >/dev/null 2>&1 || true
    if [[ -x $BIN ]] && version "$BIN" >/dev/null 2>&1; then
        return 0
    fi
    update_realm_action || return 1
    resolve_core >/dev/null 2>&1 || true
    [[ -x $BIN ]] && version "$BIN" >/dev/null 2>&1 || {
        fail 'Realm 核心安装失败'
        return 1
    }
}

rule_count() {
    jq -er '.endpoints | length' "$CONF"
}

start_realm() {
    local count was_enabled=0
    count=$(rule_count) || return 1
    (( count )) || { warn '暂无转发规则，无法启动 Realm'; return 1; }
    ensure_core || return 1
    svc enabled 2>/dev/null && was_enabled=1
    if [[ ! -f $UNIT ]]; then
        write_unit || { fail 'Realm 服务配置创建失败'; return 1; }
    fi
    if ! (( was_enabled )); then
        svc enable >/dev/null 2>&1 || { fail 'Realm 开机自启设置失败'; return 1; }
    fi
    if svc active 2>/dev/null; then
        success 'Realm 已在运行，开机自启已开启'
        return 0
    fi
    if svc start >/dev/null 2>&1 && ready; then
        success 'Realm 已启动，开机自启已开启'
        return 0
    fi
    (( was_enabled )) || svc disable >/dev/null 2>&1 || true
    fail 'Realm 启动失败，已恢复原开机自启状态'
    return 1
}

stop_realm() {
    local active=0 enabled=0
    svc active 2>/dev/null && active=1
    svc enabled 2>/dev/null && enabled=1
    if (( !active && !enabled )); then
        info 'Realm 已停止，且开机自启未开启'
        return 0
    fi
    if (( active )) && ! svc stop >/dev/null 2>&1; then
        fail 'Realm 停止失败，开机自启保持不变'
        return 1
    fi
    if (( enabled )) && ! svc disable >/dev/null 2>&1; then
        fail 'Realm 已停止，但取消开机自启失败'
        return 1
    fi
    if svc active 2>/dev/null || svc enabled 2>/dev/null; then
        fail 'Realm 状态未完全停止，请稍后检查'
        return 1
    fi
    success 'Realm 已停止，开机自启已关闭'
}

restart_realm() {
    local count
    count=$(rule_count) || return 1
    (( count )) || { warn '暂无转发规则，无法重启 Realm'; return 1; }
    ensure_core || return 1
    if [[ ! -f $UNIT ]]; then
        write_unit || { fail 'Realm 服务配置创建失败'; return 1; }
    fi
    svc enable >/dev/null 2>&1 || { fail 'Realm 开机自启设置失败，未执行重启'; return 1; }
    if svc restart >/dev/null 2>&1 && ready; then
        success 'Realm 已重启，开机自启已开启'
        return 0
    fi
    fail 'Realm 重启失败，请检查服务日志'
    return 1
}

update_realm() (
    local temp active=0 replaced=0 had=0 status interrupted=0 sum member current
    resolve_core >/dev/null 2>&1 || true
    temp=$(mktemp -d "$DIR/.download.XXXXXX") || exit 1
    cleanup() {
        status=$?
        (( status == 130 )) && interrupted=1
        trap - EXIT
        trap '' INT TERM HUP
        if (( replaced )); then
            svc stop >/dev/null 2>&1 || true
            if (( had )); then
                cp -p "$temp/old" "$BIN.restore" && mv -f "$BIN.restore" "$BIN" || fail '恢复旧程序失败'
            else rm -f "$BIN"; fi
            if (( active )); then
                svc reset >/dev/null 2>&1 || true
                svc restart && ready || fail '旧程序恢复后未能启动'
            fi
            fail '升级未成功，已尝试恢复原程序'
            (( interrupted )) || status=1
        fi
        rm -rf -- "$temp"
        exit "$status"
    }
    trap cleanup EXIT
    trap interrupt_exit INT
    trap 'exit 143' TERM HUP
    info '正在检查 Realm 核心更新'
    get "$API" "$temp/release.json" && select_asset "$temp/release.json" "$(uname -m)" || {
        fail '获取最新版本失败，请检查 GitHub 访问或 API 限流'; exit 1;
    }
    current=$(version "$BIN" 2>/dev/null) || current=''
    [[ $current != "${TAG#v}" ]] || { info "Realm 核心已是最新版本 $TAG"; exit 0; }
    get "$URL" "$temp/package.tar.gz" || exit 1
    sum=$(sha256sum "$temp/package.tar.gz") || exit 1
    [[ ${sum%% *} == "${HASH#sha256:}" ]] || { fail 'SHA256 校验失败'; exit 1; }
    tar -tzf "$temp/package.tar.gz" > "$temp/files" || exit 1
    member=$(awk '/(^|\/)realm$/ {print}' "$temp/files")
    [[ -n $member && $member != *$'\n'* && $member != /* && $member != *'..'* ]] || exit 1
    tar -xOzf "$temp/package.tar.gz" -- "$member" > "$temp/realm" && chmod 755 "$temp/realm" || exit 1
    current=$(version "$temp/realm" 2> "$temp/version.error") || {
        fail "新版程序无法执行或无法读取版本（架构：$(uname -m)）"
        cat "$temp/version.error" >&2
        exit 1
    }
    [[ $current == "${TAG#v}" ]] || { fail "版本不匹配：期望 ${TAG#v}，实际 $current"; exit 1; }
    if [[ -f $BIN ]]; then
        cp -p "$BIN" "$temp/old" || exit 1
        if [[ $BIN == "$MANAGED_BIN" ]]; then cp -p "$BIN" "$BIN.bak" || exit 1; fi
        had=1
    fi
    if svc active; then active=1; fi
    replaced=1
    mkdir -p "${BIN%/*}" && mv -f "$temp/realm" "$BIN" || exit 1
    if (( active )); then svc restart && ready || exit 1; fi
    replaced=0
    success "Realm 核心已更新至 $TAG"
)

update_realm_action() {
    update_realm || { fail 'Realm 核心更新失败'; return 1; }
}

update_script() (
    local temp first_line new_hash old_hash new_version
    temp=$(mktemp "${RT%/*}/.realm-manager.XXXXXX") || exit 1
    trap 'rm -f -- "$temp"' EXIT
    trap interrupt_exit INT
    trap 'exit 143' TERM HUP
    info '正在检查管理脚本更新'
    get "${SCRIPT_URL}?v=$$-$RANDOM" "$temp" || { fail '管理脚本下载失败，请检查 GitHub 连接'; exit 1; }
    IFS= read -r first_line < "$temp" || true
    [[ $first_line == '#!/bin/sh' ]] || { fail '下载内容不是有效的管理脚本'; exit 1; }
    bash -n "$temp" || { fail '新版管理脚本语法检查失败，未替换当前版本'; exit 1; }
    new_version=$(sed -n 's/^SCRIPT_VERSION=\([0-9][0-9.]*\)$/\1/p' "$temp")
    [[ $new_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail '新版管理脚本缺少有效版本号'; exit 1; }
    if [[ -f $RT ]]; then
        new_hash=$(sha256sum "$temp") || exit 1
        old_hash=$(sha256sum "$RT") || exit 1
        if [[ ${new_hash%% *} == "${old_hash%% *}" ]]; then
            info "管理脚本已是最新版本 v$new_version"
            exit 0
        fi
    fi
    chmod 755 "$temp" && mv -f "$temp" "$RT" || { fail '管理脚本替换失败'; exit 1; }
    trap - EXIT INT TERM HUP
    success "管理脚本已更新至 v$new_version"
)

update_management_script() {
    update_script || { fail '管理脚本更新失败'; return 1; }
}

reload_script() {
    trap - INT TERM HUP
    exec 9>&-
    exec bash "$RT"
    fail '无法重新加载管理脚本，请重新运行 r'
}

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 > 0 && 10#$1 < 65536 )); }

valid_ipv4() {
    local octet
    local -a octets
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$1"
    for octet in "${octets[@]}"; do
        [[ $octet == 0 || $octet != 0* ]] && (( 10#$octet <= 255 )) || return 1
    done
}

valid_ipv6() {
    local address=$1 group compressed=0
    local -a groups=()
    if [[ $address == *.* ]]; then
        valid_ipv4 "${address##*:}" || return 1
        address="${address%:*}:0:0"
    fi
    [[ $address =~ ^[a-fA-F0-9:]+$ && $address != *:::* ]] || return 1
    if [[ $address == *::* ]]; then
        [[ ${address#*::} != *::* ]] || return 1
        compressed=1
        address=${address/::/:}
        address=${address#:}; address=${address%:}
    else
        [[ $address != :* && $address != *: ]] || return 1
    fi
    [[ -z $address ]] || IFS=: read -r -a groups <<< "$address"
    for group in "${groups[@]}"; do [[ $group =~ ^[a-fA-F0-9]{1,4}$ ]] || return 1; done
    if (( compressed )); then (( ${#groups[@]} < 8 )); else (( ${#groups[@]} == 8 )); fi
}

valid_host() {
    local host=${1%.} label
    local -a labels
    [[ ${#host} -ge 1 && ${#host} -le 253 && $host != .* && $host != *. && $host != *..* ]] || return 1
    if [[ $1 == *.* && $1 =~ ^[0-9.]+$ ]]; then valid_ipv4 "$1"; return; fi
    IFS=. read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

remote_address() {
    local host=$1 port=$2
    valid_port "$port" || { fail '目标端口应为 1–65535'; return 1; }
    if [[ $host == \[*\] ]]; then
        host=${host:1:${#host}-2}
        [[ $host == *:* ]] || { fail 'IPv6 地址无效'; return 1; }
    fi
    if [[ $host == *:* ]]; then
        valid_ipv6 "$host" || { fail 'IPv6 地址无效'; return 1; }
        printf '[%s]:%d\n' "$host" "$((10#$port))"
    else
        valid_host "$host" || { fail '请输入有效的 IP 或域名，不要带协议、路径或空白'; return 1; }
        printf '%s:%d\n' "$host" "$((10#$port))"
    fi
}

show_resolution() {
    local host=$1 output address resolved='' family=''
    [[ $host != *:* ]] && ! valid_ipv4 "$host" || return 0
    output=$(timeout 5 getent ahosts "$host" 9>&- 2>/dev/null) || output=''
    while read -r address _; do
        if valid_ipv4 "$address"; then
            resolved=$address; family=ipv4; break
        elif [[ -z $resolved ]] && valid_ipv6 "$address"; then
            resolved=$address; family=ipv6
        fi
    done <<< "$output"
    if [[ -n $resolved ]]; then
        success "域名已解析: $host -> $resolved ($family)"
    else
        warn "域名解析失败: $host，暂未获取到可用的 IP，可继续保存"
    fi
}

apply_rules() (
    local candidate=$1 temp active=0 had_unit=0 changed=0 enabled=0 status interrupted=0 count
    temp=$(mktemp -d "$DIR/.change.XXXXXX") || exit 1
    if svc active 2>/dev/null; then active=1; fi
    if svc enabled 2>/dev/null; then enabled=1; fi
    rollback() {
        status=$?
        (( status == 130 )) && interrupted=1
        trap - EXIT
        trap '' INT TERM HUP
        if (( changed )); then
            svc stop >/dev/null 2>&1 || true
            if (( enabled == 0 )); then svc disable >/dev/null 2>&1 || true; fi
            cp -p "$temp/config" "$CONF" || fail '恢复旧配置失败'
            if (( had_unit )); then cp -p "$temp/unit" "$UNIT"; else rm -f "$UNIT"; fi
            svc reload >/dev/null 2>&1 || true
            if (( enabled )); then svc enable >/dev/null 2>&1 || true; fi
            if (( active )); then
                svc reset >/dev/null 2>&1 || true
                svc restart >/dev/null 2>&1 && ready || fail '恢复旧服务失败'
            fi
            fail '修改未生效，已尝试恢复原规则'
            (( interrupted )) || status=1
        fi
        rm -rf -- "$temp"
        exit "$status"
    }
    trap rollback EXIT
    trap interrupt_exit INT
    trap 'exit 143' TERM HUP
    count=$(jq -er '.endpoints | length' "$candidate") || exit 1
    cp -p "$CONF" "$temp/config" && cp -p "$CONF" "$CONF.bak" || exit 1
    if [[ -f $UNIT ]]; then cp -p "$UNIT" "$temp/unit" || exit 1; had_unit=1; fi
    if (( count )); then
        ensure_core
        status=$?
        (( status == 130 )) && exit 130
        (( status == 0 )) || exit 1
    fi
    changed=1
    chmod 600 "$candidate" && mv -f "$candidate" "$CONF" || exit 1
    if (( count )); then
        write_unit || exit 1
        if (( active )); then
            svc restart >/dev/null 2>&1 && ready || exit 1
        fi
    elif (( had_unit )); then
        if (( active )); then svc stop >/dev/null 2>&1 || exit 1; fi
        if (( enabled )); then svc disable >/dev/null 2>&1 || exit 1; fi
    fi
    changed=0
)

print_rules() {
    local index name listen remote protocol port
    while IFS=$'\t' read -r index name listen remote protocol; do
        port=${listen##*:}
        printf '  %s[%s]%s 【%s】 本机 :%s%s%s → %s%s%s  %s[%s]%s\n' \
            "$GREEN" "$index" "$NC" "$name" "$BLUE" "$port" "$NC" \
            "$BLUE" "$remote" "$NC" "$YELLOW" "$protocol" "$NC"
    done < <(jq -r "$JQ_PROTOCOL"'
        .network as $g | .endpoints | to_entries[]
        | .value as $v | ($v | protocol($g) | ascii_upcase) as $proto
        | ($v.name // ("转发规则-" + ($v.listen | split(":") | last))) as $name
        | [(.key+1), $name, $v.listen, $v.remote, $proto] | @tsv' "$CONF")
}

view_rules() {
    local count
    count=$(jq '.endpoints|length' "$CONF") || return 1
    printf '\n'
    info '=== 当前端口转发规则 ==='
    printf '\n'
    if (( count == 0 )); then warn '暂无转发规则'; return; fi
    print_rules
    printf '\n  共 %s%s%s 条转发规则\n' "$GREEN" "$count" "$NC"
}

choose_rule() {
    local result=$1 action=${2:-选择} n count
    count=$(jq '.endpoints|length' "$CONF") || return 1
    printf '\n' >&2
    info "=== ${action}端口转发规则 ===" >&2
    printf '\n' >&2
    (( count )) || { warn '暂无转发规则' >&2; return 1; }
    print_rules >&2
    printf '\n' >&2
    read_input n "  请输入要${action}的序号 (0 取消): " || return 1
    [[ -n $n && $n != 0 ]] || { MENU_CANCELLED=1; return 1; }
    [[ $n =~ ^[0-9]{1,6}$ ]] && (( 10#$n > 0 && 10#$n <= count )) || { fail '无效选择'; return 1; }
    printf -v "$result" '%d' "$((10#$n-1))"
}

save_rule() {
    local index=$1 port=$2 host=$3 target=$4 protocol=${5:-tcp} name=${6:-}
    local remote current='' old_protocol='' temp proto flag sockets pid=''
    case "$protocol" in tcp|udp|tcp+udp) ;; *) fail '请选择 TCP、UDP 或 TCP+UDP'; return 1 ;; esac
    valid_port "$port" || { fail '监听端口应为 1–65535'; return 1; }
    port=$((10#$port))
    name=${name:-转发规则-$port}
    [[ ${#name} -le 60 && ! $name =~ [[:cntrl:]] ]] || { fail '备注限 60 字，不能包含控制字符'; return 1; }
    remote=$(remote_address "$host" "$target") || return 1
    if jq -e --argjson i "$index" --arg p "$port" --arg proto "$protocol" "$JQ_PROTOCOL"'
        .network as $g | .endpoints | to_entries | any(
            .key != $i and (.value.listen | split(":") | last)==$p
            and ((.value | protocol($g)) as $old | $old==$proto or $old=="tcp+udp" or $proto=="tcp+udp"))' "$CONF" >/dev/null; then
        fail "${protocol^^} 端口 $port 已有转发规则"; return 1
    else
        [[ $? == 1 ]] || return 1
    fi
    if (( index >= 0 )); then
        current=$(jq -r --argjson i "$index" '.endpoints[$i].listen' "$CONF") || return 1
        old_protocol=$(jq -r --argjson i "$index" "$JQ_PROTOCOL"'
            .network as $g | .endpoints[$i] | protocol($g)' "$CONF") || return 1
        if svc active; then pid=$(svc pid) || pid=''; fi
    fi
    for proto in tcp udp; do
        [[ $protocol == "$proto" || $protocol == tcp+udp ]] || continue
        flag=-ltnp; [[ $proto != udp ]] || flag=-uanp
        sockets=$(ss -H "$flag" "sport = :$port") || { fail '无法检查端口占用'; return 1; }
        [[ -n $sockets ]] || continue
        if [[ ${current##*:} == "$port" && ($old_protocol == "$proto" || $old_protocol == tcp+udp) && $pid =~ ^[1-9][0-9]*$ ]] &&
            awk -v pid="pid=$pid," '!index($0,pid) {bad=1} END {exit bad}' <<< "$sockets"; then continue; fi
        fail "${proto^^} 端口 $port 已被占用"; return 1
    done
    temp=$(mktemp "$DIR/.rules.XXXXXX") || return 1
    trap 'rm -f -- "$temp"; interrupt_exit' INT
    # 保留已有规则的监听地址；新规则默认 IPv4 全接口。
    local listen="${current%:*}:$port"
    [[ -n $current ]] || listen="0.0.0.0:$port"
    jq --argjson i "$index" --arg l "$listen" --arg r "$remote" --arg proto "$protocol" --arg name "$name" '
        {listen:$l,remote:$r,name:$name} as $rule
        | {no_tcp:($proto=="udp"),use_udp:($proto!="tcp")} as $net
        | if $i<0 then .endpoints += [$rule + {network:$net}]
          else .endpoints[$i] |= (. + $rule | .network = ((.network // {}) + $net)) end' "$CONF" > "$temp" && apply_rules "$temp"
    local status=$?
    trap interrupt_exit INT
    rm -f "$temp"
    if (( status == 0 )); then
        if (( index < 0 )); then
            success '端口转发规则已添加并生效'
        else
            success '转发规则已修改并生效'
        fi
        printf '  转发模式: %s%s%s\n' "$GREEN" "${protocol^^}" "$NC"
        printf '  【%s】 本机端口: %s%s%s → 目标: %s%s%s\n' \
            "$name" "$GREEN" "$port" "$NC" "$GREEN" "$remote" "$NC"
    fi
    return "$status"
}

read_port() {
    local result=$1 label=$2 previous=${3:-} input
    while true; do
        read_input input "  ${label}${previous:+ (回车保持 $previous)}: " || return 1
        input=${input:-$previous}
        if valid_port "$input"; then printf -v "$result" '%d' "$((10#$input))"; return; fi
        fail '无效端口，请输入 1–65535 之间的数字'
    done
}

choose_protocol() {
    local result=$1 current=${2:-} choice selected prompt='  请选择 [1-3] (默认 1): '
    printf '\n  %s请选择转发协议：%s\n' "$BLUE" "$NC" >&2
    printf '    %s[1]%s 仅 TCP\n    %s[2]%s 仅 UDP\n    %s[3]%s TCP+UDP\n' "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" >&2
    if [[ -n $current ]]; then
        printf '    %s[0]%s 保持 %s\n' "$GREEN" "$NC" "${current^^}" >&2
        prompt='  请选择 [0-3] (回车不改): '
    fi
    while true; do
        read_input choice "$prompt" || return 1
        case "$choice" in
            '') selected=${current:-tcp} ;;
            0) selected=$current ;;
            1) selected=tcp ;;
            2) selected=udp ;;
            3) selected=tcp+udp ;;
            *) selected='' ;;
        esac
        if [[ -n $selected ]]; then printf -v "$result" '%s' "$selected"; return; fi
        fail '无效选择，请重新输入'
    done
}

edit_rule() {
    local index=${1:--1} port='' host='' target='' protocol='' name='' value h
    local host_prompt='  请输入目标地址 (IP 或域名): ' target_label='请输入目标端口'
    if (( index >= 0 )); then
        value=$(jq -r --argjson i "$index" '.endpoints[$i].listen' "$CONF") || return 1
        port=${value##*:}
        value=$(jq -r --argjson i "$index" '.endpoints[$i].remote' "$CONF") || return 1
        target=${value##*:}; host=${value%:*}
        protocol=$(jq -r --argjson i "$index" "$JQ_PROTOCOL"' .network as $g | .endpoints[$i] | protocol($g)' "$CONF") || return 1
        name=$(jq -r --argjson i "$index" --arg fallback "转发规则-$port" '.endpoints[$i].name // $fallback' "$CONF") || return 1
        printf '\n  当前规则: 【%s】 本机 :%s%s%s → %s%s%s  [%s%s%s]\n\n' \
            "$name" "$BLUE" "$port" "$NC" "$BLUE" "$value" "$NC" "$YELLOW" "${protocol^^}" "$NC"
        read_input value "  新备注名称 (回车保持 $name): " || return 1
        name=${value:-$name}
        read_port port '新本机监听端口' "$port" || return 1
        host_prompt="  新目标地址 (回车保持 $host): "
        target_label='新目标端口'
    else
        printf '\n'
        info '=== 添加端口转发规则 ==='
        printf '\n'
        read_port port '请输入本机监听端口' || return 1
    fi
    while true; do
        read_input h "$host_prompt" || return 1
        h=${h:-$host}
        if remote_address "$h" 1 >/dev/null; then host=$h; break; fi
    done
    show_resolution "$host" || return 1
    read_port target "$target_label" "$target" || return 1
    choose_protocol protocol "$protocol" || return 1
    if (( index < 0 )); then
        read_input name "  请输入备注名称 (回车默认: 转发规则-$port): " || return 1
    fi
    save_rule "$index" "$port" "$host" "$target" "$protocol" "$name"
}

delete_rules() {
    local index=$1 temp answer count selected_port status
    if (( index == -1 )); then
        count=$(jq '.endpoints|length' "$CONF") || return 1
        if (( count == 0 )); then warn '暂无转发规则'; return 0; fi
        printf '\n'
        warn "确认清空全部 ${count} 条端口转发规则？"
        read_input answer '  (Y/N): ' || return 1
        [[ $answer == y || $answer == Y ]] || { MENU_CANCELLED=1; return 1; }
    else
        selected_port=$(jq -r --argjson i "$index" '.endpoints[$i].listen | split(":") | last' "$CONF") || return 1
    fi
    temp=$(mktemp "$DIR/.rules.XXXXXX") || return 1
    trap 'rm -f -- "$temp"; interrupt_exit' INT
    jq --argjson i "$index" 'if $i<0 then .endpoints=[] else del(.endpoints[$i]) end' "$CONF" > "$temp" && apply_rules "$temp"
    status=$?
    trap interrupt_exit INT
    rm -f "$temp"
    if (( status == 0 )); then
        if (( index == -1 )); then success '所有端口转发规则已清空';
        else success "已删除端口 ${selected_port} 的转发规则"; fi
    fi
    return "$status"
}

uninstall() {
    local answer startup="$RUNLEVEL/realm"
    [[ $INIT != systemd ]] || startup="${UNIT%/*}/multi-user.target.wants/realm.service"
    printf '\n'
    info '=== 一键卸载 Realm ==='
    printf '\n'
    read_input answer "  ${YELLOW}[注意] 卸载将删除 Realm、全部规则和备份，是否继续？(Y/N): ${NC}" || return 1
    [[ $answer == y || $answer == Y ]] || { MENU_CANCELLED=1; return 1; }
    check_service || return 1
    if [[ -f $UNIT ]] || svc active; then svc stop >/dev/null 2>&1 || { fail '停止服务失败，未删除文件'; return 1; }; fi
    if svc enabled 2>/dev/null; then svc disable >/dev/null 2>&1 || { fail '取消自启失败，未删除文件'; return 1; }; fi
    if svc active; then fail '服务仍在运行，未删除文件'; return 1; fi
    svc reset >/dev/null 2>&1 || true
    rm -f -- "$UNIT" "$UNIT.bak" "$startup" || return 1
    svc reload >/dev/null 2>&1 || return 1
    rm -f -- "${RT%/*}"/.realm-manager.?????? || return 1
    rm -f -- "$CONF" "$CONF.bak" "$MANAGED_BIN" "$MANAGED_BIN.bak" || return 1
    rm -rf -- "$DIR"/.download.?????? "$DIR"/.change.?????? "$DIR"/.rules.?????? || return 1
    rmdir "$DIR" 2>/dev/null || true
    rm -f -- "$LOG" "$LOG".* "$RT" "$LOCK" || return 1
    printf '  卸载完成：服务、核心、规则、备份、独立日志和 r 命令已清理\n'
}

run_menu_action() {
    "$@"
    local status=$?
    (( status == 130 )) && interrupt_exit
    return "$status"
}

menu() {
    local count choice index header_pad state state_pad core core_width core_pad script_pad
    MENU_CANCELLED=0 INPUT_EOF=0
    while true; do
        MENU_CANCELLED=0 INPUT_EOF=0
        clear_terminal
        count=$(jq '.endpoints|length' "$CONF") || return 1
        service_state state
        core_version core
        header_pad=$((6-${#count})); (( header_pad > 0 )) || header_pad=1
        state_pad=17
        case $core in
            未安装) core_width=6 ;;
            未知) core_width=4 ;;
            *) core_width=${#core} ;;
        esac
        core_pad=$((23-core_width)); (( core_pad > 0 )) || core_pad=1
        script_pad=$((24-${#SCRIPT_VERSION})); (( script_pad > 0 )) || script_pad=1
        printf '\n%s  ╔═══════════════════════════════════════╗\n' "$BLUE"
        printf '  ║    端口转发管理（当前规则：%s%s%s 条）%*s║\n' "$GREEN" "$count" "$BLUE" "$header_pad" ''
        printf '  ║    Realm 状态：%s%s%s%*s║\n' "$GREEN" "$state" "$BLUE" "$state_pad" ''
        printf '  ║    Realm 版本：%s%s%s%*s║\n' "$GREEN" "$core" "$BLUE" "$core_pad" ''
        printf '  ║    管理脚本：%sv%s%s%*s║\n' "$GREEN" "$SCRIPT_VERSION" "$BLUE" "$script_pad" ''
        printf '  ╠═══════════════════════════════════════╣\n'
        printf '  ║  %s基础功能%29s║\n' "$BLUE" ''
        printf '  ║  %s[1]%s  添加转发规则%20s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[2]%s  查看转发规则%20s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[3]%s  修改转发规则%20s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[4]%s  删除转发规则%20s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[5]%s  清空所有转发规则%16s║\n' "$GREEN" "$BLUE" ''
        printf '  ║%39s║\n' ''
        printf '  ║  %s服务管理%29s║\n' "$BLUE" ''
        printf '  ║  %s[6]%s  启动 Realm%22s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[7]%s  停止 Realm%22s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[8]%s  重启 Realm%22s║\n' "$GREEN" "$BLUE" ''
        printf '  ║%39s║\n' ''
        printf '  ║  %s更新与卸载%27s║\n' "$BLUE" ''
        printf '  ║  %s[9]%s  安装/更新 Realm%17s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[10]%s 更新管理脚本%20s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[11]%s 一键卸载%24s║\n' "$GREEN" "$BLUE" ''
        printf '  ║%39s║\n' ''
        printf '  ║  %s[0]%s  退出脚本%24s║\n' "$GREEN" "$BLUE" ''
        printf '  ╚═══════════════════════════════════════╝%s\n\n' "$NC"
        read -r -p '  请输入选项 [0-11]: ' choice
        local status=$?
        (( status == 130 )) && interrupt_exit
        (( status == 0 )) || return 0
        case "$choice" in
            1) run_menu_action edit_rule || true ;;
            2) run_menu_action view_rules || true ;;
            3) run_menu_action choose_rule index '修改' && run_menu_action edit_rule "$index" || true ;;
            4) run_menu_action choose_rule index '删除' && run_menu_action delete_rules "$index" || true ;;
            5) run_menu_action delete_rules -1 || true ;;
            6) printf '\n'; info '=== 启动 Realm ==='; printf '\n'; run_menu_action start_realm || true ;;
            7) printf '\n'; info '=== 停止 Realm ==='; printf '\n'; run_menu_action stop_realm || true ;;
            8) printf '\n'; info '=== 重启 Realm ==='; printf '\n'; run_menu_action restart_realm || true ;;
            9) printf '\n'; run_menu_action update_realm_action || true ;;
            10)
                if run_menu_action update_management_script; then
                    pause_enter '  按回车加载最新脚本...'
                    (( INPUT_EOF )) && return 0
                    reload_script
                    return
                fi
                ;;
            11) if run_menu_action uninstall; then return 0; fi ;;
            0) return 0 ;;
            *) fail '无效选项' ;;
        esac
        (( MENU_CANCELLED )) || pause_enter
        (( INPUT_EOF )) && return 0
    done
}

main() {
    local command=${0##*/}
    case "${1:-}" in
        -v|--version) printf 'Realm 管理脚本 v%s\n' "$SCRIPT_VERSION"; return 0 ;;
        -h|--help) printf '用法：%s [--update|--update-script|--uninstall|--version]\n不带参数打开管理菜单；--update 安装/更新 Realm；--update-script 更新管理脚本；--uninstall 卸载并清理全部规则；--version 查看管理脚本版本\n' "$command"; return 0 ;;
        ''|--update|--update-script|--uninstall) ;;
        *) fail "用法：$command [--update|--update-script|--uninstall|--version]"; return 1 ;;
    esac
    [[ $(uname -s) == Linux && $EUID == 0 ]] || {
        fail '请在 Linux VPS/容器中以 root 或 sudo 运行'; return 1;
    }
    umask 077
    trap interrupt_exit INT
    detect_init && dependencies || return 1
    mkdir -p /run/lock || return 1
    acquire_lock || return 1
    trap 'exit 0' TERM HUP
    mkdir -p "$DIR" || return 1
    maintenance_cleanup
    if [[ ${1:-} == --update-script ]]; then update_management_script && reload_script; return; fi
    resolve_core >/dev/null 2>&1 || true
    check_service || return 1
    if [[ ${1:-} == --uninstall ]]; then uninstall; return; fi
    init_config || return 1
    if [[ ${1:-} == --update ]]; then
        update_realm_action
    else
        menu
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -uo pipefail
    main "$@"
fi
