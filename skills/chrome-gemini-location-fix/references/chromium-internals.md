# Chromium 源码摘录（country / Glic 地区判定）

供离线参考。均为 Chromium `main`（对应 Chrome 155.x）。

---

## `components/variations/service/variations_field_trial_creator.cc`

```cpp
  state->session_consistency_country = GetLatestCountry();
  state->permanent_consistency_country = LoadPermanentConsistencyCountry(
      version, state->session_consistency_country);
  permanent_consistency_country_ = state->permanent_consistency_country;
  permanent_consistency_country_initialized_ = true;
```

```cpp
std::string VariationsFieldTrialCreator::LoadPermanentConsistencyCountry(
    const base::Version& version,
    const std::string& latest_country) {
  // ① 命令行开关：--variations-override-country
  const std::string override_country = base::ToLowerASCII(
      base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
          switches::kVariationsOverrideCountry));
  if (!override_country.empty()) {
    return override_country;
  }

  // ② 持久化覆盖
  const std::string permanent_overridden_country =
      local_state()->GetString(prefs::kVariationsPermanentOverriddenCountry);
  if (!permanent_overridden_country.empty()) {
    base::UmaHistogramEnumeration(
        "Variations.LoadPermanentConsistencyCountryResult",
        LoadPermanentConsistencyCountryResult::kHasPermanentOverriddenCountry);
    return permanent_overridden_country;
  }

  // ③ Local State 里按版本号钉死的那一对
  const std::string stored_version_string =
      seed_store_->GetPermanentConsistencyVersion();
  const std::string stored_country =
      seed_store_->GetPermanentConsistencyCountry();
  const bool is_stored_info_valid = !stored_version_string.empty() &&
                                    !stored_country.empty() &&
                                    stored_version.IsValid();
  const bool does_version_match =
      is_stored_info_valid && version == stored_version;
  ...
  // Use the stored country if one is available and was fetched since the last
  // time Chrome was updated.
  if (does_version_match) {
    return stored_country;          // ← 版本一致就永远返回旧国家
  }

  if (latest_country.empty()) {
    // If we've never received a country code from the server, use an empty
    // country so that it won't pass any filters that specifically include
    // countries, but so that it will pass any filters that specifically exclude
    // countries.
    return std::string();          // ← 空串会让上层回退到设备区域
  }

  // ④ 否则采用服务端最新值并重存
  StorePermanentCountry(version, latest_country);
  return latest_country;
}
```

`StorePermanentCountry` / `StoreVariationsOverriddenCountry`：

```cpp
void VariationsFieldTrialCreator::StorePermanentCountry(
    const base::Version& version, const std::string& country) {
  seed_store_->SetPermanentConsistencyCountryAndVersion(country, version.GetString());
}

void VariationsFieldTrialCreator::StoreVariationsOverriddenCountry(
    const std::string& country) {
  local_state()->SetString(prefs::kVariationsPermanentOverriddenCountry, country);
  permanent_consistency_country_ = country;
  permanent_consistency_country_initialized_ = true;
}
```

---

## `components/variations/service/variations_service_utils.cc`

```cpp
std::string GetCurrentCountryCode(const VariationsService* variations) {
  std::string country;
  if (variations) {
    country = variations->GetStoredPermanentCountry();
  }
  // Since variations doesn't provide a permanent country by default on things
  // like local builds, we try to fall back to the country_codes component which
  // should always have one.
  return country.empty()
             ? std::string(country_codes::GetCurrentCountryID().CountryCode())
             : country;
}
```

`country_codes::GetCurrentCountryID()` **按设备区域/语言**推导，
所以设备区域为 `zh_CN` 时会得到 `CN` —— 与代理出口无关。

---

## `components/variations/service/variations_service.cc`

```cpp
std::string VariationsService::GetLatestCountry() const {
  return field_trial_creator_.GetLatestCountry();      // → variations_country
}

std::string VariationsService::GetStoredPermanentCountry() const {
  return field_trial_creator_.GetPermanentConsistencyCountry();
}

bool VariationsService::OverrideStoredPermanentCountry(
    const std::string& country_override) { ... }
```

---

## `chrome/browser/glic/glic_pref_names_internal.h`

```cpp
// Integer pref storing the last observed ProfileReadyState.
inline constexpr char kGlicLastProfileReadyState[] =
    "glic.profile_enablement.last_ready_state";
```

