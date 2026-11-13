# Tokenory design

Native macOS utility for checking AI usage and USD cost estimates. Preserve the menu bar entry, a single statistics window and standard Settings.

- The app icon is a front-facing orange counter with dark drums turning from 648 to 649. In `AppIcon.icon`, the default and dark appearances both use the orange enamel as the tile fill. The window follows the macOS mask at a constant inward distance (82 units on the 928-unit case), including at the corners. The 18 pt menu bar icon shows the last two drums in an orange case with a blue units digit. Render it in its original colors.
- Use system typography, semantic foreground/background colors and native controls. Use blue only for selection and the primary chart.
- Overview: compact filters and a toolbar range calendar; adjacent token/cost totals, secondary active-day/model counts, a token mix strip and a metric-switching chart. Tool and model rankings share a token/cost sort. Annual activity and model history follow below.
- Dates use a temporal axis; values use locale-aware formatting. Never compress every date into a categorical label.
- All UI copy lives in the String Catalog with stable semantic keys, complete sentences, placeholders and plural variants. English and Simplified Chinese ship together.
- Prices are managed by the app. Missing evidence is shown as an unavailable estimate; users never enter unit prices.
- Display USD with `$`, comma grouping and two decimal places. Compact token numbers use comma grouping and at most two decimal places; full token counts remain integers. Display rounding never changes stored values or pricing. Unknown costs must never appear as zero.

## Workspace surfaces

Watermelon references are recorded in `docs/design/watermelon-reference-2026-11-05.md` and `docs/design/watermelon-refinement-2026-11-06.md`. Implement the borrowed composition and interaction patterns with SwiftUI and Swift Charts.

- Canvas: neutral gray in light mode, ink charcoal in dark mode. Panels use a small luminance step, a 12 pt radius and 18 pt padding. Fields use an 8 pt radius. Preserve native sidebar materials.
- Typography: system body/callout for controls and rows, semibold headings, 32 pt primary totals and monospaced numeric digits. Chart readouts and record details show full integer token counts; costs retain the common two-decimal display format.
- Blue identifies the main series and selection. Stable tool colors distinguish model history layers. Do not use green/red to judge changes in usage.
- The upper chart combines Tokens bars and a cost line with independent axes. It keeps zero baselines and a temporal axis. Single-day ranges use 24 Beijing hours, based on actual timestamps across all effective records. Daily imports stay unallocated, future hours stay empty, and unknown costs break the line. The cost curve uses monotone interpolation through the observed values. Pointer and keyboard readouts show both metrics and incomplete pricing.
- Date selection uses a two-month range calendar with immediate presets and an explicit Apply for custom ranges. Cancel leaves the filter intact.
- Records use aligned SwiftUI rows, thin separators, a fixed header, full-row detail buttons and 50/100/200-row numbered pagination. Narrow windows can scroll the table horizontally and wrap the footer.
- The main window supports an 800 pt minimum width. Below a 720 pt detail width, distribution panels stack. Filter controls can wrap in Records.
- Settings uses vertical category buttons, a single content heading and a stable content-sized window. Control edges align to the trailing column. Disclosure headers are full-width buttons. Pricing groups by provider and identical complete pricing rules, with a model/provider search.
- Tab selection slides for 200 ms; disclosures reveal for 200 ms; pagination selection moves for 180 ms. Respect Reduce Motion. Chart pointer feedback is immediate; background collection does not animate values.
- Keep the menubar's existing compact summary and Liquid Glass presentation independent from workspace styling.
- Use tokens.ci's monochrome template brand marks beside tool, provider and model names. Default size is 14 pt, with 18–22 pt marks for headings. Marks inherit foreground color in both appearances; unknown names use a neutral system symbol. Generate native assets with `script/generate_brand_icons.py`.
- Opening a workspace window shows the Dock icon; closing the last workspace returns to menu-bar-only operation. Minimized windows retain their Dock entry.
- Per the user's explicit preference, suppress the visual focus halo on app surfaces while preserving native keyboard controls and accessibility labels.

For future components, reuse `WorkspacePanel` for a complete data or settings group, not each field. Keep captions only when they affect interpretation. Use native controls for focus, keyboard handling and accessibility.

## Annual activity

- Fixed YlGnBu calendar using upstream light and dark ramps; no palette control. The Monday-first calendar uses Beijing reporting dates; habit bars run Sunday through Saturday. Hover shows the shared chart readout style; click opens the day with a return action.
- The calendar and stacked model chart cover the last 12 months, independently of the upper date range. Global dimensions still apply; the history tool picker further narrows its own chart.
- Daily and trailing 30-day average share a raw total; chronological order is fixed. Missing days count as zero activity; unknown costs break only the affected model intervals; zero-token synthetic records with no cost count as zero. Zero-token records are not active days.
- Keep permanent copy to titles, metric/range labels and controls. Put cost basis and average definitions in help; show missing-price details on inspection. Follow docs/design/copy-review.md (7eec783).

- Tool and model rankings share one panel and a top-level Tokens/cost segmented control. Shared controls sit outside either child ranking; binary metric choices use one-click segments.

- Overview defaults to the last 7 days. Coding patterns is a separate annual panel with the top weekday share, biggest day, Sunday-first weekday bars and 24-hour bars from timestamped effective records.
- Reuse upstream profile vocabulary: Input / 输入, Coding patterns / 编码习惯, Most productive day / 最高产的一天, Biggest day / 单日最高, Usage over time / 用量走势.
- Cache annual presentation data per refresh; isolate hover observation to readouts. Lazy-load overview sections and reuse cached history on navigation.

- Coding-pattern charts share a compact row when detail width is at least 760 pt, and stack below it. Both plots use an 85 pt height.
- Keep details and sources mounted after first visit. Sources requests do not fetch price catalogs; already loaded source data refreshes after scans.
