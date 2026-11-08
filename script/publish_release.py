#!/usr/bin/env python3
"""Publish the signed archive and update its stable Sparkle feed on GitHub."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import xml.etree.ElementTree as ET

REPO = 'ryekee/tokenory'
FEED_BRANCH = 'updates'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def gh(*args, payload=None):
    result = subprocess.run(['gh', *args], input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True)
    return result.stdout


def api(path, payload=None, method=None):
    args = ['api', f'repos/{REPO}/{path}']
    if method:
        args += ['--method', method]
    if payload is not None:
        args += ['--input', '-']
    return json.loads(gh(*args, payload=payload))


def finalize_feed(feed, asset, version, build):
    """Bind the generated enclosure to the exact uploaded, signed archive."""
    root = ET.fromstring(feed)
    items = root.findall('channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one generated update')
    item = items[0]
    enclosure = item.find('enclosure')
    if (item.findtext(f'{{{SPARKLE}}}shortVersionString') != version
            or item.findtext(f'{{{SPARKLE}}}version') != build
            or enclosure is None
            or not enclosure.get(f'{{{SPARKLE}}}edSignature')):
        raise ValueError('Feed version or update signature does not match the release')
    expected_name = f'Tokenory-{version}-macOS-arm64.zip'
    asset_id = asset.get('id')
    expected_url = f'https://api.github.com/repos/{REPO}/releases/assets/{asset_id}'
    if (type(asset_id) is not int or asset_id <= 0 or asset.get('url') != expected_url
            or asset.get('name') != expected_name or asset.get('state') != 'uploaded'
            or asset.get('size') != int(enclosure.get('length', '0'))):
        raise ValueError('Uploaded asset does not match the signed enclosure')
    # The EdDSA signature covers archive bytes, so changing the download URL preserves it.
    enclosure.set('url', expected_url)
    ET.register_namespace('sparkle', SPARKLE)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=pathlib.Path)
    parser.add_argument('--target', required=True, help='Full commit SHA of the built source')
    args = parser.parse_args()
    folder = args.directory.resolve()
    with (folder / 'Tokenory.app/Contents/Info.plist').open('rb') as f:
        info = plistlib.load(f)
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    tag = f'v{version}'
    archive = folder / f'Tokenory-{version}-macOS-arm64.zip'
    feed = folder / 'appcast.xml'
    notes = folder / 'release-notes.md'
    if json.loads((folder / 'notarization.json').read_text())['status'] != 'Accepted':
        raise ValueError('Notarization has not succeeded')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(folder / 'Tokenory.app')], check=True)
    expected_digest = 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()
    # Draft uploads cannot become the latest feed before all artifacts are ready.
    releases = api('releases?per_page=100')
    release = next((r for r in releases if r['tag_name'] == tag), None)
    if release is None:
        gh('release', 'create', tag, str(archive), '--repo', REPO, '--target', args.target,
           '--draft', '--title', f'Tokenory {tag}', '--notes-file', str(notes))
        releases = api('releases?per_page=100')
        release = next(r for r in releases if r['tag_name'] == tag)
    if release['target_commitish'] != args.target:
        raise ValueError('Existing release targets different source')
    asset = next((a for a in release['assets'] if a['name'] == archive.name), None)
    if asset is None or asset.get('digest') != expected_digest:
        raise ValueError('Remote archive is missing or has a different SHA256; do not overwrite a published binary')
    feed.write_bytes(finalize_feed(feed.read_bytes(), asset, version, build))
    sums = folder / 'SHA256SUMS.txt'
    sums.write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in [archive, feed]))
    if release['draft']:
        gh('release', 'upload', tag, str(feed), str(sums), '--clobber', '--repo', REPO)
        gh('release', 'edit', tag, '--draft=false', '--latest', '--repo', REPO)
    else:
        # A retry may only publish the same feed already attached to the release.
        remote_feed = next((a for a in release['assets'] if a['name'] == feed.name), None)
        if remote_feed is None or remote_feed.get('digest') != 'sha256:' + hashlib.sha256(feed.read_bytes()).hexdigest():
            raise ValueError('Published feed differs; use a new release')
    latest = api('releases/latest')
    if latest['id'] != release['id']:
        raise ValueError('This release is not latest; refusing to move the update feed backwards')
    # A dedicated generated branch avoids committing a mutable feed into app source.
    refs = api(f'git/matching-refs/heads/{FEED_BRANCH}')
    ref = next((r for r in refs if r['ref'] == f'refs/heads/{FEED_BRANCH}'), None)
    parent = ref['object']['sha'] if ref else None
    tree_args = {'tree': [{'path': 'appcast.xml', 'mode': '100644', 'type': 'blob', 'content': feed.read_text()}]}
    if parent:
        tree_args['base_tree'] = api(f'git/commits/{parent}')['tree']['sha']
    tree = api('git/trees', tree_args)
    commit = api('git/commits', {'message': f'Publish update feed for {tag}', 'tree': tree['sha'],
                               'parents': [parent] if parent else []})
    if ref:
        api(f'git/refs/heads/{FEED_BRANCH}', {'sha': commit['sha'], 'force': False}, 'PATCH')
    else:
        api('git/refs', {'ref': f'refs/heads/{FEED_BRANCH}', 'sha': commit['sha']})
    print(f'https://github.com/{REPO}/releases/tag/{tag}')
    print(f'https://raw.githubusercontent.com/{REPO}/{FEED_BRANCH}/appcast.xml')


if __name__ == '__main__':
    main()
