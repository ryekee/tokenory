#!/usr/bin/env python3
"""Validate and publish the official price feed without releasing the app."""
import argparse
import base64
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
REPO = 'repos/ryekee/tokenory'
BRANCH = 'updates'
FILE_API = f'{REPO}/contents/pricing.json'


def gh(*args, payload=None):
    return json.loads(subprocess.check_output(
        ['gh', 'api', *args], input=json.dumps(payload) if payload else None, text=True,
    ))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--validator', type=Path, default=ROOT / 'cli/target/debug/tokenory',
                        help='Tokenory worker binary built from the current source')
    args = parser.parse_args()
    path = ROOT / 'cli/tokenory/data/remote-pricing.json'
    subprocess.run([str(args.validator.resolve()), 'validate-pricing', str(path)], check=True)

    body = path.read_bytes()
    revision = json.loads(body)['revision']
    files = gh(f'{REPO}/contents?ref={BRANCH}')
    previous = next((item for item in files if item['name'] == 'pricing.json'), None)
    payload = {'message': f'Publish pricing revision {revision}', 'branch': BRANCH,
               'content': base64.b64encode(body).decode('ascii')}
    if previous is not None:
        current = gh(f'{FILE_API}?ref={BRANCH}')
        old_body = base64.b64decode(current['content'])
        if body == old_body:
            print(f'Pricing revision {revision} already published.')
            return
        if revision <= json.loads(old_body)['revision']:
            raise SystemExit('Increase the pricing revision before publishing changed rates.')
        payload['sha'] = current['sha']

    result = gh('--method', 'PUT', FILE_API, '--input', '-', payload=payload)
    print(result['commit']['html_url'])


if __name__ == '__main__':
    main()