---

## `chrome/browser/glic/public/glic_enabling.cc`

### 国家名单比对

```cpp
bool EvaluateCountryLists(const base::Feature& feature,
                          const char* default_enabled_countries,
                          std::string_view histogram_name,
                          std::string_view permanent_country_code,
                          std::string_view session_country_code) {
  CHECK(base::FeatureList::IsEnabled(feature));
  const std::vector<std::string> enabled_countries =
      GetFieldTrialParamAsSplitString(feature, "enabled_countries",
                                      default_enabled_countries);
  const std::vector<std::string> disabled_countries =
      GetFieldTrialParamAsSplitString(feature, "disabled_countries", "");

  const bool use_session_country = base::FeatureList::IsEnabled(
      features::kGlicUseSessionCountryForFiltering);

  if (std::ranges::any_of(disabled_countries, permanent_country_matches) ||
      (use_session_country &&
       std::ranges::any_of(disabled_countries, session_country_matches))) {
    return false;                                    // kBlockedInExclusionList
  }
  if (enabled_countries.size() == 1 && enabled_countries[0] == "*") {
    return true;                                     // kAllowedWildcardInclusion
  }
  if (std::ranges::any_of(enabled_countries, permanent_country_matches) ||
      (use_session_country &&
       std::ranges::any_of(enabled_countries, session_country_matches))) {
    return true;                                     // kAllowedInInclusionList
  }
  return false;                                      // kBlockedNotInInclusionList
}
```

```cpp
bool EvaluateCountryEnablement(std::string_view permanent_country_code,
                               std::string_view session_country_code) {
  if (!base::FeatureList::IsEnabled(features::kGlicCountryFiltering)) {
    return true;          // kAllowedFilteringDisabled —— 开关关掉就不过滤
  }
  return EvaluateCountryLists(features::kGlicCountryFiltering,
                              kDefaultEnabledCountries,
                              kCountryFilteringResultAdultHistogram,
                              permanent_country_code, session_country_code);
}
```

### 国家值来源

```cpp
std::string GlicEnablingDelegate::GetPermanentCountryCode() const {
  return base::ToLowerASCII(variations::GetCurrentCountryCode(
      g_browser_process->variations_service()));
}

std::string GlicEnablingDelegate::GetSessionCountryCode() const {
  std::string latest_country;
  if (g_browser_process->variations_service()) {
    latest_country = base::ToLowerASCII(
        g_browser_process->variations_service()->GetLatestCountry());
  }
  return latest_country;
}
```

### ready state 判定（`5` 的唯一来源）

```cpp
mojom::ProfileReadyState GlicEnabling::GetProfileReadyState(Profile* profile) {
  auto* command_line = base::CommandLine::ForCurrentProcess();
  if (command_line->HasSwitch(::switches::kGlicAutomation)) {
    return mojom::ProfileReadyState::kReady;         // 测试用旁路
  }

  const ProfileEnablement enablement = EnablementForProfile(profile);
  if (enablement.DisallowedByAdmin()) return mojom::ProfileReadyState::kDisabledByAdmin;

  if (!enablement.primary_account_is_fully_signed_in ||
      enablement.primary_account_needs_signed_in) {
    return mojom::ProfileReadyState::kSignInRequired;
  }

  if (!enablement.primary_account_is_capable) {
    return enablement.anchor_entrypoint_override_active
               ? mojom::ProfileReadyState::kIneligibleAccount
               : mojom::ProfileReadyState::kIneligible;
  }

  // Similar to account capability, for country filtering we only show a
  // specific mismatch error if the entry point is anchored.
  if (!enablement.allowed_by_country_filter) {
    return enablement.anchor_entrypoint_override_active
               ? mojom::ProfileReadyState::kLocationMismatch    // ← 5
               : mojom::ProfileReadyState::kIneligible;         // ← 4
  }

  if (enablement.anchor_entrypoint_override_active) {
    return mojom::ProfileReadyState::kIneligibleAccount;
  }
  if (!enablement.IsEnabled()) return mojom::ProfileReadyState::kIneligible;
  return mojom::ProfileReadyState::kReady;
}
```

### 结果缓存

