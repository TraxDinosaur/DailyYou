// Behavior based on DenserMeerkat/June (GPL-3.0)
import 'dart:convert';
import 'dart:io';
import 'package:daily_you/models/attachment.dart';
import 'package:daily_you/models/entry.dart';
import 'package:daily_you/models/location.dart';
import 'package:daily_you/models/tag.dart';
import 'package:daily_you/utils/imports/import_bundle.dart';
import 'package:daily_you/utils/imports/import_source.dart';
import 'package:daily_you/utils/zip_utils.dart';
import 'package:daily_you/utils/tag_name_sanitizer.dart';
import 'package:path/path.dart' as p;

enum PortableFormat { dayOne, storyPad }

Future<ImportBundle> parsePortable(
    ImportSource source, PortableFormat format) async {
  var directory = Directory(source.directoryPath);
  var document = source.file;
  final input = await document.open();
  final header = await input.read(4);
  await input.close();
  if (header.length == 4 && header[0] == 0x50 && header[1] == 0x4b) {
    directory = Directory(p.join(source.directoryPath, 'portable_contents'));
    await ZipUtils.extract(document.path, directory.path);
    final candidates = await directory
        .list(recursive: true)
        .where((file) =>
            file is File && p.extension(file.path).toLowerCase() == '.json')
        .cast<File>()
        .toList();
    if (format == PortableFormat.dayOne) {
      candidates.removeWhere(
          (file) => p.basename(file.path).toLowerCase() != 'journal.json');
    }
    if (candidates.isEmpty) {
      throw const FormatException('No journal JSON found');
    }
    // StoryPad archives can also carry unrelated settings JSON.
    document = candidates.first;
    if (format == PortableFormat.storyPad) {
      for (final candidate in candidates) {
        final data = jsonDecode(await candidate.readAsString());
        if (data is Map && (data['data'] ?? data['tables'] ?? data) is Map) {
          final tables = data['data'] ?? data['tables'] ?? data;
          if (tables['stories'] is List) {
            document = candidate;
            break;
          }
        }
      }
    }
  }
  final root = jsonDecode(await document.readAsString());
  if (root is! Map<String, dynamic>) {
    throw const FormatException('Invalid journal document');
  }
  final tables = format == PortableFormat.dayOne
      ? root
      : (root['data'] ?? root['tables'] ?? root);
  if (tables is! Map) throw const FormatException('Invalid journal tables');
  final rows = tables[format == PortableFormat.dayOne ? 'entries' : 'stories'];
  if (rows is! List || rows.isEmpty) {
    throw const FormatException('No entries found');
  }
  final files = <String, File>{};
  await for (final entity
      in directory.list(recursive: true, followLinks: false)) {
    if (entity is! File || p.extension(entity.path).toLowerCase() == '.json') {
      continue;
    }
    files[p.relative(entity.path, from: directory.path).replaceAll('\\', '/')] =
        entity;
    files.putIfAbsent(p.basename(entity.path), () => entity);
    files.putIfAbsent(p.basenameWithoutExtension(entity.path), () => entity);
  }
  final tagsById = <String, String>{
    if (tables['tags'] is List)
      for (final tag in tables['tags'] as List)
        if (tag is Map && tag['id'] != null && tag['title'] is String)
          '${tag['id']}': tag['title'] as String,
  };
  return ImportBundle(entries: [
    for (final row in rows)
      if (row is Map<String, dynamic>) _entry(row, format, files, tagsById),
  ]);
}

