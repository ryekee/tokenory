#!/usr/bin/env python3
"""Generate the macOS app and menu bar assets from their brand originals."""
import json
import pathlib
import shutil
import subprocess
root = pathlib.Path(__file__).resolve().parent.parent
assets = root / 'macos/Tokenory/Resources/Assets.xcassets'
assets.mkdir(parents=True, exist_ok=True)
def manifest(path, data):
    (path / 'Contents.json').write_text(json.dumps({**data, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
manifest(assets, {})
brand = root / 'assets/brand'
flat = brand / 'tokenory-counter-flat'
shutil.copyfile(flat / 'tokenory-counter-flat.png', brand / 'app-icon.png')
# Icon Composer supplies the orange housing; both icon formats use the same window and drums.
native_layers = assets.parent / 'AppIcon.icon' / 'Assets'
for index, layer in enumerate(('recessed-square-aperture', 'three-parallel-drums',
                               'changing-register', 'thumbwheel-and-units-index'), start=1):
    shutil.copyfile(flat / 'layers' / f'{index + 1:02}-{layer}.svg',
                    native_layers / f'{index:02}-{layer}.svg')
app_icon = assets / 'AppIcon.appiconset'
app_icon.mkdir(exist_ok=True)
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = str(size * scale)
        filename = f'icon-{size}@{scale}x.png'
        subprocess.run(['sips', '-z', pixels, pixels, str(brand / 'app-icon.png'),
                        '--out', str(app_icon / filename)], check=True, stdout=subprocess.DEVNULL)
        images.append({'filename': filename, 'idiom': 'mac', 'scale': f'{scale}x', 'size': f'{size}x{size}'})
manifest(app_icon, {'images': images})

menu_icon = assets / 'MenuBarIcon.imageset'
menu_icon.mkdir(exist_ok=True)
shutil.copyfile(brand / 'menu-icon.svg', menu_icon / 'icon.svg')
manifest(menu_icon, {
    'images': [{'filename': 'icon.svg', 'idiom': 'mac'}],
    'properties': {'preserves-vector-representation': True, 'template-rendering-intent': 'original'},
})
accent=assets/'AccentColor.colorset'
accent.mkdir(exist_ok=True)
manifest(accent, {'colors':[{'idiom':'universal','color':{'color-space':'srgb','components':{'red':'0.18','green':'0.34','blue':'0.62','alpha':'1.0'}}},{'idiom':'universal','appearances':[{'appearance':'luminosity','value':'dark'}],'color':{'color-space':'srgb','components':{'red':'0.48','green':'0.68','blue':'0.98','alpha':'1.0'}}}]})
