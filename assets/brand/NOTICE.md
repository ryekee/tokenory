# Native brand glyphs

The native app follows tokens.ci's `web/src/components/profile/ModelIcon.tsx`: monochrome glyphs inherit the surrounding foreground color. The app does not use the original colored logo artwork.

- Main input: `web/src/lib/brandIcons.generated.ts`, generated upstream from `@lobehub/icons-static-svg`.
- Additional tool inputs: `vendor/cline.svg` and `vendor/githubcopilot.svg`, copied from `@lobehub/icons-static-svg` 1.94.0 on the npm registry.
- Upstream: https://github.com/lobehub/lobe-icons
- License: MIT, Copyright (c) 2023 LobeHub. The full notice is in `vendor/LICENSE` and bundled with the native app.
- Regenerate native SVG image sets with `python3 script/generate_brand_icons.py`. Do not hand-edit generated image sets.

Brand names and marks remain the property of their respective owners.
