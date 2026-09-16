#!/usr/bin/env bash
set +o posix
set -euo pipefail
export PATH="/usr/bin:$PATH"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=.
source "$ROOT/realm.sh"
INIT=${1:-systemd}
[[ $INIT == systemd || $INIT == openrc ]] || exit 1
mkdir -p "$ROOT/.test-work"
WORK=$(mktemp -d "$ROOT/.test-work/run.XXXXXX")
passed=0
pass() { passed=$((passed+1)); printf 'PASS %02d %s\n' "$passed" "$1"; }
bad() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
expect_fail() { if "$@" > "$WORK/expected-error.log" 2>&1; then bad "unexpected success: $*"; fi; }
equal() { [[ $1 == "$2" ]] || bad "expected [$2], got [$1]"; }

# Windows 使用官方 jq，关闭 CRLF 转换；Linux 直接用本机 jq。
if [[ -x $ROOT/.test-tools/jq.exe ]]; then jq() { "$ROOT/.test-tools/jq.exe" --binary "$@"; }; fi
if ! command -v sha256sum >/dev/null; then
    sha256sum() { node -e 'const fs=require("fs"),c=require("crypto");console.log(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex")+"  "+process.argv[1])' "$1"; }
fi
# 精简 Windows Git 不带 chmod；权限设置需要在 Linux 上验证。
if ! command -v chmod >/dev/null; then chmod() { :; }; fi
# 系统服务替身；所有操作均在独立临时目录，不接触真实主机。
systemctl() {
    printf '%s\n' "$*" >> "$DIR/service.calls"
    case "$1" in
        show)
            case "$4" in
                FragmentPath) [[ ! -f $UNIT ]] || printf '%s\n' "$UNIT" ;;
                ExecStart) printf 'path=%s ; argv[]=%s -c %s\n' "$BIN" "$BIN" "$CONF" ;;
                MainPID) printf '4242\n' ;;
            esac ;;
        is-active) [[ -f $DIR/active ]] ;;
        is-enabled) [[ -f $DIR/enabled ]] ;;
        enable) touch "$DIR/enabled" ;;
        disable)
            rm -f "$DIR/enabled"
            if [[ -f $DIR/fail-disable-once ]]; then rm -f "$DIR/fail-disable-once"; return 1; fi ;;
        stop) rm -f "$DIR/active" ;;
        start|restart)
            if [[ -f $DIR/fail-binary && $(cat "$BIN") == "$(cat "$DIR/fail-binary")" ]]; then return 1; fi
            if jq -e '.endpoints | any(.remote == "fail.example:443")' "$CONF" >/dev/null; then return 1; fi
            touch "$DIR/active" ;;
        daemon-reload|reset-failed) : ;;
        *) return 1 ;;
    esac
}
rc-service() {
    [[ $1 == realm ]] || return 1
    if [[ $2 == status ]]; then systemctl is-active --quiet realm
    else systemctl "$2" realm; fi
}
rc-update() {
    [[ $2 == realm && $3 == default ]] || return 1
    case "$1" in
        add) touch "$RUNLEVEL/realm"; systemctl enable realm ;;
        del) rm -f "$RUNLEVEL/realm"; systemctl disable realm ;;
        *) return 1 ;;
    esac
}
pgrep() {
    [[ $1 == -f && $2 == -x && $3 == "$BIN -c ${CONF//./\\.}" && -f $DIR/active ]] || return 1
    printf '4242\n'
}
sleep() { :; }
ss() {
    if [[ $* == *-ltnp* ]]; then
        [[ -f $DIR/active ]] || return 0
        jq -r '.endpoints[].listen' "$CONF" | while read -r listen; do
            [[ ! -f $DIR/missing-port || $listen != *":$(cat "$DIR/missing-port")" ]] || continue
            printf 'LISTEN 0 128 %s *:* users:(("realm",pid=4242,fd=7))\n' "$listen"
        done
    elif [[ -f $DIR/occupied-port && $* == *":$(cat "$DIR/occupied-port")"* ]]; then
        printf 'LISTEN 0 128 0.0.0.0:%s *:*\n' "$(cat "$DIR/occupied-port")"
    fi
}
version() { [[ -f $1 ]] && head -n 1 "$1"; }
new_case() {
    DIR="$WORK/$1"; mkdir -p "$DIR/service" "$DIR/runlevel"
    BIN="$DIR/realm"; CONF="$DIR/config.json"; UNIT="$DIR/service/realm.service"
    RUNLEVEL="$DIR/runlevel"
    [[ $INIT != openrc ]] || UNIT="$DIR/service/realm"
    [[ $OSTYPE != msys* ]] || BIN+=.exe
    printf '2.6.0\n' > "$BIN"; chmod 755 "$BIN"
}

