---
name: chrome-gemini-location-fix
description: |
  修复 Chrome 内置 Gemini / Glic 按钮「地区不可用」（location-mismatch）的 skill。
  何时激活：用户说"Chrome 的 Gemini 按钮用不了 / 点了说地区不支持 /
  Gemini in Chrome 打不开 / glic 不可用 / 我代理都修好了为什么还是不行"；
  或排查中发现 `glic.profile_enablement.last_ready_state` 为 5、
  `is_glic_eligible` 为 false、`variations_country` 为 cn。
  核心判断：**网络/DNS/代理修好只是必要条件**——Chrome 会把 variations 国家
  连同版本号持久化到 Local State，同版本内永不更新，必须单独纠正；
  且必须补 `variations_permanent_overridden_country`，只改
  `variations_country` + 版本对（多数教程的做法）**会失败**。
metadata:
  author: soimy
  version: "1.0.0"
  tags: [chrome, gemini, glic, location, variations, troubleshooting, macos]
  homepage: https://github.com/soimy/chrome-gemini-fix
---

# 修复 Chrome Gemini 按钮的地区锁定

## 何时用

用户报告 Chrome 内置 Gemini（Glic）按钮不可用、提示地区不支持，且**已经排查过网络**。
典型话术：

- "我 Chrome 的 Gemini 按钮用不了"
- "lede/passwall 我都修好了，为什么还是不行？"
- "gemini 说在我所在地区不可用"
- "clientservices.googleapis.com 已经不走国内了，但按钮还是坏的"

**不适用**：Gemini 网页版（gemini.google.com）打不开 —— 那是纯网络问题，见文末「区分」。

---

## 核心洞察（先建立正确预期）

> 用户最容易误判的一点：**"我把代理修好了" ≠ "Chrome 会用新地区"**。

Chrome 把 variations 国家按 **Chrome 版本号**钉死在 `Local State` 里：

```json
"variations_permanent_consistency_country": ["155.0.8059.80", "cn"]
```

`LoadPermanentConsistencyCountry()` 在「版本号一致」时**直接返回这个旧国家**，
优先级**高于**服务端新下发的国家。这是 Google 防止换出口刷灰度的刻意设计。
所以：**换出口、修 DNS、重装代理全都无效，必须直接改这个字段。**

而且——**只改这个字段仍然不够**（见下方决策树的实测结论）。

---

## 判定：先确认是不是这个病

### 1. 读状态

```bash
UD="$HOME/Library/Application Support/Google/Chrome"

# 判定结果（5 = location-mismatch）
/usr/bin/python3 -c "
import json;d=json.load(open('$UD/Default/Preferences'))
g=d.get('glic',{})
print('last_ready_state       =', g.get('profile_enablement',{}).get('last_ready_state'))
print('previously_not_allowed =', g.get('previously_not_allowed'))
"
# 国家字段
/usr/bin/python3 -c "
import json;d=json.load(open('$UD/Local State'))
for k in ['variations_country','variations_permanent_consistency_country',
          'variations_permanent_overridden_country']:
    print(f'{k:42s} =', repr(d.get(k,'(未设置)')))
i=d.get('profile',{}).get('info_cache',{}).get('Default',{})
print('is_glic_eligible                          =', i.get('is_glic_eligible'))
"
```

### 2. 对照表（`last_ready_state` → 原因）

| 值 | 名称 | 含义 / 下一步 |
|---|---|---|
| 2 | `ready` | 已正常，无需处理 |
| 3 | `disabled-by-admin` | 企业策略，非本项目范围 |
| 4 | `ineligible` | **不是**国家问题主诉；可能是 locale、未 anchored 的国家失败、灰度未覆盖 |
| 5 | `location-mismatch` | **本 skill 目标** —— `allowed_by_country_filter == false` 且按钮已 anchored |
| 6 | `ineligible-account` | 账号能力问题，非国家 |

值来自 `glicPrivate.ProfileReadyState`（声明顺序即索引）：
`0 error, 1 sign-in-required, 2 ready, 3 disabled-by-admin, 4 ineligible, 5 location-mismatch, 6 ineligible-account`

### 3. 顺带确认网络层（必要条件）

```bash
dig +short clientservices.googleapis.com          # 期望：代理侧地址（如 198.18.x）
dig +short geminiweb-pa.googleapis.com            # Glic 的服务端判定接口
curl -sI 'https://clientservices.googleapis.com/chrome-variations/seed?osname=mac&milestone=155' \
  | grep -i x-country                             # 期望：us（或目标国家）
```

