#!/system/bin/sh
# 用户可选功能实现库（由 service.sh 和 webui.sh 共用）：
#   1. 真实电量显示（bind-mount chip_soc -> capacity，由 $BK/no_real_soc 控制）
#   2. 禁止 1% 强制超级省电（oplusdevicepolicy，由 $BK/no_policy 控制）
#   当 $BK/skip 存在时优先解绑并恢复原厂设备策略。

feature_real_soc_bind() {
    uv_unbind_capacity "$CAP" "$CAPUE"
    _frs_bound=0
    # 优先进入 PID 1 的全局挂载命名空间执行绑定，确保 system_server 可见
    if command -v nsenter >/dev/null 2>&1; then
        if nsenter -t 1 -m -- mount --bind "$CS" "$CAP" 2>/dev/null; then
            _frs_bound=1
            klog "已绑定 chip_soc -> capacity（nsenter -t 1 -m，全局命名空间）"
        fi
    fi
    if [ "$_frs_bound" = "0" ] && mount --bind "$CS" "$CAP" 2>/dev/null; then
        _frs_bound=1
        klog "已绑定 chip_soc -> capacity（当前命名空间）"
    fi
    if [ "$_frs_bound" = "1" ]; then
        echo change > "$CAPUE" 2>/dev/null
        return 0
    fi
    klog "bind mount 失败，保留官方平滑电量"
    return 1
}

feature_real_soc_unbind() {
    uv_unbind_capacity "$CAP" "$CAPUE"
}

feature_real_soc_sync() {
    if [ -f "$BK/no_real_soc" ]; then
        feature_real_soc_unbind
        klog "检测到 no_real_soc 标记，已解绑真实电量显示"
    elif [ -f "$BK/skip" ]; then
        feature_real_soc_unbind
        klog "检测到 skip 标记（已手动恢复），已解绑真实电量显示"
    else
        feature_real_soc_bind
    fi
}

uv_policy_decode() {
    awk '
    /Parcel\(/ {parcel=1}
    parcel {
        line=$0
        sub(/^[[:space:]]*0x[[:xdigit:]]+:[[:space:]]*/, "", line)
        sub(/^.*Parcel\(/, "", line)
        sub(/\047.*$/, "", line)
        gsub(/[()]/, " ", line)
        n=split(line,a,/[[:space:]]+/)
        for(i=1;i<=n;i++) if(length(a[i])==8 && a[i] !~ /[^0-9a-fA-F]/) w[++k]=tolower(a[i])
    }
    END {
        if(w[1]!="00000000") exit 1
        if(k==2 && w[2]=="ffffffff") print "absent"
        else if(k==5 && w[2]=="00000004" && w[3]=="00720074" && w[4]=="00650075" && w[5]=="00000000") print "true"
        else if(k==5 && w[2]=="00000005" && w[3]=="00610066" && w[4]=="0073006c" && w[5]=="00000065") print "false"
        else exit 1
    }'
}

uv_policy_read() {
    _uv_parcel=$(su 1000 -c "service call oplusdevicepolicy 4 s16 $KEY i32 1" 2>&1) || return 1
    printf '%s\n' "$_uv_parcel" | uv_policy_decode
}

# 新版只备份本模块策略键。旧备份能确认原键缺失时沿用默认行为。
feature_policy_original() {
    if [ -f "$BK/policy_orig.txt" ]; then
        cat "$BK/policy_orig.txt"
    elif [ -f "$BK/orig_state" ]; then
        case "$(cat "$BK/orig_state")" in
            absent) echo absent ;;
            existed)
                [ -s "$BK/devicepolicy_orig.xml" ] || return 1
                # 旧版保留了整份策略文件。只取能明确识别的单键布尔值。
                awk -v key="$KEY" '
                    /<[^>]+>/ { xml=1 }
                    index($0, key) {
                        hits++
                        if ($0 ~ ("<" key ">true</" key ">") ||
                            $0 ~ ("<boolean name=\"" key "\" value=\"true\"[[:space:]]*/>")) value="true"
                        else if ($0 ~ ("<" key ">false</" key ">") ||
                            $0 ~ ("<boolean name=\"" key "\" value=\"false\"[[:space:]]*/>")) value="false"
                    }
                    END {
                        if (!xml) exit 1
                        if (!hits) print "absent"
                        else if (hits == 1 && value != "") print value
                        else exit 1
                    }' "$BK/devicepolicy_orig.xml" ;;
            *) return 1 ;;
        esac
    else
        [ ! -f "$BK/applied" ] && uv_policy_read
    fi
}

