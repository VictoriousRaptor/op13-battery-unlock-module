#!/system/bin/sh
# 模块卸载脚本：
#   1. 若内核模块仍在内存，将 hook 强制值设为原厂值并保持加载（避免 rmmod 重置 vbat_uv）
#   2. 解绑真实电量挂载，恢复本模块的设备策略键
#   3. WebUI 已确认恢复成功时清理备份目录

MODDIR=${0%/*}
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }


BK=/data/adb/uv2800_backup
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode

touch "$MODDIR/disable" || exit 1
mkdir -p "$BK" || exit 1
exec 9>>"$BK/.service.lock"
flock -x 9 || exit 1
uv_log_sep "uninstall.sh 卸载 开始"
echo "- uv2800 卸载"

P=/sys/module/uv2800/parameters
if [ -d "$P" ]; then
    _orig=$(cat "$BK/adsp_orig.txt" 2>/dev/null | tr -d "[:space:]")
    case "$_orig" in ''|*[!0-9]*) _orig="" ;; esac
    if [ -z "$_orig" ] || [ "$_orig" -lt 3000 ] 2>/dev/null || [ "$_orig" -gt 5000 ] 2>/dev/null; then
        _orig=$(uv_dt_orig 2>/dev/null)
    fi
    if [ -n "$_orig" ] && [ "$_orig" -ge 3000 ] 2>/dev/null; then
        echo "$_orig" > "$P/uv_shutdown_mv" 2>/dev/null
        echo "$_orig" > "$P/uv_target_mv" 2>/dev/null
        echo "$_orig" > "$P/uv_term_mv" 2>/dev/null
        echo "$_orig" > "$P/uv_adsp_mv" 2>/dev/null
        echo 1 > "$P/resume" 2>/dev/null
        sleep 1
        echo "- 已把 hook 强制值设为原厂 ${_orig} mV（vbat_uv=$(cat /sys/class/oplus_chg/battery/vbat_uv 2>/dev/null)）"
        uv_log "卸载前 hook 强制值设为原厂 ${_orig} mV"
    fi
fi

echo "- 模块已标记为禁用（hook 保持生效，vbat_uv 维持原厂值直到下次重启）"
uv_log "模块已禁用（未 rmmod，hook 保持生效）"

CAP=/sys/class/power_supply/battery/capacity
uv_unbind_capacity "$CAP"
_un=$?
if [ "$_un" -gt 0 ]; then
    echo "- 已恢复官方平滑电量显示（解绑 $_un 层）"
    uv_log "已恢复官方平滑电量显示（解绑 $_un 层）"
else
    echo "- 电量显示本来就是官方平滑值，无需恢复"
fi

. "$MODDIR/lib/features.sh"
feature_policy_restore || { echo "- 超级省电策略恢复失败，备份保留在 $BK"; exit 1; }

_verified=$(cat "$BK/restore_verified" 2>/dev/null)
if [ -f "$BK/skip" ] && [ -n "$_verified" ] && [ "$_verified" = "$(cat "$BK/adsp_orig.txt" 2>/dev/null)" ]; then
    rm -rf "$BK" || exit 1
    echo "- WebUI 已确认恢复原厂，模块备份、状态和日志已清理"
else
    uv_log "缺少 WebUI 恢复成功记录，保留 $BK 供核对"
fi