**若网络层没通，先修网络再回来。** 两边都通才算完整修复。

---

## 决策树

```
last_ready_state == 5 ?
├─ 否 → 不是本 skill 的问题（见对照表）
└─ 是
   ├─ 网络层通吗（x-country == 目标国）？
   │   ├─ 否 → 先修 DNS/代理，回到这里
   │   └─ 是 ↓
   └─ 执行修复：
      ① 完全退出 Chrome（必须先退，否则退出时内存副本会覆盖你的改动）
      ② 备份 Local State 与各 profile 的 Preferences
      ③ 写 Local State：
           variations_permanent_overridden_country = "<cc>"   ← 【关键，别漏】
           variations_permanent_consistency_country = [<原版本号>, "<cc>"]
           variations_country = "<cc>"
           variations_safe_seed_session_consistency_country = "<cc>"
           profile.info_cache.<每个 profile>.is_glic_eligible = true
      ④ 写各 <Profile>/Preferences：
           glic.previously_not_allowed = false
           glic.profile_enablement.last_ready_state = 2
      ⑤ 重开 Chrome，点一下 Gemini 按钮触发初始化
      ⑥ 用哨兵法验证（下节）
```

**不要省略 ③ 的第一行。** 实测：只做 `variations_country` + 版本对 + `is_glic_eligible`
（这是网上多数教程/脚本的做法）结果**仍然是 5**，补上
`variations_permanent_overridden_country` 后才变 2。

---

## 执行

优先用现成脚本（本 skill 的仓库里）：`scripts/fix-chrome-glic.sh`

```bash
./scripts/fix-chrome-glic.sh --check      # 先只读诊断
./scripts/fix-chrome-glic.sh              # 修复（自动退出/备份/重开）
./scripts/fix-chrome-glic.sh --check      # 复核，期望 2 (ready)
```

若要手工做，等价的核心改动：

```bash
UD="$HOME/Library/Application Support/Google/Chrome"
CC=us

# 1) 退出 Chrome（优雅退出，别 kill）
osascript -e 'tell application "Google Chrome" to quit'
until ! pgrep -x "Google Chrome" >/dev/null; do sleep 1; done

# 2) 备份
cp -p "$UD/Local State" "$UD/Local State.bak-$(date +%Y%m%d%H%M%S)"

# 3) 打补丁
/usr/bin/python3 - "$UD" "$CC" <<'PY'
import json, os, sys, glob
ud, cc = sys.argv[1], sys.argv[2]
p = os.path.join(ud, "Local State")
d = json.load(open(p, encoding="utf-8"))
d["variations_permanent_overridden_country"] = cc          # ← 关键
pair = d.get("variations_permanent_consistency_country")
if isinstance(pair, list) and len(pair) == 2:
    pair[1] = cc
    d["variations_permanent_consistency_country"] = pair    # 保留原版本号
d["variations_country"] = cc
d["variations_safe_seed_session_consistency_country"] = cc
for name, info in d.setdefault("profile", {}).setdefault("info_cache", {}).items():
    if isinstance(info, dict):
        info["is_glic_eligible"] = True
t = p + ".tmp"
json.dump(d, open(t, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
os.replace(t, p)

for pref in glob.glob(os.path.join(ud, "*/Preferences")):
    pf = json.load(open(pref, encoding="utf-8"))
    g = pf.setdefault("glic", {})
    g["previously_not_allowed"] = False
    g.setdefault("profile_enablement", {})["last_ready_state"] = 2
    t = pref + ".tmp"
    json.dump(pf, open(t, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    os.replace(t, pref)
print("done")
PY

# 4) 重开
open -a "Google Chrome"
```

---

## 验证：必须用哨兵法

**坑点**：`last_ready_state` 是「上次观测到的状态」缓存，**Chrome 只在状态变化时才写它**。
所以修完直接读它，**无法区分**「这次真的算出了 ready」和「旧值没被刷新」。

正确做法——先把该字段写成 `2` 当哨兵，再启动，看是否被改动：

```bash
./scripts/glic-probe.sh                                  # 基线
./scripts/glic-probe.sh "--variations-override-country=us"   # 强制国家，用于定位
```

判读：

- 启动后仍是 `2` → 哨兵未被改动，真实状态就是 **ready** ✅
- 启动后被改成别的值（如 `5`）→ Chrome 确实重算过，且结果就是这个值 ❌

