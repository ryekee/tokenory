import importlib.util
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('publish_release', SCRIPTS / 'publish_release.py')
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)

NOTES = {
    'en': {'features': ['Compare usage & costs.'], 'fixes': ['Fix a crash.']},
    'zh-Hans': {'features': ['比较用量和费用。'], 'fixes': ['修复崩溃。']},
}
MARKDOWN = (
    '## English\n\n### New Features\n\n- Compare usage & costs.\n\n### Fixes\n\n- Fix a crash.\n\n'
    '## 简体中文\n\n### 新功能\n\n- 比较用量和费用。\n\n### 修复\n\n- 修复崩溃。\n'
)
XML_LANG = '{http://www.w3.org/XML/1998/namespace}lang'

class FeedTests(unittest.TestCase):
    def setUp(self):
        self.feed = b'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>6</sparkle:version><sparkle:shortVersionString>0.1.4</sparkle:shortVersionString>
        <description>Notes &amp; details</description>
        <enclosure url="https://github.com/ryekee/tokenory/releases/download/v0.1.4/Tokenory-0.1.4-macOS-arm64.zip" length="123" sparkle:edSignature="signature"/>
        </item></channel></rss>'''
        self.asset = {'id': 42, 'name': 'Tokenory-0.1.4-macOS-arm64.zip', 'state': 'uploaded', 'size': 123,
                      'url': 'https://api.github.com/repos/ryekee/tokenory/releases/assets/42',
                      'browser_download_url': 'https://github.com/ryekee/tokenory/releases/download/v0.1.4/Tokenory-0.1.4-macOS-arm64.zip'}

    def testUsesPublicDownloadWithoutAPIAndPreservesSignatureAndNotes(self):
        result = ET.fromstring(publish.finalize_feed(self.feed, self.asset, '0.1.4', '6'))
        item = result.find('channel/item')
        self.assertEqual(item.find('enclosure').get('url'), self.asset['browser_download_url'])
        self.assertEqual(item.find('enclosure').get(f'{{{publish.SPARKLE}}}edSignature'), 'signature')
        self.assertEqual(item.findtext('description'), 'Notes & details')

    def testRejectsMismatchedAssetsAndUnsignedOrWrongVersions(self):
        for changes in [{'browser_download_url': 'https://example.com/archive'}, {'size': 124}, {'name': 'other.zip'}, {'state': 'new'}, {'id': '42'}, {'url': 'https://example.com/archive'}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                publish.finalize_feed(self.feed, self.asset | changes, '0.1.4', '6')
        for feed in [self.feed.replace(b'0.1.4</', b'0.1.5</'), self.feed.replace(b'>6<', b'>7<'),
                     self.feed.replace(b' sparkle:edSignature="signature"', b'')]:
            with self.assertRaises(ValueError):
                publish.finalize_feed(feed, self.asset, '0.1.4', '6')

    def testFinalizingSameFeedIsRepeatableForPublishRetry(self):
        once = publish.finalize_feed(self.feed, self.asset, '0.1.4', '6')
        self.assertEqual(once, publish.finalize_feed(once, self.asset, '0.1.4', '6'))

    def testDraftAssetUsesTagUrlInFeed(self):
        draft_asset = self.asset | {
            'browser_download_url': self.asset['browser_download_url'].replace(
                '/v0.1.4/', '/untagged-72ae1138e3ebb2a7665a/'
            ),
        }
        result = ET.fromstring(publish.finalize_feed(self.feed, draft_asset, '0.1.4', '6', draft=True))
        self.assertEqual(result.find('channel/item/enclosure').get('url'), self.asset['browser_download_url'])
        with self.assertRaises(ValueError):
            publish.finalize_feed(self.feed, draft_asset, '0.1.4', '6')

    def testPublishRejectsFeedThatDoesNotMatchBilingualNotes(self):
        with tempfile.TemporaryDirectory() as work:
            folder = self.makeReleaseFolder(work)
            with patch.object(sys, 'argv', ['publish_release.py', str(folder), '--target', 'commit']):
                with self.assertRaisesRegex(ValueError, 'release notes'):
                    publish.main()

    def testDraftRetryPublishesBilingualBodyAndAllThreeFeeds(self):
        with tempfile.TemporaryDirectory() as work:
            folder = self.makeReleaseFolder(work)
            result = subprocess.run(
                [sys.executable, SCRIPTS / 'release_notes.py', folder / 'release-notes.json',
                 '--appcast', folder / 'appcast.xml'],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            canonical = ET.parse(folder / 'appcast.xml')
            descriptions = canonical.findall('channel/item/description')
            self.assertEqual([(node.get(XML_LANG), node.text) for node in descriptions], [
                ('en', '## New Features\n\n- Compare usage & costs.\n\n## Fixes\n\n- Fix a crash.\n'),
                ('zh-Hans', '## 新功能\n\n- 比较用量和费用。\n\n## 修复\n\n- 修复崩溃。\n'),
            ])
            self.assertTrue(all(node.get(f'{{{publish.SPARKLE}}}format') == 'markdown' for node in descriptions))
            asset = self.asset | {'digest': 'sha256:6675ba780648c8506cb002c86621f9d33f8093e12541c690a8d3261c47c92bcc'}
            draft = {'id': 23, 'tag_name': 'v0.1.4', 'target_commitish': 'commit', 'draft': True,
                     'assets': [asset], 'body': 'Old single-language notes'}
            with (
                patch.object(sys, 'argv', ['publish_release.py', str(folder), '--target', 'commit']),
                patch.object(publish.subprocess, 'run'),
                patch.object(publish, 'gh') as github,
                patch.object(publish, 'api', side_effect=[
                    [draft], draft | {'draft': False, 'body': MARKDOWN}, [],
                    {'sha': 'tree'}, {'sha': 'update-commit'}, {},
                ]) as api,
            ):
                publish.main()
            body_file = folder.resolve() / 'release-notes.md'
            self.assertEqual(body_file.read_text(encoding='utf-8'), MARKDOWN)
            github.assert_any_call('release', 'edit', 'v0.1.4', '--notes-file', str(body_file), '--draft=false',
                                   '--latest', '--repo', publish.REPO)
            tree = next(call.args[1]['tree'] for call in api.call_args_list if call.args[0] == 'git/trees')
            self.assertEqual(
                {entry['path']: [node.get(XML_LANG) for node in ET.fromstring(entry['content']).findall(
                    'channel/item/description'
                )] for entry in tree},
                {'appcast.xml': ['en', 'zh-Hans'], 'appcast.en.xml': ['en'], 'appcast.zh-Hans.xml': ['zh-Hans']},
            )
            for entry in tree:
                enclosure = ET.fromstring(entry['content']).find('channel/item/enclosure')
                self.assertEqual(enclosure.get('url'), asset['browser_download_url'])
                self.assertEqual(enclosure.get(f'{{{publish.SPARKLE}}}edSignature'), 'signature')

    def makeReleaseFolder(self, directory):
        folder = pathlib.Path(directory)
        info = folder / 'Tokenory.app/Contents/Info.plist'
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.4', 'CFBundleVersion': '6'}))
        (folder / 'Tokenory-0.1.4-macOS-arm64.zip').write_bytes(b'a' * 123)
        (folder / 'notarization.json').write_text('{"status":"Accepted"}', encoding='utf-8')
        (folder / 'release-notes.json').write_text(json.dumps(NOTES), encoding='utf-8')
        (folder / 'appcast.xml').write_bytes(self.feed)
        return folder


class ReleaseNotesTests(unittest.TestCase):
    def testPreviewUsesBothLanguagesAndOmitsEmptySections(self):
        notes = {lang: sections | {'fixes': []} for lang, sections in NOTES.items()}
        result = self.preview(notes)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '## English\n\n### New Features\n\n- Compare usage & costs.\n\n'
                         '## 简体中文\n\n### 新功能\n\n- 比较用量和费用。\n')

    def testValidationRejectsMissingBlankAndUnmatchedNotes(self):
        for notes in [
            {'en': NOTES['en']},
            {'en': NOTES['en'], 'zh-Hans': {'features': NOTES['zh-Hans']['features']}},
            {lang: {'features': [], 'fixes': []} for lang in NOTES},
            NOTES | {'zh-Hans': {'features': [], 'fixes': ['修复崩溃。']}},
            NOTES | {'zh-Hans': {'features': ['比较用量和费用。', '另一个功能。'], 'fixes': ['修复崩溃。']}},
            NOTES | {'zh-Hans': {'features': [' '], 'fixes': ['修复崩溃。']}},
            NOTES | {'zh-Hans': {'features': ['第一行。\n第二行。'], 'fixes': ['修复崩溃。']}},
        ]:
            with self.subTest(notes=notes):
                result = self.preview(notes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('error: release notes', result.stderr)

    def preview(self, notes):
        with tempfile.TemporaryDirectory() as work:
            source = pathlib.Path(work) / 'release-notes.json'
            source.write_text(json.dumps(notes), encoding='utf-8')
            return subprocess.run([sys.executable, SCRIPTS / 'release_notes.py', source],
                                  capture_output=True, text=True)


if __name__ == '__main__':
    unittest.main()