new_case legacy
cat > "$DIR/config.toml" <<'EOF'
[[endpoints]]
listen = "[::]:10000"
remote = "example.com:443"
[[endpoints]]
listen = "[::]:10001"
remote = "[2001:db8::1]:8443"
EOF
cp "$DIR/config.toml" "$DIR/original.toml"
init_config
equal "$(jq '.endpoints|length' "$CONF")" 2
equal "$(jq -r '.endpoints[1].remote' "$CONF")" '[2001:db8::1]:8443'
cmp "$DIR/config.toml" "$DIR/original.toml"
pass 'original TOML imports without modifying the original file'

new_case custom
printf '[network]\nuse_udp = true\n' > "$DIR/config.toml"
expect_fail init_config
[[ ! -e $CONF ]] || bad 'unsupported TOML was overwritten'
pass 'custom legacy options are rejected without losing configuration'

new_case rules
init_config
save_rule -1 10000 example.com 443 > /dev/null
save_rule -1 10001 '[2001:db8::1]' 8443 > /dev/null
equal "$(jq '.endpoints|length' "$CONF")" 2
[[ -f $DIR/active && -f $DIR/enabled ]] || bad 'add did not activate service'
pass 'adding IPv4/domain and IPv6 rules enables and starts the service'

check_service
if [[ $INIT == openrc ]]; then
    grep -q '^supervisor="supervise-daemon"$' "$UNIT"
    grep -q '^    use net$' "$UNIT"
    /usr/bin/sh -n "$UNIT"
else
    grep -q '^WantedBy=multi-user.target$' "$UNIT"
fi
pass "$INIT service definition and existing-service ownership check"

expect_fail save_rule -1 10000 duplicate.example 443
expect_fail save_rule -1 65536 example.com 443
expect_fail save_rule -1 10002 'example.com"\n injected' 443
expect_fail save_rule -1 10002 example.com 0
equal "$(jq '.endpoints|length' "$CONF")" 2
pass 'duplicate ports, invalid ports and injected target strings are rejected'

printf '10003' > "$DIR/occupied-port"
expect_fail save_rule -1 10003 example.com 443
pass 'a port owned by another process is rejected before service changes'

save_rule 0 10004 changed.example 8443 > /dev/null
equal "$(jq -r '.endpoints[0].listen' "$CONF")" '0.0.0.0:10004'
equal "$(jq -r '.endpoints[0].remote' "$CONF")" 'changed.example:8443'
pass 'editing updates both listening port and destination'

cp "$CONF" "$DIR/expected.json"
expect_fail save_rule 0 10004 fail.example 443
cmp "$CONF" "$DIR/expected.json"
[[ -f $DIR/active && -f $DIR/enabled ]] || bad 'configuration rollback lost running state'
pass 'failed restart restores configuration and running state'

printf '10005' > "$DIR/missing-port"
expect_fail save_rule -1 10005 example.com 443
cmp "$CONF" "$DIR/expected.json"
rm "$DIR/missing-port"
pass 'a running process with a missing listener is treated as failure'

delete_rules 0 > /dev/null
equal "$(jq '.endpoints|length' "$CONF")" 1
equal "$(jq -r '.endpoints[0].listen' "$CONF")" '0.0.0.0:10001'
pass 'delete removes the entire selected rule and preserves the other rule'

touch "$DIR/fail-disable-once"
expect_fail delete_rules -1 <<< y
equal "$(jq '.endpoints|length' "$CONF")" 1
[[ -f $DIR/active && -f $DIR/enabled ]] || bad 'clear rollback lost enabled state'
pass 'failed clear restores rules, running state and boot enablement'

delete_rules -1 <<< y > /dev/null
equal "$(jq '.endpoints|length' "$CONF")" 0
[[ ! -f $DIR/active && ! -f $DIR/enabled ]] || bad 'empty service still active/enabled'
save_rule -1 10006 restored.example 443 > /dev/null
[[ -f $DIR/active && -f $DIR/enabled ]] || bad 'new rule after clear not activated'
pass 'clear stops/disables the service; adding again starts/enables it'

menu <<< 0 > "$WORK/menu.txt"
grep -q '\[5\] 清空所有转发规则' "$WORK/menu.txt"
grep -q '\[0\] 退出脚本' "$WORK/menu.txt"
if grep -Eq '切换转发引擎|返回上级菜单|安装|更新' "$WORK/menu.txt"; then bad 'unexpected menu entry'; fi
pass 'opening the script goes straight to the requested Realm-only menu'

