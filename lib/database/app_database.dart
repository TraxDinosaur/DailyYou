import 'dart:io';

import 'package:daily_you/config_provider.dart';
import 'package:daily_you/database/image_storage.dart';
import 'package:daily_you/l10n/generated/app_localizations.dart';
import 'package:daily_you/storage/external_sync_health.dart';
import 'package:daily_you/storage/file_store.dart';
import 'package:daily_you/storage/local_file_store.dart';
import 'package:daily_you/storage/storage_picker.dart';
import 'package:daily_you/utils/operation_outcome.dart';
import 'package:daily_you/utils/generated/tag_icon_registry.dart';
import 'package:daily_you/models/entry.dart';
import 'package:daily_you/models/image.dart';
import 'package:daily_you/models/location.dart';
import 'package:daily_you/models/person.dart';
import 'package:daily_you/models/song.dart';
import 'package:daily_you/models/space.dart';
import 'package:daily_you/models/tag.dart';
import 'package:daily_you/models/tag_category.dart';
import 'package:daily_you/models/template.dart';
import 'package:daily_you/providers/entries_provider.dart';
import 'package:daily_you/providers/entry_images_provider.dart';
import 'package:daily_you/providers/entry_locations_provider.dart';
import 'package:daily_you/providers/entry_songs_provider.dart';
import 'package:daily_you/providers/people_provider.dart';
import 'package:daily_you/providers/spaces_provider.dart';
import 'package:daily_you/providers/tags_provider.dart';
import 'package:daily_you/providers/templates_provider.dart';
import 'package:easy_debounce/easy_debounce.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  static final AppDatabase instance = AppDatabase._init();
  AppDatabase._init();

  static DatabaseExecutor executorOr(DatabaseExecutor? executor) =>
      executor ?? instance.database!;

  static const String databaseFileName = 'daily_you.db';

  final Logger _logger = Logger('AppDatabase');

  final ExternalSyncHealth externalSyncHealth =
      ExternalSyncHealth('AppDatabase');

  /// True when a migration from external storage was attempted on the last
  /// [init] but failed.
  bool migrationFailed = false;

  static Database? _database;
  Database? get database => _database;

  @visibleForTesting
  set database(Database? database) => _database = database;

  String? _internalPath;

  FileStore get internalStore => LocalFileStore(dirname(_internalPath!));

  FileStore? get externalStore =>
      usingExternalLocation() ? FileStore.external(getExternalPath()) : null;

  Future<bool> init(
      {bool forceWithoutSync = false, bool allowMigration = true}) async {
    _internalPath = await getInternalPath();
    migrationFailed = false;
    bool success = true;

    if (Platform.isAndroid && allowMigration) {
      final migrated = await _migrateDbFromExternalStorage();
      if (!migrated && !forceWithoutSync) {
        // Migration was attempted but failed
        migrationFailed = true;
        return false;
      }
    }

    // Migration is foreground-only. A background task (allowMigration: false)
    // must never create a fresh database before the user has migrated their
    // data, so bail if there is nothing to open yet.
    if (!allowMigration && !await File(_internalPath!).exists()) {
      return false;
    }

    if (usingExternalLocation() && !forceWithoutSync) {
      if (await hasExternalLocationPermission()) {
        try {
          await _syncWithExternalDatabase();
        } catch (error, stackTrace) {
          _logger.warning(
              'Syncing with external database failed, falling back to local database',
              error,
              stackTrace);
          success = false;
        }
      } else {
        success = false;
      }
    }

    await AppDatabase.instance.open();
    return success;
  }

  /// Returns whether it is safe to open the internal database. False means a
  /// migration was needed but failed, so the caller must not create a fresh
  /// database over the still-intact external copy.
  Future<bool> _migrateDbFromExternalStorage() async {
    if (await File(_internalPath!).exists()) return true;

    final oldDir = await getExternalStorageDirectory();
    if (oldDir == null) return true;
    final oldPath = join(oldDir.path, databaseFileName);
    if (!await File(oldPath).exists()) return true;

    _logger.info('Database migration started: $oldPath -> $_internalPath');
    try {
      await File(oldPath).copy(_internalPath!);
      if (await _validateSqliteDatabase(_internalPath!)) {
        await File(oldPath).delete();
        _logger.info('Database migration finished successfully');
        return true;
      }
      // Integrity check failed: discard the bad copy and keep the external
      // original so the migration can be retried instead of proceeding.
      await File(_internalPath!).delete();
      _logger.severe(
          'Database migration failed: integrity check failed, kept original external database');
      return false;
    } catch (error, stackTrace) {
      // Remove any partial copy so the migration is retried on relaunch.
      if (await File(_internalPath!).exists()) {
        await File(_internalPath!).delete();
      }
      _logger.severe('Database migration failed', error, stackTrace);
      return false;
    }
  }

  Future<void> open() async {
    _database = await openDatabase(
      _internalPath!,
      version: 9,
      onCreate: _createDatabase,
      onUpgrade: _onUpgrade,
      onDowngrade: _onDowngrade,
    );

    await EntriesProvider.instance.load();
    await EntryImagesProvider.instance.load();
    await EntrySongsProvider.instance.load();
    await EntryLocationsProvider.instance.load();
    await SpacesProvider.instance.load();
    await PeopleProvider.instance.load();
    await TemplatesProvider.instance.load();
    await TagsProvider.instance.load();
  }

  Future<void> close() async {
    final db = _database!;
    _database = null;
    db.close();
  }

  Future<bool> validateDatabase(String path) async {
    return await _validateSqliteDatabase(path);
  }

  Future<bool> _validateSqliteDatabase(String path) async {
    try {
      final db = await openDatabase(path, readOnly: true);
      final result = await db.rawQuery("PRAGMA integrity_check;");
      await db.close();

      return result.first.values.first == "ok";
    } catch (error, stackTrace) {
      _logger.warning(
          'Database integrity check failed for $path', error, stackTrace);
      return false;
    }
  }

  Future<bool> exportSnapshotTo(String path) async {
    final db = _database;
    if (db == null) return false;

    try {
      await db.execute("VACUUM INTO '$path'");
      if (await _validateSqliteDatabase(path)) return true;
    } catch (error, stackTrace) {
      _logger.severe('Database snapshot to $path failed', error, stackTrace);
    }

    if (await File(path).exists()) await File(path).delete();
    return false;
  }

  bool usingExternalLocation() {
    return ConfigProvider.instance.get(Settings.useExternalDb);
  }

  Future<String> getInternalPath() async {
    final basePath = await getApplicationSupportDirectory();
    if (!basePath.existsSync()) basePath.createSync(recursive: true);
    return join(basePath.path, databaseFileName);
  }

  String getExternalPath() {
    return ConfigProvider.instance.get(Settings.externalDbUri);
  }

  /// Return whether the app has permission to access the external location
  Future<bool> hasExternalLocationPermission() async {
    return await externalStore?.isAvailable() ?? false;
  }

  Future<OperationOutcome> selectExternalLocation(
      Function(String) updateStatus) async {
    bool databaseUpdated = false;
    var outcome = const OperationOutcome.succeeded();

    // Save old external path
    var oldExternalPath = getExternalPath();
    var oldUseExternalPath = usingExternalLocation();
    await _database!.close();

    try {
      var selectedDirectory = await StoragePicker.pickDirectory();
      if (selectedDirectory == null) {
        outcome = const OperationOutcome.cancelled();
      } else {
        await ConfigProvider.instance
            .set(Settings.externalDbUri, selectedDirectory.uri);
        await ConfigProvider.instance.set(Settings.useExternalDb, true);

        // Sync with external folder
        databaseUpdated = await _syncWithExternalDatabase(forceOverwrite: true);
        if (!databaseUpdated) outcome = const OperationOutcome.failed();
      }
    } catch (error, stackTrace) {
      _logger.severe(
          'Selecting an external database location failed', error, stackTrace);
      outcome = OperationOutcome.failed(error);
    }

    // Cleanup
    await open();
    if (!databaseUpdated) {
      // Restore state after failure
      await ConfigProvider.instance
          .set(Settings.externalDbUri, oldExternalPath);
      await ConfigProvider.instance
          .set(Settings.useExternalDb, oldUseExternalPath);
    } else {
      try {
        if (ImageStorage.instance.usingExternalLocation() &&
            await ImageStorage.instance.hasExternalLocationPermission()) {
          await ImageStorage.instance
              .syncImageFolder(true, updateStatus: updateStatus);
        }
      } catch (error, stackTrace) {
        _logger.severe(
            'Syncing images after the database location changed failed',
            error,
            stackTrace);
        outcome = OperationOutcome.failed(error);
      }
    }
    return outcome;
  }

  Future<void> resetExternalLocation() async {
    await ConfigProvider.instance.set(Settings.useExternalDb, false);
  }

  /// Overwrite the external database with local changes
  /// If an external database is not in use, no action is taken
  Future<void> updateExternalDatabase() async {
    if (!usingExternalLocation()) return;

    EasyDebounce.debounce("update-remote-database", Duration(seconds: 1),
        () async {
      final externalLocation = externalStore;
      if (externalLocation == null) return;

      final exportName =
          "$databaseFileName.export_${DateTime.now().millisecondsSinceEpoch}";
      final exportPath = join(dirname(_internalPath!), exportName);

      await externalSyncHealth.record("external database write", () async {
        try {
          if (!await exportSnapshotTo(exportPath)) return false;

          final bytes = await internalStore.read(exportName);
          if (bytes == null) return false;

          return await externalLocation.write(databaseFileName, bytes);
        } finally {
          await internalStore.delete(exportName);
        }
      });
    });
  }

  /// Pull in remote changes if the external database is newer or if forceOverwrite is set
  Future<bool> _syncWithExternalDatabase({bool forceOverwrite = false}) async {
    final externalLocation = externalStore;
    if (externalLocation == null) return false;

    if (!await externalLocation.exists(databaseFileName)) {
      final bytes = await internalStore.read(databaseFileName);
      if (bytes == null) return false;

      return externalSyncHealth.record("external database write",
          () => externalLocation.write(databaseFileName, bytes));
    }

    if (forceOverwrite || await _isExternalDatabaseNewer(externalLocation)) {
      // Overwrite internal DB
      final externalBytes = await externalLocation.read(databaseFileName);
      if (externalBytes == null) return false;

      final temporaryName =
          "$databaseFileName.${DateTime.now().millisecondsSinceEpoch}.tmp";
      await internalStore.write(temporaryName, externalBytes);

      final temporaryPath = join(dirname(_internalPath!), temporaryName);
      if (await _validateSqliteDatabase(temporaryPath)) {
        return internalStore.rename(temporaryName, databaseFileName);
      }

      await internalStore.delete(temporaryName);
      return false;
    }
    return true;
  }

  /// Return whether the external database is newer
  Future<bool> _isExternalDatabaseNewer(FileStore externalLocation) async {
    final internalModifiedTime =
        await internalStore.modifiedTime(databaseFileName) ?? DateTime.now();

    final externalModifiedTime =
        await externalLocation.modifiedTime(databaseFileName) ??
            internalModifiedTime;

    return externalModifiedTime.isAfter(internalModifiedTime);
  }

  // SQLite Database Actions

  Future _createDatabase(Database db, int version) async {
    _database = db;
    await createSchema(db);
    await TemplatesProvider.instance.createDefaultTemplates();
    await TagsProvider.instance.createDefaultTags();
    await createWelcomeEntry();
  }

  Future<void> createSchema(Database db) async {
    await db.execute('''
CREATE TABLE $entriesTable (
  ${EntryFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ${EntryFields.text} TEXT NOT NULL,
  ${EntryFields.mood} INTEGER,
  ${EntryFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
  ${EntryFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
)
''');
    await db.execute('''
CREATE TABLE $templatesTable (
  ${TemplatesFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ${TemplatesFields.name} TEXT NOT NULL,
  ${TemplatesFields.text} TEXT,
  ${TemplatesFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
  ${TemplatesFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
)
''');
    await db.execute('''
CREATE TABLE $imagesTable (
    ${EntryImageFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${EntryImageFields.entryId} INTEGER NOT NULL,
    ${EntryImageFields.imgPath} TEXT NOT NULL,
    ${EntryImageFields.imgRank} INTEGER NOT NULL,
    ${EntryImageFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    FOREIGN KEY (${EntryImageFields.entryId}) REFERENCES $entriesTable (id)
)
''');

    await _createTagTables(db);
    await _createTemplateTagTable(db);
    await _createSongTables(db);
    await _createLocationTable(db);
    await _createSpaceTables(db);
    await _createPeopleTables(db);
  }

  @visibleForTesting
  Future<void> createWelcomeEntry() async {
    final deviceLocale = WidgetsBinding.instance.platformDispatcher.locale;
    Locale locale;
    if (AppLocalizations.delegate.isSupported(deviceLocale)) {
      locale = deviceLocale;
    } else {
      final langOnly = Locale(deviceLocale.languageCode);
      locale = AppLocalizations.delegate.isSupported(langOnly)
          ? langOnly
          : const Locale('en');
    }
    final l10n = await AppLocalizations.delegate.load(locale);
    final now = DateTime.now();

    final welcomeEntry = await EntriesProvider.instance.add(
      Entry(
        text: l10n.welcomeLogBodyText,
        mood: 1,
        timeCreate: now,
        timeModified: now,
      ),
      skipUpdate: true,
    );

    final imageBytes =
        await rootBundle.load('assets/daily_you_First_Steps.webp');
    final imageName = await ImageStorage.instance.create(
      'daily_you_First_Steps.webp',
      imageBytes.buffer.asUint8List(),
      currTime: now,
    );
    if (imageName != null) {
      await EntryImagesProvider.instance.add(
        EntryImage(
          entryId: welcomeEntry.id,
          imgPath: imageName,
          imgRank: 0,
          timeCreate: now,
        ),
        skipUpdate: true,
      );
    }

    final favoriteTag = TagsProvider.instance.tags
        .where((tag) => tag.icon == TagIconKey.favorite)
        .firstOrNull;
    if (favoriteTag != null) {
      await TagsProvider.instance.addEntryTag(EntryTag(
        entryId: welcomeEntry.id!,
        tagId: favoriteTag.id!,
        timeCreate: now,
      ));
    }

    final energyTag = TagsProvider.instance.tags
        .where((tag) => tag.icon == TagIconKey.batteryChargingFull)
        .firstOrNull;
    if (energyTag != null) {
      await TagsProvider.instance.addEntryTag(EntryTag(
        entryId: welcomeEntry.id!,
        tagId: energyTag.id!,
        value: '10',
        timeCreate: now,
      ));
    }
  }

  Future<bool> _tableExists(DatabaseExecutor db, String tableName) async {
    final result = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [tableName],
    );
    return result.isNotEmpty;
  }

  Future<bool> _columnExists(
      DatabaseExecutor db, String tableName, String columnName) async {
    if (!await _tableExists(db, tableName)) return false;
    final columns = await db.rawQuery('PRAGMA table_info($tableName)');
    return columns.any((c) =>
        c['name']?.toString().toLowerCase() == columnName.toLowerCase());
  }

  Future<void> _createTagTables(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS $tagCategoriesTable (
    ${TagCategoryFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${TagCategoryFields.icon} TEXT,
    ${TagCategoryFields.iconType} INTEGER NOT NULL DEFAULT 0,
    ${TagCategoryFields.name} TEXT NOT NULL,
    ${TagCategoryFields.color} INTEGER,
    ${TagCategoryFields.sortOrder} INTEGER NOT NULL DEFAULT 0,
    ${TagCategoryFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    ${TagCategoryFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
);
''');

    await db.execute('''
CREATE TABLE IF NOT EXISTS $tagsTable (
    ${TagFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${TagFields.categoryId} INTEGER,
    ${TagFields.icon} TEXT,
    ${TagFields.iconType} INTEGER NOT NULL DEFAULT 0,
    ${TagFields.name} TEXT NOT NULL,
    ${TagFields.tagType} INTEGER NOT NULL,
    ${TagFields.color} INTEGER,
    ${TagFields.sortOrder} INTEGER NOT NULL DEFAULT 0,
    ${TagFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    ${TagFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    FOREIGN KEY (${TagFields.categoryId}) REFERENCES $tagCategoriesTable (id)
);
''');

    await db.execute('''
CREATE TABLE IF NOT EXISTS $entryTagsTable (
    ${EntryTagFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${EntryTagFields.entryId} INTEGER NOT NULL,
    ${EntryTagFields.tagId} INTEGER NOT NULL,
    ${EntryTagFields.value} TEXT,
    ${EntryTagFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    FOREIGN KEY (${EntryTagFields.entryId}) REFERENCES $entriesTable (id),
    FOREIGN KEY (${EntryTagFields.tagId}) REFERENCES $tagsTable (id)
);
''');
  }

  Future<void> _createTemplateTagTable(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS $templateTagsTable (
    ${TemplateTagFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${TemplateTagFields.templateId} INTEGER NOT NULL,
    ${TemplateTagFields.tagId} INTEGER NOT NULL,
    ${TemplateTagFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    FOREIGN KEY (${TemplateTagFields.templateId}) REFERENCES $templatesTable (id),
    FOREIGN KEY (${TemplateTagFields.tagId}) REFERENCES $tagsTable (id)
);
''');
  }

  Future<void> _createSongTables(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS $entrySongsTable (
    ${EntrySongFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${EntrySongFields.entryId} INTEGER NOT NULL,
    ${EntrySongFields.videoId} TEXT NOT NULL,
    ${EntrySongFields.url} TEXT NOT NULL,
    ${EntrySongFields.title} TEXT NOT NULL,
    ${EntrySongFields.artist} TEXT NOT NULL,
    ${EntrySongFields.album} TEXT,
    ${EntrySongFields.coverPath} TEXT,
    ${EntrySongFields.previewUrl} TEXT,
    ${EntrySongFields.previewStartMs} INTEGER NOT NULL DEFAULT 0,
    ${EntrySongFields.previewEndMs} INTEGER,
    ${EntrySongFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    FOREIGN KEY (${EntrySongFields.entryId}) REFERENCES $entriesTable (id)
);
''');

    await db.execute('''
CREATE TABLE IF NOT EXISTS $templateSongSlotsTable (
    ${TemplateSongSlotFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${TemplateSongSlotFields.templateId} INTEGER NOT NULL,
    ${TemplateSongSlotFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    FOREIGN KEY (${TemplateSongSlotFields.templateId}) REFERENCES $templatesTable (id)
);
''');
  }

  Future<void> _createLocationTable(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS $entryLocationsTable (
    ${EntryLocationFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${EntryLocationFields.entryId} INTEGER NOT NULL,
    ${EntryLocationFields.latitude} REAL,
    ${EntryLocationFields.longitude} REAL,
    ${EntryLocationFields.placeName} TEXT,
    ${EntryLocationFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    FOREIGN KEY (${EntryLocationFields.entryId}) REFERENCES $entriesTable (id)
);
''');
  }

  Future<void> _createSpaceTables(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS $spacesTable (
    ${SpaceFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${SpaceFields.name} TEXT NOT NULL UNIQUE,
    ${SpaceFields.isDefault} INTEGER NOT NULL DEFAULT 0,
    ${SpaceFields.icon} TEXT,
    ${SpaceFields.color} INTEGER,
    ${SpaceFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    ${SpaceFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
);
''');

    await db.execute('''
CREATE TABLE IF NOT EXISTS $entrySpacesTable (
    ${EntrySpaceFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${EntrySpaceFields.entryId} INTEGER NOT NULL,
    ${EntrySpaceFields.spaceId} INTEGER NOT NULL,
    FOREIGN KEY (${EntrySpaceFields.entryId}) REFERENCES $entriesTable (id),
    FOREIGN KEY (${EntrySpaceFields.spaceId}) REFERENCES $spacesTable (id),
    UNIQUE (${EntrySpaceFields.entryId}, ${EntrySpaceFields.spaceId})
);
''');
  }

  Future<void> _createPeopleTables(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS $peopleTable (
    ${PersonFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${PersonFields.name} TEXT NOT NULL UNIQUE,
    ${PersonFields.note} TEXT,
    ${PersonFields.color} INTEGER,
    ${PersonFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    ${PersonFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
);
''');

    await db.execute('''
CREATE TABLE IF NOT EXISTS $entryPeopleTable (
    ${EntryPersonFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${EntryPersonFields.entryId} INTEGER NOT NULL,
    ${EntryPersonFields.personId} INTEGER NOT NULL,
    FOREIGN KEY (${EntryPersonFields.entryId}) REFERENCES $entriesTable (id),
    FOREIGN KEY (${EntryPersonFields.personId}) REFERENCES $peopleTable (id),
    UNIQUE (${EntryPersonFields.entryId}, ${EntryPersonFields.personId})
);
''');
  }

  Future<void> _ensureSchemaElements(DatabaseExecutor db) async {
    await _createTagTables(db);
    await _createTemplateTagTable(db);
    await _createSongTables(db);
    await _createLocationTable(db);
    await _createSpaceTables(db);
    await _createPeopleTables(db);

    if (await _tableExists(db, entrySongsTable) &&
        !await _columnExists(db, entrySongsTable, EntrySongFields.album)) {
      await db.execute(
          'ALTER TABLE $entrySongsTable ADD COLUMN ${EntrySongFields.album} TEXT;');
    }
  }

  Future<void> _sanitizePortedPaths(DatabaseExecutor db) async {
    try {
      if (await _tableExists(db, imagesTable)) {
        final rows = await db.query(imagesTable,
            columns: [EntryImageFields.id, EntryImageFields.imgPath]);
        for (final row in rows) {
          final id = row[EntryImageFields.id] as int?;
          final rawPath = row[EntryImageFields.imgPath] as String?;
          if (id != null &&
              rawPath != null &&
              (rawPath.contains('/') || rawPath.contains('\\'))) {
            final cleanName = basename(rawPath);
            await db.update(
              imagesTable,
              {EntryImageFields.imgPath: cleanName},
              where: '${EntryImageFields.id} = ?',
              whereArgs: [id],
            );
          }
        }
      }

      if (await _tableExists(db, entrySongsTable)) {
        final rows = await db.query(entrySongsTable, columns: [
          EntrySongFields.id,
          EntrySongFields.coverPath,
          EntrySongFields.url,
        ]);
        for (final row in rows) {
          final id = row[EntrySongFields.id] as int?;
          final coverPath = row[EntrySongFields.coverPath] as String?;
          final url = row[EntrySongFields.url] as String?;
          final updates = <String, Object?>{};

          if (coverPath != null &&
              (coverPath.contains('/') || coverPath.contains('\\'))) {
            updates[EntrySongFields.coverPath] = basename(coverPath);
          }
          if (url != null && url.startsWith('file://') && url.length > 7) {
            final filePath = url.substring(7);
            if (filePath.contains('/') || filePath.contains('\\')) {
              updates[EntrySongFields.url] = 'file://${basename(filePath)}';
            }
          }

          if (id != null && updates.isNotEmpty) {
            await db.update(
              entrySongsTable,
              updates,
              where: '${EntrySongFields.id} = ?',
              whereArgs: [id],
            );
          }
        }
      }
    } catch (e, st) {
      _logger.warning('Error while sanitizing ported paths', e, st);
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    _database = db;
    _logger.info('Upgrading database from v$oldVersion to v$newVersion');

    if (oldVersion < 2) {
      if (!await _tableExists(db, templatesTable)) {
        await db.execute('''
CREATE TABLE IF NOT EXISTS $templatesTable (
  ${TemplatesFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ${TemplatesFields.name} TEXT NOT NULL,
  ${TemplatesFields.text} TEXT,
  ${TemplatesFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
  ${TemplatesFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
);
''');
        await TemplatesProvider.instance.createDefaultTemplates();
      }
    }

    if (oldVersion < 3) {
      await db.execute('''
CREATE TABLE IF NOT EXISTS $imagesTable (
    ${EntryImageFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    ${EntryImageFields.entryId} INTEGER NOT NULL,
    ${EntryImageFields.imgPath} TEXT NOT NULL,
    ${EntryImageFields.imgRank} INTEGER NOT NULL,
    ${EntryImageFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
    FOREIGN KEY (${EntryImageFields.entryId}) REFERENCES $entriesTable (id)
);
''');
      if (await _columnExists(db, entriesTable, deprecatedImgPath)) {
        await db.transaction((txn) async {
          await txn.execute('''
INSERT INTO $imagesTable (${EntryImageFields.entryId}, ${EntryImageFields.imgPath}, ${EntryImageFields.imgRank}, ${EntryImageFields.timeCreate})
SELECT ${EntryFields.id}, $deprecatedImgPath, 0, ${EntryFields.timeCreate}
FROM $entriesTable
WHERE $deprecatedImgPath IS NOT NULL;
''');
          await txn.execute('ALTER TABLE $entriesTable RENAME TO old_entries;');
          await txn.execute('''
CREATE TABLE $entriesTable (
  ${EntryFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ${EntryFields.text} TEXT NOT NULL,
  ${EntryFields.mood} INTEGER,
  ${EntryFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
  ${EntryFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
);
''');
          await txn.execute('''
INSERT INTO $entriesTable (${EntryFields.id}, ${EntryFields.text}, ${EntryFields.mood}, ${EntryFields.timeCreate}, ${EntryFields.timeModified})
SELECT ${EntryFields.id}, ${EntryFields.text}, ${EntryFields.mood}, ${EntryFields.timeCreate}, ${EntryFields.timeModified}
FROM old_entries;
''');
          await txn.execute('DROP TABLE old_entries;');
        });
      }
    }

    if (oldVersion < 4) {
      await _createTagTables(db);
      if (await _tableExists(db, tagsTable)) {
        final count = Sqflite.firstIntValue(
                await db.rawQuery('SELECT COUNT(*) FROM $tagsTable')) ??
            0;
        if (count == 0) {
          await TagsProvider.instance.createDefaultTags();
        }
      }
    }

    if (oldVersion < 5) {
      await _createTemplateTagTable(db);
    }

    if (oldVersion < 6) {
      await _createSongTables(db);
    }

    if (oldVersion < 7) {
      await _createLocationTable(db);
    }

    if (oldVersion < 8) {
      if (await _tableExists(db, entrySongsTable) &&
          !await _columnExists(db, entrySongsTable, EntrySongFields.album)) {
        await db.execute(
            'ALTER TABLE $entrySongsTable ADD COLUMN ${EntrySongFields.album} TEXT;');
      }
    }

    if (oldVersion < 9) {
      await _createSpaceTables(db);
      await _createPeopleTables(db);
    }

    await _ensureSchemaElements(db);
    await _sanitizePortedPaths(db);
  }

  Future<void> _onDowngrade(Database db, int oldVersion, int newVersion) async {
    _logger.warning(
        'Database downgrade requested from v$oldVersion to v$newVersion; preserving data');
    _database = db;
    await _ensureSchemaElements(db);
    await _sanitizePortedPaths(db);
  }

  @visibleForTesting
  Future<void> testOnUpgrade(Database db, int oldVersion, int newVersion) =>
      _onUpgrade(db, oldVersion, newVersion);

  @visibleForTesting
  Future<void> testOnDowngrade(Database db, int oldVersion, int newVersion) =>
      _onDowngrade(db, oldVersion, newVersion);

  @visibleForTesting
  Future<void> testSanitizePortedPaths(DatabaseExecutor db) =>
      _sanitizePortedPaths(db);
}
