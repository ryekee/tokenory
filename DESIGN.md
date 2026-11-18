# Tokenory design

Native macOS utility for checking AI usage and USD cost estimates. Preserve the menu bar entry, a single statistics window and standard Settings.

## Mechanical HUD

- Tokens use exact grouped integers without a unit suffix; costs retain a leading $. Menu bar HUD visibility uses a trailing checkmark. HUD Settings contains only controls: no explanatory footers or sound-preview button.

- Optional floating counter with preset positions, enabled in the menu bar or Settings → HUD. It does not take focus or create a Dock workspace entry. Persist the selected placement and follow the display containing the pointer, checked every 250 ms while visible.
- HUD 位置在设置页用 2 × 3 布局选择左上／中上／右上／左下／中下／右下；以鼠标所在屏幕 visibleFrame 贴边放置，避开菜单栏与 Dock，上下外壳保留 5 pt 内边距，四角左右外壳边距按底部边距（含 Dock）乘屏幕宽高比计算，并优先避让侧边 Dock。
- Render the counter at 50% of the original prototype dimensions: a 210 × 82 pt case inside a 220 × 92 pt window. Preserve full-size native audio popover controls. Restoring position must not restore the old larger dimensions.
- Follow the approved `docs/prototypes/mechanical-hud/index.html`: orange enamel case, recessed dark drums, blue units digit, no header text, Saira Extra Condensed SemiBold, mechanical text-fragment / coin icon buttons. The speaker opens a compact sound popover.
- Display all-agent today totals independently of dashboard filters, using the device’s current timezone and local midnight. Tokens remain full integers; USD uses two decimal places. Unavailable cost is —; partially priced cost has ≈ and a hover explanation.
- New increases accelerate briefly and decelerate over the last 66% of the movement. Sound follows drum crossings. First display, metric/day changes, decreases and Reduce Motion settle silently. Add incoming increments to the current roll without resetting its position, velocity or animation clock. Changed drums use monotone velocity-matched braking to the newest target; unchanged drums finish their existing motion.
- The HUD speaker button directly toggles sound; adjust volume in Settings. HUD has no context menu. Persist independent sound enablement and volume. Default sound off and volume 35%. Hiding the HUD cancels animation and sound. Keep the standalone demo and font license for future website use.

- The app icon is a front-facing orange counter with dark drums turning from 648 to 649. In `AppIcon.icon`, the default and dark appearances both use the orange enamel as the tile fill. The window follows the macOS mask at a constant inward distance (82 units on the 928-unit case), including at the corners. The 18 pt menu bar icon shows the last two drums in an orange case with a blue units digit. Render it in its original colors.
- Use system typography, semantic foreground/background colors and native controls. Use blue only for selection and the primary chart.
- Overview: compact filters and a toolbar range calendar; adjacent token/cost totals, secondary active-day/model counts, a token mix strip and a combined Tokens and cost chart. Tool and model rankings share a token/cost sort. Annual activity and model history follow below.
- Dates use a temporal axis; values use locale-aware formatting. Never compress every date into a categorical label.
- All UI copy lives in the String Catalog with stable semantic keys, complete sentences, placeholders and plural variants. English and Simplified Chinese ship together.
- Prices are managed by the app. Missing evidence is shown as an unavailable estimate; users never enter unit prices.
- Display USD with `$`, comma grouping and two decimal places. Compact token numbers use comma grouping and at most two decimal places; full token counts remain integers. Display rounding never changes stored values or pricing. Unknown costs must never appear as zero.

## Workspace surfaces

Watermelon references are recorded in `docs/design/watermelon-reference-2026-11-05.md` and `docs/design/watermelon-refinement-2026-11-06.md`. Implement the borrowed composition and interaction patterns with SwiftUI and Swift Charts.

