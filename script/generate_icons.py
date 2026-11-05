#!/usr/bin/env python3
"""Generate Xcode icon sizes from the approved brand originals using sips."""
import json
import pathlib
import subprocess
root = pathlib.Path(__file__).resolve().parent.parent
assets = root / 'macos/Tokenory/Resources/Assets.xcassets'
assets.mkdir(parents=True, exist_ok=True)
def manifest(path, data):
    (path / 'Contents.json').write_text(json.dumps({**data, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
manifest(assets, {})
for name, original, sizes in [('AppIcon.appiconset', 'app-icon.png', [(s, scale) for s in [16,32,128,256,512] for scale in [1,2]]), ('MenuBarIcon.imageset', None, [(18,1),(18,2)])]:
    dest = assets / name
    dest.mkdir(exist_ok=True)
    images=[]
    for size,scale in sizes:
        filename=f'icon-{size}@{scale}x.png'
        if original: subprocess.run(['sips','-z',str(size*scale),str(size*scale),str(root/'assets/brand'/original),'--out',str(dest/filename)],check=True,stdout=subprocess.DEVNULL)
        entry={'filename':filename,'idiom':'mac','scale':f'{scale}x'}
        if name.endswith('appiconset'): entry['size']=f'{size}x{size}'
        images.append(entry)
    manifest(dest, {'images':images, **({'properties': {'template-rendering-intent':'template'}} if name.endswith('imageset') else {})})
accent=assets/'AccentColor.colorset'
accent.mkdir(exist_ok=True)
manifest(accent, {'colors':[{'idiom':'universal','color':{'color-space':'srgb','components':{'red':'0.18','green':'0.34','blue':'0.62','alpha':'1.0'}}},{'idiom':'universal','appearances':[{'appearance':'luminosity','value':'dark'}],'color':{'color-space':'srgb','components':{'red':'0.48','green':'0.68','blue':'0.98','alpha':'1.0'}}}]})

subprocess.run(['swift', '-module-cache-path', str(root/'.build/swift-module-cache'), str(root/'script/render_menu_icon.swift'), str(assets/'MenuBarIcon.imageset')], check=True)
