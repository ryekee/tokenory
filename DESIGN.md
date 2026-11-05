# Tokenory design

Native macOS utility for checking AI usage and USD cost estimates. Preserve the menu bar entry, a single statistics window and standard Settings.

- Identity: a notched champagne coin on ink navy. The same notch identifies the monochrome menu icon. No letter T or stacked bars.
- Use system typography, semantic foreground/background colors and native controls. Use blue only for selection and the primary chart.
- Overview: compact filters, adjacent token and cost totals, one readable time chart, then aligned tool/model lists. Avoid nested cards and decorative labels.
- Dates use a temporal axis; values use locale-aware formatting. Never compress every date into a categorical label.
- All UI copy lives in the String Catalog with stable semantic keys, complete sentences, placeholders and plural variants. English and Simplified Chinese ship together.
- Prices are managed by the app. Missing evidence is shown as an unavailable estimate; users never enter unit prices.
- Main numbers use two decimal places at most; request details may show small USD amounts. Unknown costs must never appear as zero.
