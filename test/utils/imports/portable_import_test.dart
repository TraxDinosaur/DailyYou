import 'dart:convert';
import 'dart:io';
import 'package:daily_you/utils/imports/import_portable.dart';
import 'package:daily_you/utils/imports/import_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';

void main() {
  late Directory directory;
  setUp(() async =>
      directory = await Directory.systemTemp.createTemp('portable_'));
  tearDown(() async => directory.delete(recursive: true));
  test('Day One preserves dates, tags, text, and local photos', () async {
    await Directory(join(directory.path, 'photos')).create();
    await File(join(directory.path, 'photos', 'cover.jpg'))
        .writeAsString('photo');
    await File(join(directory.path, 'Journal.json')).writeAsString(jsonEncode({
      'entries': [
        {
          'text': '# A day\n\nMy memory',
          'creationDate': '2026-06-15T10:30:00Z',
          'tags': ['Travel'],
          'photos': [
            {'md5': 'cover', 'type': 'jpg'}
          ]
        }
      ],
    }));
    final bundle = await parsePortable(
        ImportSource(directory.path, 'Journal.json'), PortableFormat.dayOne);
    expect(bundle.entries.single.entry.text, '# A day\n\nMy memory');
    expect(bundle.entries.single.entry.timeCreate.toUtc(),
        DateTime.utc(2026, 6, 15, 10, 30));
    expect(bundle.entries.single.entry.timeCreate.isUtc, isFalse);
    expect(bundle.entries.single.entry.timeModified.isUtc, isFalse);
    expect(bundle.entries.single.tags.single.name, 'Travel');
    expect(bundle.entries.single.attachments, hasLength(1));
  });
  test('StoryPad resolves tags and rich pages from its data root', () async {
    await File(join(directory.path, 'story.json')).writeAsString(jsonEncode({
      'version': 2,
      'data': {
        'tags': [
          {'id': 42, 'title': 'Travel'}
        ],
        'stories': [
          {
            'year': 2026,
            'month': 6,
            'day': 15,
            'tags': [42],
            'latest_content': {
              'title': 'Summer Trip',
              'rich_pages': [
                {'markdown': 'Flight was on time.'}
              ]
            }
          }
        ],
      },
    }));
    final bundle = await parsePortable(
        ImportSource(directory.path, 'story.json'), PortableFormat.storyPad);
    expect(bundle.entries.single.entry.text,
        '# Summer Trip\n\nFlight was on time.');
    expect(bundle.entries.single.tags.single.name, 'Travel');
    expect(bundle.entries.single.entry.timeCreate.day, 15);
  });
  test('unrecognised documents fail instead of silently importing nothing',
      () async {
    await File(join(directory.path, 'bad.json')).writeAsString('{}');
    await expectLater(
        parsePortable(
            ImportSource(directory.path, 'bad.json'), PortableFormat.dayOne),
        throwsFormatException);
  });
}
