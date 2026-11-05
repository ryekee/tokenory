#!/usr/bin/env python3
"""Generate native template assets from tokens.ci's monochrome brand glyphs."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / "web/src/lib/brandIcons.generated.ts").read_text()
payload = source.split("=", 1)[1].strip().removesuffix(";")
glyphs = json.loads(re.sub(r",\s*}", "}", payload))
icons = {
    slug: f'<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="black" color="black">{glyph}</svg>\n'
    for slug, glyph in glyphs.items()
}
for path in (ROOT / "assets/brand/vendor").glob("*.svg"):
    svg = path.read_text().replace("currentColor", "black")
    root, body = svg.split(">", 1)
    root = re.sub(r'\s(?:width|height)="[^"]*"', "", root)
    icons[path.stem] = root + ' width="14" height="14">' + body
for slug, svg in icons.items():
    folder = ROOT / f"macos/Tokenory/Resources/Assets.xcassets/Brand-{slug}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "icon.svg").write_text(svg.replace("currentColor", "black"))
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    }, indent=2) + "\n")
print(f"Generated {len(icons)} template brand assets")
(ROOT / "macos/Tokenory/Resources/LobeHub-Icons-LICENSE.txt").write_text(
    (ROOT / "assets/brand/vendor/LICENSE").read_text()
)
