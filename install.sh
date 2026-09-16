#!/bin/sh
# 安装 rt 管理命令，兼容 Alpine 的默认 /bin/sh。
set -eu

install_rt() {
    [ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] || {
        printf '请在 Linux 服务器上以 root 运行安装指令。\n' >&2
        return 1
    }
    if ! command -v bash >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash curl ca-certificates
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y bash curl ca-certificates
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y bash curl ca-certificates
        elif command -v yum >/dev/null 2>&1; then
            yum install -y bash curl ca-certificates
        else
            printf '请先安装 bash、curl 和 ca-certificates。\n' >&2
            return 1
        fi
    fi
    mkdir -p /usr/local/bin
    temp=$(mktemp /usr/local/bin/.rt.XXXXXX)
    trap 'rm -f "$temp"' 0
    trap 'exit 1' 1 2 15
    curl -fLsS --retry 2 --connect-timeout 15 --max-time 180 \
        --proto '=https' --proto-redir '=https' \
        https://raw.githubusercontent.com/haoch1/realm-tcp/main/realm.sh -o "$temp"
    bash -n "$temp"
    chmod 755 "$temp"
    mv -f "$temp" /usr/local/bin/rt
    printf '安装完成！输入 rt 打开菜单，rt --update 更新 Realm 核心。\n'
    if [ -t 1 ] && [ -r /dev/tty ]; then
        exec /usr/local/bin/rt </dev/tty
    fi
}

install_rt "$@"
