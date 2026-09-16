#!/bin/sh
# Realm 端口转发管理。首次启动时安装最新版；r --update 更新核心。

# POSIX 启动段：Alpine 没有 Bash 时先安装，再交给 Bash 运行。
install_packages() {
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash ca-certificates curl jq tar coreutils flock iproute2-ss procps
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash ca-certificates curl jq tar coreutils util-linux iproute2 procps
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bash ca-certificates curl jq tar coreutils util-linux iproute procps-ng
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bash ca-certificates curl jq tar coreutils util-linux iproute procps-ng
    else
        printf '无法识别包管理器，需要 apt-get、apk、dnf 或 yum。\n' >&2
        return 1
    fi
}

if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        [ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] || {
            printf '请在 Linux 服务器上以 root 运行。\n' >&2
            exit 1
        }
        install_packages || exit 1
    fi
    exec bash "$0" "$@"
fi

DIR=/root/realm
BIN=$DIR/realm
CONF=$DIR/config.json
UNIT=/etc/systemd/system/realm.service
INIT=systemd
RUNLEVEL=/etc/runlevels/default
RT=/usr/local/bin/r
LOG=/var/log/realm.log
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
pause_enter() { read -r -p '  按回车继续...' _ || true; }
pause_menu() {
    printf '\n'
    if [[ -t 0 ]]; then
        read -r -s -n 1 -p '  按任意键返回主菜单...' _ || true
        printf '\n'
    else
        read -r -p '  按任意键返回主菜单...' _ || true
    fi
}
get() { curl -fLsS --retry 2 --connect-timeout 15 --max-time 180 --proto '=https' --proto-redir '=https' "$1" -o "$2"; }
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

dependencies() {
    local cmd missing=0
    for cmd in curl jq tar sha256sum timeout flock ss pgrep stat; do command -v "$cmd" >/dev/null || missing=1; done
    (( missing )) || return 0
    install_packages || return 1
    for cmd in curl jq tar sha256sum timeout flock ss pgrep stat; do command -v "$cmd" >/dev/null || return 1; done
}

is_manager_pid() {
    local pid=$1 command
    [[ -r /proc/$pid/cmdline ]] || return 1
    command=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    [[ $command == *'/usr/local/bin/r'* || $command == *'/realm.sh'* || $command == *' realm.sh '* ]]
}

