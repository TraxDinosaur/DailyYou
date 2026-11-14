// Behavior based on DenserMeerkat/June (GPL-3.0)
import 'package:daily_you/utils/imports/import_bundle.dart';
import 'package:daily_you/utils/imports/import_source.dart';
import 'package:daily_you/utils/markdown_io_helper.dart';

Future<ImportBundle> parseMarkdown(ImportSource source) async => ImportBundle(
      entries: [
        ImportedEntry(MarkdownIoHelper.parseMarkdownEntry(
            await source.file.readAsString()))
      ],
    );
