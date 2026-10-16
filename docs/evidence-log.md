# 实测证据记录

本文件记录一次真实排查的完整证据链（macOS，Chrome 155.x，代理出口在美国）。
目的是让结论**可复核**，而不是只给「据说」。

---

## A. 环境

```
macOS，系统区域 AppleLocale = zh_CN
Chrome 155.0.8059.40 → 排查中途自动升级到 155.0.8059.80
出口代理：透明代理网关（OpenWrt/LEDE + passwall，分流节点在美国）
```

初始 `Local State` 关键字段：

```
variations_country                                   = "cn"
variations_permanent_consistency_country             = ["155.0.8059.40", "cn"]
variations_safe_seed_session_consistency_country     = "cn"
variations_safe_seed_permanent_consistency_country   = "us"
variations_safe_seed_milestone                       = 147
profile.info_cache.Default.is_glic_eligible          = false
```

初始 `Default/Preferences`：

```
glic.onboarding_status                = 5
glic.pinned_to_tabstrip               = true
glic.previously_not_allowed           = true
glic.profile_enablement.last_ready_state = 5
account_values.sync.glic_rollout_eligibility = true
```

---

## B. 网络层已修好（证明问题不在 DNS/出口）

```
$ dig +short clientservices.googleapis.com
198.18.195.9                      # fake-ip → 走代理

$ dig +short geminiweb-pa.googleapis.com
198.18.98.251                     # 这是 Glic 的服务端状态判定接口

$ curl -sI 'https://clientservices.googleapis.com/chrome-variations/seed?osname=mac&milestone=155' | grep -i x-country
x-country: us                     # Google 认为我们在美国

$ curl -s https://ipinfo.io/89.208.248.239/json
{ "ip": "89.208.248.239", "city": "Los Angeles", "country": "US",
  "org": "AS25820 IT7 Networks Inc" }
```

`geminiweb-pa.googleapis.com/v1/glicStatus` 是从 Chrome 二进制里挖出来的判定端点：

```
$ strings -a "Google Chrome Framework" | grep -E 'glic' | grep -E '^https://'
https://gemini.google.com/glic
https://gemini.google.com/glic/intro?
https://geminiweb-pa.googleapis.com/v1/glicStatus
```

**网络全通，但 `last_ready_state` 仍为 5** —— 问题不在网络。

---

## C. 枚举与原因定位

```
$ strings -a "Google Chrome Framework" | grep ProfileReadyState
{"namespace":"glicPrivate", …
 "types":[{"id":"glicPrivate.ProfileReadyState","type":"string","enum":[
    {"name":"error"},{"name":"sign-in-required"},{"name":"ready"},
    {"name":"disabled-by-admin"},{"name":"ineligible"},
    {"name":"location-mismatch"},{"name":"ineligible-account"}]}, …}
```

按声明顺序索引 → `5 = location-mismatch`。

`chrome/browser/glic/glic_pref_names_internal.h` 确认该 pref 就是存这个枚举：

```cpp
// Integer pref storing the last observed ProfileReadyState.
inline constexpr char kGlicLastProfileReadyState[] =
    "glic.profile_enablement.last_ready_state";
```

二进制里同时存在 `kLocationMismatch` / `location_mismatch_help_url` /
`locationMismatchNotice` / `locationMismatchNoticeHeader` 等符号，
帮助链接为 `https://support.google.com/gemini/answer/17117411#gic_access`。

官方帮助页要求：*"in a supported region"*、*"Set your device settings to use a
supported language"*、*"Use the latest version of Chrome"*、*"Sign in to Chrome"*。

---

## D. 关键 A/B 实验（哨兵法）

**动机**：`last_ready_state` 只在状态变化时写入，直接读无法区分「算出 ready」与
「旧值未刷新」。因此先把该字段写成 `2` 当哨兵，再启动 Chrome，观察是否被改动。

### 实验 1 — 只按社区通行做法改（无命令行参数）

改动：`variations_country=us`、`variations_permanent_consistency_country=["155.0.8059.80","us"]`、
`is_glic_eligible=true`、`previously_not_allowed=false`、`last_ready_state=2`(哨兵)

启动方式：`open -a "Google Chrome"`

结果（35 秒后回读）：

