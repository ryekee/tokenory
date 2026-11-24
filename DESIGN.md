# Tokenory design

Native macOS utility for checking AI usage and USD cost estimates. Preserve the menu bar entry, a single statistics window and standard Settings.

## Mechanical HUD

- Tokens use exact grouped integers without a unit suffix; costs retain a leading $. Menu bar HUD visibility uses a trailing checkmark. HUD Settings contains only controls: no explanatory footers or sound-preview button.

- Optional floating counter with preset positions, enabled in the menu bar or Settings → HUD. It does not take focus or create a Dock workspace entry. Persist the selected placement and follow the display containing the pointer, checked every 250 ms while visible. Keep the HUD out of other apps’ macOS full-screen Spaces and restore it on the desktop if enabled.
- HUD 位置在设置页用 2 × 3 布局选择左上／中上／右上／左下／中下／右下；以鼠标所在屏幕 visibleFrame 贴边放置，避开菜单栏与 Dock，上下外壳保留 5 pt 内边距，四角左右外壳边距按底部边距（含 Dock）乘屏幕宽高比计算，并优先避让侧边 Dock。
- Render the counter at 50% of the original prototype dimensions: a 210 × 82 pt case inside a 220 × 92 pt window. Preserve full-size native audio popover controls. Restoring position must not restore the old larger dimensions.
- Use an orange enamel case, recessed dark drums, a blue units digit, Saira Extra Condensed SemiBold, and mechanical text-fragment / coin icon buttons. Keep the counter free of header text. The speaker opens a compact sound popover.
- Idle hiding is off by default. When enabled, hide the HUD after 30 seconds without new usage and show it on the next usage update. Turning idle hiding off restores an idle-hidden HUD. Double-click the readout or case to open statistics after the system multi-click interval. A third click cancels the pending open. Triple-click the same area to turn off the HUD by default, ignore the gesture, or hide it for 30 seconds, 1 minute or 5 minutes. When that duration ends, show the HUD and start a new idle period if idle hiding is enabled.
- Display all-agent today totals independently of dashboard filters, using the device’s current timezone and local midnight. Tokens remain full integers; USD uses two decimal places. Unavailable cost is —; partially priced cost has ≈ and a hover explanation.
- New increases accelerate briefly and decelerate over the last 66% of the movement. Sound follows drum crossings. First display, metric/day changes, decreases and Reduce Motion settle silently. Add incoming increments to the current roll without resetting its position, velocity or animation clock. Changed drums use monotone velocity-matched braking to the newest target; unchanged drums finish their existing motion.
- Switch the displayed metric and toggle sound directly on the HUD. In Settings, align the volume control on the right and use 5% steps. With sound enabled, volume changes play a sample at the selected level. Unmuting in Settings or on the HUD plays the same sample. Match the row spacing used elsewhere in HUD settings. HUD has no context menu. Persist independent sound enablement and volume. Default sound off and volume 35%. Hiding the HUD cancels rolling animation and its sound. The website demo and its licensed font are maintained in `site/`.

- The app icon is a front-facing orange counter with dark drums turning from 648 to 649. In `AppIcon.icon`, the default and dark appearances both use the orange enamel as the tile fill. The window follows the macOS mask at a constant inward distance (82 units on the 928-unit case), including at the corners. The 18 pt menu bar icon shows the last two drums in an orange case with a blue units digit. Render it in its original colors.
- Use system typography, semantic foreground/background colors and native controls. Use Tokyo Neon for the dark statistics workspace and the Tokenory-designed Tokyo Neon Light for the light workspace. Follow the appearance selected in General settings.
- Overview: compact filters and a toolbar range calendar; adjacent token/cost totals, secondary active-day/model counts, a token mix strip and a combined Tokens and cost chart. Tool and model rankings share a token/cost sort. Annual activity and model history follow below.
- Dates use a temporal axis; values use locale-aware formatting. Never compress every date into a categorical label.
- All UI copy lives in the String Catalog with stable semantic keys, complete sentences, placeholders and plural variants. English and Simplified Chinese ship together.
- Prices are managed by the app. Missing evidence is shown as an unavailable estimate; users never enter unit prices.
- Display USD with `$`, comma grouping and two decimal places. Compact token numbers use comma grouping and at most two decimal places; full token counts remain integers. Display rounding never changes stored values or pricing. Unknown costs must never appear as zero.

