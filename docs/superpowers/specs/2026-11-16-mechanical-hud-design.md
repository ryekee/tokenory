# Mechanical HUD — approved prototype

The user approved `docs/prototypes/mechanical-hud/index.html` for native integration on 2026-11-16. Preserve this standalone, embedded-font demo for the future website.

Show today's cumulative usage for every agent, independent of dashboard filters, using the existing Asia/Shanghai reporting day. Switch Tokens / USD cost with the approved text-fragment and coin icons. Keep the orange enamel case, recessed dark drums, blue units digit, Saira Extra Condensed SemiBold, and no header labels. Use the existing standard-rate estimate, never source cost or subscription charges. Unknown cost is unavailable; partial pricing is marked and explained on hover.

The approved motion has a short acceleration, brief cruise and long deceleration. Sound follows actual drum crossings, with independent mute and persistent volume. First presentation, metric changes, midnight and downward corrections settle immediately and silently. Coalesce updates received during a roll into the latest target. Respect Reduce Motion; hiding the HUD stops work and sound.

Approaches considered: full mechanical counter (chosen for app-icon continuity), thin mechanical counter (less desktop space, weaker visual identity). Native SwiftUI / AppKit implementation follows the chosen full-counter prototype; the HTML remains a website demo.

Implementation choices: a draggable, nonactivating floating panel with saved position; HUD visibility in menu and Settings; sound initially off, volume 35%; HUD initially off until enabled. Settings supplies volume and a sound preview. Scan-completion events supply live totals; midnight and wake refresh the day even if the menu is closed. No fake increments in the shipped HUD.
