#!/bin/bash
#
# glic-probe.sh — 用「哨兵法」确定性验证 Gemini 按钮的地区判定结果
#
# 为什么要哨兵
#   glic.profile_enablement.last_ready_state 是个「上次观测到的状态」缓存，
#   Chrome **只在状态发生变化时**才写它。所以直接读它无法区分
#   「这次真的算出了 ready」和「还是上次留下的旧值」。
#   本脚本先把该字段写成 2(ready) 当哨兵，再启动 Chrome；
#   若启动后它被改成别的值，就说明 Chrome 确实重新计算过，且结果是新值。
#
# 用法
#   ./glic-probe.sh                       # 不带额外参数启动（复现默认行为）
#   ./glic-probe.sh "--variations-override-country=us"
#   ./glic-probe.sh "--enable-features=GlicCountryFiltering:enabled_countries/*"
#
# 环境变量
#   CHROME_DIR   用户数据目录（同 fix-chrome-glic.sh）
#   WAIT         启动后等待秒数，默认 35
#
set -uo pipefail

CHROME_DIR="${CHROME_DIR:-$HOME/Library/Application Support/Google/Chrome}"
WAIT="${WAIT:-35}"
ARGS="${1:-}"

echo "### 用户数据目录: $CHROME_DIR"
echo "### 额外启动参数: ${ARGS:-<无>}"
echo

osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 45); do
  pgrep -x "Google Chrome" >/dev/null 2>&1 || break
  sleep 1
done
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  echo "✗ Chrome 未能在 45 秒内退出，中止"; exit 1
fi

/usr/bin/python3 - "$CHROME_DIR" <<'PY'
import json, os, sys, glob
cd = sys.argv[1]
def atomic(obj, path):
    t = path + ".tmp"
    json.dump(obj, open(t, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    os.replace(t, path)

st_path = os.path.join(cd, "Local State")
st = json.load(open(st_path, encoding="utf-8"))
st.setdefault("profile", {}).setdefault("info_cache", {}).setdefault("Default", {})["is_glic_eligible"] = True
atomic(st, st_path)

for pref in sorted(glob.glob(os.path.join(cd, "*/Preferences"))):
    try:
        pf = json.load(open(pref, encoding="utf-8"))
    except Exception:
        continue
    g = pf.setdefault("glic", {})
    g.setdefault("profile_enablement", {})["last_ready_state"] = 2   # 哨兵
    g["previously_not_allowed"] = False
    atomic(pf, pref)
    print(f"  哨兵已写入 {os.path.basename(os.path.dirname(pref))}: last_ready_state=2, is_glic_eligible=True")
PY

if [ -n "$ARGS" ]; then
  # shellcheck disable=SC2086
  open -a "Google Chrome" --args $ARGS
else
  open -a "Google Chrome"
fi
echo "  已启动，等待 ${WAIT}s ..."
sleep "$WAIT"

/usr/bin/python3 - "$CHROME_DIR" <<'PY'
import json, os, sys, glob
cd = sys.argv[1]
names = {0:"error",1:"sign-in-required",2:"ready",3:"disabled-by-admin",
         4:"ineligible",5:"location-mismatch",6:"ineligible-account"}
st = json.load(open(os.path.join(cd, "Local State"), encoding="utf-8"))
ic = st.get("profile", {}).get("info_cache", {})
print("  国家字段:")
print(f"    variations_country                      = {st.get('variations_country')!r}")
print(f"    variations_permanent_consistency_country= {st.get('variations_permanent_consistency_country')!r}")
print(f"    variations_permanent_overridden_country = {st.get('variations_permanent_overridden_country', '(未设置)')!r}")
for name, info in ic.items():
    if isinstance(info, dict) and "is_glic_eligible" in info:
        print(f"    info_cache.{name}.is_glic_eligible        = {info['is_glic_eligible']}")
print("  判定结果:")
for pref in sorted(glob.glob(os.path.join(cd, "*/Preferences"))):
    try:
        pf = json.load(open(pref, encoding="utf-8"))
    except Exception:
        continue
    g = pf.get("glic")
    if not g:
        continue
    rs = g.get("profile_enablement", {}).get("last_ready_state")
    prof = os.path.basename(os.path.dirname(pref))
    verdict = "哨兵未被改动 / 需再触发一次面板" if rs == 2 else "Chrome 已重算"
    print(f"    [{prof}] last_ready_state = {rs} ({names.get(rs,'?')})   <- {verdict}")
    print(f"    [{prof}] previously_not_allowed = {g.get('previously_not_allowed')}")
PY
