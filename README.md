# chrome-gemini-fix

修复 Chrome 内置 **Gemini in Chrome**（Glic）按钮因**地区被永久锁定**而不可用的问题。

> **TL;DR (English)** — Chrome pins the variations country to your install by
> writing `variations_permanent_consistency_country = ["<version>", "<country>"]`
> into `Local State`. As long as the Chrome version is unchanged,
> `LoadPermanentConsistencyCountry()` keeps returning that **stale** country and
> never adopts the country the server sends. Fixing your proxy/DNS is therefore
> *not enough*. The reliable cure is the persistent override pref
> `variations_permanent_overridden_country = "us"`, which sits just below the
> `--variations-override-country` command-line switch in priority. Run
> `scripts/fix-chrome-glic.sh`.

---

## 症状

- 工具栏上能看到 Gemini 按钮（或它是错误态），但点开提示当前地区不可用。
- `~/Library/Application Support/Google/Chrome/Local State`：
  ```json
  "variations_country": "cn",
  "variations_permanent_consistency_country": ["155.0.8059.80", "cn"]
  ```
- `.../Chrome/Default/Preferences`：
  ```json
  "glic": {
    "previously_not_allowed": true,
    "profile_enablement": { "last_ready_state": 5 }
  }
  ```

`last_ready_state` 的取值来自 Chrome 二进制里的

```
glicPrivate.ProfileReadyState =
  0 error | 1 sign-in-required | 2 ready | 3 disabled-by-admin
  4 ineligible | 5 location-mismatch | 6 ineligible-account
```

**`5 = location-mismatch`（地区不匹配）** —— 不是网络不通，是 Chrome 认为你在错误的地区。

---

## 根因（源码级）

### 1. 国家被版本号钉死

`components/variations/service/variations_field_trial_creator.cc`：

```cpp
  // Use the stored country if one is available and was fetched since the last
  // time Chrome was updated.
  if (does_version_match) {
    return stored_country;          // ← 版本一致就直接返回旧国家，无视服务端新值
  }
  ...
  StorePermanentCountry(version, latest_country);   // 只有 Chrome 升级后才会重存
```

这是 Google 防止用户靠换出口切换 Finch 灰度的**刻意设计**：同一个 Chrome 版本内，
地区一旦被记录就不会再更新。

### 2. 其中 `location-mismatch` 只有一个触发点

`chrome/browser/glic/public/glic_enabling.cc`：

```cpp
  // Similar to account capability, for country filtering we only show a
  // specific mismatch error if the entry point is anchored.
  if (!enablement.allowed_by_country_filter) {
    if (enablement.anchor_entrypoint_override_active) {
      return mojom::ProfileReadyState::kLocationMismatch;   // ← 5
    } else {
      return mojom::ProfileReadyState::kIneligible;          // ← 4
    }
  }
```

`allowed_by_country_filter` 的来源：

```cpp
std::string GlicEnablingDelegate::GetPermanentCountryCode() const {
  return base::ToLowerASCII(variations::GetCurrentCountryCode(
      g_browser_process->variations_service()));
}
// components/variations/service/variations_service_utils.cc
std::string GetCurrentCountryCode(const VariationsService* variations) {
  std::string country;
  if (variations) country = variations->GetStoredPermanentCountry();
  // 国家为空时回退到 country_codes 组件 —— 它按【设备区域】算
  return country.empty()
       ? std::string(country_codes::GetCurrentCountryID().CountryCode())
       : country;
}
```

于是国家会落到 `enabled_countries` 名单里比对
（`kDefaultEnabledCountries` 编译在二进制里，`us` 是第一项）。

### 3. 关键：改对国家字段仍然不够

`LoadPermanentConsistencyCountry()` 的取值优先级：

| # | 来源 | 持久 | 本脚本是否使用 |
|---|---|---|---|
| 1 | `--variations-override-country=<cc>` 命令行开关 | ✗ | 仅用于定位问题 |
| 2 | `variations_permanent_overridden_country` | ✓ | **✔ 采用** |
| 3 | `variations_permanent_consistency_country` `[version, country]` | ✓ | ✔ 一并纠正 |
| 4 | seed 带回的 latest country | — | — |

**实测 A/B**（哨兵法，先把状态写成 2 再启动，看是否被改回）：

| 配置 | `last_ready_state` |
|---|---|
| 只改 #3 + `is_glic_eligible`（社区通行做法） | **5** location-mismatch ❌ |
| 加 #1（命令行） | **2** ready ✅ |
| 加 #2（持久化，**无任何启动参数**） | **2** ready ✅ |

> 也就是说，多数教程教的那套（`variations_country` + `variations_permanent_consistency_country`
> + `is_glic_eligible`）在本机会失败——**必须补上 #2**。

