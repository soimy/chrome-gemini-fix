#!/bin/bash
#
# fix-chrome-glic.sh — 解除 Chrome「Gemini in Chrome」的地区永久锁定
#
# 适用症状
#   Gemini 按钮出现在工具栏（或显示为错误态），但点了提示不可用/地区不支持。
#   Chrome 的 Local State / Preferences 里可以看到：
#       glic.profile_enablement.last_ready_state = 5
#       profile.info_cache.<Profile>.is_glic_eligible = false
#
# 根因
#   Chrome 每次抓 variations seed 时，会把服务端给的国家连同 **Chrome 版本号**
#   写进 Local State：
#       variations_permanent_consistency_country = ["<version>", "<country>"]
#   而 components/variations/service/variations_field_trial_creator.cc 的
#   LoadPermanentConsistencyCountry() 只要发现「存的版本号 == 当前版本」就直接
#   返回那个国家，**永远不再采纳服务端新给的值** —— 这是 Google 防止用户靠换出口
#   来切换地区灰度（Finch）的刻意设计。
#
#   Glic 的国家过滤读的正是这个值（见 chrome/browser/glic/public/glic_enabling.cc）：
#       GlicEnablingDelegate::GetPermanentCountryCode()
#         -> variations::GetCurrentCountryCode(variations_service())
#         -> variations->GetStoredPermanentCountry()
#   不在 enabled_countries 名单里 => allowed_by_country_filter = false
#   按钮已 anchored 时 GetProfileReadyState() 就返回 kLocationMismatch(=5)。
#
#   所以：只把 DNS / 出口修好是不够的，Chrome 内部的国家值必须一起纠正。
#
# 取值优先级（同一个函数内，从上到下）
#   1. --variations-override-country=<cc>        命令行开关，最高，但不持久
#   2. variations_permanent_overridden_country   <-- 本脚本写入的持久化覆盖
#   3. variations_permanent_consistency_country  ["version", "country"]
#   4. seed 带回的 latest country
#
#   实测结论（详见 docs/evidence-log.md）：
#     * 只改 3（按社区通行做法）→ 仍为 5 (location-mismatch)
#     * 加 1               → 2 (ready)
#     * 加 2（免启动参数） → 2 (ready)  ← 本脚本采用
#
# 用法
#   ./fix-chrome-glic.sh              # 退出 Chrome → 备份 → 打补丁 → 重开
#   ./fix-chrome-glic.sh --check      # 只读诊断，不改任何东西
#   ./fix-chrome-glic.sh --country=us # 指定目标国家（默认 us）
#
# 环境变量
#   CHROME_DIR   用户数据目录，默认 ~/Library/Application Support/Google/Chrome
#                （Beta/Dev/Canary 分别是 .../Google/Chrome Beta 等）
#   COUNTRY      目标国家代码，等价于 --country
#
set -euo pipefail

CHROME_DIR="${CHROME_DIR:-$HOME/Library/Application Support/Google/Chrome}"
STATE="$CHROME_DIR/Local State"
COUNTRY="${COUNTRY:-us}"
MODE="apply"

for arg in "$@"; do
  case "$arg" in
    --check)          MODE="check" ;;
    --country=*)      COUNTRY="${arg#*=}" ;;
    -h|--help)        sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $arg（--help 查看用法）" >&2; exit 2 ;;
  esac
done
COUNTRY="$(printf '%s' "$COUNTRY" | tr '[:upper:]' '[:lower:]')"

READY_NAMES='{0:"error",1:"sign-in-required",2:"ready",3:"disabled-by-admin",4:"ineligible",5:"location-mismatch",6:"ineligible-account"}'

show_state() {
  /usr/bin/python3 - "$CHROME_DIR" <<PY
import json, os, glob
cd = "$CHROME_DIR"
state = os.path.join(cd, "Local State")
if not os.path.exists(state):
    print("  (找不到 Local State)"); raise SystemExit(0)
st = json.load(open(state, encoding="utf-8"))
names = $READY_NAMES
print(f"  variations_country                      = {st.get('variations_country')!r}")
print(f"  variations_permanent_consistency_country= {st.get('variations_permanent_consistency_country')!r}")
print(f"  variations_permanent_overridden_country = {st.get('variations_permanent_overridden_country', '(未设置)')!r}")
ic = st.get("profile", {}).get("info_cache", {})
for name, info in ic.items():
    if isinstance(info, dict) and "is_glic_eligible" in info:
        print(f"  info_cache.{name}.is_glic_eligible        = {info['is_glic_eligible']}")
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
    print(f"  [{prof}] last_ready_state = {rs} ({names.get(rs, '?')})"
          f"   previously_not_allowed = {g.get('previously_not_allowed')}")
PY
}

echo "== 环境 =="
echo "  用户数据目录: $CHROME_DIR"
echo "  目标国家    : $COUNTRY"
[ -f "$STATE" ] || { echo "✗ 找不到 Local State: $STATE" >&2; exit 1; }
echo
echo "== 当前状态 =="
show_state

if [ "$MODE" = "check" ]; then
  echo
  echo "(--check 模式，未做任何修改)"
  exit 0
fi

