#!/usr/bin/env bash
# 基于 jinqians/realm；菜单参考 0xdabiaoge/singbox-lite/advanced_relay.sh。
# 单引擎、纯 TCP。首次添加时安装最新版；bash realm.sh --update 更新核心。

DIR=/root/realm
BIN=$DIR/realm
CONF=$DIR/config.json
UNIT=/etc/systemd/system/realm.service
INIT=systemd
RUNLEVEL=/etc/runlevels/default
API=https://api.github.com/repos/zhboner/realm/releases/latest
BLUE=$'\033[1;34m' GREEN=$'\033[0;32m' RED=$'\033[0;31m' NC=$'\033[0m'

fail() { printf '%s错误：%s%s\n' "$RED" "$*" "$NC" >&2; return 1; }
get() { curl -fLsS --retry 2 --connect-timeout 15 --max-time 180 --proto '=https' --proto-redir '=https' "$1" -o "$2"; }
version() { timeout 10 "$1" -v 2>/dev/null | awk 'NR==1 {sub(/^v/, "", $NF); print $NF}'; }

dependencies() {
    local cmd missing=0
    for cmd in curl jq tar sha256sum timeout flock ss pgrep; do command -v "$cmd" >/dev/null || missing=1; done
    (( missing )) || return 0
    if command -v apk >/dev/null; then
        apk add --no-cache ca-certificates curl jq tar coreutils flock iproute2-ss procps
    elif command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y ca-certificates curl jq tar coreutils util-linux iproute2 procps
    elif command -v dnf >/dev/null; then
        dnf install -y ca-certificates curl jq tar coreutils util-linux iproute procps-ng
    elif command -v yum >/dev/null; then
        yum install -y ca-certificates curl jq tar coreutils util-linux iproute procps-ng
    else
        fail '请先安装 curl、jq、tar、coreutils、util-linux、iproute2 和 procps。'; return 1
    fi || return 1
    for cmd in curl jq tar sha256sum timeout flock ss pgrep; do command -v "$cmd" >/dev/null || return 1; done
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
description="Realm TCP forwarding"
command="$BIN"
command_args="-c $CONF"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
output_log="/var/log/realm.log"
error_log="/var/log/realm.log"
depend() {
    use net
}
EOF
        chmod 755 "$UNIT"
        return
    fi
    cat > "$UNIT" <<EOF
[Unit]
Description=Realm TCP forwarding
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
    local temp
    temp=$(mktemp "$DIR/.import.XXXXXX") || return 1
    # 只导入原脚本的三行式 TOML；自定义配置遇到未知字段时停止，避免丢失设置。
    if [[ -s $DIR/config.toml ]]; then
        if ! awk '
          function emit() {
            if (listen=="" && remote=="") return
            if (listen=="" || remote=="") {bad=1; return}
            print listen "\t" remote
          }
          /^[[:space:]]*(#.*)?$/ {next}
          /^[[:space:]]*\[\[endpoints\]\][[:space:]]*(#.*)?$/ {emit(); listen=""; remote=""; endpoint=1; next}
          /^[[:space:]]*\[network\][[:space:]]*$/ {endpoint=0; next}
          !endpoint && /^[[:space:]]*(no_tcp|use_udp)[[:space:]]*=[[:space:]]*false[[:space:]]*(#.*)?$/ {next}
          endpoint && /^[[:space:]]*(listen|remote)[[:space:]]*=[[:space:]]*"[^"\\]*"[[:space:]]*(#.*)?$/ {
            split($0,a,"\"")
            if ($0 ~ /^[[:space:]]*listen/) {if(listen!="") bad=1; listen=a[2]}
            else {if(remote!="") bad=1; remote=a[2]}
            next
          }
          {bad=1}
          END {emit(); if(bad) exit 1}
        ' "$DIR/config.toml" > "$temp"; then
            rm -f "$temp"; fail '旧 TOML 含有自定义或不完整配置，请先手动转换；原文件未修改。'; return 1
        fi
    fi
    jq -Rn '{network:{no_tcp:false,use_udp:false}, endpoints:[inputs | split("\t") | {listen:.[0],remote:.[1]}]}' \
        < "$temp" > "$temp.json" && mv "$temp.json" "$CONF"
    local status=$?
    rm -f "$temp" "$temp.json"
    return "$status"
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
    local attempt pid sockets address found port
    for attempt in 1 2 3 4 5; do
        sleep 0.4
        svc active || continue
        pid=$(svc pid) || continue
        [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
        sockets=$(ss -H -ltnp) || continue
        found=1
        while IFS= read -r address; do
            port=${address##*:}
            if ! awk -v port="$port" -v pid="pid=$pid," \
                '$4 ~ (":" port "$") && index($0,pid) {ok=1} END {exit !ok}' <<< "$sockets"; then found=0; break; fi
        done < <(jq -r '.endpoints[].listen' "$CONF")
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
    current=$(version "$BIN") || current=''
    [[ $current != "${TAG#v}" ]] || { printf '已是最新版 %s。\n' "$TAG"; exit 0; }
    get "$URL" "$temp/package.tar.gz" || exit 1
    sum=$(sha256sum "$temp/package.tar.gz") || exit 1
    [[ ${sum%% *} == "${HASH#sha256:}" ]] || { fail 'SHA256 校验失败。'; exit 1; }
    tar -tzf "$temp/package.tar.gz" > "$temp/files" || exit 1
    member=$(awk '/(^|\/)realm$/ {print}' "$temp/files")
    [[ -n $member && $member != *$'\n'* && $member != /* && $member != *'..'* ]] || exit 1
    tar -xOzf "$temp/package.tar.gz" -- "$member" > "$temp/realm" && chmod 755 "$temp/realm" || exit 1
    [[ $(version "$temp/realm") == "${TAG#v}" ]] || { fail '新版程序不能运行或版本不匹配。'; exit 1; }
    if [[ -f $BIN ]]; then cp -p "$BIN" "$temp/old" && cp -p "$BIN" "$BIN.bak" || exit 1; had=1; fi
    if svc active; then active=1; fi
    replaced=1
    mv -f "$temp/realm" "$BIN" || exit 1
    if (( active )); then svc restart && ready || exit 1; fi
    replaced=0
    printf 'Realm 已更新至 %s。\n' "$TAG"
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
    if (( count )) && { [[ ! -x $BIN ]] || ! version "$BIN" >/dev/null; }; then update_realm || exit 1; fi
    cp -p "$CONF" "$temp/config" && cp -p "$CONF" "$CONF.bak" || exit 1
    if [[ -f $UNIT ]]; then cp -p "$UNIT" "$temp/unit" || exit 1; had_unit=1; fi
    if svc active; then active=1; fi
    if svc enabled 2>/dev/null; then enabled=1; fi
    changed=1
    chmod 600 "$candidate" && mv -f "$candidate" "$CONF" || exit 1
    if (( count )); then
        write_unit && svc enable && svc restart && ready || exit 1
    elif (( had_unit )); then
        svc stop || exit 1
        if (( enabled )); then svc disable || exit 1; fi
    fi
    changed=0
    printf '规则已生效。\n'
)

view_rules() {
    if [[ $(jq '.endpoints|length' "$CONF") == 0 ]]; then printf '暂无转发规则。\n'; return; fi
    jq -r '.endpoints | to_entries[] | "[\(.key+1)] \(.value.listen) → \(.value.remote)  [TCP / Realm]"' "$CONF"
}

choose_rule() {
    local n count
    count=$(jq '.endpoints|length' "$CONF") || return 1
    (( count )) || { fail '暂无转发规则。'; return 1; }
    view_rules >&2
    read -r -p '规则编号（回车取消）：' n || return 1
    [[ -n $n ]] || return 1
    [[ $n =~ ^[0-9]{1,6}$ ]] && (( 10#$n > 0 && 10#$n <= count )) || { fail '编号无效。'; return 1; }
    printf '%d\n' "$((10#$n-1))"
}

save_rule() {
    local index=$1 port=$2 host=$3 target=$4 remote current temp
    valid_port "$port" || { fail '监听端口应为 1–65535。'; return 1; }
    port=$((10#$port))
    remote=$(remote_address "$host" "$target") || return 1
    if jq -e --argjson i "$index" --arg p "$port" \
        '.endpoints | to_entries | any(.key != $i and (.value.listen|split(":")|last)==$p)' "$CONF" >/dev/null; then
        fail "端口 $port 已有转发规则。"; return 1
    fi
    current=$(jq -r --argjson i "$index" 'if $i<0 then "" else .endpoints[$i].listen end' "$CONF") || return 1
    if [[ ${current##*:} != "$port" && -n $(ss -H -ltn "sport = :$port") ]]; then
        fail "TCP 端口 $port 已被占用。"; return 1
    fi
    temp=$(mktemp "$DIR/.rules.XXXXXX") || return 1
    # 保留已有规则的监听地址；新规则默认 IPv4 全接口。
    local listen="${current%:*}:$port"
    [[ -n $current ]] || listen="0.0.0.0:$port"
    jq --argjson i "$index" --arg l "$listen" --arg r "$remote" \
        'if $i<0 then .endpoints += [{listen:$l,remote:$r}]
         else .endpoints[$i] += {listen:$l,remote:$r} end' "$CONF" > "$temp" && apply_rules "$temp"
    local status=$?
    rm -f "$temp"
    if (( status == 0 )); then printf '请确保系统防火墙和云安全组已放行 TCP %s。\n' "$port"; fi
    return "$status"
}

edit_rule() {
    local index=${1:--1} port='' host='' target='' value p h t
    if (( index >= 0 )); then
        value=$(jq -r --argjson i "$index" '.endpoints[$i].listen' "$CONF"); port=${value##*:}
        value=$(jq -r --argjson i "$index" '.endpoints[$i].remote' "$CONF"); target=${value##*:}; host=${value%:*}
    fi
    read -r -p "本机监听端口${port:+ [$port]}：" p || return 1
    read -r -p "目标 IP/域名${host:+ [$host]}：" h || return 1
    read -r -p "目标端口${target:+ [$target]}：" t || return 1
    save_rule "$index" "${p:-$port}" "${h:-$host}" "${t:-$target}"
}

delete_rules() {
    local index=$1 temp answer
    if (( index == -1 )); then
        read -r -p '确认清空全部规则？[y/N] ' answer || return 1
        [[ $answer == y || $answer == Y ]] || return 0
    fi
    temp=$(mktemp "$DIR/.rules.XXXXXX") || return 1
    jq --argjson i "$index" 'if $i<0 then .endpoints=[] else del(.endpoints[$i]) end' "$CONF" > "$temp" && apply_rules "$temp"
    local status=$?
    rm -f "$temp"
    return "$status"
}

menu() {
    local count choice index
    while true; do
        [[ -t 1 ]] && printf '\033[2J\033[H'
        count=$(jq '.endpoints|length' "$CONF") || return 1
        printf '\n%s  ╔══════════════════════════════════════════════╗\n' "$BLUE"
        printf '  ║  端口转发管理 · Realm                       ║\n'
        printf '  ╚══════════════════════════════════════════════╝%s\n' "$NC"
        printf '     当前规则：%s%s%s 条\n\n' "$GREEN" "$count" "$NC"
        printf '     [1] 添加转发规则\n     [2] 查看当前转发规则\n     [3] 修改转发规则\n     [4] 删除转发规则\n'
        printf '     %s[5] 清空所有转发规则%s\n     [0] 退出脚本\n\n' "$RED" "$NC"
        read -r -p '请输入选项 [0-5]：' choice || return 0
        case "$choice" in
            1) edit_rule || true ;;
            2) view_rules ;;
            3) index=$(choose_rule) && edit_rule "$index" || true ;;
            4) index=$(choose_rule) && delete_rules "$index" || true ;;
            5) delete_rules -1 || true ;;
            0) return 0 ;;
            *) fail '无效选项。' ;;
        esac
        read -r -p '按回车继续……' choice || return 0
    done
}

main() {
    case "${1:-}" in
        -h|--help) printf '用法：sudo bash realm.sh [--update]\n不带参数直接打开转发管理；--update 更新 Realm 到最新稳定版。\n'; return 0 ;;
        ''|--update) ;;
        *) fail '用法：sudo bash realm.sh [--update]'; return 1 ;;
    esac
    [[ $(uname -s) == Linux && $EUID == 0 ]] || {
        fail '请在 Linux VPS/容器中以 root 或 sudo 运行。'; return 1;
    }
    umask 077
    detect_init && dependencies || return 1
    mkdir -p /run/lock || return 1
    exec 9>/run/lock/realm-manager.lock || return 1
    flock -n 9 || { fail '另一个管理脚本正在运行。'; return 1; }
    check_service && mkdir -p "$DIR" && init_config || return 1
    if [[ ${1:-} == --update ]]; then update_realm; else menu; fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -uo pipefail
    main "$@"
fi
