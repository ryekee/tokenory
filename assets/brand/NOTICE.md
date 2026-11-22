# Native brand glyphs

Native template glyphs inherit the surrounding foreground color, following the tokens.ci model icons.

- Main input: `glyphs.json`, extracted from `web/src/lib/brandIcons.generated.ts` in missuo/tokens commit `26c3e8442998d78e892ea4b2a9360cc2fdae9c58`. The upstream file was generated from `@lobehub/icons-static-svg`.
- Additional tool inputs: `vendor/cline.svg` and `vendor/githubcopilot.svg`, copied from `@lobehub/icons-static-svg` 1.94.0 on the npm registry.
- Upstream: https://github.com/lobehub/lobe-icons
- License: MIT, Copyright (c) 2023 LobeHub. The full notice is in `vendor/LICENSE` and bundled with the native app.
- Regenerate native SVG image sets with `python3 script/generate_brand_icons.py`. Do not hand-edit generated image sets.

Brand names and marks remain the property of their respective owners.