ImportedEntry _entry(Map<String, dynamic> row, PortableFormat format,
    Map<String, File> files, Map<String, String> tagsById) {
  final dayOne = format == PortableFormat.dayOne;
  final rawDate = !dayOne &&
          row['year'] is int &&
          row['month'] is int &&
          row['day'] is int
      ? DateTime(row['year'], row['month'], row['day'], row['hour'] ?? 12,
          row['minute'] ?? 0, row['second'] ?? 0)
      : DateTime.tryParse(
          '${row[dayOne ? 'creationDate' : 'created_at'] ?? row['createdAt']}');
  if (rawDate == null) {
    throw const FormatException('Entry has no valid creation date');
  }
  final date = rawDate.toLocal();
  final updated = DateTime.tryParse(
          '${row[dayOne ? 'modifiedDate' : 'updated_at'] ?? row['updatedAt']}') ??
      date;
  final attachments = <ImportedAttachment>[];
  void attach(dynamic reference, AttachmentType type) {
    if (reference is! String) return;
    final file = files[reference] ?? files[p.posix.basename(reference)];
    if (file == null ||
        attachments.any((a) =>
            a.media is FileMedia &&
            (a.media as FileMedia).file.path == file.path)) {
      return;
    }
    attachments.add(ImportedAttachment(
        type: type,
        rank: attachments.length,
        timeCreate: date,
        media: FileMedia(file)));
  }

  final tags = <String>{};
  for (final tag in row['tags'] as List? ?? []) {
    final name = dayOne ? '$tag' : tagsById['$tag'];
    if (name != null) {
      final sanitized = sanitizeTagName(name);
      if (sanitized.isNotEmpty) tags.add(sanitized);
    }
  }
  if (row['starred'] == true || row['pinned'] == true) tags.add('Favorite');
  String text;
  if (dayOne) {
    text = row['text'] as String? ?? '';
    for (final photo in row['photos'] as List? ?? []) {
      if (photo is! Map) continue;
      attach(photo['filename'] ?? photo['md5'] ?? photo['identifier'],
          AttachmentType.image);
    }
    for (final audio in row['audios'] as List? ?? []) {
      if (audio is! Map) continue;
      attach(audio['filename'] ?? audio['md5'] ?? audio['identifier'],
          AttachmentType.audio);
    }
  } else {
    final content = row['latest_content'] ?? row['latestContent'];
    if (content is! Map) throw const FormatException('Story has no content');
    final pages = <String>[];
    for (final page in content['rich_pages'] ??
        content['richPages'] ??
        content['pages'] ??
        []) {
      final operations = page is Map ? page['body'] : page;
      String body =
          page is Map && page['markdown'] is String ? page['markdown'] : '';
      if (body.isEmpty && operations is List) {
        final buffer = StringBuffer();
        for (final operation in operations) {
          if (operation is! Map) continue;
          final insert = operation['insert'];
          if (insert is String) buffer.write(insert);
          if (insert is Map) {
            attach(insert['media'] ?? insert['image'], AttachmentType.image);
            attach(insert['audio'], AttachmentType.audio);
          }
        }
        body = buffer.toString();
      }
      final title = page is Map ? page['title'] : null;
      if (body.trim().isNotEmpty) {
        pages.add(
            '${title is String && title.isNotEmpty ? '# $title\n\n' : ''}${body.trim()}');
      }
    }
    text = pages.isNotEmpty
        ? pages.join('\n\n')
        : '${content['plain_text'] ?? content['plainText'] ?? ''}';
    final title = content['title'];
    if (title is String && title.isNotEmpty) text = '# $title\n\n$text';
  }
  final place = row[dayOne ? 'location' : 'place'];
  EntryLocation? location;
  if (place is Map) {
    final lat = place['latitude'];
    final lon = place['longitude'];
    if (lat is num && lon is num && lat.abs() <= 90 && lon.abs() <= 180) {
      location = EntryLocation(
          entryId: -1,
          latitude: lat.toDouble(),
          longitude: lon.toDouble(),
          placeName: place['placeName'] as String? ?? place['name'] as String?,
          timeCreate: date);
    }
  }
  return ImportedEntry(
      Entry(
          text: text.trim(), timeCreate: date, timeModified: updated.toLocal()),
      tags: [
        for (final tag in tags)
          ImportedEntryTag(name: tag, tagType: TagType.label)
      ],
      attachments: attachments,
      location: location);
}