## Workspace surfaces

Implement the workspace composition and interaction patterns with SwiftUI and Swift Charts.

- Place a gear at the trailing edge of the sidebar status row. It opens the same Settings window as the menu bar.
- Align to visible control edges: fixed-width containers must not hide the actual edges of segmented controls. Avoid duplicate spacing between parent and child layouts.
- Dropdowns use the same single downward chevron and anchored option popover as the model chooser. Show the active value in the trigger and mark the choice in the list. In inactive dashboard and Settings windows, the trigger text uses the same system gray as the date picker. Keep search for longer lists and preserve single-click segmented controls.
- Use solid canvas and panel fills. The light canvas is cool off-white (#F6F8FA) with white panels (#FFFFFF). The dark canvas is near-black violet (#100E18) with plum panels (#20182C). Panels use a 12 pt radius and 18 pt padding. Fields use an 8 pt radius. Preserve native sidebar materials. Apply theme ink to text and chart marks. Keep native button feedback across window states. Settings action buttons and menus use the system gray when the window is inactive. In dark mode, lift dropdowns above the panel with a lighter backing and use a muted gray label.
- Typography: system body/callout for controls and rows, semibold headings, 32 pt primary totals and monospaced numeric digits. Chart readouts and record details show full integer token counts; costs retain the common two-decimal display format.
- Blue identifies local Tokens, mint identifies other devices, pink identifies the total cost line, and yellow identifies Fast. Light mode uses the app icon’s blue units indicator (#2E579E) for selection. Dark mode uses neon pink (#FF4081). Keep axes neutral. The annual activity calendar retains its own surface and YlGnBu scale. Stable tool colors distinguish model history layers. Do not use green/red to judge changes in usage.
- The upper chart combines Tokens bars and a cost line with independent axes. It keeps zero baselines and a temporal axis. Single-day ranges in the local view use the system time zone and its actual day length. The combined device view uses the shared Beijing time zone. Daily imports, approximate timestamps and records whose archived day differs from their system-local day stay unallocated to an hour. Future hours stay empty and unknown costs break the line. The cost curve uses monotone interpolation through the observed values. Pointer and keyboard readouts show both metrics and incomplete pricing.
- Date selection uses a two-month range calendar with immediate presets and an explicit Apply for custom ranges. Cancel leaves the filter intact. Toolbar arrows shift the shared selection by its inclusive day count. A forward step stops at the current reporting day, and All Time disables both arrows. Historical selections stay fixed. Stepping to a range that matches Today, Last 7 Days or Last 30 Days restores that rolling preset.
- Records use aligned SwiftUI rows, thin separators, a fixed header, full-row detail buttons and 50/100/200-row numbered pagination. The header shows the filtered Tokens and estimated cost totals above the matching columns. Pagination leaves those totals intact. Narrow layouts use compact columns and show Simplified Chinese dates as `yyyy/M/d`. The footer can wrap.
- With at least 936 pt of space inside the Records content margins, display the selected record beside the table. Keep the selected row visible and let the detail scroll separately. Use a sheet with less space.
- In Records, zero matches replace pagination with a clear-filters or date-picker action. Clearing dimensions keeps the current dates.
- In Records, the Conversation picker searches effective records within the current date and dimension filters. Use the saved Codex title as the row and selection label when available. For untitled conversations, use the tool and latest activity as the label, with the model and a short session ID for reference. Selecting a conversation resets pagination and leaves the Overview scope intact.
- The main window supports an 800 pt minimum width. Below a 720 pt detail width, distribution panels stack. In Overview and Records, the filter bar fits one row and contracts dropdowns as the window narrows. In light appearance, the closed tool, provider and model selectors use gray text (#59636E) with a lighter gray chevron.
- Settings uses vertical category buttons, a single content heading and a stable content-sized window. Control edges align to the trailing column. Settings use the same small native switch size. General contains appearance, language, currency and login settings. Appearance defaults to System and also offers Light and Dark in a dropdown aligned with the language selector. Apply the choice immediately across windows and remember it on relaunch. Use the same app accent for native switches, segmented controls and custom selections. About shows the app icon, installed version and Sparkle controls. Size each dropdown for its localized options. Disclosure headers are full-width buttons. Align the rate refresh button to the right of its explanation. Refresh rates and preview the recalculated estimates in one flow. Require confirmation before writing changes to saved estimates. Keep search, the All and Used choices, and model selection in one pricing dropdown. Group displayed rates by provider and identical complete pricing rules.
- After a user chooses a backup file, confirm the file name and ledger replacement in a native dialog. Cancel is the default action.
- Offer 30, 60 and 120 seconds for the scan interval. Show a previously saved custom interval until the user chooses a preset.
- Keep collection save at the bottom of the scan-path card. Keep the width stable across the short save, saving, saved and retry labels, and restore the save action on edit. On failure retain Retry and expandable details in the card. Keep backup and restore feedback beside those controls.
- Tab selection slides for 200 ms; disclosures reveal for 200 ms; pagination selection moves for 180 ms. Respect Reduce Motion. Chart pointer feedback is immediate; background collection does not animate values.
- Keep the menubar's compact summary and Liquid Glass presentation independent from workspace styling. Its three columns read Tokens / Cost / Speed (Tokens / 费用 / 速度), with today’s duration-weighted turn speed to the right of cost. This query ignores dashboard filters; missing speed is — and estimates carry ≈.
- Use tokens.ci's monochrome template brand marks beside tool, provider and model names. Default size is 14 pt, with 18–22 pt marks for headings. Marks inherit foreground color in both appearances; unknown names use a neutral system symbol. Generate native assets with `script/generate_brand_icons.py`.
- Opening a workspace window shows the Dock icon; closing the last workspace returns to menu-bar-only operation. Minimized windows retain their Dock entry.
- Per the user's explicit preference, suppress the visual focus halo on app surfaces while preserving native keyboard controls and accessibility labels.

For future components, reuse `WorkspacePanel` for a complete data or settings group, not each field. Keep captions only when they affect interpretation. Use native controls for focus, keyboard handling and accessibility.

- Place Sources in Settings, alongside Collection and iCloud Sync. Group sources by device. Show each local tool once and disclose its scan diagnostics and ledger sources together. Match the amount style for local and remote devices. Place the supported-tool catalog and export controls in separate cards after the devices. Align the export scope on the left and the format menu on the right. In iCloud Sync, use separate cards for syncing and cloud storage. Place descriptions on the left and actions on the right, show relative time for the last sync, and require a scope choice and confirmation before deleting cloud data. Highlight Cancel in both dialogs.
- Show the collection scanner’s default paths as read-only rows beside editable additions for the selected tool. The tool selector identifies the editor. Keep button labels and the collection save result free of trailing punctuation.
- Group historical import, backup, restore and the local database location in Data. Choose the import format from the Choose File menu before opening the file picker. Place the Manage Backups menu on the right with Create Backup and Restore from Backup. Keep previews and source conflicts beside the file chooser. Keep prior imports in a disclosure. Confirm undo and restore with the affected batch or file.

## Overview and trends

- When several Macs contribute to the selected range, align the total Tokens, estimated cost and distinct model count on shared typographic baselines. Show the matching figure for this Mac directly below each total. Count a shared model once in the total. Use a desktop symbol and a localized “This Mac” label on the Tokens and cost detail rows. Keep the secondary model count numeric. Align the symbol, label and value with the Fast row. Hovering the primary or secondary number opens the device breakdown; trailing space and labels remain inactive.
- Stack other Macs in mint above this Mac’s blue Tokens in both hourly and daily charts. Draw both sources as solid colors at rest. Plot the combined cost as a single pink line, with a legend sample the width of a Tokens swatch. A readout starts with the total, followed by this Mac and each participating Mac, with full Tokens and USD on the same row. Preserve unknown and partial prices.
- Use the same local/other colors in tool, model and subagent bars. The Codex summary includes participating devices. Conversation details come from this Mac and their percentages use its subagent totals.
- Place one “This Mac only” switch immediately before the date picker in the Overview toolbar. Use the system inactive label color to match the date picker in both appearances. The switch scopes every panel and filter menu to the same device selection and defaults to all participating Macs. Sort tools and providers by total Tokens across the included ledgers and models by name. The metrics, usage chart and activity calendar list other Macs in Sources order, by device name and then ID.

- Place inspection cards beside the pointer and keep its selected number, bar, day cell or point clear. Flip at the window edges. Measure a compact, stable card for the available series and device rows so its dimensions stay constant while traversing dates.

- Place the Codex subagent panel after the tool and model rankings and before annual activity when the selected filters have confirmed Codex subagent activity. Show starts, Tokens and estimated cost together. Use horizontal bars and percentage labels for Tokens and cost. The summary compares with the filtered Codex total. Keep the per-conversation section collapsed. Its rows compare with the subagent total and reveal models and main-agent context on expansion.
- The existing total includes confirmed subagent usage as part of its ledger total. Match the Coding patterns metrics with medium-weight title3 numbers. The subagent panel counts newly started threads on their start dates and shows tokens from effective usage records in the selected range. A verified start can display the card before any usage is recorded.

- Use tokens.ci as the reference for content, visual style and bilingual vocabulary. When a design proposal is requested for review, present a prototype first and preserve confirmed interactions when connecting it to real app data.
- Default to the last 7 days. Align trend labels with the visible edges of the heading, body and chart. Keep chronological order fixed; do not offer a newest-first control.
- Hide the active-day count when the selected range covers a single date.
- Tool and model rankings share one panel and a top-level Tokens/cost segmented control. Place shared controls outside both child rankings. Use one-click segments for binary choices.
- Each ranking bar shows the group's share of the selected metric. Lay out this Mac’s standard and Fast amounts, then the other Macs’ standard and Fast amounts, as adjacent full-height segments. Both Fast segments use the theme’s yellow. Their widths come out of their respective source totals. Use Fast tokens in Tokens mode and known estimated costs from Fast requests in Cost mode. Share one legend across both rankings and expose the Fast amount on row inspection.
- Daily values and trailing 30-day averages use the same raw totals. No-activity dates count as zero. Unknown costs remain gaps only in the affected series; never draw unknown costs as zero. Zero-token synthetic records with no cost count as zero. Zero-token records are not active days. Do not introduce erroneous breaks in averages.
- Daily and 30-day average views use a segmented control. The two import formats use the same single-click choice pattern.

## Turn speed

- Group by local reporting time. Use hours for one day, days for 2–7 days, and Monday-start weeks for longer ranges and All Time. Clip edge weeks to the selected dates.
- Show a quartile box and median tick for each group with at least three turns. Draw each outlier at the horizontal center of its box. Plot sparse turns at their start times and leave empty periods blank. Inspecting an outlier shows its actual turn timestamp. Hover shows the period, measured values and turn count. Selecting a box filters the list to that period and selects the observed turn closest to the median.

## Annual calendar

- Use the fixed upstream YlGnBu light and dark ramps; do not offer a palette control. The calendar is Monday-first and uses the archived day keys. The local date range follows the Mac’s time zone.
- Hover immediately shows the date and data in the shared chart readout style, with the same smooth response as other charts. Clicking a date opens that day, with a return action.
- The calendar and stacked model chart cover the last 12 months, independently of the upper date range. Global dimensions still apply; the history tool picker further narrows its own chart. Device snapshots use Beijing reporting dates for timestamped events. Day-level imports retain their source dates.

## Coding patterns

- Use a separate annual panel with the top weekday and its share, biggest day, Sunday-first weekday bars and 0:00–23:00 hourly bars from timestamped effective records.
- Charts share a compact row when detail width is at least 760 pt, and stack below it. Both plots use an 85 pt height.

## Brands and rates

- Cover every supported Agent and its associated provider/model catalog, not only those already used. Show rates supported by evidence; keep missing rates unavailable. Use the supplier's brand display name and authentic logo; display xiaomi as Xiaomi MiMo with its M logo.
- The rate table has a shared dropdown for searching and choosing All, Used or one model, with clickable, collapsible provider groups.
- Show both DeepSeek peak and off-peak rates. Place their explanation under DeepSeek, without repeating a peak-rate label at the top of the table or presenting the explanation as a rate.
- Identify compactor cost as an estimate using GPT-6 Luna as its reference.

## Copy and controls

- Use Input / 输入, Coding patterns / 编码习惯, Most productive day / 最高产的一天, Biggest day / 单日最高 and Usage over time / 用量走势.
- Keep permanent copy to titles, metric/range labels and controls. Place useful explanations next to the relevant content; put cost basis and average definitions in help and show missing-price details on inspection. Remove information icons that have neither click nor hover behavior.
- Use the same small lightning mark for documented Fast mode in Overview, Records and Speed. Overview displays tokens attributed to Fast for the selected filters. Records and Speed mark individual entries, with the mode evidence in help.

## Performance

- Build the date picker's two visible months once at opening and reuse their labels when selecting dates.
- Keep the date and scan buttons adjacent. For a range refresh, use the scan icon's existing space after 300 ms, with a minimum visible duration of 500 ms. For a first Overview load that exceeds the delay, show static placeholders in the metric and chart positions.
- On a range change, publish the local report, combined totals, and device breakdown together. Toolbar date changes keep the reading position. Selecting a day in the activity calendar takes the reader to the top for that day's report.
- Keep the current content visible until the new date-range report arrives. Drive rolling readouts from one count with carry and borrow. For large changes, briefly fade to the final portion of the same count, then roll to the result. For unit changes, fade between the two formatted values. Move plot marks independently of axis layout. Bars start at zero after an empty range, and lines draw left to right. Empty results mount only the empty state. Respect Reduce Motion and reuse annual data across range changes.
- If a report request fails, offer Retry for the current selection. Keep any previous results visible and identify their date range. A first-load failure replaces the loading indicator.
- An empty Speed report shows one state with a date or filter action. In Overview, hide empty totals and rankings and show one state for the selected dates. Show the annual panels when their scope has records. Use inline text for a missing hourly breakdown or an empty management section.
- Cache annual presentation data per refresh; isolate hover observation to readouts. Lazy-load overview sections and reuse cached history on navigation.
- Keep Records mounted after its first visit. Settings → Sources uses the settings scroll view and reloads independently when opened. Scans refresh cached source data.

## Review checklist

This checklist is a design requirement, not a record of completed acceptance.

- In a real window, inspect English and Simplified Chinese in light and dark appearances, at wide and narrow widths. Check visible-edge alignment, wrapping and the coding-pattern layout.
- Check calendar hover feedback and click-through, shared filter scope, one-click metric switches and provider disclosures.
- Check the 30-day averages with no-activity dates and unknown costs: zero activity appears as zero, unknown cost stays a gap only in its own series, and no erroneous gaps appear.
- Switch among Overview, Records, Speed and Settings → Sources; inspect loading, preserved state and responsiveness. Check calendar hover responsiveness.
- When a layout defect is found, use appropriate existing skills to inspect the whole app and fix the same class of issue.

## Agent turns

- Use one summary panel for duration-weighted generation speed, mean recorded first-token wait and mean reasoning tokens per turn. Missing values remain unavailable; definitions and measurement coverage live in help.
- Place the speed distribution below the summary on a continuous time axis. Pointer and keyboard inspection select a time group or a turn.
- Keep the chronological chart independent of list sorting (duration, newest, oldest, speed, reasoning). The list opens with the newest turn first and shows six turns per page. Only the page scrolls. Keep the list height stable on short pages and align the detail card to the list in the side-by-side layout. Stack them below 720 pt content width.
- Search the available turns by project, saved conversation title or turn ID. Keep the active search visible and clearable, and repaginate its results. Keep the existing time-group selection when searching.
- Speed includes the entire turn duration. Never label time remaining after tool waits as model generation time or expose an adjusted generation speed.

- Put hero units inline after the large value on the numeric baseline. In turn details, show throughput, reasoning and first-token wait in three columns, with labels above prominent values. Use spacing and type to group the details. Put concise metric definitions in the help control’s hover and keyboard-accessible popover.
- Reuse overview token semantics: output is mint and reasoning is neutral gray-violet. Tool waiting is brown and other turn time is indigo; legends carry matching color dots. Place reasoning and other-output totals at opposite ends under the mix strip.
- Offer agent and model filters. Mark log-timestamp duration estimates and derived speeds with ≈, preserve unknown fields, and expose current agent support in a compact information popover.

- The agent-support popover contains only Supported / Not supported sections and tool-logo grids. Show agent names only in a pointer-following hover label that stays close to the pointer, uses the hovered icon’s actual bounds for clearance, and prefers placement above it. The label does not intercept input. Do not show persistent descriptions, delegated mappings or expandable explanations; preserve accessible names. Detailed evidence stays in project documentation.

- Show a saved conversation title below the selected turn’s project when available. Use the same local title index as the Records picker. The agent, model and reasoning effort share a compact row below the title area. Long model names truncate in the middle.