```
last_ready_state       = 5  (location-mismatch)   ← 哨兵被改回 5
previously_not_allowed = True                     ← 也回退了
is_glic_eligible       = False                    ← 也回退了
variations_country     = "us"                     ← 国家字段本身保住了
```

⇒ **只改这些字段不够。**

### 实验 2 — 加命令行国家覆盖

启动方式：`open -a "Google Chrome" --args --variations-override-country=us`

结果：

```
last_ready_state = 2  (ready)     ← 哨兵未被改动，说明真实状态就是 ready
```

⇒ 确认瓶颈在 `LoadPermanentConsistencyCountry()` 的国家取值。

### 实验 3 — 改用持久化 pref（最终方案，无任何启动参数）

写入 `variations_permanent_overridden_country = "us"`，`last_ready_state = 2`(哨兵)

启动方式：`open -a "Google Chrome"`

结果：

```
last_ready_state                        = 2  (ready)   ✅
previously_not_allowed                  = False
is_glic_eligible                        = True
variations_permanent_overridden_country = "us"
variations_permanent_consistency_country= ["155.0.8059.80", "us"]
```

⇒ **这才是免启动参数的可靠修法。**

### 结论表

| # | 配置 | `last_ready_state` |
|---|---|---|
| 1 | 仅 `variations_country` + 版本对 + `is_glic_eligible` | 5 ❌ |
| 2 | 加 `--variations-override-country=us` | 2 ✅ |
| 3 | 加持久化 `variations_permanent_overridden_country="us"` | 2 ✅ |

---

## E. 尝试过但**不是**原因的假设

排查中逐条排除，记下来避免重复踩：

| 假设 | 排除依据 |
|---|---|
| Chrome 用了自定义 DoH / Secure DNS 绕过路由器 | `Local State` 中 `dns_over_https = null`，无该配置 |
| macOS 系统代理抢流量 | `scutil --proxy` → `HTTPEnable/HTTPSEnable/SOCKSEnable = 0` |
| 有 VPN/代理软件在跑 | `ps` 无 Surge/Clash/mihomo 等进程；`scutil --nc list` 无已连接服务 |
| 出口节点在 Gemini 不支持的地区 | 出口实测为美国洛杉矶（AS25820） |
| 代理域名没走对 | `clientservices` / `geminiweb-pa` / `gemini.google.com` 全为 fake-ip |
| locale 不支持 | `kDefaultEnabledLocales` 含 `zh-CN`；且 locale 失败会落到 4 而非 5 |
| 默认国家名单不含 `us` | 从二进制提取的 `kDefaultEnabledCountries` **第一项就是 `us`** |
| 账号能力不足 | `account_values.sync.glic_rollout_eligibility = true`；且该项失败是 6 而非 5 |

---

## F. 排查手法备忘

```bash
# 1. 枚举定义直接在二进制里找（比翻源码快）
strings -a ".../Google Chrome Framework" | grep -E "ProfileReadyState|kLocationMismatch"

# 2. 编译进二进制的默认名单（形如 xx,xx,xx… 的长串）
strings -a ".../Google Chrome Framework" | grep -E "^[a-z]{2}(,[a-z]{2}){25,}$"

# 3. 服务端判定端点
strings -a ".../Google Chrome Framework" | grep -E "^https://" | grep -i glic

# 4. 官方帮助链接（往往直接写在资源字符串旁边）
strings -a ".../Google Chrome Framework" | grep -B1 -A1 "location_mismatch_help_url"

# 5. Chromium 源码按需抓取（googlesource 支持 ?format=TEXT，需 base64 解码）
curl -sL "https://chromium.googlesource.com/chromium/src/+/main/<path>?format=TEXT" \
  | base64 --decode
```

> 注意 macOS 上个别 Python 版本 `base64.b64decode()` 对含换行的输入会报
> `Invalid base64-encoded string`，用 `-o` 落盘再解更稳。

---

## G. Chrome 内部诊断入口

- `chrome://glic-internals` —— Glic 专用的诊断页
  （二进制中存在 `internals/glic_internals.html` 与
  `chrome/browser/glic/host/glic_internals_page_handler.cc`）
- `chrome://version` —— 确认版本号，用于核对
  `variations_permanent_consistency_country[0]`
- `chrome://histograms` —— 可查 `Glic.CountryFilteringResult2.Adult`
  与 `Glic.ProfileEnablement.*` 等直方图