其他验证入口：

- `chrome://glic-internals` —— Glic 专用诊断页
- `chrome://histograms` —— 查 `Glic.CountryFilteringResult2.Adult`、
  `Glic.ProfileEnablement.*`
- `chrome://version` —— 确认版本号，用于核对
  `variations_permanent_consistency_country[0]`

---

## 排查其他假设（按性价比排序）

如果按上面的步骤做完仍是 `5`，依次排除：

| 序号 | 假设 | 一条命令验证 |
|---|---|---|
| 1 | Chrome 自带 DoH 绕过路由器 | 看 `Local State` 的 `dns_over_https` 是否为 null |
| 2 | macOS 系统代理抢流量 | `scutil --proxy`（三项 Enable 应为 0） |
| 3 | 有 VPN/代理软件在跑 | `scutil --nc list`；`ps aux \| grep -iE '[s]urge\|[c]lash\|[m]ihomo'` |
| 4 | 目标国家不在默认名单 | 见下「提取二进制默认名单」 |
| 5 | Finch 下发了 `enabled_countries` 覆盖 | `./scripts/glic-probe.sh "--enable-features=GlicCountryFiltering:enabled_countries/*"`；此项生效则说明是名单问题 |
| 6 | 设备区域回退导致国家为 CN | 国家为空时会回退到 `country_codes`（**按设备区域算**）；检查 `defaults read -g AppleLocale` |

有用的一次性手法：

```bash
FRAMEWORK="/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/<VER>/Google Chrome Framework"

# 枚举定义（比翻源码快）
strings -a "$FRAMEWORK" | grep -E "ProfileReadyState|kLocationMismatch"

# 编译进去的默认启用国家名单（以 us 开头的长串）
strings -a "$FRAMEWORK" | grep -E "^[a-z]{2}(,[a-z]{2}){25,}$"

# 服务端判定端点
strings -a "$FRAMEWORK" | grep -E "^https://" | grep -i glic

# 官方帮助链接
strings -a "$FRAMEWORK" | grep -A1 "location_mismatch_help_url"
```

Chromium 源码按需抓取：

```bash
curl -sL "https://chromium.googlesource.com/chromium/src/+/main/<path>?format=TEXT" \
  | base64 --decode
```

关键文件：
- `components/variations/service/variations_field_trial_creator.cc`（国家锁定与优先级链）
- `components/variations/service/variations_service_utils.cc`（国家取值 + 设备区域回退）
- `chrome/browser/glic/public/glic_enabling.cc`（Glic 国家/locale 过滤、ready state）
- `chrome/browser/glic/glic_pref_names_internal.h`（`last_ready_state` 常量）

---

## 区分：按钮不可用 vs Gemini 网页打不开

| 现象 | 根因 | 处理 |
|---|---|---|
| **按钮**在但报地区不可用 | Chrome 内部国家字段（本 skill） | 改 `variations_permanent_overridden_country` |
| **gemini.google.com 打不开 / 转圈** | 纯网络：DNS/出口 | 修代理、分流、DNS |
| 网页能开但功能受限 | 账号地区 / 年龄 / 订阅 | 非本 skill 范围 |

两者可以同时存在，**修好一个不代表另一个也好** —— 这正是用户最容易困惑的点。

---

## 安全与副作用

- 只修改本机 Chrome 用户数据文件，**不涉及 Google 账号、不上传任何数据**。
- `Local State` 不是 MAC 校验文件（那个是 `Secure Preferences`），编辑安全。
- **必须在 Chrome 完全退出时改**，否则退出时会被内存副本覆盖。
- 修改前务必备份，脚本会自动留带时间戳的 `.bak-YYYYmmddHHMMSS`。
- 退出 Chrome 会关闭用户的所有标签页 —— **执行前先向用户确认**。
- 回滚：用备份覆盖回去（先退 Chrome）。

---

## 平台路径

| 平台 | 路径 |
|---|---|
| macOS | `~/Library/Application Support/Google/Chrome/Local State` |
| Linux | `~/.config/google-chrome/Local State` |
| Windows | `%LOCALAPPDATA%\Google\Chrome\User Data\Local State` |

字段名与优先级链跨平台一致，只有退出/重启方式不同。
Beta/Dev/Canary 把路径里的 `Chrome` 换成 `Chrome Beta` / `Chrome Dev` / `Chrome Canary`。
