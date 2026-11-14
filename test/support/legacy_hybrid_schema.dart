// Schema copied from Hybrid v1.0.0 (6263bfd) for migration regression coverage.
import 'package:sqflite/sqflite.dart';
import 'package:daily_you/models/entry.dart';
import 'package:daily_you/models/image.dart';
import 'package:daily_you/models/template.dart';
import 'package:daily_you/models/tag.dart';
import 'package:daily_you/models/tag_category.dart';
import 'package:daily_you/models/song.dart';
import 'package:daily_you/models/location.dart';
import 'package:daily_you/models/space.dart';
import 'package:daily_you/models/person.dart';

class LegacyHybridSchema {
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
}
