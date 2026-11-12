#!/usr/bin/env bash
# Run with Bash and jq; all service and transaction effects are replaced below.
set -uo pipefail
exec 3>&2
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
source ./realm.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/interaction.XXXXXX") || exit 1
test_pid=$BASHPID
trap 'if [[ $BASHPID == "$test_pid" ]]; then rm -f -- "$work"/* "$work"/.[!.]*; rmdir -- "$work"; fi' EXIT
if [[ -n ${JQ_BIN:-} ]]; then
    jq() { "$JQ_BIN" --binary "$@"; }
fi
command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 1; }
passed=0
bad() { printf 'FAIL: %s\n' "$*" >&3; cat "$work/output" >&3; exit 1; }
check() { "$@" || bad "$*"; }
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
read() {
    local arg prompt_next=0
    for arg in "$@"; do
        if ((prompt_next)); then printf '%s\n' "$arg" >> "$work/prompts"; break; fi
        [[ $arg != -p ]] || prompt_next=1
    done
    builtin read "$@"
}
reset_case() { MENU_CANCELLED=0 INPUT_EOF=0; : > "$work/prompts"; : > "$work/output"; }
prompt_count() { check test "$(wc -l < "$work/prompts")" -eq "$1"; }
for reply in '' n N q Q; do
    reset_case
    confirm_action 'confirm' <<< "$reply" > "$work/output" 2>&1 && bad 'destructive action accepted cancellation'
    check test "$MENU_CANCELLED" -eq 1
    prompt_count 1
done
for reply in y Y; do
    reset_case
    check confirm_action 'confirm' <<< "$reply" > "$work/output" 2>&1
    prompt_count 1
done
reset_case
check confirm_action 'confirm' <<< $'invalid\ny' > "$work/output" 2>&1
prompt_count 2
check grep -q '请输入 y 或 n' "$work/output"
reset_case
confirm_action 'confirm' < /dev/null > "$work/output" 2>&1 && bad 'EOF confirmed action'
check test "$INPUT_EOF" -eq 1
pass 'confirmation defaults, invalid input, q/Q and EOF'

# Each operation must wait for Enter before drawing the main menu again.
menu_effect() { printf '%s\n' "$1" >> "$work/actions"; printf 'result:%s\n' "$1"; }
setup_menu_stubs() {
    core_version() { printf -v "$1" '%s' '2.9.6'; }
    jq() { printf '1\n'; }
    service_state() { printf -v "$1" '%s' '已停止'; }
    view_rules() { menu_effect view; }
    start_realm() { menu_effect start; }
    stop_realm() { menu_effect stop; }
    restart_realm() { menu_effect restart; }
    update_realm_action() { menu_effect core; }
    update_management_script() { menu_effect script; }
    uninstall() { menu_effect uninstall; }
}
(
    setup_menu_stubs
    : > "$work/actions"
    reset_case
    menu <<< $'2\n\n6\n\n7\n\n8\n\n9\n\nq' > "$work/output" 2>&1 || bad 'menu failed'
    check test "$(cat "$work/actions")" = $'view\nstart\nstop\nrestart\ncore'
    prompt_count 11
    check test "$(grep -c '按回车返回主菜单' "$work/prompts")" -eq 5
    check grep -q 'result:view' "$work/output"
    if grep -q $'\033\\[' "$work/output"; then
        # Colour is fine; erase-screen and erase-scrollback escape codes are not.
        grep -qE $'\033\\[(2J|3J|H)' "$work/output" && bad 'result was cleared'
    fi
    reset_case
    menu <<< 2 > "$work/output" 2>&1 || bad 'result pause EOF failed'
    prompt_count 2
    check grep -q '按回车返回主菜单' "$work/prompts"
    check test "$(grep -c '请输入选项' "$work/prompts")" -eq 1
    check grep -q 'result:view' "$work/output"
    reset_case
    menu < /dev/null > "$work/output" 2>&1 || bad 'menu EOF failed'
    prompt_count 1
    reset_case
    menu <<< Q > "$work/output" 2>&1 || bad 'Q did not exit'
    prompt_count 1
    reset_case
    menu <<< $'invalid\n\n0' > "$work/output" 2>&1 || bad 'invalid menu input failed'
    prompt_count 3
    edit_rule() { read_input cancelled 'cancel test'; }
    reset_case
    menu <<< $'1\nq\n0' > "$work/output" 2>&1 || bad 'cancel failed'
    prompt_count 3
    grep -q '按回车返回' "$work/prompts" && bad 'cancel asked for another Enter'
    pass 'results wait for Enter, menus do not redraw early, cancellation returns directly'
) || exit 1

