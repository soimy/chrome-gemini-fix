# 根因分析：`location-mismatch` 是怎么产生的

本文是把「现象 → 判据 → 源码 → 修复点」完整串起来的技术记录。
所有源码引用均来自 Chromium `main`（对应 Chrome 155.x）。

---

## 0. 现象

Chrome 内置 Gemini（内部代号 **Glic**，`chrome://glic-internals`）按钮不可用。
`Default/Preferences` 中：

```json
"glic": {
  "onboarding_status": 5,
  "pinned_to_tabstrip": true,
  "previously_not_allowed": true,
  "profile_enablement": { "last_ready_state": 5 }
}
```

`Local State` 中：

```json
"variations_country": "cn",
"variations_permanent_consistency_country": ["155.0.8059.80", "cn"],
"variations_safe_seed_session_consistency_country": "cn",
"profile.info_cache.Default.is_glic_eligible": false
```

---

## 1. `last_ready_state = 5` 是什么

Chrome 二进制里内嵌的 `glicPrivate` extension API 定义了：

```
glicPrivate.ProfileReadyState (string enum, 按声明顺序从 0 开始)
  0  error
  1  sign-in-required
  2  ready
  3  disabled-by-admin
  4  ineligible
  5  location-mismatch
  6  ineligible-account
```

该 pref 的常量定义在 `chrome/browser/glic/glic_pref_names_internal.h`：

```cpp
// Integer pref storing the last observed ProfileReadyState.
inline constexpr char kGlicLastProfileReadyState[] =
    "glic.profile_enablement.last_ready_state";
```

所以 `5` 就是 **`location-mismatch`**。

> 注意：这个字段是**缓存**，「只在状态变化时写入」。
> 直接读它无法判断「本轮真的算出了某状态」还是「还留着上次的旧值」——
> 这就是 `glic-probe.sh` 采用哨兵法的原因。

---

## 2. 唯一触发点

`chrome/browser/glic/public/glic_enabling.cc` → `GlicEnabling::GetProfileReadyState()`：

```cpp
mojom::ProfileReadyState GlicEnabling::GetProfileReadyState(Profile* profile) {
  const ProfileEnablement enablement = EnablementForProfile(profile);
  if (enablement.DisallowedByAdmin())          return kDisabledByAdmin;
  if (!primary_account_is_fully_signed_in || …) return kSignInRequired;

  if (!enablement.primary_account_is_capable) {          // ← 账号能力
    return anchor_entrypoint_override_active ? kIneligibleAccount : kIneligible;
  }

  // Similar to account capability, for country filtering we only show a
  // specific mismatch error if the entry point is anchored.
  if (!enablement.allowed_by_country_filter) {           // ← 只有这里
    return anchor_entrypoint_override_active ? kLocationMismatch   // 5
                                             : kIneligible;        // 4
  }
  …
}
```

**结论：`5` ⟺ `allowed_by_country_filter == false`，且按钮已 anchored**
（anchored 的依据是 `fre_is_consented` / `pinned_to_tabstrip` / `previously_not_allowed`）。

---

## 3. `allowed_by_country_filter` 的输入

```cpp
// glic_enabling.cc
result.allowed_by_country_filter = global_enabling.IsCountryEnabled();
…
std::string GlicEnablingDelegate::GetPermanentCountryCode() const {
  return base::ToLowerASCII(
      variations::GetCurrentCountryCode(g_browser_process->variations_service()));
}
std::string GlicEnablingDelegate::GetSessionCountryCode() const {
  return base::ToLowerASCII(
      g_browser_process->variations_service()->GetLatestCountry());
}
```

```cpp
// components/variations/service/variations_service_utils.cc
std::string GetCurrentCountryCode(const VariationsService* variations) {
  std::string country;
  if (variations) country = variations->GetStoredPermanentCountry();
  // Since variations doesn't provide a permanent country by default on things
  // like local builds, we try to fall back to the country_codes component which
  // should always have one.
  return country.empty()
       ? std::string(country_codes::GetCurrentCountryID().CountryCode())
       : country;
}
```