- Align to visible control edges: fixed-width containers must not hide the actual edges of segmented controls. Avoid duplicate spacing between parent and child layouts.
- Canvas: neutral gray in light mode, ink charcoal in dark mode. Panels use a small luminance step, a 12 pt radius and 18 pt padding. Fields use an 8 pt radius. Preserve native sidebar materials.
- Typography: system body/callout for controls and rows, semibold headings, 32 pt primary totals and monospaced numeric digits. Chart readouts and record details show full integer token counts; costs retain the common two-decimal display format.
- Blue identifies the main series and selection. Stable tool colors distinguish model history layers. Do not use green/red to judge changes in usage.
- The upper chart combines Tokens bars and a cost line with independent axes. It keeps zero baselines and a temporal axis. Single-day ranges use 24 Beijing hours, based on actual timestamps across all effective records. Daily imports stay unallocated, future hours stay empty, and unknown costs break the line. The cost curve uses monotone interpolation through the observed values. Pointer and keyboard readouts show both metrics and incomplete pricing.
- Date selection uses a two-month range calendar with immediate presets and an explicit Apply for custom ranges. Cancel leaves the filter intact. Toolbar arrows shift the shared selection by its inclusive day count. A forward step stops at the current reporting day, and All Time disables both arrows. Historical selections stay fixed. Stepping to a range that matches Today, Last 7 Days or Last 30 Days restores that rolling preset.
- Records use aligned SwiftUI rows, thin separators, a fixed header, full-row detail buttons and 50/100/200-row numbered pagination. Narrow windows can scroll the table horizontally and wrap the footer.
- The main window supports an 800 pt minimum width. Below a 720 pt detail width, distribution panels stack. Filter controls can wrap in Records.
- Settings uses vertical category buttons, a single content heading and a stable content-sized window. Control edges align to the trailing column. Disclosure headers are full-width buttons. Pricing groups by provider and identical complete pricing rules, with a model/provider search.
- Tab selection slides for 200 ms; disclosures reveal for 200 ms; pagination selection moves for 180 ms. Respect Reduce Motion. Chart pointer feedback is immediate; background collection does not animate values.
- Keep the menubar's compact summary and Liquid Glass presentation independent from workspace styling. Its three columns read Tokens / Cost / Speed (Tokens / 费用 / 速度), with today’s duration-weighted turn speed to the right of cost. This query ignores dashboard filters; missing speed is — and estimates carry ≈.
- Use tokens.ci's monochrome template brand marks beside tool, provider and model names. Default size is 14 pt, with 18–22 pt marks for headings. Marks inherit foreground color in both appearances; unknown names use a neutral system symbol. Generate native assets with `script/generate_brand_icons.py`.
- Opening a workspace window shows the Dock icon; closing the last workspace returns to menu-bar-only operation. Minimized windows retain their Dock entry.
- Per the user's explicit preference, suppress the visual focus halo on app surfaces while preserving native keyboard controls and accessibility labels.

For future components, reuse `WorkspacePanel` for a complete data or settings group, not each field. Keep captions only when they affect interpretation. Use native controls for focus, keyboard handling and accessibility.

## Overview and trends

- Use tokens.ci as the reference for content, visual style and bilingual vocabulary. When a design proposal is requested for review, present a prototype first and preserve confirmed interactions when connecting it to real app data.
- Default to the last 7 days. Align trend labels with the visible edges of the heading, body and chart. Keep chronological order fixed; do not offer a newest-first control.
- Hide the active-day count when the selected range covers a single date.
- Tool and model rankings share one panel and a top-level Tokens/cost segmented control. Place shared controls outside both child rankings. Use one-click segments for binary choices.
- Daily values and trailing 30-day averages use the same raw totals. No-activity dates count as zero. Unknown costs remain gaps only in the affected series; never draw unknown costs as zero. Zero-token synthetic records with no cost count as zero. Zero-token records are not active days. Do not introduce erroneous breaks in averages.

## Turn speed

- Use reporting hours on the time axis. Show a quartile box with a median tick for hours with at least three turns. Plot sparse turns and outliers individually and leave empty hours blank.
- Explain the box through its hover readout, using real values and a turn count. Keep the plot free of a persistent legend. Selecting a box filters the turn list to that hour and selects the observed turn closest to the median.

## Annual calendar

- Use the fixed upstream YlGnBu light and dark ramps; do not offer a palette control. The calendar is Monday-first and uses Beijing reporting dates.
- Hover immediately shows the date and data in the shared chart readout style, with the same smooth response as other charts. Clicking a date opens that day, with a return action.
- The calendar and stacked model chart cover the last 12 months, independently of the upper date range. Global dimensions still apply; the history tool picker further narrows its own chart.

## Coding patterns

- Use a separate annual panel with the top weekday and its share, biggest day, Sunday-first weekday bars and 0:00–23:00 hourly bars from timestamped effective records.
- Charts share a compact row when detail width is at least 760 pt, and stack below it. Both plots use an 85 pt height.

## Brands and rates

