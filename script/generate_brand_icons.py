#!/usr/bin/env python3
"""Generate native assets from the checked-in brand sources.
[INPUT]: Web 字形和 vendor 品牌素材。
[OUTPUT]: 原生 Assets.xcassets 图标和许可证副本。
[POS]: 品牌源文件到原生资源的唯一生成入口。
[PROTOCOL]: Update this header on change, then check AGENTS.md
"""
import json
from pathlib import Path
import re
import subprocess

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
for path in (ROOT / "assets/brand/providers").glob("*.svg"):
    svg = path.read_text().replace("currentColor", "black")
    svg = svg[svg.index("<svg"):]
    root, body = svg.split(">", 1)
    root = re.sub(r'\s(?:width|height)="[^"]*"', "", root)
    icons["provider-" + path.stem] = root + ' width="14" height="14">' + body
# MiMo 模型和 micode 工具共用新的 M 标志。
if "provider-xiaomi" in icons:
    icons["xiaomimimo"] = icons["provider-xiaomi"]
provider_brands = json.loads((ROOT / "macos/Tokenory/Resources/ProviderCatalog.json").read_text())
original_provider_icons = {v["icon"] for v in provider_brands.values() if v["original"]}
for slug, svg in icons.items():
    folder = ROOT / f"macos/Tokenory/Resources/Assets.xcassets/Brand-{slug}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "icon.svg").write_text(svg.replace("currentColor", "black"))
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "original" if slug in original_provider_icons else "template"},
    }, indent=2) + "\n")
print(f"Generated {len(icons)} template brand assets")
(ROOT / "macos/Tokenory/Resources/LobeHub-Icons-LICENSE.txt").write_text(
    (ROOT / "assets/brand/vendor/LICENSE").read_text()
)

for path in sorted((ROOT / "assets/brand/vendor").iterdir()):
    if path.suffix not in {".png", ".webp"}:
        continue
    folder = ROOT / f"macos/Tokenory/Resources/Assets.xcassets/Brand-{path.stem}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["sips", "-s", "format", "png", "-Z", "28", str(path), "--out", str(folder / "icon@2x.png")], check=True, capture_output=True)
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon@2x.png", "idiom": "mac", "scale": "2x"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "original"},
    }, indent=2) + "\n")