**重要**：国家为空时会回退到 `country_codes` 组件，而它**按设备区域/语言**计算
（这台机器 `AppleLocale = zh_CN` → `CN`）。这解释了为什么即便代理出口是美国，
判定依然可能拿到 `cn`。

---

## 4. 名单比对

`glic_enabling.cc`：

```cpp
bool EvaluateCountryLists(const base::Feature& feature,
                          const char* default_enabled_countries,
                          std::string_view histogram_name,
                          std::string_view permanent_country_code,
                          std::string_view session_country_code) {
  const auto enabled_countries = GetFieldTrialParamAsSplitString(
      feature, "enabled_countries", default_enabled_countries);   // Finch 参数优先
  const auto disabled_countries =
      GetFieldTrialParamAsSplitString(feature, "disabled_countries", "");
  const bool use_session_country =
      base::FeatureList::IsEnabled(features::kGlicUseSessionCountryForFiltering);

  if (任何 disabled 命中)                      return false;  // kBlockedInExclusionList
  if (enabled == ["*"])                        return true;   // kAllowedWildcardInclusion
  if (任何 enabled 命中 permanent 或 session)  return true;   // kAllowedInInclusionList
  return false;                                               // kBlockedNotInInclusionList
}

bool EvaluateCountryEnablement(std::string_view permanent, std::string_view session) {
  if (!base::FeatureList::IsEnabled(features::kGlicCountryFiltering)) {
    // kAllowedFilteringDisabled
    return true;          // ← 开关关掉时不做过滤
  }
  return EvaluateCountryLists(features::kGlicCountryFiltering,
                              kDefaultEnabledCountries, …);
}
```

编译进二进制的默认名单（`kDefaultEnabledCountries`，从 Chrome 155 二进制提取）
**以 `us` 开头，包含美国**：

```
us,ca,nz,in,as,au,bd,bn,bt,cc,ck,cx,fj,fm,gu,hk,hm,id,jp,kh,ki,kr,la,lk,mh,mm,mn,mo,mp,mv,my,
nc,nf,np,nr,nu,pf,pg,ph,pk,pn,pw,sb,sg,th,tk,tl,to,tv,tw,vn,vu,wf,ws,ag,ar,bb,bo,br,bs,bz,cl,
co,cr,dm,do,ec,gd,gt,gy,hn,ht,jm,kn,lc,mx,ni,pa,pe,py,sr,sv,tt,uy,vc,ve,ae,am,ao,aq,az,ba,bf,
bh,bi,bj,bw,cd,cf,cg,ci,cm,cv,dj,dz,eg,eh,er,et,ga,ge,gh,gm,gn,gq,gw,il,iq,jo,ke,kg,km,kw,kz,
lb,lr,ls,ly,ma,md,me,mg,mk,ml,mr,mu,mw,mz,na,ne,ng,om,pr,ps,qa,rs,rw,sa,sc,sd,sl,sn,so,ss,st,
sz,td,tg,tj,tm,tn,tz,ua,ug,um,uz,vi,xk,ye,za,zm,zw
```

⇒ **只要运行时的国家真的是 `us`，过滤必然通过。**
反过来说：过滤失败 ⟹ 运行时的国家**不是** `us`。

### 过滤结果被进程内缓存

```cpp
bool GlicGlobalEnabling::IsCountryEnabledImpl(CountryEvaluator evaluate,
                                              bool& is_enabled,
                                              std::optional<LastCheckedCountries>& last_checked) {
  if (is_enabled) return true;                       // 一旦 true 就永久粘住
  LastCheckedCountries current{delegate_->GetPermanentCountryCode(),
                               delegate_->GetSessionCountryCode()};
  if (last_checked.has_value() && *last_checked == current) {
    return false;                                    // 国家没变 → 沿用旧结论
  }
  last_checked = current;
  is_enabled = evaluate(current.permanent_country, current.session_country);
  return is_enabled;
}
```

---

## 5. 国家值为什么是错的

`components/variations/service/variations_field_trial_creator.cc`：

