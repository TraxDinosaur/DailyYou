import 'dart:io';
import 'package:daily_you/database/app_database.dart';
import 'package:daily_you/models/attachment.dart';
import 'package:daily_you/models/song.dart';
import 'package:daily_you/models/location.dart';
import 'package:daily_you/models/space.dart';
import 'package:daily_you/models/person.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/legacy_hybrid_schema.dart';
import '../support/config_provider_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  useTemporaryConfig();

  test('upgrades the unmodified hybrid v9 schema with all associations intact',
      () async {
    final folder = await Directory.systemTemp.createTemp('hybrid_v9_');
    final path = join(folder.path, 'daily_you.db');
    final factory = databaseFactoryFfi;
    var db = await factory.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 9,
          onCreate: (db, _) => LegacyHybridSchema().createSchema(db),
        ));
    final now = DateTime(2026, 11, 14).toIso8601String();
    await db.insert('entries', {
      'id': 42,
      'text': 'My original journal',
      'mood': -2,
      'time_create': now,
      'time_modified': now
    });
    await db.insert('entry_images', {
      'id': 7,
      'entry_id': 42,
      'img_path': 'movie.mp4',
      'img_rank': 2,
      'time_create': now
    });
    await db.insert(
        entrySongsTable,
        EntrySong(
                entryId: 42,
                videoId: 'abcdefghijk',
                url: 'https://music.youtube.com/watch?v=abcdefghijk',
                title: 'Track',
                artist: 'Artist',
                album: 'Album',
                coverPath: 'cover.jpg',
                previewUrl: 'local.mp3',
                timeCreate: DateTime.parse(now))
            .toJson());
    await db.insert(entryLocationsTable, {
      'entry_id': 42,
      'latitude': 23.0,
      'longitude': 72.0,
      'place_name': 'Home',
      'time_create': now
    });
    await db.insert(spacesTable,
        {'id': 5, 'name': 'Travel', 'time_create': now, 'time_modified': now});
    await db.insert(entrySpacesTable, {'entry_id': 42, 'space_id': 5});
    await db.insert(peopleTable,
        {'id': 6, 'name': 'Alex', 'time_create': now, 'time_modified': now});
    await db.insert(entryPeopleTable, {'entry_id': 42, 'person_id': 6});
    await db.close();
    db = await factory.openDatabase(path,
        options: OpenDatabaseOptions(
          version: AppDatabase.schemaVersion,
          onUpgrade: AppDatabase.instance.onUpgrade,
        ));
    try {
      expect((await db.query('entries')).single['mood'], 1);
      expect((await db.query('entries')).single['text'], 'My original journal');
      final attachment = (await db.query(attachmentsTable)).single;
      expect(attachment['id'], 7);
      expect(attachment['file_path'], 'movie.mp4');
      expect(attachment['type'], 'video');
      expect(attachment['rank'], 2);
      expect((await db.query(entrySongsTable)).single['album'], 'Album');
      expect(
          (await db.query(entryLocationsTable)).single['place_name'], 'Home');
      expect((await db.query(entrySpacesTable)).single['space_id'], 5);
      expect((await db.query(entryPeopleTable)).single['person_id'], 6);
      // Re-running schema reconciliation must not shift mood a second time.
      await AppDatabase.instance.onUpgrade(db, 9, AppDatabase.schemaVersion);
      expect((await db.query('entries')).single['mood'], 1);
      expect((await db.query('mood_scale')).length, 5);
    } finally {
      await db.close();
      AppDatabase.instance.database = null;
      await folder.delete(recursive: true);
    }
  });
}
