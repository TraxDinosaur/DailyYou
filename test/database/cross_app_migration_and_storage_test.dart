// Behavior based on DenserMeerkat/June (GPL-3.0)
import 'dart:io';

import 'package:daily_you/config_provider.dart';
import 'package:daily_you/database/app_database.dart';
import 'package:daily_you/database/entry_song_dao.dart';
import 'package:daily_you/database/image_storage.dart';
import 'package:daily_you/models/entry.dart';
import 'package:daily_you/models/image.dart';
import 'package:daily_you/models/location.dart';
import 'package:daily_you/models/person.dart';
import 'package:daily_you/models/song.dart';
import 'package:daily_you/models/space.dart';
import 'package:daily_you/models/template.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/config_provider_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useTemporaryConfig();
  setUpAll(sqfliteFfiInit);

  group('Cross-App SQLite Migration & Idempotence', () {
    test('upgrades unmodified Main Daily You v5 database to v9 without duplicate column error', () async {
      final dbFactory = databaseFactoryFfi;
      final tempDir = await Directory.systemTemp.createTemp('cross_app_v5_');
      final dbPath = join(tempDir.path, 'main_daily_you_v5.db');

      try {
        // 1. Create a version 5 database matching Main Daily You upstream
        final dbV5 = await dbFactory.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 5,
            onCreate: (db, version) async {
              await db.execute('''
CREATE TABLE $entriesTable (
  ${EntryFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ${EntryFields.text} TEXT NOT NULL,
  ${EntryFields.mood} INTEGER,
  ${EntryFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
  ${EntryFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
);
''');
              await db.execute('''
CREATE TABLE $templatesTable (
  ${TemplatesFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ${TemplatesFields.name} TEXT NOT NULL,
  ${TemplatesFields.text} TEXT,
  ${TemplatesFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
  ${TemplatesFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
);
''');
              await db.execute('''
CREATE TABLE $imagesTable (
    ${EntryImageFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${EntryImageFields.entryId} INTEGER NOT NULL,
    ${EntryImageFields.imgPath} TEXT NOT NULL,
    ${EntryImageFields.imgRank} INTEGER NOT NULL,
    ${EntryImageFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now'))
);
''');
            },
          ),
        );

        final now = DateTime.now().toIso8601String();
        await dbV5.rawInsert('''
INSERT INTO $entriesTable (id, text, mood, time_create, time_modified)
VALUES (101, 'Original app diary entry from version 5', 2, '$now', '$now')
''');

        await dbV5.rawInsert('''
INSERT INTO $templatesTable (id, name, text, time_create, time_modified)
VALUES (1, 'Daily Reflection', 'Reflect on today', '$now', '$now')
''');

        await dbV5.rawInsert('''
INSERT INTO $imagesTable (id, entry_id, img_path, img_rank, time_create)
VALUES (1, 101, '/data/user/0/com.demizo.daily_you/app_flutter/Images/original_pic.jpg', 0, '$now')
''');

        await dbV5.close();

        // 2. Open with Hybrid App migration to v9
        final upgradedDb = await dbFactory.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 9,
            onUpgrade: AppDatabase.instance.testOnUpgrade,
            onDowngrade: AppDatabase.instance.testOnDowngrade,
          ),
        );

        AppDatabase.instance.database = upgradedDb;

        // 3. Verify original entries, templates, images are intact
        final entries = await upgradedDb.query(entriesTable);
        expect(entries.length, 1);
        expect(entries.first['text'], 'Original app diary entry from version 5');
        expect(entries.first['id'], 101);

        final templates = await upgradedDb.query(templatesTable);
        expect(templates.length, 1);
        expect(templates.first['name'], 'Daily Reflection');

        // Path should be sanitized to basename
        final images = await upgradedDb.query(imagesTable);
        expect(images.length, 1);
        expect(images.first[EntryImageFields.imgPath], 'original_pic.jpg');

        // 4. Verify all hybrid tables exist and are usable
        // entry_songs with album column
        final song = await EntrySongDao.add(EntrySong(
          entryId: 101,
          videoId: 'abc1234',
          url: 'https://music.youtube.com/watch?v=abc1234',
          title: 'Hybrid Song',
          artist: 'Artist',
          album: 'Album Name',
          timeCreate: DateTime.now(),
        ));
        expect(song.id, isNotNull);

        final fetchedSongs = await EntrySongDao.getByEntryId(101);
        expect(fetchedSongs.length, 1);
        expect(fetchedSongs.first.album, 'Album Name');

        // entry_locations
        await upgradedDb.insert(entryLocationsTable, {
          EntryLocationFields.entryId: 101,
          EntryLocationFields.latitude: 37.7749,
          EntryLocationFields.longitude: -122.4194,
          EntryLocationFields.placeName: 'San Francisco',
          EntryLocationFields.timeCreate: now,
        });
        final locations = await upgradedDb.query(entryLocationsTable);
        expect(locations.length, 1);
        expect(locations.first[EntryLocationFields.placeName], 'San Francisco');

        // spaces and people
        await upgradedDb.insert(spacesTable, {
          SpaceFields.name: 'Travel',
          SpaceFields.isDefault: 0,
          SpaceFields.timeCreate: now,
          SpaceFields.timeModified: now,
        });
        final spaces = await upgradedDb.query(spacesTable);
        expect(spaces.length, 1);
        expect(spaces.first[SpaceFields.name], 'Travel');

        await upgradedDb.insert(peopleTable, {
          PersonFields.name: 'Alex',
          PersonFields.timeCreate: now,
          PersonFields.timeModified: now,
        });
        final people = await upgradedDb.query(peopleTable);
        expect(people.length, 1);
        expect(people.first[PersonFields.name], 'Alex');

        // 5. Test idempotence: running migration again on the already upgraded database must not crash
        await AppDatabase.instance.testOnUpgrade(upgradedDb, 5, 9);
        await AppDatabase.instance.testOnUpgrade(upgradedDb, 8, 9);

        await upgradedDb.close();
      } finally {
        if (await tempDir.exists()) {
          try {
            await tempDir.delete(recursive: true);
          } catch (_) {}
        }
      }
    });

    test('preserves user data on downgrade without dropping tables', () async {
      final dbFactory = databaseFactoryFfi;
      final tempDir = await Directory.systemTemp.createTemp('downgrade_');
      final dbPath = join(tempDir.path, 'downgrade.db');

      try {
        final db = await dbFactory.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 10,
            onCreate: (db, version) async {
              await db.execute('''
CREATE TABLE $entriesTable (
  ${EntryFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ${EntryFields.text} TEXT NOT NULL,
  ${EntryFields.mood} INTEGER,
  ${EntryFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
  ${EntryFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
);
''');
            },
          ),
        );

        final now = DateTime.now().toIso8601String();
        await db.rawInsert('''
INSERT INTO $entriesTable (id, text, mood, time_create, time_modified)
VALUES (1, 'Important entry that must survive downgrade', 1, '$now', '$now')
''');
        await db.close();

        // Downgrade to version 9 using testOnDowngrade
        final downgradedDb = await dbFactory.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 9,
            onDowngrade: AppDatabase.instance.testOnDowngrade,
          ),
        );

        final entries = await downgradedDb.query(entriesTable);
        expect(entries.length, 1);
        expect(entries.first['text'], 'Important entry that must survive downgrade');

        await downgradedDb.close();
      } finally {
        if (await tempDir.exists()) {
          try {
            await tempDir.delete(recursive: true);
          } catch (_) {}
        }
      }
    });
  });

  group('External Storage Failure Recovery', () {
    test('resetExternalLocation and resetImageFolderLocation cleanly fall back to local storage', () async {
      final config = ConfigProvider.instance;
      await config.set(Settings.useExternalDb, true);
      await config.set(Settings.externalDbUri, 'content://invalid.uri/from/old/app');
      await config.set(Settings.useExternalImg, true);
      await config.set(Settings.externalImgUri, 'content://invalid.uri/from/old/app/images');

      expect(AppDatabase.instance.usingExternalLocation(), isTrue);
      expect(ImageStorage.instance.usingExternalLocation(), isTrue);

      // Simulates user clicking "Continue With Local Database"
      await AppDatabase.instance.resetExternalLocation();
      await ImageStorage.instance.resetImageFolderLocation();

      expect(AppDatabase.instance.usingExternalLocation(), isFalse);
      expect(ImageStorage.instance.usingExternalLocation(), isFalse);
    });
  });
}
