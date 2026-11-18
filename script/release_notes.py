"""Preview bilingual release notes or embed them in a generated Sparkle appcast."""
import argparse
import json
import pathlib
import re
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
XML_LANG = '{http://www.w3.org/XML/1998/namespace}lang'
FORMAT = f'{{{SPARKLE}}}format'
LINK = f'{{{SPARKLE}}}releaseNotesLink'
HEADINGS = {
    'en': ('English', {'features': 'New Features', 'fixes': 'Fixes'}),
    'zh-Hans': ('简体中文', {'features': '新功能', 'fixes': '修复'}),
}
ET.register_namespace('sparkle', SPARKLE)


def load_notes(path):
    try:
        notes = json.loads(path.read_text(encoding='utf-8'))
    except (ValueError, OSError) as error:
        raise ValueError(f'release notes could not be read from {path}: {error}') from error
    if not isinstance(notes, dict) or notes.keys() != HEADINGS.keys():
        raise ValueError('release notes must contain en and zh-Hans')
    for language, (_, headings) in HEADINGS.items():
        sections = notes[language]
        if not isinstance(sections, dict) or sections.keys() != headings.keys():
            raise ValueError(f'release notes for {language} must contain features and fixes arrays')
        for category, entries in sections.items():
            if not isinstance(entries, list):
                raise ValueError(f'release notes for {language}/{category} must be an array')
            for index, entry in enumerate(entries):
                if (not isinstance(entry, str) or not entry.strip() or len(entry.strip().splitlines()) != 1
                        or re.search(r'[\x00-\x08\x0b\x0c\x0e-\x1f\ud800-\udfff\ufffe\uffff]', entry)):
                    raise ValueError(f'release notes for {language}/{category} need text on one line per bullet')
                entries[index] = entry.strip()
    for category, entries in notes['en'].items():
        if len(entries) != len(notes['zh-Hans'][category]):
            raise ValueError(f'release notes for {category} need the same number of English and Chinese bullets')
    if not any(notes['en'].values()):
        raise ValueError('release notes must contain at least one feature or fix in both languages')
    return notes


def render_sections(notes, language, heading):
    sections = []
    for category, title in HEADINGS[language][1].items():
        if notes[language][category]:
            bullets = '\n'.join(f'- {entry}' for entry in notes[language][category])
            sections.append(f'{heading} {title}\n\n{bullets}')
    return '\n\n'.join(sections) + '\n'


def github_markdown(notes):
    return '\n'.join(f'## {label}\n\n{render_sections(notes, language, "###")}'
                     for language, (label, _) in HEADINGS.items())


def appcast_item(root):
    items = root.findall('channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one generated update')
    return items[0]


def descriptions_for(notes):
    # Sparkle uses the first description as a fallback if its language matching fails.
    for language in HEADINGS:
        description = ET.Element('description', {XML_LANG: language, FORMAT: 'markdown'})
        description.text = render_sections(notes, language, '##')
        yield description


def verify_notes(item, notes):
    descriptions = item.findall('description')
    expected = list(descriptions_for(notes))
    if (item.find(LINK) is not None or len(descriptions) != len(expected)
            or any(actual.attrib != wanted.attrib or actual.text != wanted.text or len(actual)
                   for actual, wanted in zip(descriptions, expected))):
        raise ValueError('appcast release notes do not match release-notes.json')


def localized_feeds(public_feed):
    # The explicit app language feeds share the verified enclosure with the System feed.
    for language in HEADINGS:
        root = ET.fromstring(public_feed)
        item = appcast_item(root)
        for description in item.findall('description'):
            if description.get(XML_LANG) != language:
                item.remove(description)
        yield f'appcast.{language}.xml', ET.tostring(root, encoding='utf-8', xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('notes', type=pathlib.Path)
    parser.add_argument('--appcast', type=pathlib.Path, help='Embed the notes in this generated appcast')
    args = parser.parse_args()
    try:
        notes = load_notes(args.notes)
        if args.appcast is None:
            print(github_markdown(notes), end='')
        else:
            root = ET.parse(args.appcast).getroot()
            item = appcast_item(root)
            for node in item.findall('description') + item.findall(LINK):
                item.remove(node)
            item.extend(descriptions_for(notes))
            ET.ElementTree(root).write(args.appcast, encoding='utf-8', xml_declaration=True)
    except (ET.ParseError, OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