lock_holder_pid() {
    local inode pid fd fd_inode
    pid=$(cat "$LOCK" 2>/dev/null) || pid=''
    if [[ $pid =~ ^[1-9][0-9]*$ ]] && (( pid != $$ )) && kill -0 "$pid" 2>/dev/null && is_manager_pid "$pid"; then
        printf '%s\n' "$pid"
        return 0
    fi

    inode=$(stat -Lc '%i' "$LOCK" 2>/dev/null) || inode=''
    if [[ -n $inode && -r /proc/locks ]]; then
        pid=$(awk -v inode="$inode" '$2=="FLOCK" && $6 ~ (":" inode "$") {print $5; exit}' /proc/locks)
        if [[ $pid =~ ^[1-9][0-9]*$ ]] && (( pid != $$ )) && kill -0 "$pid" 2>/dev/null && is_manager_pid "$pid"; then
            printf '%s\n' "$pid"
            return 0
        fi
    fi

    # 兼容旧脚本留下的空锁文件；BSD flock 可能记录已经退出的 flock 子进程 PID。
    [[ -n $inode ]] || return 1
    for fd in /proc/[0-9]*/fd/*; do
        [[ -e $fd ]] || continue
        fd_inode=$(stat -Lc '%i' "$fd" 2>/dev/null) || continue
        [[ $fd_inode == "$inode" ]] || continue
        pid=${fd#/proc/}
        pid=${pid%%/*}
        [[ $pid =~ ^[1-9][0-9]*$ ]] && (( pid != $$ )) && is_manager_pid "$pid" || continue
        printf '%s\n' "$pid"
        return 0
    done
    return 1
}

acquire_lock() {
    local holder attempt
    exec 9>>"$LOCK" || { fail '无法打开管理锁。'; return 1; }
    if flock -n 9; then
        printf '%s\n' "$$" > "$LOCK"
        return 0
    fi

    holder=$(lock_holder_pid 2>/dev/null) || holder=''
    if [[ $holder =~ ^[1-9][0-9]*$ ]] && kill -0 "$holder" 2>/dev/null && is_manager_pid "$holder"; then
        info '检测到旧的管理界面，正在自动接管...'
        kill -TERM "$holder" 2>/dev/null || true
        for (( attempt=0; attempt<50; attempt++ )); do
            if flock -n 9; then
                printf '%s\n' "$$" > "$LOCK"
                success '已关闭旧管理界面。'
                return 0
            fi
            sleep 0.1
        done
        fail "旧管理脚本仍在执行操作，请稍后重试（PID: $holder）。"
        return 1
    fi

    fail "管理锁被其他进程占用${holder:+（PID: $holder）}，请稍后重试。"
}

detect_init() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
        INIT=systemd; UNIT=/etc/systemd/system/realm.service
    elif command -v rc-service >/dev/null && command -v rc-update >/dev/null && command -v supervise-daemon >/dev/null; then
        INIT=openrc; UNIT=/etc/init.d/realm
    else
        fail '需要 systemd 或 OpenRC；无 init 的容器请先配置服务管理。'; return 1
    fi
}

# 只抽象必要的服务动作；转发不使用 nftables、IP forwarding 或特权网络接口。
svc() {
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
}

check_service() {
    local path command
    if [[ $INIT == openrc ]]; then
        [[ ! -f $UNIT ]] || { grep -Fxq "command=\"$BIN\"" "$UNIT" && grep -Fxq "command_args=\"-c $CONF\"" "$UNIT"; } ||
            { fail '发现其他配置的 Realm OpenRC 服务，不能直接接管。'; return 1; }
        return 0
    fi
    path=$(systemctl show realm -p FragmentPath --value) || return 1
    [[ -z $path ]] && return 0
    command=$(systemctl show realm -p ExecStart --value) || return 1
    [[ $path == "$UNIT" && $command == *"$BIN -c $DIR/config."* ]] ||
        fail '发现其他路径的 realm 服务，不能直接接管。'
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
    [[ -f $CONF ]] && { jq -e '.endpoints | type == "array"' "$CONF" >/dev/null; return; }
    printf '{"endpoints":[]}\n' > "$CONF"
}

select_asset() {
    local json=$1 arch=$2 target
    case "$arch" in
        x86_64|amd64) target=x86_64-unknown-linux-musl ;;
        aarch64|arm64) target=aarch64-unknown-linux-musl ;;
        armv7l|armv7) target=armv7-unknown-linux-musleabihf ;;
        *) fail "暂不支持架构：$arch"; return 1 ;;
    esac
    jq -e '.draft == false and .prerelease == false' "$json" >/dev/null || return 1
    TAG=$(jq -er '.tag_name' "$json") || return 1
    [[ $TAG =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail '无法识别稳定版标签。'; return 1; }
    local name="realm-$target.tar.gz"
    URL=$(jq -er --arg name "$name" '.assets[] | select(.name==$name) | .browser_download_url' "$json") || return 1
    HASH=$(jq -er --arg name "$name" '.assets[] | select(.name==$name) | .digest' "$json") || return 1
    [[ $URL == "https://github.com/zhboner/realm/releases/download/$TAG/$name" && $HASH =~ ^sha256:[a-f0-9]{64}$ ]] || {
        fail '安装包地址或 SHA256 摘要无效。'; return 1;
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
    fail 'Realm 启动失败或端口未监听。systemd 查看 journalctl -u realm；OpenRC 查看 /var/log/realm.log。'
}

update_realm() (
    local temp active=0 replaced=0 had=0 status sum member current
    temp=$(mktemp -d "$DIR/.download.XXXXXX") || exit 1
    cleanup() {
        status=$?
        trap - EXIT INT TERM HUP
        if (( replaced )); then
            svc stop >/dev/null 2>&1 || true
            if (( had )); then
                cp -p "$temp/old" "$BIN.restore" && mv -f "$BIN.restore" "$BIN" || fail '恢复旧程序失败。'
            else rm -f "$BIN"; fi
            if (( active )); then
                svc reset >/dev/null 2>&1 || true
                svc restart && ready || fail '旧程序恢复后未能启动。'
            fi
            fail '升级未成功，已尝试恢复原程序。'; status=1
        fi
        rm -rf -- "$temp"
        exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    printf '正在获取 Realm 最新稳定版……\n'
    get "$API" "$temp/release.json" && select_asset "$temp/release.json" "$(uname -m)" || {
        fail '获取最新版本失败，请检查 GitHub 访问或 API 限流。'; exit 1;
    }
    current=$(version "$BIN" 2>/dev/null) || current=''
    [[ $current != "${TAG#v}" ]] || { printf '已是最新版 %s。\n' "$TAG"; exit 0; }
    get "$URL" "$temp/package.tar.gz" || exit 1
    sum=$(sha256sum "$temp/package.tar.gz") || exit 1
    [[ ${sum%% *} == "${HASH#sha256:}" ]] || { fail 'SHA256 校验失败。'; exit 1; }
    tar -tzf "$temp/package.tar.gz" > "$temp/files" || exit 1
    member=$(awk '/(^|\/)realm$/ {print}' "$temp/files")
    [[ -n $member && $member != *$'\n'* && $member != /* && $member != *'..'* ]] || exit 1
    tar -xOzf "$temp/package.tar.gz" -- "$member" > "$temp/realm" && chmod 755 "$temp/realm" || exit 1
    current=$(version "$temp/realm" 2> "$temp/version.error") || {
        fail "新版程序无法执行或无法读取版本（架构：$(uname -m)）。"
        cat "$temp/version.error" >&2
        exit 1
    }
    [[ $current == "${TAG#v}" ]] || { fail "版本不匹配：期望 ${TAG#v}，实际 $current。"; exit 1; }
    if [[ -f $BIN ]]; then cp -p "$BIN" "$temp/old" && cp -p "$BIN" "$BIN.bak" || exit 1; had=1; fi
    if svc active; then active=1; fi
    replaced=1
    mv -f "$temp/realm" "$BIN" || exit 1
    if (( active )); then svc restart && ready || exit 1; fi
    replaced=0
    printf 'Realm 已更新至 %s。\n' "$TAG"
)

update_script() (
    local target_dir temp first_line new_hash old_hash
    target_dir=${RT%/*}
    [[ $target_dir != "$RT" ]] || target_dir=.
    temp=$(mktemp "$target_dir/.realm-manager.XXXXXX") || exit 1
    cleanup_script_update() { [[ -z ${temp:-} ]] || rm -f -- "$temp"; }
    trap cleanup_script_update EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    printf '  正在获取最新管理脚本...\n'
    get "$SCRIPT_URL" "$temp" || { fail '管理脚本下载失败，请检查 GitHub 连接。'; exit 1; }
    IFS= read -r first_line < "$temp" || true
    [[ $first_line == '#!/bin/sh' ]] || { fail '下载内容不是有效的管理脚本。'; exit 1; }
    bash -n "$temp" || { fail '新版管理脚本语法检查失败，未替换当前版本。'; exit 1; }
    if [[ -f $RT ]]; then
        new_hash=$(sha256sum "$temp") || exit 1
        old_hash=$(sha256sum "$RT") || exit 1
        if [[ ${new_hash%% *} == "${old_hash%% *}" ]]; then
            printf '  管理脚本已是最新版。\n'
            exit 0
        fi
    fi
    chmod 755 "$temp" && mv -f "$temp" "$RT" || { fail '管理脚本替换失败。'; exit 1; }
    trap - EXIT INT TERM HUP
    success '管理脚本已更新，重新运行 r 即可使用。'
)

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 > 0 && 10#$1 < 65536 )); }

remote_address() {
    local host=$1 port=$2
    valid_port "$port" || { fail '目标端口应为 1–65535。'; return 1; }
    if [[ $host == \[*\] ]]; then host=${host:1:${#host}-2}; fi
    if [[ $host == *:* ]]; then
        [[ $host =~ ^[a-fA-F0-9:.]+$ ]] || { fail 'IPv6 地址无效。'; return 1; }
        printf '[%s]:%d\n' "$host" "$((10#$port))"
    else
        [[ $host =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || { fail '请输入 IP 或域名，不要带协议、路径或空白。'; return 1; }
        printf '%s:%d\n' "$host" "$((10#$port))"
    fi
}

apply_rules() (
    local candidate=$1 temp active=0 had_unit=0 changed=0 enabled=0 status count
    temp=$(mktemp -d "$DIR/.change.XXXXXX") || exit 1
    rollback() {
        status=$?
        trap - EXIT INT TERM HUP
        if (( changed )); then
            svc stop >/dev/null 2>&1 || true
            if (( enabled == 0 )); then svc disable >/dev/null 2>&1 || true; fi
            cp -p "$temp/config" "$CONF" || fail '恢复旧配置失败。'
            if (( had_unit )); then cp -p "$temp/unit" "$UNIT"; else rm -f "$UNIT"; fi
            svc reload || true
            if (( enabled )); then svc enable >/dev/null 2>&1 || true; fi
            if (( active )); then
                svc reset >/dev/null 2>&1 || true
                svc restart && ready || fail '恢复旧服务失败。'
            fi
            fail '修改未生效，已尝试恢复原规则。'; status=1
        fi
        rm -rf -- "$temp"
        exit "$status"
    }
    trap rollback EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    count=$(jq -er '.endpoints | length' "$candidate") || exit 1
    if (( count )) && { [[ ! -x $BIN ]] || ! version "$BIN" >/dev/null 2>&1; }; then update_realm || exit 1; fi
    cp -p "$CONF" "$temp/config" && cp -p "$CONF" "$CONF.bak" || exit 1
    if [[ -f $UNIT ]]; then cp -p "$UNIT" "$temp/unit" || exit 1; had_unit=1; fi
    if svc active; then active=1; fi
    if svc enabled 2>/dev/null; then enabled=1; fi
    changed=1
    chmod 600 "$candidate" && mv -f "$candidate" "$CONF" || exit 1
    if (( count )); then
        write_unit && svc enable >/dev/null 2>&1 && svc restart >/dev/null 2>&1 && ready || exit 1
    elif (( had_unit )); then
        svc stop >/dev/null 2>&1 || exit 1
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
    printf '\n  共 %s%s%s 条转发规则。\n' "$GREEN" "$count" "$NC"
}

choose_rule() {
    local action=${1:-选择} n count
    count=$(jq '.endpoints|length' "$CONF") || return 1
    printf '\n' >&2
    info "=== ${action}端口转发规则 ===" >&2
    printf '\n' >&2
    (( count )) || { warn '暂无转发规则' >&2; return 1; }
    print_rules >&2
    printf '\n' >&2
    read -r -p "  请输入要${action}的序号 (0 取消): " n || return 1
    [[ -n $n && $n != 0 ]] || return 1
    [[ $n =~ ^[0-9]{1,6}$ ]] && (( 10#$n > 0 && 10#$n <= count )) || { fail '无效选择'; return 1; }
    printf '%d\n' "$((10#$n-1))"
}

save_rule() {
    local index=$1 port=$2 host=$3 target=$4 protocol=${5:-tcp} name=${6:-}
    local remote current old_protocol temp proto flag sockets pid=''
    case "$protocol" in tcp|udp|tcp+udp) ;; *) fail '请选择 TCP、UDP 或 TCP+UDP。'; return 1 ;; esac
    valid_port "$port" || { fail '监听端口应为 1–65535。'; return 1; }
    port=$((10#$port))
    name=${name:-转发规则-$port}
    [[ ${#name} -le 60 && ! $name =~ [[:cntrl:]] ]] || { fail '备注限 60 字，不能包含控制字符。'; return 1; }
    remote=$(remote_address "$host" "$target") || return 1
    if jq -e --argjson i "$index" --arg p "$port" --arg proto "$protocol" "$JQ_PROTOCOL"'
        .network as $g | .endpoints | to_entries | any(
            .key != $i and (.value.listen | split(":") | last)==$p
            and ((.value | protocol($g)) as $old | $old==$proto or $old=="tcp+udp" or $proto=="tcp+udp"))' "$CONF" >/dev/null; then
        fail "${protocol^^} 端口 $port 已有转发规则。"; return 1
    fi
    current=$(jq -r --argjson i "$index" 'if $i<0 then "" else .endpoints[$i].listen end' "$CONF") || return 1
    old_protocol=$(jq -r --argjson i "$index" "$JQ_PROTOCOL"'
        .network as $g | if $i<0 then "" else .endpoints[$i] | protocol($g) end' "$CONF") || return 1
    if svc active; then pid=$(svc pid) || pid=''; fi
    for proto in tcp udp; do
        [[ $protocol == "$proto" || $protocol == tcp+udp ]] || continue
        flag=-ltnp; [[ $proto != udp ]] || flag=-uanp
        sockets=$(ss -H "$flag" "sport = :$port") || { fail '无法检查端口占用。'; return 1; }
        [[ -n $sockets ]] || continue
        if [[ ${current##*:} == "$port" && ($old_protocol == "$proto" || $old_protocol == tcp+udp) && $pid =~ ^[1-9][0-9]*$ ]] &&
            awk -v pid="pid=$pid," '!index($0,pid) {bad=1} END {exit bad}' <<< "$sockets"; then continue; fi
        fail "${proto^^} 端口 $port 已被占用。"; return 1
    done
    temp=$(mktemp "$DIR/.rules.XXXXXX") || return 1
    # 保留已有规则的监听地址；新规则默认 IPv4 全接口。
    local listen="${current%:*}:$port"
    [[ -n $current ]] || listen="0.0.0.0:$port"
    jq --argjson i "$index" --arg l "$listen" --arg r "$remote" --arg proto "$protocol" --arg name "$name" '
        {listen:$l,remote:$r,name:$name} as $rule
        | {no_tcp:($proto=="udp"),use_udp:($proto!="tcp")} as $net
        | if $i<0 then .endpoints += [$rule + {network:$net}]
          else .endpoints[$i] |= (. + $rule | .network = ((.network // {}) + $net)) end' "$CONF" > "$temp" && apply_rules "$temp"
    local status=$?
    rm -f "$temp"
    if (( status == 0 )); then
        if (( index < 0 )); then
            success '端口转发规则已添加并生效！'
        else
            success '转发规则已修改并生效！'
        fi
        printf '  引擎: %sRealm%s\n' "$GREEN" "$NC"
        printf '  转发模式: %s%s%s\n' "$GREEN" "${protocol^^}" "$NC"
        printf '  【%s】 本机端口: %s%s%s → 目标: %s%s%s\n' \
            "$name" "$GREEN" "$port" "$NC" "$GREEN" "$remote" "$NC"
    fi
    return "$status"
}

read_port() {
    local label=$1 previous=${2:-} value
    while true; do
        read -r -p "  ${label}${previous:+ (回车保持 $previous)}: " value || return 1
        value=${value:-$previous}
        if valid_port "$value"; then printf '%d\n' "$((10#$value))"; return; fi
        fail '无效端口，请输入 1–65535 之间的数字。'
    done
}

choose_protocol() {
    local current=${1:-} choice
    printf '\n  %s请选择转发协议：%s\n' "$BLUE" "$NC" >&2
    printf '    %s[1]%s 仅 TCP\n    %s[2]%s 仅 UDP\n    %s[3]%s TCP+UDP\n' "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" >&2
    if [[ -n $current ]]; then printf '    %s[0]%s 保持 %s\n' "$GREEN" "$NC" "${current^^}" >&2; fi
    while true; do
        if [[ -n $current ]]; then read -r -p '  请选择 [0-3] (回车不改): ' choice || return 1
        else read -r -p '  请选择 [1-3] (默认 1): ' choice || return 1; fi
        case "$choice" in
            '') printf '%s\n' "${current:-tcp}"; return ;;
            0) if [[ -n $current ]]; then printf '%s\n' "$current"; return; fi ;;
            1) printf 'tcp\n'; return ;;
            2) printf 'udp\n'; return ;;
            3) printf 'tcp+udp\n'; return ;;
        esac
        fail '无效选择，请重新输入。'
    done
}

edit_rule() {
    local index=${1:--1} port='' host='' target='' protocol='' name='' value h
    if (( index >= 0 )); then
        value=$(jq -r --argjson i "$index" '.endpoints[$i].listen' "$CONF"); port=${value##*:}
        value=$(jq -r --argjson i "$index" '.endpoints[$i].remote' "$CONF"); target=${value##*:}; host=${value%:*}
        protocol=$(jq -r --argjson i "$index" "$JQ_PROTOCOL"' .network as $g | .endpoints[$i] | protocol($g)' "$CONF") || return 1
        name=$(jq -r --argjson i "$index" --arg fallback "转发规则-$port" '.endpoints[$i].name // $fallback' "$CONF") || return 1
        printf '\n  当前规则: 【%s】 本机 :%s%s%s → %s%s%s  [%s%s%s]\n\n' \
            "$name" "$BLUE" "$port" "$NC" "$BLUE" "$value" "$NC" "$YELLOW" "${protocol^^}" "$NC"
        read -r -p "  新备注名称 (回车保持 $name): " value || return 1
        name=${value:-$name}
        port=$(read_port '新本机监听端口' "$port") || return 1
    else
        printf '\n'
        info '=== 添加端口转发规则 (引擎: Realm) ==='
        printf '\n'
        port=$(read_port '请输入本机监听端口') || return 1
    fi
    while true; do
        if (( index >= 0 )); then
            read -r -p "  新目标地址 (回车保持 $host): " h || return 1
        else
            read -r -p '  请输入目标地址 (IP 或域名): ' h || return 1
        fi
        h=${h:-$host}
        if remote_address "$h" 1 >/dev/null; then host=$h; break; fi
    done
    if (( index >= 0 )); then
        target=$(read_port '新目标端口' "$target") || return 1
    else
        target=$(read_port '请输入目标端口') || return 1
    fi
    protocol=$(choose_protocol "$protocol") || return 1
    if (( index < 0 )); then
        read -r -p "  请输入备注名称 (回车默认: 转发规则-$port): " name || return 1
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
        read -r -p '  (y/N): ' answer || return 1
        [[ $answer == y || $answer == Y ]] || return 0
    else
        selected_port=$(jq -r --argjson i "$index" '.endpoints[$i].listen | split(":") | last' "$CONF") || return 1
    fi
    temp=$(mktemp "$DIR/.rules.XXXXXX") || return 1
    jq --argjson i "$index" 'if $i<0 then .endpoints=[] else del(.endpoints[$i]) end' "$CONF" > "$temp" && apply_rules "$temp"
    status=$?
    rm -f "$temp"
    if (( status == 0 )); then
        if (( index == -1 )); then success '所有端口转发规则已清空';
        else success "已删除端口 ${selected_port} 的转发规则"; fi
    fi
    return "$status"
}

uninstall() {
    local answer
    printf '\n'
    info '=== 一键卸载 Realm ==='
    printf '\n'
    warn '卸载将删除 Realm、全部规则和备份，是否继续？'
    read -r -p '  (y/N): ' answer || return 1
    [[ $answer == y || $answer == Y ]] || return 1
    check_service || return 1
    if svc active; then svc stop || { fail '停止服务失败，未删除文件。'; return 1; }; fi
    if svc enabled 2>/dev/null; then svc disable || { fail '取消自启失败，未删除文件。'; return 1; }; fi
    if svc active; then fail '服务仍在运行，未删除文件。'; return 1; fi
    svc reset >/dev/null 2>&1 || true
    rm -f -- "$UNIT" "$UNIT.bak" || return 1
    svc reload || return 1
    rm -rf -- "$DIR" || return 1
    rm -f -- "$LOG" "$LOG".* "$RT" "$LOCK" || return 1
    printf '卸载完成：服务、核心、规则、备份、独立日志和 r 命令已清理。\n'
}

menu() {
    local count choice index header_pad
    MENU_INTERRUPTED=0
    trap 'MENU_INTERRUPTED=1' INT
    while true; do
        [[ -t 1 ]] && printf '\033[2J\033[H'
        count=$(jq '.endpoints|length' "$CONF") || return 1
        header_pad=$((7-${#count})); (( header_pad > 0 )) || header_pad=1
        printf '\n%s  ╔═══════════════════════════════════════╗\n' "$BLUE"
        printf '  ║    端口转发管理 (当前规则: %s%s%s 条)%*s║\n' "$GREEN" "$count" "$BLUE" "$header_pad" ''
        printf '  ╠═══════════════════════════════════════╣\n'
        printf '  ║  %s[1]%s 添加转发规则%21s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[2]%s 查看当前转发规则%17s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[3]%s 修改转发规则%21s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[4]%s 删除转发规则%21s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[5]%s 清空所有转发规则%17s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[6]%s 更新 Realm%23s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[7]%s 更新管理脚本%21s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[8]%s 一键卸载%25s║\n' "$GREEN" "$BLUE" ''
        printf '  ║  %s[0]%s 退出脚本%25s║\n' "$GREEN" "$BLUE" ''
        printf '  ╚═══════════════════════════════════════╝%s\n\n' "$NC"
        MENU_INTERRUPTED=0
        if ! read -r -p '  请输入选项 [0-8]: ' choice; then
            if (( MENU_INTERRUPTED )); then pause_menu; continue; fi
            trap - INT
            return 0
        fi
        MENU_INTERRUPTED=0
        case "$choice" in
            1) edit_rule || true ;;
            2) view_rules ;;
            3) index=$(choose_rule '修改') && edit_rule "$index" || true ;;
            4) index=$(choose_rule '删除') && delete_rules "$index" || true ;;
            5) delete_rules -1 || true ;;
            6) printf '\n'; info '=== 更新 Realm ==='; printf '\n'; update_realm || true ;;
            7) printf '\n'; info '=== 更新管理脚本 ==='; printf '\n'; update_script || true ;;
            8) if uninstall; then trap - INT; return 0; fi ;;
            0) trap - INT; return 0 ;;
            *) fail '无效选项。' ;;
        esac
        if (( MENU_INTERRUPTED )); then pause_menu; else pause_enter; fi
    done
}

main() {
    local command=${0##*/}
    case "${1:-}" in
        -h|--help) printf '用法：%s [--update|--update-script|--uninstall]\n不带参数打开管理菜单；--update 更新 Realm；--update-script 更新管理脚本；--uninstall 卸载并清理全部规则。\n' "$command"; return 0 ;;
        ''|--update|--update-script|--uninstall) ;;
        *) fail "用法：$command [--update|--update-script|--uninstall]"; return 1 ;;
    esac
    [[ $(uname -s) == Linux && $EUID == 0 ]] || {
        fail '请在 Linux VPS/容器中以 root 或 sudo 运行。'; return 1;
    }
    umask 077
    detect_init && dependencies || return 1
    mkdir -p /run/lock || return 1
    acquire_lock || return 1
    trap 'exit 0' TERM HUP
    if [[ ${1:-} == --update-script ]]; then update_script; return; fi
    check_service || return 1
    if [[ ${1:-} == --uninstall ]]; then uninstall; return; fi
    mkdir -p "$DIR" && init_config || return 1
    if [[ ${1:-} == --update ]]; then
        update_realm
    else
        if ! version "$BIN" >/dev/null 2>&1; then update_realm || return 1; fi
        menu
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -uo pipefail
    main "$@"
fi
