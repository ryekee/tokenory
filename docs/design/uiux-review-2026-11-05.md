# UI/UX review

Inspected the installed app and current SwiftUI source. Applied impeccable's native critique/polish workflow and craft floor. Native controls and window structure follow build-macos-apps:swiftui-patterns. apple-design is primarily a web translation of Apple patterns, so the macOS-specific skill is the closer match.

Observed defects:
- Every date was a categorical x-axis label, producing an unreadable grid across history.
- Filters stretched across the window and separated related choices.
- Cost totals showed unnecessary fractional digits; primary totals were separated by unused space.
- The price screen asked users to supply model rates and used only peak DeepSeek rates.
- Localized display text also served as navigation state.

Direction: preserve native navigation; compact the filter row; use real dates, sparse ticks and restrained grid lines; align summary metrics; reduce model-list density with an explicit expansion; move rates to a read-only section. Use a String Catalog and stable navigation IDs. Use direct English and Chinese copy, with only necessary cost limitations.

## Native verification

- English Overview: temporal axis shows weekly labels, locale-aware compact totals and two-decimal USD summary. Found and corrected a summary divider that aligned to the text baseline instead of the metric block.
- Settings: changed Follow System to Simplified Chinese through the native language picker; labels changed immediately.
- Chinese Pricing: read-only rates and missing-model disclosure, no rate-entry fields.
- Chinese Records: localized dates, translated controls, numeric columns and six-decimal small request costs remain readable.
- Icons: checked app artwork at 128/64/32 px and the independent menu glyph at 18 pt. The template uses exact circles; no tracing or color-image extraction.


## Delivery validation

- Tokenory Rust crate: 32 tests passed, including schedule boundaries, holidays, exact provider matching, offline catalog upgrades, historical snapshot preservation and float-safe reprice validation. Clippy passed with warnings denied.
- Native app: 6 XCTest cases passed, including real helper lifecycle, bilingual resource lookup, English plurals, Chinese counts and the Beijing reporting boundary.
- 158 String Catalog entries have both en and zh-Hans translations; all literal UI localization keys resolve.
- Release build and deep/strict ad-hoc signature verification passed. The build script now re-signs the outer app after helper-only incremental changes.
- Installed in ~/Applications/Tokenory.app. Verified final Chinese month labels and compact filters in the running application. English Overview/Settings and Chinese Overview/Settings/Records were reviewed during this task; no light-mode, relogin or sleep/wake acceptance is claimed here.
- Independent 18 pt menu geometry and 128/64/32 px app artwork: see [icon preview](icon-preview.png). Source PNG and SVG are under assets/brand; regenerate Xcode assets with `python3 script/generate_icons.py`.

The installed database was backed up before repricing. Effective tokens remained 18,304,383,257 during the fixed comparison; continuous collection resumes afterward. DeepSeek's 545 local records remained 194,207,906 tokens, with the current-rate estimate corrected from USD 2.204343388 to USD 1.426144316. Previous price snapshots and source costs remain stored. Private before/after evidence is under local-data/uiux-evidence; it is not committed.
