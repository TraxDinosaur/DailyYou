// Copyright (C) 2026 Demizo and contributors
// SPDX-License-Identifier: GPL-3.0-only
// Additional terms under GPLv3 section 7 apply; see ADDITIONAL_TERMS.md.

import 'dart:async';
import 'dart:io';

import 'package:daily_you/database/entry_song_dao.dart';
import 'package:daily_you/database/entry_store.dart';
import 'package:daily_you/models/location.dart';
import 'package:daily_you/models/song.dart';
import 'package:daily_you/notification_manager.dart';
import 'package:daily_you/models/tag.dart';
import 'package:daily_you/providers/entry_locations_provider.dart';
import 'package:daily_you/providers/entry_songs_provider.dart';
import 'package:daily_you/models/template.dart';
import 'package:daily_you/providers/tags_provider.dart';
import 'package:daily_you/providers/templates_provider.dart';
import 'package:daily_you/utils/song_service.dart';
import 'package:daily_you/utils/youtube_url_parser.dart';
import 'package:daily_you/widgets/add_song_dialog.dart';
import 'package:daily_you/widgets/entry_draft_dirty_tracker.dart';
import 'package:daily_you/widgets/location_picker_dialog.dart';
import 'package:daily_you/widgets/song_card_widget.dart';
import 'package:daily_you/config_provider.dart';
import 'package:daily_you/database/attachment_storage.dart';
import 'package:daily_you/models/attachment.dart';
import 'package:daily_you/providers/entry_attachments_provider.dart';
import 'package:daily_you/widgets/app_dialog.dart';
import 'package:daily_you/utils/file_size_format.dart';
import 'package:daily_you/widgets/attachment_type_presentation.dart';
import 'package:daily_you/widgets/content_width_limit.dart';
import 'package:daily_you/widgets/entry_date_time_labels.dart';
import 'package:daily_you/widgets/failure_dialog.dart';
import 'package:daily_you/widgets/file_size_row.dart';
import 'package:daily_you/widgets/tag_attachment_source.dart';
import 'package:daily_you/widgets/tag_grouped_chip_list.dart';
import 'package:daily_you/widgets/tag_picker_dialog.dart';
import 'package:daily_you/widgets/tag_chip.dart';
import 'package:daily_you/time_manager.dart';
import 'package:provider/provider.dart';
import 'package:daily_you/pages/audio_recorder_page.dart';
import 'package:daily_you/pages/full_screen_text_editor_page.dart';
import 'package:daily_you/providers/people_provider.dart';
import 'package:daily_you/providers/spaces_provider.dart';
import 'package:daily_you/widgets/editor_action_bar.dart';
import 'package:daily_you/widgets/editor_action_bar/editor_keyboard_session.dart';
import 'package:daily_you/widgets/location_map_preview_widget.dart';
import 'package:daily_you/widgets/editor_action_bar/toolbar_menu_action.dart';
import 'package:daily_you/widgets/entry_attachment_editable_list.dart';
import 'package:daily_you/widgets/icons/svg_icon.dart';
import 'package:easy_debounce/easy_debounce.dart';
import 'package:material_ui/material_ui.dart';
import 'package:daily_you/l10n/generated/app_localizations.dart';
import 'package:daily_you/models/entry.dart';
import 'package:daily_you/widgets/entry_attachment_actions.dart';
import 'package:daily_you/widgets/entry_mood_picker.dart';
import 'package:daily_you/widgets/entry_text_edit.dart';
import 'package:daily_you/widgets/markdown_preview_controller.dart';

class AddEditEntryPage extends StatefulWidget {
  final Entry? entry;
  final DateTime? overrideCreateDate;
  final bool openCamera;
  final List<EntryAttachment> attachments;
  final String? sharedText;
  final int? initialSpaceId;
  final List<int>? initialPersonIds;

  const AddEditEntryPage({
    super.key,
    this.entry,
    this.overrideCreateDate,
    this.openCamera = false,
    this.attachments = const <EntryAttachment>[],
    this.sharedText,
    this.initialSpaceId,
    this.initialPersonIds,
  });

  static String mergeSharedText(String baseText, String? sharedText) {
    if (sharedText == null) return baseText;
    return baseText.isEmpty ? sharedText : '$baseText\n\n$sharedText';
  }

