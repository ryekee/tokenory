import importlib.util
import pathlib
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('publish_release', pathlib.Path(__file__).parents[1] / 'publish_release.py')
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.feed = b'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>6</sparkle:version><sparkle:shortVersionString>0.1.4</sparkle:shortVersionString>
        <description>Notes &amp; details</description>
        <enclosure url="https://github.com/ryekee/tokenory/releases/download/v0.1.4/Tokenory-0.1.4-macOS-arm64.zip" length="123" sparkle:edSignature="signature"/>
        </item></channel></rss>'''
        self.asset = {'id': 42, 'name': 'Tokenory-0.1.4-macOS-arm64.zip', 'state': 'uploaded', 'size': 123,
                      'url': 'https://api.github.com/repos/ryekee/tokenory/releases/assets/42'}

    def testUsesExactPublicAPIAssetAndPreservesSignatureAndNotes(self):
        result = ET.fromstring(publish.finalize_feed(self.feed, self.asset, '0.1.4', '6'))
        item = result.find('channel/item')
        self.assertEqual(item.find('enclosure').get('url'), self.asset['url'])
        self.assertEqual(item.find('enclosure').get(f'{{{publish.SPARKLE}}}edSignature'), 'signature')
        self.assertEqual(item.findtext('description'), 'Notes & details')

    def testRejectsMismatchedAssetsAndUnsignedOrWrongVersions(self):
        for changes in [{'size': 124}, {'name': 'other.zip'}, {'state': 'new'}, {'id': '42'}, {'url': 'https://example.com/archive'}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                publish.finalize_feed(self.feed, self.asset | changes, '0.1.4', '6')
        for feed in [self.feed.replace(b'0.1.4</', b'0.1.5</'), self.feed.replace(b'>6<', b'>7<'),
                     self.feed.replace(b' sparkle:edSignature="signature"', b'')]:
            with self.assertRaises(ValueError):
                publish.finalize_feed(feed, self.asset, '0.1.4', '6')

    def testFinalizingSameFeedIsRepeatableForPublishRetry(self):
        once = publish.finalize_feed(self.feed, self.asset, '0.1.4', '6')
        self.assertEqual(once, publish.finalize_feed(once, self.asset, '0.1.4', '6'))


if __name__ == '__main__':
    unittest.main()