```cpp
bool GlicGlobalEnabling::IsCountryEnabledImpl(
    CountryEvaluator evaluate, bool& is_enabled,
    std::optional<LastCheckedCountries>& last_checked_countries) {
  if (is_enabled) return true;                        // 一旦 true 永久粘住
  if (GlicEnabling::IsRetailDemoModeDesktop()) { is_enabled = true; return true; }
  LastCheckedCountries current_countries{delegate_->GetPermanentCountryCode(),
                                         delegate_->GetSessionCountryCode()};
  if (last_checked_countries.has_value() &&
      *last_checked_countries == current_countries) {
    return false;                                     // 国家没变 → 沿用旧结论
  }
  last_checked_countries = current_countries;
  is_enabled = evaluate(current_countries.permanent_country,
                        current_countries.session_country);
  return is_enabled;
}
```

### locale（区分 4 与 5）

```cpp
constexpr char kDefaultEnabledLocales[] =
#if BUILDFLAG(IS_ANDROID)
    "en-GB,en-US"
#else
    "af,am,bg,bn,ca,cs,da,de,el,es,es-419,et,fi,fil,fr,gu,hi,hr,hu,id,it,ja,kn,"
    "ko,lt,lv,ml,mr,ms,nl,no,pl,pt-BR,pt-PT,ro,ru,sk,sl,sr,sv,sw,ta,te,th,tr,"
    "uk,vi,zh-CN,zh-TW,en-GB,en-US"
#endif
    ;
```

locale 失败（`allowed_by_locale_filter == false`）**不会**产生 `location-mismatch`，
最终落到 `kIneligible(4)` —— 这是区分两者的关键。

---

## `chrome/browser/glic/host/glic.mojom`

```cpp
// @generate glic_api
// Client error dialog types.
[Stable, Extensible]
enum ClientErrorDialogType {
  [Default] kUnknown = 0,
  kDisabledByOrganization = 1,
  kGenericAvailability = 2,
  kIneligibleAccount = 3,
  kSignout = 4,
  kUnsupportedLocation = 5,
};
```

---

## 编译进二进制的默认国家名单

`kDefaultEnabledCountries`（Chrome 155 实测提取，`us` 为首项）：

```
us,ca,nz,in,as,au,bd,bn,bt,cc,ck,cx,fj,fm,gu,hk,hm,id,jp,kh,ki,kr,la,lk,mh,mm,mn,mo,mp,mv,my,
nc,nf,np,nr,nu,pf,pg,ph,pk,pn,pw,sb,sg,th,tk,tl,to,tv,tw,vn,vu,wf,ws,ag,ar,bb,bo,br,bs,bz,cl,
co,cr,dm,do,ec,gd,gt,gy,hn,ht,jm,kn,lc,mx,ni,pa,pe,py,sr,sv,tt,uy,vc,ve,ae,am,ao,aq,az,ba,bf,
bh,bi,bj,bw,cd,cf,cg,ci,cm,cv,dj,dz,eg,eh,er,et,ga,ge,gh,gm,gn,gq,gw,il,iq,jo,ke,kg,km,kw,kz,
lb,lr,ls,ly,ma,md,me,mg,mk,ml,mr,mu,mw,mz,na,ne,ng,om,pr,ps,qa,rs,rw,sa,sc,sd,sl,sn,so,ss,st,
sz,td,tg,tj,tm,tn,tz,ua,ug,um,uz,vi,xk,ye,za,zm,zw
```

提取命令：

```bash
strings -a "…/Google Chrome Framework" | grep -E "^[a-z]{2}(,[a-z]{2}){25,}$"
```

---

## 相关 feature flag 名称

| Flag | 作用 |
|---|---|
| `kGlicCountryFiltering` | 关掉则完全不做国家过滤（`kAllowedFilteringDisabled`） |
| `kGlicUseSessionCountryForFiltering` | 除 permanent 国家外，是否也拿 session 国家比对 |
| `kGlicMinorCountryFiltering` | 未成年账号的独立名单（默认更严） |
| `kGlicLocaleFiltering` | locale 过滤，失败落 4 不落 5 |

对应的 UMA 直方图（`chrome://histograms` 可查）：

- `Glic.CountryFilteringResult2.Adult` / `.Minor`
- `Glic.LocaleFilteringResult`
- `Glic.ProfileEnablement.*` / `Glic.ProfileEnablement.AnchoredDespiteEligibilityReason.*`
- `Glic.GlobalEnabling.FeatureDisabledReason.*`
- `Variations.LoadPermanentConsistencyCountryResult`（**可直接看出走了哪条分支**）