# Reload is intercepted here so no installed command or real service is touched.
(
    setup_menu_stubs
    reload_script() { touch "$work/reloaded"; }
    reset_case
    menu <<< $'10\n' > "$work/output" 2>&1 || bad 'script update failed'
    prompt_count 2
    check test -f "$work/reloaded"
    check grep -q '按回车加载最新脚本' "$work/prompts"
    rm -f -- "$work/reloaded"
    reset_case
    menu <<< 10 > "$work/output" 2>&1 || bad 'reload EOF failed'
    prompt_count 2
    check test ! -f "$work/reloaded"
    pass 'script updates wait for Enter and skip reload on EOF'
) || exit 1

DIR=$work
CONF=$work/config.json
UNIT=$work/realm.service
apply_rules() { cp "$1" "$CONF"; printf 'applied\n' >> "$work/transactions"; }
svc() { return 1; }
ss() { return 0; }
show_resolution() { return 0; }
fixture() {
    : > "$work/transactions"
    printf '%s\n' '{"network":{"no_tcp":false,"use_udp":false},"endpoints":[{"listen":"[::]:1080","remote":"example.com:443","name":"original","network":{"no_tcp":false,"use_udp":false}}]}' > "$CONF"
}
fixture
reset_case
check edit_rule 0 <<< $'1\nnew-name\n\n2\nnew.example\n\n3\n20000\n\n4\n8443\n\n5\n3\n\n0' > "$work/output" 2>&1
prompt_count 16
check test "$(wc -l < "$work/transactions")" -eq 5
check jq -e '.endpoints[0] | .name=="new-name" and .listen=="[::]:20000" and .remote=="new.example:8443" and .network.use_udp==true and .network.no_tcp==false' "$CONF" >/dev/null
pass 'field menu edits name, host, both ports and protocol directly'
for reply in q Q; do
    fixture
    reset_case
    edit_rule 0 <<< $'1\n'"$reply" > "$work/output" 2>&1 && bad 'cancelled edit succeeded'
    prompt_count 2
    check test ! -s "$work/transactions"
done
fixture
reset_case
edit_rule 0 <<< 1 > "$work/output" 2>&1 && bad 'EOF edit succeeded'
check test "$INPUT_EOF" -eq 1
check test ! -s "$work/transactions"
reset_case
check edit_rule 0 <<< $'1\n\n3\n\n4\n\n5\n\n0' > "$work/output" 2>&1
prompt_count 9
check test ! -s "$work/transactions"
pass 'cancelled, unchanged and incomplete edits do not save'
fixture
reset_case
check edit_rule <<< $'20001\nnew.example\n443\n1\nnew-rule' > "$work/output" 2>&1
prompt_count 5
check jq -e '.endpoints|length==2' "$CONF" >/dev/null
pass 'adding still collects only the required rule fields'

for reply in '' 0 00 q Q; do
    fixture
    reset_case
    choose_rule selected 删除 <<< "$reply" > "$work/output" 2>&1 && bad 'cancelled selection succeeded'
    check test "$MENU_CANCELLED" -eq 1
done
fixture
reset_case
check choose_rule selected 删除 <<< 1 > "$work/output" 2>&1
check delete_rules "$selected" < /dev/null >> "$work/output" 2>&1
prompt_count 1
check grep -q '选中即删除' "$work/prompts"
check jq -e '.endpoints|length==0' "$CONF" >/dev/null
pass 'single deletion uses only the explicit selector'

for reply in '' n q; do
    fixture
    reset_case
    delete_rules -1 <<< "$reply" > "$work/output" 2>&1 && bad 'clear accepted cancellation'
    prompt_count 1
    check test ! -s "$work/transactions"
    reset_case
    uninstall <<< "$reply" > "$work/output" 2>&1 && bad 'uninstall accepted cancellation'
    prompt_count 1
done
fixture
reset_case
check delete_rules -1 <<< Y > "$work/output" 2>&1
prompt_count 1
check jq -e '.endpoints|length==0' "$CONF" >/dev/null
pass 'clear requires one confirmation and uninstall cancels before service effects'
printf 'All Realm interaction checks passed.\n'