META="$ROOT/.test-tools/realm-release.json"
for arch in x86_64 aarch64 armv7l; do
    select_asset "$META" "$arch"
    [[ $URL == *musl*.tar.gz && $HASH == sha256:* ]] || bad 'wrong official asset selected'
done
expect_fail select_asset "$META" riscv64
jq '.prerelease=true' "$META" > "$WORK/prerelease.json"
expect_fail select_asset "$WORK/prerelease.json" x86_64
jq '(.assets[].digest)=null' "$META" > "$WORK/no-digest.json"
expect_fail select_asset "$WORK/no-digest.json" x86_64
pass 'live release metadata selects 3 architectures and rejects unsupported/unverifiable releases'

# 用可校验的归档测试完整安装事务；仅替换版本读取和外部服务，不模拟事务本身。
mkdir -p "$WORK/package"
printf '2.9.6\n' > "$WORK/package/realm"
tar -czf "$WORK/package.tar.gz" -C "$WORK/package" realm
sum=$(sha256sum "$WORK/package.tar.gz"); sum=${sum%% *}
jq -n --arg hash "sha256:$sum" '{tag_name:"v2.9.6",draft:false,prerelease:false,assets:[{
  name:"realm-x86_64-unknown-linux-musl.tar.gz",
  browser_download_url:"https://github.com/zhboner/realm/releases/download/v2.9.6/realm-x86_64-unknown-linux-musl.tar.gz",
  digest:$hash}]}' > "$WORK/release.json"
uname() { [[ ${1:-} != -m ]] || printf 'x86_64\n'; }
get() {
    [[ ! -f $DIR/network-failure ]] || return 22
    if [[ $1 == "$API" ]]; then cp "$WORK/release.json" "$2"; else cp "$WORK/package.tar.gz" "$2"; fi
    if [[ -f $DIR/corrupt-download && $1 != "$API" ]]; then printf broken >> "$2"; fi
}

new_case first-install
init_config
rm "$BIN"
save_rule -1 12000 example.com 443 > /dev/null
equal "$(version "$BIN")" 2.9.6
[[ -f $DIR/active && -f $DIR/enabled ]] || bad 'first install did not start/enable service'
pass 'first rule installs the latest core automatically and activates forwarding'

svc stop
svc disable
delete_rules -1 <<< y > /dev/null
equal "$(jq '.endpoints|length' "$CONF")" 0
[[ ! -f $DIR/active && ! -f $DIR/enabled ]] || bad 'clearing disabled service enabled it'
pass 'clearing an already stopped/disabled service succeeds'

new_case update
init_config
save_rule -1 11000 example.com 443 > /dev/null
cp "$CONF" "$DIR/expected.json"
update_realm > /dev/null
equal "$(version "$BIN")" 2.9.6
equal "$(version "$BIN.bak")" 2.6.0
cmp "$CONF" "$DIR/expected.json"
[[ -f $DIR/active ]] || bad 'updated service not active'
pass 'successful upgrade keeps rules and backs up the previous binary'

cp "$DIR/service.calls" "$DIR/calls-before"
update_realm > /dev/null
cmp "$DIR/service.calls" "$DIR/calls-before"
pass 'already-latest upgrade does not restart the service'

printf '2.6.0\n' > "$BIN"
touch "$DIR/corrupt-download"
expect_fail update_realm
equal "$(version "$BIN")" 2.6.0
[[ -f $DIR/active ]] || bad 'corrupt download affected the service'
rm "$DIR/corrupt-download"
touch "$DIR/network-failure"
expect_fail update_realm
equal "$(version "$BIN")" 2.6.0
rm "$DIR/network-failure"
pass 'checksum and download failures leave the original program running'

printf '2.9.6' > "$DIR/fail-binary"
expect_fail update_realm
equal "$(version "$BIN")" 2.6.0
cmp "$CONF" "$DIR/expected.json"
[[ -f $DIR/active ]] || bad 'upgrade rollback did not restore service'
rm "$DIR/fail-binary"
pass 'a failed new binary startup rolls back to the running old version'

rm "$DIR/active"
update_realm > /dev/null
equal "$(version "$BIN")" 2.9.6
[[ ! -f $DIR/active ]] || bad 'stopped service was unexpectedly started'
pass 'upgrading a stopped service preserves its stopped state'

printf '\n%d behavior checks passed (%s). Evidence: %s\n' "$passed" "$INIT" "$WORK"