- Cover every supported Agent and its associated provider/model catalog, not only those already used. Show rates supported by evidence; keep missing rates unavailable. Use the supplier's brand display name and authentic logo; display xiaomi as Xiaomi MiMo with its M logo.
- The rate table has a one-click All / Used switch and clickable, collapsible provider groups.
- Show both DeepSeek peak and off-peak rates. Place their explanation under DeepSeek, without repeating a peak-rate label at the top of the table or presenting the explanation as a rate.
- Identify compactor cost as an estimate using GPT-6 Luna as its reference. See [compactor pricing](docs/local/devin-compactor.md).

## Copy and controls

- Follow [the bilingual copy review](docs/design/copy-review.md). Use Input / 输入, Coding patterns / 编码习惯, Most productive day / 最高产的一天, Biggest day / 单日最高 and Usage over time / 用量走势.
- Keep permanent copy to titles, metric/range labels and controls. Place useful explanations next to the relevant content; put cost basis and average definitions in help and show missing-price details on inspection. Remove information icons that have neither click nor hover behavior.

## Performance

- Build the date picker's two visible months once at opening and reuse their labels when selecting dates.
- Keep the date and scan buttons adjacent. Show report progress in the scan icon's existing space.
- Keep the current content visible until the new date-range report arrives. Drive rolling readouts from one count with carry and borrow. For large changes, briefly fade to the final portion of the same count, then roll to the result. For unit changes, fade between the two formatted values. Move plot marks independently of axis layout. Bars start at zero after an empty range, and lines draw left to right. Empty results mount only the empty state. Respect Reduce Motion and reuse annual data across range changes.
- Cache annual presentation data per refresh; isolate hover observation to readouts. Lazy-load overview sections and reuse cached history on navigation.
- Keep details and sources mounted after first visit. Sources requests do not fetch price catalogs; already loaded source data refreshes after scans. Keep overview, details and sources responsive when entering and switching pages.

## Review checklist

This checklist is a design requirement, not a record of completed acceptance.

- In a real window, inspect English and Simplified Chinese in light and dark appearances, at wide and narrow widths. Check visible-edge alignment, wrapping and the coding-pattern layout.
- Check calendar hover feedback and click-through, shared filter scope, one-click metric switches and provider disclosures.
- Check the 30-day averages with no-activity dates and unknown costs: zero activity appears as zero, unknown cost stays a gap only in its own series, and no erroneous gaps appear.
- Switch among overview, details and sources; inspect loading, preserved state and responsiveness. Check calendar hover responsiveness.
- When a layout defect is found, use appropriate existing skills to inspect the whole app and fix the same class of issue.

The Watermelon documents linked above are historical reference records; this document is the current design specification.

[UI layout audit](docs/local/ui-layout-audit.md) records historical root causes and acceptance; it does not establish that every current state passes.

## Agent turns

- Use one summary panel for duration-weighted generation speed, mean recorded first-token wait and mean reasoning tokens per turn. Missing values remain unavailable; definitions and measurement coverage live in help.
- Place a monotone speed curve below the summary. Use real timestamps and join observed points across gaps without inserting zero values. Pointer and keyboard inspection select a turn.
- Keep the chronological chart independent of list sorting (duration, newest, oldest, speed, reasoning). Use native date/model controls, 50-row list pages and a detail panel; stack list/detail below 720 pt content width.
- Speed includes the entire turn duration. Never label time remaining after tool waits as model generation time or expose an adjusted generation speed.

- Put hero units inline after the large value on the numeric baseline. In turn details, show throughput, reasoning and first-token wait in three columns, with labels above prominent values.
- Reuse overview token semantics: output is teal and reasoning is gray. Tool waiting is brown and other turn time is indigo; legends carry matching color dots. Place reasoning and other-output totals at opposite ends under the mix strip.
- Offer agent and model filters. Mark log-timestamp duration estimates and derived speeds with ≈, preserve unknown fields, and expose current agent support in a compact information popover.

- The agent-support popover contains only Supported / Not supported sections and tool-logo grids. Show agent names only in a pointer-following hover label that stays close to the pointer, uses the hovered icon’s actual bounds for clearance, and prefers placement above it. The label does not intercept input. Do not show persistent descriptions, delegated mappings or expandable explanations; preserve accessible names. Detailed evidence stays in project documentation.

- Turn-detail agent, model and reasoning effort share one compact horizontal row below the project title; long model names truncate in the middle.