feature_policy_restore() {
    [ -f "$BK/policy_orig.txt" ] || [ -f "$BK/orig_state" ] || [ -f "$BK/applied" ] || return 0
    _fpr_orig=$(feature_policy_original) || {
        uv_log "无法确定旧策略键原值，请核对 $BK/devicepolicy_orig.xml；已保留备份"
        return 1
    }
    case "$_fpr_orig" in true|false|absent) ;; *) return 1 ;; esac
    _fpr_cur=$(uv_policy_read) || return 1
    if [ "$_fpr_cur" != "$_fpr_orig" ]; then
        [ "$_fpr_orig" = absent ] && _fpr_orig=false
        if [ "$_fpr_cur" != "$_fpr_orig" ]; then
            su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 $_fpr_orig i32 1" >/dev/null 2>&1 || return 1
            [ "$(uv_policy_read)" = "$_fpr_orig" ] || return 1
        fi
    fi
    rm -f "$BK/applied" "$BK/orig_state" "$BK/devicepolicy_orig.xml" "$BK/policy_orig.txt"
}

feature_policy_apply() {
    _fpa_i=0; _fpa_ok=0
    while [ "$_fpa_i" -lt 60 ]; do
        _fpa_out=$(su 1000 -c "service call oplusdevicepolicy 4 s16 $KEY i32 1" 2>&1)
        case "$_fpa_out" in
            *Parcel*) _fpa_ok=1; break ;;
            *"Transaction too large"*)
                klog "⚠️ oplusdevicepolicy 出现 Transaction too large（/data/system 下策略 XML 堆积）"
                klog "   请将本日志反馈作者；本次跳过设备策略，不影响其他功能"
                _fpa_ok=-1; break
                ;;
        esac
        sleep 1
        _fpa_i=$((_fpa_i + 1))
    done
    if [ "$_fpa_ok" = "1" ]; then
        if [ ! -f "$BK/policy_orig.txt" ]; then
            _fpa_orig=$(feature_policy_original) || return 1
            case "$_fpa_orig" in true|false|absent) ;; *) return 1 ;; esac
            printf '%s\n' "$_fpa_orig" > "$BK/policy_orig.tmp" &&
                mv "$BK/policy_orig.tmp" "$BK/policy_orig.txt" || return 1
        fi
        su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 true i32 1" >/dev/null 2>&1 || return 1
        [ "$(uv_policy_read)" = true ] && touch "$BK/applied" || return 1
        klog "设备策略 $KEY=true（waited ${_fpa_i}s）"
        return 0
    elif [ "$_fpa_ok" = "0" ]; then
        klog "⚠️ 等待 oplusdevicepolicy 服务超时（60s），设备策略未应用（下次开机重试）"
        return 1
    fi
    return 1
}

feature_policy_sync() {
    if [ -f "$BK/skip" ]; then
        feature_policy_restore || return 1
        klog "检测到 skip 标记（已手动恢复），已恢复设备策略"
        klog "若要重新自动应用，请 rm $BK/skip"
    elif [ -f "$BK/no_policy" ]; then
        feature_policy_restore || return 1
        klog "检测到 no_policy 标记，已恢复设备策略（仅策略，不影响 ADSP）"
    else
        feature_policy_apply
    fi
}
