#!/usr/bin/env bash
set +o posix
set -euo pipefail
export PATH="/usr/bin:$PATH"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p .test-work
work=$(mktemp -d .test-work/install.XXXXXX)
passed=0

# 将安装位置改到测试目录，包管理和下载使用替身；执行完整安装入口。
for mode in apk apt-get dnf yum ready download-failure invalid-script non-root; do
    dir="$work/$mode"
    mkdir -p "$dir/bin"
    printf 'existing manager\n' > "$dir/bin/rt"
    cp "$dir/bin/rt" "$dir/original"
    cat > "$dir/run.sh" <<'EOF'
set +o posix
set -eu
dir=$1 mode=$2 real_bash=$3
packages_ready=0
case "$mode" in ready|download-failure|invalid-script|non-root) packages_ready=1 ;; esac
command() {
    if [ "${1:-}" = -v ]; then
        case "$2" in
            bash|curl) [ "$packages_ready" = 1 ]; return ;;
            apk|apt-get|dnf|yum) [ "$2" = "$mode" ]; return ;;
        esac
    fi
    builtin command "$@"
}
uname() { printf 'Linux\n'; }
id() { if [ "$mode" = non-root ]; then printf '1000\n'; else printf '0\n'; fi; }
apk() { printf 'apk %s\n' "$*" >> "$dir/packages"; packages_ready=1; }
apt-get() { printf 'apt-get %s\n' "$*" >> "$dir/packages"; packages_ready=1; }
dnf() { printf 'dnf %s\n' "$*" >> "$dir/packages"; packages_ready=1; }
yum() { printf 'yum %s\n' "$*" >> "$dir/packages"; packages_ready=1; }
curl() {
    [ "$mode" != download-failure ] || return 22
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then output=$2; shift 2; else shift; fi
    done
    if [ "$mode" = invalid-script ]; then printf 'if then\n' > "$output"
    else cp realm.sh "$output"; fi
}
bash() { "$real_bash" "$@"; }
if ! builtin command -v chmod >/dev/null; then chmod() { :; }; fi
EOF
    sed "s|/usr/local/bin|$dir/bin|g" install.sh >> "$dir/run.sh"
    if "$BASH" "$dir/run.sh" "$dir" "$mode" "$BASH" > "$dir/output" 2>&1; then
        case "$mode" in download-failure|invalid-script|non-root) cat "$dir/output"; exit 1 ;; esac
        cmp realm.sh "$dir/bin/rt"
        "$BASH" "$dir/bin/rt" --help | grep -q 'rt \[--update\]'
        if [[ $mode == ready ]]; then
            [[ ! -f $dir/packages ]]
        else
            grep -q "^$mode " "$dir/packages"
            grep -q 'bash curl ca-certificates' "$dir/packages"
        fi
    else
        case "$mode" in
            download-failure|invalid-script|non-root) cmp "$dir/original" "$dir/bin/rt" ;;
            *) cat "$dir/output"; exit 1 ;;
        esac
    fi
    if compgen -G "$dir/bin/.rt.*" >/dev/null; then printf 'Temporary installer file leaked\n'; exit 1; fi
    passed=$((passed+1))
    printf 'PASS %02d installer %s\n' "$passed" "$mode"
done

# README 的一键入口必须在下载失败时停止，并兼容 curl / wget。
entry=$(sed -n '/^sh -c /p' README.md)
[[ -n $entry ]]
for downloader in curl wget neither; do
    (
        curl() { [[ $downloader == curl ]] || return 22; printf 'printf "installer reached\\n"\n'; }
        wget() { [[ $downloader == wget ]] || return 22; printf 'printf "installer reached\\n"\n'; }
        export -f curl wget
        export downloader
        if eval "$entry" > "$work/entry-$downloader" 2>&1; then
            [[ $downloader != neither ]]
            grep -q '^installer reached$' "$work/entry-$downloader"
        else
            [[ $downloader == neither ]]
            ! grep -q 'installer reached' "$work/entry-$downloader"
        fi
    )
    passed=$((passed+1))
    printf 'PASS %02d one-click entry %s\n' "$passed" "$downloader"
done
printf '\n%d installer checks passed. Evidence: %s\n' "$passed" "$work"
