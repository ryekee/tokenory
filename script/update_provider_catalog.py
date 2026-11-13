#!/usr/bin/env python3
"""[INPUT]: models.dev 的供应商、模型费率和 SVG；LobeHub 的 MiMo 标志。
[OUTPUT]: 离线价格目录、供应商品牌目录和 SVG 源文件。
[POS]: 全量供应商目录的生成入口；运行后执行 generate_brand_icons.py。
[PROTOCOL]: Update this header on change, then check AGENTS.md
"""
import concurrent.futures
import json
import math
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent

def fetch(url):
    return subprocess.check_output(['curl', '-fsSL', '--retry', '2', '--max-time', '40', url])

def main():
    providers = json.loads(fetch('https://models.dev/api.json'))
    brands, entries = {}, []
    directory = ROOT / 'assets/brand/providers'
    directory.mkdir(exist_ok=True)
    def logo(item):
        key, provider = item
        url = 'https://models.dev/logos/' + key + '.svg'
        if key.startswith('xiaomi'):
            url = 'https://registry.npmmirror.com/@lobehub/icons-static-svg/latest/files/icons/xiaomimimo.svg'
        data = fetch(url)
        assert ET.fromstring(data).tag.endswith('svg'), key
        if key.startswith('xiaomi'):
            # 从官方字标的 MiMo 部分保留首个 M，避免小尺寸文字不可读。
            paths = list(ET.fromstring(data).findall('{http://www.w3.org/2000/svg}path'))[:2]
            data = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 13.3 6.8 6.8" fill="currentColor">' + ''.join('<path d="' + p.attrib['d'] + '"/>' for p in paths) + '</svg>').encode()

        colors = re.findall(r'(?:fill|stroke)[=:]\s*[\"\']?([^\"\';\s>]+)', data.decode())
        original = any(c.lower() not in {'none', 'currentcolor', 'black', '#000', '#000000', 'transparent'} for c in colors)
        (directory / (key + '.svg')).write_bytes(data)
        return key, {'name': provider['name'].replace('Xiaomi', 'Xiaomi MiMo') if key.startswith('xiaomi') else provider['name'], 'icon': 'provider-' + key, 'source': url, 'original': original, 'subscription': 'plan' in key or key in {'github-copilot', 'gitlab', 'cline-pass'}}
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        for key, brand in pool.map(logo, providers.items()):
            brands[key] = brand
    keys = {'input': 'input_cost_per_token', 'output': 'output_cost_per_token', 'cache_read': 'cache_read_input_token_cost', 'cache_write': 'cache_creation_input_token_cost'}
    for provider, data in sorted(providers.items()):
        for model_id, model in sorted(data.get('models', {}).items()):
            if 'text' not in model.get('modalities', {}).get('output', []):
                continue
            cost = model.get('cost', {})
            rates = {}
            for source, target in keys.items():
                value = cost.get(source)
                if value is not None and (not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0):
                    raise ValueError(f'Invalid cost: {provider}/{model_id}')
                rates[target] = value / 1e6 if value is not None else None
            entries.append({'provider': provider, 'model': model.get('id', model_id), 'rates': rates, 'schedule': None, 'allowFast': False, 'explicitFree': False, 'matchedKey': f'{provider}/{model_id}', 'source': 'models.dev', 'assumption': 'Public catalog reference; subscription plans use API-equivalent estimates; not an actual bill'})
    resources = ROOT / 'macos/Tokenory/Resources'
    (resources / 'ProviderCatalog.json').write_text(json.dumps(brands, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
    data_dir = ROOT / 'cli/tokenory/data'
    data_dir.mkdir(exist_ok=True)
    (data_dir / 'price-catalog.json').write_text(json.dumps(entries, ensure_ascii=False, separators=(',', ':')) + '\n')
    (directory / 'AGENTS.md').write_text('# assets/brand/providers/\n> L2 | Parent: ../../../AGENTS.md\n\n由 script/update_provider_catalog.py 生成。来源见 ProviderCatalog.json。\n\n' + ''.join(f'{key}.svg: {v["name"]} 的供应商标志。\n' for key, v in sorted(brands.items())) + '\nLICENSE: models.dev 素材许可证；MiMo 字标遵循 vendor/LICENSE。\n\n[PROTOCOL]: Update this header on change, then check AGENTS.md\n')
    print(f'Generated {len(brands)} providers, {len(entries)} text model prices')

if __name__ == '__main__':
    main()