  @override
  State<AddEditEntryPage> createState() => _AddEditEntryPageState();
}

class _AddEditEntryPageState extends State<AddEditEntryPage>
    with WidgetsBindingObserver {
  late Entry _entry;
  int id = -1;
  String text = "";
  int? mood;
  DateTime? entryDate;
  late List<EntrySong> _currentSongs;
  EntryLocation? _currentLocation;
  int? _currentSpaceId;
  List<int> _currentPersonIds = [];
  late List<EntryAttachment> _currentAttachments;
  int _pendingAttachmentCount = 0;
  bool _loadingEntry = true;
  bool _openedCamera = false;
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  final MarkdownPreviewController _textEditingController =
      MarkdownPreviewController();
  final UndoHistoryController _undoController = UndoHistoryController();
  bool _deletingEntry = false;
  bool _closing = false;
  bool _newEntry = false;
  bool _creatingNewEntry = false;
  late TagAttachmentSource _tagSource;
  late EntryDraftDirtyTracker _dirtyTracker;
  late final EntryDraftSession _draftSession = EntryStore.instance.beginDraft();

  Future<void> _initEntry() async {
    String dirtyTrackerBaselineText;
    if (widget.entry == null) {
      var createTime =
          (TimeManager.isToday(widget.overrideCreateDate ?? DateTime.now()))
              ? DateTime.now()
              : (widget.overrideCreateDate ?? DateTime.now());
      var templateText = "";
      final defaultTemplate = TemplatesProvider.instance.getDefaultTemplate();
      final defaultTagIds = <int>[];
      if (defaultTemplate != null) {
        templateText = defaultTemplate.text ?? "";
        defaultTagIds.addAll(TagsProvider.instance
            .getTemplateTagsForTemplate(defaultTemplate.id!)
            .map((templateTag) => templateTag.tagId));
      }
      dirtyTrackerBaselineText = templateText;
      _tagSource = TagAttachmentSource(
          supportsValues: true, initialTagIds: defaultTagIds);
      _entry = Entry(
        text: AddEditEntryPage.mergeSharedText(templateText, widget.sharedText),
        mood: null,
        timeCreate: createTime,
        timeModified: DateTime.now(),
      );
      _newEntry = true;
      _creatingNewEntry = true;
      id = -1;
      _currentSpaceId = widget.initialSpaceId;
      _currentPersonIds = List.from(widget.initialPersonIds ?? const []);
      if (defaultTemplate?.id != null) {
        EntrySongDao.hasSongSlotForTemplate(defaultTemplate!.id!)
            .then((hasSlot) {
          if (hasSlot && _currentSongs.isEmpty && mounted) {
            _promptAddSong();
          }
        });
      }
    } else {
      _entry = widget.entry!;
      id = _entry.id ?? -1;
      _currentSongs = [
        for (final s in EntrySongsProvider.instance.getForEntryId(id)) s.copy()
      ];
      _currentLocation =
          EntryLocationsProvider.instance.getForEntryId(id)?.copy();
      _currentSpaceId = SpacesProvider.instance.getSpaceIdForEntry(id);
      _currentPersonIds =
          List.from(PeopleProvider.instance.getPersonIdsForEntry(id));
      _tagSource = TagAttachmentSource.fromEntryTags(
          TagsProvider.instance.getEntryTagsForEntry(id));
      dirtyTrackerBaselineText = _entry.text;
      if (widget.sharedText != null) {
        _entry = _entry.copy(
          text:
              AddEditEntryPage.mergeSharedText(_entry.text, widget.sharedText),
        );
      }
    }
    _dirtyTracker = EntryDraftDirtyTracker(
      text: dirtyTrackerBaselineText,
      mood: _entry.mood,
      date: _entry.timeCreate,
      seededTagIds: _tagSource.attachedTagIds.toSet(),
    );
    _tagSource.addListener(_onTagsChanged);
    mood = _entry.mood;
    entryDate = _entry.timeCreate;
    text = _entry.text;
    _textEditingController.addListener(() {
      text = _textEditingController.text;
      _scheduleSave();
    });
    setState(() {
      _loadingEntry = false;
    });

    if (widget.sharedText != null) {
      final sharedVideoId = YouTubeUrlParser.extractVideoId(widget.sharedText!);
      if (sharedVideoId != null) {
        unawaited(_autoAddSong(widget.sharedText!));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _textEditingController.selection =
            TextSelection.collapsed(offset: _textEditingController.text.length);
      });
    }

    if (widget.openCamera && !_openedCamera) {
      _openedCamera = true;
      _importAttachments(EntryAttachmentActions.takePhoto());
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentAttachments = List.empty(growable: true);
    for (var attachment in widget.attachments) {
      _currentAttachments.add(attachment.copy());
    }
    _currentSongs = List.empty(growable: true);
    _initEntry();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _focusNode.dispose();
    _textEditingController.dispose();
    _undoController.dispose();
    EasyDebounce.cancel("save-entry");
    _tagSource.removeListener(_onTagsChanged);
    _tagSource.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden) {
      _saveEntry();
    }
  }

  Future<void> _openFullScreenEditor() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        allowSnapshotting: false,
        builder: (context) => FullScreenTextEditorPage(
          initialText: _textEditingController.text,
        ),
      ),
    );
    if (result != null) {
      _textEditingController.text = result;
    }
  }

  void _showDeleteEntryPopup() {
    if (_newEntry && !_hasNewEntryChanges()) {
      Navigator.of(context).pop();
      return;
    }
    showAppDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(AppLocalizations.of(context)!.deleteLogTitle),
          actions: [
            TextButton(
              child:
                  Text(MaterialLocalizations.of(context).deleteButtonTooltip),
              onPressed: () async {
                _deletingEntry = true;
                EasyDebounce.cancel("save-entry");
                final navigator = Navigator.of(context);
                if (_newEntry) {
                  await _saveEntry();
                }
                final entryToDelete = _entry;
                // Pop dialog
                navigator.pop();
                // Pop edit page
                navigator.pop();
                if (!_creatingNewEntry && navigator.canPop()) {
                  // Pop view page
                  navigator.pop();
                }
                await EntryStore.instance.delete(entryToDelete);
                await _deleteUnsavedFiles(_currentAttachments);
              },
            ),
            TextButton(
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
              onPressed: () async {
                Navigator.pop(context);
              },
            )
          ],
          content: Text(AppLocalizations.of(context)!.deleteLogDescription),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyboardInset = EditorActionBarOverlay.keyboardInsetOf(context);

    return _loadingEntry
        ? Scaffold()
        : PopScope(
            onPopInvokedWithResult: (didPop, result) async {
              if (!_deletingEntry) {
                await _saveEntry();
              }
            },
            child: Scaffold(
              appBar: AppBar(
                iconTheme: Theme.of(context).iconTheme,
                leading: _deleteButton(),
                actions: [_closeButton()],
              ),
              body: EditorActionBarOverlay(
                keyboardInset: keyboardInset,
                body: LayoutBuilder(
                  builder: (context, constraints) {
                    final sidePadding = contentSideInset(constraints.maxWidth);
                    final capPadding =
                        EdgeInsets.symmetric(horizontal: sidePadding);
                    return CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding: capPadding,
                          sliver: SliverToBoxAdapter(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (_currentAttachments.isNotEmpty ||
                                      _pendingAttachmentCount > 0)
                                    EntryAttachmentEditableList(
                                        attachments: _currentAttachments,
                                        pendingCount: _pendingAttachmentCount,
                                        onAttachmentsChanged:
                                            (attachments) async {
                                          final removed =
                                              _unsavedRemovedBy(attachments);
                                          _currentAttachments = attachments;
                                          await _saveEntry();
                                          await _deleteUnsavedFiles(removed);
                                        }),
                                  StatefulBuilder(
                                    builder: (context, setLocalState) =>
                                        _buildMetadataCard(
                                            context, theme, setLocalState),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: capPadding,
                          sliver: _buildTextEditorSliver(context),
                        ),
                      ],
                    );
                  },
                ),
                actionBar: EditorActionBar(
                  controller: _textEditingController,
                  undoController: _undoController,
                  focusNode: _focusNode,
                  onTemplateInserted: _applyInsertedTemplateTags,
                  onTagSelected: (tag) => _tagSource.addTagId(tag.id!),
                  onPersonSelected: (person) {
                    if (person.id != null &&
                        !_currentPersonIds.contains(person.id!)) {
                      setState(() {
                        _currentPersonIds.add(person.id!);
                      });
                      _scheduleSave();
                    }
                  },
                  mainActions: _buildMainActions(context),
                ),
              ),
            ),
          );
  }

  // The card showing entry date/time, mood, and tags.
  // setLocalState is the StatefulBuilder's setter, so a mood change only
  // rebuilds this card instead of the whole scroll view.
  Widget _buildMetadataCard(
    BuildContext context,
    ThemeData theme,
    StateSetter setLocalState,
  ) {
    return Card.filled(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: _buildDateTimeButtons(context, theme),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4.0, bottom: 4.0),
            child: EntryMoodPicker(
                moodValue: mood,
                onChangedMood: (mood) {
                  setLocalState(() => this.mood = mood);
                  _scheduleSave();
                }),
          ),
          _buildSpaceAndPeopleChips(theme, setLocalState),
          _buildTagChips(),
          _buildLocationChip(theme),
          _buildSongList(setLocalState),
        ],
      ),
    );
  }

  Widget _buildSpaceAndPeopleChips(ThemeData theme, StateSetter setLocalState) {
    final spacesProvider = SpacesProvider.instance;
    final peopleProvider = PeopleProvider.instance;
    final currentSpace = _currentSpaceId != null
        ? spacesProvider.spaces
            .where((s) => s.id == _currentSpaceId)
            .firstOrNull
        : null;

    final taggedPeople = peopleProvider.people
        .where((p) => _currentPersonIds.contains(p.id))
        .toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (currentSpace != null)
            FilterChip(
              avatar: const Icon(Icons.dashboard_rounded, size: 16),
              label: Text(currentSpace.name),
              selected: true,
              showCheckmark: false,
              onSelected: (_) => _promptSelectSpace(setLocalState),
            )
          else
            ActionChip(
              avatar: const Icon(Icons.dashboard_outlined, size: 16),
              label: const Text('Add Space'),
              onPressed: () => _promptSelectSpace(setLocalState),
            ),
          for (final person in taggedPeople)
            InputChip(
              avatar: const Icon(Icons.person_rounded, size: 16),
              label: Text('@${person.name}'),
              onDeleted: () {
                setLocalState(() {
                  _currentPersonIds.remove(person.id);
                });
                _scheduleSave();
              },
            ),
          ActionChip(
            avatar: const Icon(Icons.person_add_rounded, size: 16),
            label: const Text('Add Person'),
            onPressed: () => _promptAddPersonToEntry(setLocalState),
          ),
        ],
      ),
    );
  }

  Future<void> _promptSelectSpace(StateSetter setLocalState) async {
    final spaces = SpacesProvider.instance.spaces;
    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Select Space',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: Icon(
                Icons.notes_rounded,
                color: _currentSpaceId == null
                    ? Theme.of(ctx).colorScheme.primary
                    : null,
              ),
              title: const Text('None (Normal Journal)'),
              trailing: _currentSpaceId == null
                  ? const Icon(Icons.check_rounded, color: Colors.green)
                  : null,
              onTap: () => Navigator.of(ctx).pop(-1),
            ),
            for (final space in spaces)
              ListTile(
                leading: Icon(
                  space.isDefault ? Icons.star_rounded : Icons.folder_rounded,
                  color: space.id == _currentSpaceId
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
                title: Text(space.name),
                trailing: space.id == _currentSpaceId
                    ? const Icon(Icons.check_rounded, color: Colors.green)
                    : null,
                onTap: () => Navigator.of(ctx).pop(space.id),
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Create New Space'),
              onTap: () => Navigator.of(ctx).pop(-999),
            ),
          ],
        ),
      ),
    );

    if (!mounted || selected == null) return;

    if (selected == -1) {
      setLocalState(() {
        _currentSpaceId = null;
      });
      _scheduleSave();
    } else if (selected == -999) {
      final controller = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('New Space'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Space name',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        ),
      );
      if (name != null && name.isNotEmpty && mounted) {
        final created = await SpacesProvider.instance.addSpace(name);
        setLocalState(() {
          _currentSpaceId = created.id;
        });
        _scheduleSave();
      }
    } else {
      setLocalState(() {
        _currentSpaceId = selected;
      });
      _scheduleSave();
    }
  }

  Future<void> _promptAddPersonToEntry(StateSetter setLocalState) async {
    final people = PeopleProvider.instance.people;
    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Tag Person',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            for (final person in people)
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: Text('@${person.name}'),
                trailing: _currentPersonIds.contains(person.id)
                    ? const Icon(Icons.check_rounded, color: Colors.green)
                    : null,
                onTap: () => Navigator.of(ctx).pop(person.id),
              ),
            ListTile(
              leading: const Icon(Icons.person_add_rounded),
              title: const Text('Add New Person'),
              onTap: () => Navigator.of(ctx).pop(-999),
            ),
          ],
        ),
      ),
    );

    if (!mounted || selected == null) return;

    if (selected == -999) {
      final controller = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Add Person'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              prefixText: '@',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Add'),
            ),
          ],
        ),
      );
      if (name != null && name.isNotEmpty && mounted) {
        final newPerson = await PeopleProvider.instance.addPerson(name);
        if (newPerson.id != null) {
          setLocalState(() {
            if (!_currentPersonIds.contains(newPerson.id!)) {
              _currentPersonIds.add(newPerson.id!);
            }
          });
          _scheduleSave();
        }
      }
    } else {
      setLocalState(() {
        if (!_currentPersonIds.contains(selected)) {
          _currentPersonIds.add(selected);
        } else {
          _currentPersonIds.remove(selected);
        }
      });
      _scheduleSave();
    }
  }

  Widget _buildLocationChip(ThemeData theme) {
    if (_currentLocation == null ||
        (_currentLocation!.placeName == null &&
            _currentLocation!.latitude == null)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(left: 8.0, right: 8.0, bottom: 8.0),
      child: LocationMapPreviewWidget(
        location: _currentLocation!,
        isEditable: true,
        onTap: _promptEditLocation,
        onEdit: _promptEditLocation,
        onRemove: () async {
          setState(() {
            _currentLocation = null;
          });
          if (id != -1) {
            await EntryLocationsProvider.instance.removeForEntry(id);
          }
          await _saveEntry();
        },
      ),
    );
  }

  Widget _buildSongList(StateSetter setLocalState) {
    if (_currentSongs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
      child: Column(
        children: [
          for (final song in _currentSongs)
            SongCardWidget(
              song: song,
              compact: true,
              onUpdate: (updated) async {
                setLocalState(() {
                  final idx = _currentSongs.indexOf(song);
                  if (idx != -1) _currentSongs[idx] = updated;
                });
                if (updated.id != null) {
                  await EntrySongDao.update(updated);
                }
                await _saveEntry();
              },
              onDelete: () async {
                setLocalState(() {
                  _currentSongs.remove(song);
                });
                if (song.id != null) {
                  await EntrySongsProvider.instance.remove(song);
                }
                await _saveEntry();
              },
            ),
        ],
      ),
    );
  }

  Widget _buildTagChips() {
    const padding = EdgeInsets.only(left: 8, right: 8, bottom: 8);
    return ListenableBuilder(
      listenable: _tagSource,
      builder: (context, _) {
        final attachedIds = _tagSource.attachedTagIds;
        if (attachedIds.isEmpty) return const SizedBox.shrink();
        final tagsProvider = Provider.of<TagsProvider>(context);
        final attachedSet = attachedIds.toSet();
        final tagPool = tagsProvider.tags
            .where((tag) => attachedSet.contains(tag.id))
            .toList();
        final sections = tagsProvider.buildSections('', tagPool: tagPool);
        return Padding(
          padding: padding,
          child: TagGroupedChipList(
            sections: sections,
            chipBuilder: (tag) => TagChip(
              tag: tag,
              value: _tagSource.valueFor(tag.id!),
              onTap: tag.tagType == TagType.tracker
                  ? () => _tagSource.editValue(context, tag)
                  : null,
              onRemove: () => _tagSource.detach(tag.id!),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDateTimeButtons(BuildContext context, ThemeData theme) {
    return EntryDateTimeLabels(
      dateTime: entryDate!,
      dateColor: theme.colorScheme.primary,
      timeColor: theme.colorScheme.primary,
      onDateTap: _chooseDate,
      onTimeTap: _chooseTime,
    );
  }

  List<ToolbarAction> _buildMainActions(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return [
      ToolbarAction(
        icon: const Icon(Icons.local_offer_rounded),
        onPressed: () => showAppDialog(
          context: context,
          builder: (_) =>
              TagPickerDialog(mode: TagPickerMode.attach, source: _tagSource),
        ),
      ),
      ToolbarAction(
        icon: const SvgIcon('assets/icons/attach_file.svg'),
        menu: [
          ToolbarMenuAction(
            icon: Icons.mic_rounded,
            label: l10n.actionAddAudio,
            onSelected: () =>
                _importAttachments(EntryAttachmentActions.pickAudioFile()),
          ),
          ToolbarMenuAction(
            icon: Icons.videocam_rounded,
            label: l10n.actionAddVideo,
            onSelected: () => _importAttachments(
                EntryAttachmentActions.pickVideosFromGallery()),
          ),
          ToolbarMenuAction(
            icon: Icons.photo_rounded,
            label: l10n.actionAddImage,
            onSelected: () =>
                _importAttachments(EntryAttachmentActions.pickFromGallery()),
          ),
        ],
      ),
      ToolbarAction(
        icon: const Icon(Icons.photo_camera_rounded),
        menu: [
          ToolbarMenuAction(
            icon: Icons.mic_rounded,
            label: l10n.actionRecordAudio,
            onSelected: _recordAudio,
          ),
          if (Platform.isAndroid) ...[
            ToolbarMenuAction(
              icon: Icons.videocam_rounded,
              label: l10n.actionTakeVideo,
              onSelected: () =>
                  _importAttachments(EntryAttachmentActions.takeVideo()),
            ),
            ToolbarMenuAction(
              icon: Icons.photo_camera_rounded,
              label: l10n.actionTakePhoto,
              onSelected: () =>
                  _importAttachments(EntryAttachmentActions.takePhoto()),
            ),
          ],
        ],
      ),
      ToolbarAction(
        icon: const Icon(Icons.music_note_rounded),
        onPressed: _promptAddSong,
      ),
      ToolbarAction(
        icon: const Icon(Icons.location_on_rounded),
        onPressed: _promptEditLocation,
      ),
    ];
  }

  Widget _buildTextEditorSliver(BuildContext context) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Builder(
        builder: (context) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            EditorKeyboardSessionScope.maybeOf(context)?.resume();
            _focusNode.requestFocus();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: StatefulBuilder(
                    builder: (context, setState) => EntryTextEditor(
                      text: text,
                      focusNode: _focusNode,
                      textEditingController: _textEditingController,
                      undoHistoryController: _undoController,
                      onExpand: _openFullScreenEditor,
                    ),
                  ),
                ),
                SizedBox(height: 16 + EditorActionBar.reservedHeight(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _deleteButton() => IconButton(
        icon: const Icon(Icons.delete),
        tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
        onPressed: () => _showDeleteEntryPopup(),
      );

  Widget _closeButton() => IconButton(
        icon: const Icon(Icons.check_rounded),
        tooltip: MaterialLocalizations.of(context).okButtonLabel,
        onPressed: _saveAndClose,
      );

  Future<void> _saveAndClose() async {
    if (_closing) return;
    _closing = true;
    try {
      await _saveEntry();
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _chooseDate() async {
    DateTime? pickedDate = await TimeManager.pickDate(
      context,
      initialDate: entryDate!,
      firstDate: TimeManager.minEntryDate,
      lastDate: DateTime.now(),
    );
    if (pickedDate == null) return;

    entryDate = entryDate!.copyWith(
      year: pickedDate.year,
      month: pickedDate.month,
      day: pickedDate.day,
    );
    await _saveEntry();
  }

  Future<void> _chooseTime() async {
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(entryDate!),
      builder: (context, child) => AppDialogTransition(child: child!),
    );
    if (pickedTime == null) return;

    entryDate = entryDate!.copyWith(
      hour: pickedTime.hour,
      minute: pickedTime.minute,
    );
    await _saveEntry();
  }

  void _scheduleSave() {
    EasyDebounce.debounce("save-entry", const Duration(seconds: 5), _saveEntry);
  }

  Future<void> _saveEntry() async {
    if (_newEntry && !_hasNewEntryChanges()) return;

    if ((_newEntry || _hasEntryFieldChanges()) &&
        Platform.isAndroid &&
        TimeManager.isSameDay(DateTime.now(), entryDate!)) {
      await NotificationManager.instance.dismissReminderNotification();
    }

    final saved = await _draftSession.save(_buildDraft);
    _adoptSavedEntry(saved);
    _adoptSavedAttachments(saved);
    await _persistSongs(saved.id!);
    if (_currentLocation != null) {
      if (_currentLocation!.placeName != null ||
          _currentLocation!.latitude != null) {
        _currentLocation!.entryId = saved.id!;
        await EntryLocationsProvider.instance.setLocation(_currentLocation!);
      } else {
        await EntryLocationsProvider.instance.removeForEntry(saved.id!);
      }
    }
    if (_currentSpaceId != null) {
      await SpacesProvider.instance
          .assignEntryToSpace(saved.id!, _currentSpaceId!);
    } else {
      await SpacesProvider.instance.unassignEntryFromSpace(saved.id!);
    }
    await PeopleProvider.instance.setEntryPeople(saved.id!, _currentPersonIds);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _promptEditLocation() async {
    final updated = await LocationPickerDialog.show(
      context,
      initialLocation: _currentLocation,
    );
    if (updated != null && mounted) {
      setState(() {
        _currentLocation = updated;
      });
      await _saveEntry();
    }
  }

  Future<void> _persistSongs(int entryId) async {
    for (var i = 0; i < _currentSongs.length; i++) {
      final song = _currentSongs[i];
      if (song.id == null || song.entryId != entryId) {
        song.entryId = entryId;
        final savedSong = await EntrySongsProvider.instance.add(song);
        _currentSongs[i] = savedSong;
      }
    }
  }

  Future<void> _promptAddSong({String? initialLink}) async {
    final song = await AddSongDialog.show(context, initialLink: initialLink);
    if (song != null && mounted) {
      setState(() {
        _currentSongs.add(song);
      });
      await _saveEntry();
    }
  }

  Future<void> _autoAddSong(String url) async {
    try {
      final result = await SongService.instance.resolveSong(url);
      if (mounted) {
        setState(() {
          _currentSongs.add(result.toEntrySong(entryId: id));
        });
        await _saveEntry();
      }
    } catch (_) {}
  }

  EntryDraft _buildDraft(Entry? saved) {
    if (saved != null) _adoptSavedEntry(saved);
    final entry = _hasEntryFieldChanges()
        ? _entry.copy(
            text: text,
            mood: mood,
            timeCreate: entryDate,
            timeModified: DateTime.now(),
          )
        : _entry;
    return EntryDraft(
      entry: entry,
      tags: _tagSource.toEntryTags(id),
      attachments: [
        for (final attachment in _currentAttachments) attachment.copy()
      ],
    );
  }

  void _adoptSavedEntry(Entry saved) {
    _entry = saved;
    id = saved.id!;
    _newEntry = false;
    _dirtyTracker.markSaved(
      text: saved.text,
      mood: saved.mood,
      date: saved.timeCreate,
    );
  }

  void _adoptSavedAttachments(Entry saved) {
    final persistedIds = {
      for (final attachment
          in EntryAttachmentsProvider.instance.getForEntry(saved))
        attachment.filePath: attachment.id
    };
    _currentAttachments = [
      for (final attachment in _currentAttachments)
        attachment.copy(
            id: persistedIds[attachment.filePath], entryId: saved.id)
    ];
  }

  bool _hasEntryFieldChanges() {
    return _dirtyTracker.hasFieldChanges(
        text: text, mood: mood, date: entryDate!);
  }

  void _onTagsChanged() {
    _scheduleSave();
  }

  bool _hasNewEntryChanges() {
    return _dirtyTracker.hasUnsavedChanges(
          text: text,
          mood: mood,
          date: entryDate!,
          tagSource: _tagSource,
          hasAttachments: _currentAttachments.isNotEmpty,
        ) ||
        _currentSongs.isNotEmpty ||
        _currentLocation != null ||
        _currentSpaceId != null ||
        _currentPersonIds.isNotEmpty;
  }

  void _applyInsertedTemplateTags(Template template) {
    if (template.id == null) return;
    final templateTagIds = TagsProvider.instance
        .getTemplateTagsForTemplate(template.id!)
        .map((templateTag) => templateTag.tagId);
    for (final tagId in templateTagIds) {
      _tagSource.addTagId(tagId);
    }
    EntrySongDao.hasSongSlotForTemplate(template.id!).then((hasSlot) {
      if (hasSlot && mounted) {
        _promptAddSong();
      }
    });
  }

  List<EntryAttachment> _unsavedRemovedBy(List<EntryAttachment> remaining) => [
        for (final attachment in _currentAttachments)
          if (attachment.id == null &&
              !remaining.any((kept) =>
                  kept.type == attachment.type &&
                  kept.filePath == attachment.filePath))
            attachment
      ];

  Future<void> _deleteUnsavedFiles(List<EntryAttachment> attachments) async {
    for (final attachment in attachments) {
      if (attachment.id != null) continue;
      final inUse = EntryAttachmentsProvider.instance.attachments.any((saved) =>
          saved.type == attachment.type &&
          saved.filePath == attachment.filePath);
      if (inUse) continue;
      await AttachmentStorage.instance
          .delete(attachment.filePath, attachment.type);
    }
  }

  Future<void> _addAttachments(List<NewAttachment> newAttachments) async {
    _currentAttachments = EntryAttachment.appendRanked(
        _currentAttachments, newAttachments,
        entryId: id);
    await _saveEntry();
  }

  Future<void> _importAttachments(
      Future<List<PendingAttachment>> picking) async {
    final List<PendingAttachment> pending;
    try {
      pending = await picking;
    } catch (error) {
      await _showAttachmentFailure(error);
      return;
    }
    if (pending.isEmpty) return;
    if (!mounted) {
      await EntryAttachmentActions.discardAll(pending);
      return;
    }

    setState(() => _pendingAttachmentCount += pending.length);
    final large = pending.where((attachment) => attachment.isLarge).firstOrNull;
    if (large != null) {
      unawaited(_warnAboutSize(large.type, large.name, large.sizeBytes!));
    }

    Object? failure;
    var stored = const <NewAttachment>[];
    try {
      stored = await EntryAttachmentActions.storeAll(pending,
          isCancelled: () => !mounted);
    } catch (error) {
      failure = error;
    } finally {
      _pendingAttachmentCount -= pending.length;
      if (stored.isEmpty && mounted) setState(() {});
    }
    if (stored.isNotEmpty) await _addAttachments(stored);
    if (failure != null || (mounted && stored.length < pending.length)) {
      await _showAttachmentFailure(failure);
    }
  }

  Future<void> _showAttachmentFailure(Object? error) async {
    if (!mounted) return;
    await showFailureDialog(context,
        description:
            AppLocalizations.of(context)!.attachmentAddErrorDescription,
        error: error);
  }

  Future<void> _recordAudio() async {
    final attachment = await Navigator.of(context).push<NewAttachment>(
      MaterialPageRoute(
        allowSnapshotting: false,
        fullscreenDialog: true,
        builder: (context) => const AudioRecorderPage(),
      ),
    );
    if (attachment == null) return;
    await _addAttachments([attachment]);
    final sizeBytes = await AttachmentStorage.instance
        .sizeBytes(attachment.filePath, attachment.type);
    if (sizeBytes != null && attachment.type.isLarge(sizeBytes)) {
      await _warnAboutSize(attachment.type, attachment.filePath, sizeBytes);
    }
  }

  Future<void> _warnAboutSize(
      AttachmentType type, String name, int sizeBytes) async {
    if (ConfigProvider.instance.get(Settings.suppressLargeAttachmentWarning) ||
        !mounted) {
      return;
    }

    var suppress = false;
    await showAppDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocalState) => AlertDialog(
          title: Text(
              AppLocalizations.of(dialogContext)!.largeAttachmentWarningTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppLocalizations.of(dialogContext)!
                  .largeAttachmentWarningDescription),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: FileSizeRow(
                  icon: type.icon,
                  label: name,
                  sizeText: formatFileSize(sizeBytes,
                      AppLocalizations.of(dialogContext)!.localeName),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: suppress,
                onChanged: (value) =>
                    setLocalState(() => suppress = value ?? false),
                title: Text(AppLocalizations.of(dialogContext)!.dontShowAgain),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (suppress) {
                  await ConfigProvider.instance
                      .set(Settings.suppressLargeAttachmentWarning, true);
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child:
                  Text(MaterialLocalizations.of(dialogContext).okButtonLabel),
            ),
          ],
        ),
      ),
    );
  }
}