---

## 为什么"把路由器/代理修好"不够

网络层修好只是**必要条件**。本机的实测结果：

| 检查 | 结果 |
|---|---|
| `clientservices.googleapis.com` | `198.18.x`（fake-ip → 代理）✓ |
| `geminiweb-pa.googleapis.com`（Glic 状态判定接口） | `198.18.x` → 代理 ✓ |
| GGC 返回的 `x-country` | `us` ✓ |
| 出口 IP | 美国 ✓ |

**网络全通，但按钮依然报 `location-mismatch`** —— 因为卡点在 Chrome 自己持久化的国家字段里，
与 DNS/出口无关。两件事必须分别处理。

---

## 快速开始

```bash
git clone https://github.com/soimy/chrome-gemini-fix.git
cd chrome-gemini-fix

# 1) 先只读诊断，看看现在是什么状态
./scripts/fix-chrome-glic.sh --check

# 2) 修复（会优雅退出 Chrome → 备份 → 打补丁 → 重开）
./scripts/fix-chrome-glic.sh

# 3) 点一下工具栏的 Gemini 按钮，再复核
./scripts/fix-chrome-glic.sh --check
# 期望：last_ready_state = 2 (ready)
```

Chrome 内部诊断页：`chrome://glic-internals`

### 选项

```
./scripts/fix-chrome-glic.sh --check             # 只读，不改
./scripts/fix-chrome-glic.sh --country=us        # 目标国家（默认 us）
CHROME_DIR=".../Google/Chrome Beta" ./scripts/fix-chrome-glic.sh
```

---

## 排查工具：哨兵法

`last_ready_state` 是**「上次观测到的状态」缓存，Chrome 只在状态变化时才写它**，
所以直接读无法区分「这次算出 ready」和「还是旧值」。

`scripts/glic-probe.sh` 先把该字段写成 `2` 当哨兵，再启动 Chrome，
然后看它有没有被改成别的值：

```bash
./scripts/glic-probe.sh                                        # 基线
./scripts/glic-probe.sh "--variations-override-country=us"     # 验证国家假设
./scripts/glic-probe.sh "--enable-features=GlicCountryFiltering:enabled_countries/*"
```

---

## 文件说明

```
chrome-gemini-fix/
├── scripts/
│   ├── fix-chrome-glic.sh           # 一键修复（备份 + 补丁 + 重开）
│   └── glic-probe.sh                # 哨兵法验证 / A-B 排查
├── docs/
│   ├── root-cause.md                # 源码级归因（含文件、函数、枚举）
│   └── evidence-log.md              # 本次实测的完整证据与命令输出
└── skills/
    └── chrome-gemini-location-fix/
        └── SKILL.md                 # 给 AI Agent 用的 skill（方法论 + 决策树）
```

---

## 回滚

补丁会先在原地留带时间戳的备份（`Local State.bak-YYYYmmddHHMMSS` 等）：

```bash
# 先完全退出 Chrome
UD="$HOME/Library/Application Support/Google/Chrome"
cp "$UD/Local State.bak-<STAMP>"          "$UD/Local State"
cp "$UD/Default/Preferences.bak-<STAMP>"  "$UD/Default/Preferences"
```

---

## 兼容性与注意

- 主要面向 **macOS**（脚本用了 `osascript` / `pgrep -x` / `open -a`）。
  Linux/Windows 的字段与路径不同，思路相同，见 `docs/root-cause.md`。
- 写 `Local State` 是安全的：它不是 MAC 校验文件（那个是 `Secure Preferences`），
  且必须在 **Chrome 完全退出** 时修改 —— 否则退出时会被内存副本覆盖。
- `last_ready_state` / `is_glic_eligible` / `previously_not_allowed` 都是**缓存**，
  Chrome 会自行重算；脚本写它们只是为了让 UI 立刻脱离旧错误态。
- Chrome 大版本升级后若复发，直接重跑 `scripts/fix-chrome-glic.sh`。

---

## 参考

- Chromium `variations_field_trial_creator.cc` — 国家永久一致性逻辑
- Chromium `chrome/browser/glic/public/glic_enabling.cc` — Glic 地区/语言过滤
- Chromium `components/variations/service/variations_service_utils.cc` — 国家取值与设备区域回退
- Google 帮助：<https://support.google.com/gemini/answer/17117411#gic_access>
- 同类项目：[lcandy2/enable-chrome-ai](https://github.com/lcandy2/enable-chrome-ai)、
  [appsail/Gemini-in-Chrome](https://github.com/appsail/Gemini-in-Chrome)

## License

MIT — 见 [LICENSE](LICENSE)

> 非 Google 官方项目。只修改本机 Chrome 的用户数据文件，不涉及账号、不上传任何数据。