echo
echo "== 退出 Chrome =="
# 只用 -x 精确匹配主进程名，避免误伤 Helper 子进程
WAS_RUNNING=0
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "  Chrome 正在运行，发送优雅退出（不是强杀）"
  osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    pgrep -x "Google Chrome" >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -x "Google Chrome" >/dev/null 2>&1; then
    echo "  ✗ Chrome 60 秒内未退出，已中止（未做任何修改）" >&2
    exit 1
  fi
  echo "  ✓ 已退出"
else
  echo "  ✓ Chrome 本来就没在运行"
fi

STAMP="$(date +%Y%m%d%H%M%S)"
echo
echo "== 备份 =="
cp -p "$STATE" "$STATE.bak-$STAMP"
echo "  ✓ $STATE.bak-$STAMP"
for pref in "$CHROME_DIR"/*/Preferences; do
  [ -f "$pref" ] || continue
  cp -p "$pref" "$pref.bak-$STAMP"
  echo "  ✓ $pref.bak-$STAMP"
done

echo
echo "== 打补丁 =="
/usr/bin/python3 - "$CHROME_DIR" "$COUNTRY" <<'PY'
import json, os, sys, glob

chrome_dir, country = sys.argv[1], sys.argv[2]
state_path = os.path.join(chrome_dir, "Local State")
changes = []

def atomic_dump(obj, path):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)

# ---------------- Local State（安装级） ----------------
st = json.load(open(state_path, encoding="utf-8"))

def set_key(k, v):
    old = st.get(k, "<不存在>")
    if old != v:
        changes.append(f"  {k}\n      {old!r}  ->  {v!r}")
        st[k] = v

# (1) 会话一致性国家：每次启动读取，也是 seed 的 latest country 落点
set_key("variations_country", country)

# (2) 按版本号钉死的那一对：保留原版本号，只替换国家
pcc = st.get("variations_permanent_consistency_country")
if isinstance(pcc, list) and len(pcc) == 2:
    if pcc[1] != country:
        changes.append(f"  variations_permanent_consistency_country\n      {pcc!r}  ->  {[pcc[0], country]!r}")
        pcc[1] = country
        st["variations_permanent_consistency_country"] = pcc
    print(f"  (版本号保持 {pcc[0]}，仅替换国家)")
else:
    print(f"  ! variations_permanent_consistency_country 结构异常，跳过: {pcc!r}")

# (3) safe seed 的会话国家
set_key("variations_safe_seed_session_consistency_country", country)

# (4) 【关键】持久化国家覆盖 —— 优先级仅次于命令行开关，免去每次带启动参数
set_key("variations_permanent_overridden_country", country)

# (5) 所有 profile 的 Gemini 资格缓存
info_cache = st.setdefault("profile", {}).setdefault("info_cache", {})
for name, info in info_cache.items():
    if isinstance(info, dict) and info.get("is_glic_eligible") is not True:
        old = info.get("is_glic_eligible", "<不存在>")
        info["is_glic_eligible"] = True
        changes.append(f"  profile.info_cache.{name}.is_glic_eligible\n      {old!r}  ->  True")

atomic_dump(st, state_path)
print(f"  ✓ {state_path}")

# ---------------- Preferences（每个 profile 一份） ----------------
for pref in sorted(glob.glob(os.path.join(chrome_dir, "*/Preferences"))):
    try:
        pf = json.load(open(pref, encoding="utf-8"))
    except Exception as e:
        print(f"  ! 跳过 {pref}: {e}")
        continue
    prof = os.path.basename(os.path.dirname(pref))
    glic = pf.setdefault("glic", {})
    if glic.get("previously_not_allowed"):
        glic["previously_not_allowed"] = False
        changes.append(f"  [{prof}] glic.previously_not_allowed\n      True  ->  False")
    pe = glic.setdefault("profile_enablement", {})
    # last_ready_state 只是「上次观测到的状态」，Chrome 会自行重算；
    # 这里清成 ready 是为了让 UI 立刻脱离旧的错误态。
    if pe.get("last_ready_state") != 2:
        changes.append(f"  [{prof}] glic.profile_enablement.last_ready_state\n      {pe.get('last_ready_state')!r}  ->  2 (ready)")
        pe["last_ready_state"] = 2
    atomic_dump(pf, pref)
    print(f"  ✓ {pref}")

print()
if changes:
    print("== 改动清单 ==")
    for c in changes:
        print(c)
else:
    print("== 无改动（字段已是目标值）==")
PY

echo
echo "== 重开 Chrome =="
if [ "$WAS_RUNNING" = "1" ]; then
  open -a "Google Chrome"
  echo "  ✓ 已拉起 Chrome（无额外启动参数）"
else
  echo "  - Chrome 原本未运行，未自动拉起"
fi

echo
echo "== 提示 =="
cat <<'TIP'
  * 让 Gemini 面板真正初始化（点一下工具栏按钮）后，再执行本脚本 --check 复核，
    期望看到 last_ready_state = 2 (ready)。
  * Chrome 内部诊断页：chrome://glic-internals
  * 若 Chrome 大版本升级后复发，直接重跑本脚本即可。
  * 回滚：用备份覆盖 Local State / Preferences（需先完全退出 Chrome）。
TIP