```cpp
  state->session_consistency_country = GetLatestCountry();          // variations_country
  state->permanent_consistency_country = LoadPermanentConsistencyCountry(
      version, state->session_consistency_country);
  permanent_consistency_country_ = state->permanent_consistency_country;
  permanent_consistency_country_initialized_ = true;
```

```cpp
std::string VariationsFieldTrialCreator::LoadPermanentConsistencyCountry(
    const base::Version& version, const std::string& latest_country) {
  // ① 命令行开关，最高优先级
  const std::string override_country = base::ToLowerASCII(
      base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
          switches::kVariationsOverrideCountry));
  if (!override_country.empty()) return override_country;

  // ② 持久化覆盖 pref
  const std::string permanent_overridden_country =
      local_state()->GetString(prefs::kVariationsPermanentOverriddenCountry);
  if (!permanent_overridden_country.empty()) return permanent_overridden_country;

  const std::string stored_version_string = seed_store_->GetPermanentConsistencyVersion();
  const std::string stored_country        = seed_store_->GetPermanentConsistencyCountry();
  const bool does_version_match = … version == stored_version …;

  …
  // Use the stored country if one is available and was fetched since the last
  // time Chrome was updated.
  if (does_version_match) {
    return stored_country;           // ③ 版本一致 → 永远返回旧国家
  }

  if (latest_country.empty()) {
    // 从未收到服务端国家 → 返回空串，于是上层回退到 country_codes（设备区域）
    return std::string();
  }

  // ④ 否则用服务端最新值，并重存
  StorePermanentCountry(version, latest_country);
  return latest_country;
}
```

**这就是问题的骨架**：`variations_permanent_consistency_country` 一旦被写成
`["<当前版本>", "cn"]`，只要 Chrome 不升级，第 ③ 步就永远返回 `cn`，
而这一步**优先级高于**服务端新给的值。修网络、换出口都不会改变它。

第 ② 步是唯一「既持久、又优先于 ③」的出口 —— 也是本项目修复方案的落点。
它由 Chrome 自己的 `VariationsService::OverrideStoredPermanentCountry()` 写入，
是受支持的正规 pref，不是注入式 hack。

---

## 6. 修复方案

在 **Chrome 完全退出**后修改 `Local State`：

| 字段 | 值 | 作用 |
|---|---|---|
| `variations_permanent_overridden_country` | `"us"` | **关键**，优先级 ②，立即生效 |
| `variations_permanent_consistency_country` | `[<原版本号>, "us"]` | 纠正 ③，作为兜底 |
| `variations_country` | `"us"` | 纠正 session 一致性国家 |
| `variations_safe_seed_session_consistency_country` | `"us"` | 纠正 safe seed 路径 |
| `profile.info_cache.<Profile>.is_glic_eligible` | `true` | 清掉旧资格缓存 |

`<Profile>/Preferences`：

| 字段 | 值 | 作用 |
|---|---|---|
| `glic.previously_not_allowed` | `false` | 清掉「曾被判不合格」标记 |
| `glic.profile_enablement.last_ready_state` | `2` | 让 UI 立刻脱离旧错误态（会被重算） |

---

## 7. 其他相关判据（本次未触发，但值得知道）

- **locale**：`kGlicLocaleFiltering` + `kDefaultEnabledLocales`（含 `zh-CN`）。
  locale 失败落到 `kIneligible(4)`，**不是** `location-mismatch(5)` ——
  可据此区分。
- **账号能力**：失败走 `kIneligibleAccount(6)`。
- **管理员策略**：走 `kDisabledByAdmin(3)`。
- **`--glic-dev`** 启动参数会跳过部分检查（源码中显式 bypass）。
- **`--variations-override-country=<cc>`** 会短路整个 `LoadPermanentConsistencyCountry`，
  适合做定位实验，但不持久。

## 8. 平台差异

| 平台 | 用户数据目录 |
|---|---|
| macOS | `~/Library/Application Support/Google/Chrome/Local State` |
| Linux | `~/.config/google-chrome/Local State` |
| Windows | `%LOCALAPPDATA%\Google\Chrome\User Data\Local State` |

字段名与优先级链完全一致；只是退出/重启 Chrome 的方式不同。
