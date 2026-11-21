#!/bin/sh
# ============================================================
# uv2800 - 宿主侧 WebUI 协议 smoke（不连设备）
# 用法：sh dev/webui_host_smoke.sh
# 只验证：status ASCII/键、非法输入拒绝、features 默认/标记分支。
# 真机 apply/restore/锁/命名空间/策略 setter 不在本脚本范围。
# ============================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MOD="$ROOT/模块源目录"
WEBUI="$MOD/webui.sh"
FEAT="$MOD/lib/features.sh"
FAIL=0

ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; FAIL=1; }

[ -f "$WEBUI" ] || { echo "FAIL missing webui.sh"; exit 1; }
[ -f "$FEAT" ] || { echo "FAIL missing lib/features.sh"; exit 1; }

OUT=$(sh "$WEBUI" status 2>/tmp/uv-webui-smoke.err)
RC=$?
[ "$RC" = 0 ] && ok "status rc=0" || bad "status rc=$RC"
printf '%s
' "$OUT" | grep -q '^RESULT=ok$' && ok "status RESULT=ok" || bad "status RESULT"
printf '%s
' "$OUT" | grep -q '^NO_POLICY=no$' && ok "status NO_POLICY=no" || bad "status NO_POLICY"
printf '%s
' "$OUT" | grep -q '^POLICY=' && ok "status POLICY key" || bad "status POLICY key"
if printf '%s
' "$OUT" | LC_ALL=C grep -q '[^ -~]'; then
    bad "status non-ASCII"
else
    ok "status ASCII"
fi
[ -s /tmp/uv-webui-smoke.err ] && bad "status stderr not empty" || ok "status stderr empty"

sh "$WEBUI" set-real-soc 2 >/tmp/uv-webui-smoke.out 2>&1
grep -q 'CODE=invalid_value' /tmp/uv-webui-smoke.out && ok "set-real-soc 2 rejected" || bad "set-real-soc 2"
sh "$WEBUI" policy x >/tmp/uv-webui-smoke.out 2>&1
grep -q 'CODE=invalid_value' /tmp/uv-webui-smoke.out && ok "policy x rejected" || bad "policy x"

# features.sh 分支：用临时目录 + stub，不碰真机
T=$(mktemp -d) || exit 1
BK="$T"; XML="$T/devicepolicy.xml"; KEY=test_key
CS="$T/chip_soc"; CAP="$T/capacity"; CAPUE="$T/uevent"
: > "$XML"; : > "$CS"; : > "$CAP"
klog() { :; }
uv_unbind_capacity() { :; }
mount() { return 1; }
nsenter() { return 1; }
uv_log() { :; }
echo false > "$T/key"
su() {
    case "$*" in
        *" 4 s16 "*)
            case "$(cat "$T/key")" in
                true) echo "Parcel(00000000 00000004 00720074 00650075 00000000)" ;;
                false) echo "Parcel(00000000 00000005 00610066 0073006c 00000065)" ;;
                *) echo "Parcel(error)" ;;
            esac ;;
        *" s16 true i32 1") echo true > "$T/key" ;;
        *" s16 false i32 1") echo false > "$T/key" ;;
    esac
}
. "$FEAT"

feature_policy_sync
[ -f "$T/applied" ] && ok "policy default applies" || bad "policy default"
touch "$T/no_policy"
feature_policy_sync
[ -f "$T/no_policy" ] && [ ! -f "$T/applied" ] && ok "no_policy restores" || bad "no_policy"
rm -f "$T/no_policy" "$T/applied"
feature_policy_apply
[ -f "$T/applied" ] && ok "policy re-apply" || bad "policy re-apply"
touch "$T/skip"
feature_policy_sync
[ -f "$T/skip" ] && [ ! -f "$T/applied" ] && ok "skip restores" || bad "skip"

rm -f "$T/skip"
echo true > "$T/key"
feature_policy_apply
echo '<policy updated="yes"/>' > "$XML"
feature_policy_restore && [ "$(cat "$T/key")" = true ] && [ "$(cat "$XML")" = '<policy updated="yes"/>' ] &&
    ok "restore keeps original true and unrelated XML" || bad "policy preservation"
feature_policy_apply
echo error > "$T/key"
if feature_policy_restore || [ ! -f "$BK/policy_orig.txt" ]; then bad "failed readback lost backup"; else ok "failed readback retains backup"; fi

rm -f "$T/policy_orig.txt"
echo existed > "$T/orig_state"
echo '<boolean name="test_key" value="true" />' > "$T/devicepolicy_orig.xml"
echo false > "$T/key"
feature_policy_restore && [ "$(cat "$T/key")" = true ] && [ "$(cat "$XML")" = '<policy updated="yes"/>' ] &&
    ok "legacy backup restores only saved key" || bad "legacy key migration"

# 执行真实卸载脚本的临时副本，所有设备路径替换到本次测试目录。
mkdir -p "$T/mod/lib" "$T/backup"
cp "$FEAT" "$T/mod/lib/features.sh"
sed -e "s|/data/adb/uv2800_backup|$T/backup|g" -e "s|/sys/|$T/sys/|g" "$MOD/uninstall.sh" > "$T/mod/uninstall.sh"
printf '%s\n' 'uv_log() { :; }' 'uv_log_sep() { :; }' 'uv_unbind_capacity() { return 0; }' > "$T/mod/log.sh"
# Git for Windows 不提供 flock；此用例只验证清理判定。
mkdir -p "$T/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$T/bin/flock"
chmod +x "$T/bin/flock"
touch "$T/backup/skip"
echo 3250 > "$T/backup/adsp_orig.txt"
PATH="$T/bin:$PATH" sh "$T/mod/uninstall.sh" >/dev/null && [ -f "$T/backup/adsp_orig.txt" ] &&
    ok "unverified uninstall keeps backup" || bad "unverified uninstall"
echo 3250 > "$T/backup/restore_verified"
PATH="$T/bin:$PATH" sh "$T/mod/uninstall.sh" >/dev/null && [ ! -e "$T/backup" ] &&
    ok "verified uninstall removes module state" || bad "verified uninstall"

rm -rf "$T" /tmp/uv-webui-smoke.err /tmp/uv-webui-smoke.out
[ "$FAIL" = 0 ] && echo "RESULT=ok" || echo "RESULT=fail"
exit "$FAIL"
