# Hybrid 1.1.0 upstream synchronization

Date: 2026-11-15

## Source revisions

| Source | Previous reference | Integrated reference |
| --- | --- | --- |
| Hybrid application | `6263bfd2` (1.0.0+1000001) | 1.1.0+1001000 |
| Demizo/Daily_You | `88f49152`, based on v3.6.1 | [`8984962`](https://github.com/Demizo/Daily_You/commit/8984962): v3.10.0 plus subsequent gallery/search commits |
| DenserMeerkat/June | `9f359d3` (local v2.1.0-era reference) | [`fbddaaa3`](https://github.com/DenserMeerkat/June/commit/fbddaaa3002e78f888f4b960405dd5a3faf19d82) |

The earlier workspace porting log described a completed v3.10 merge, but that merge was absent from the actual v1.0.0 Git history and source. This update uses the committed application as its baseline. The June checkout remains untouched; its newer reference was fetched into the hybrid repository for comparison. The integrated branch tips include unreleased development changes, not just release tags.

## Integrated behavior

- Daily You: unified image/video/audio attachments, audio recording and media playback, attachment sharing, media quality controls, improved external-folder synchronization, responsive calendars and layouts, mood scale customization, expanded statistics, current Markdown rendering and formatting, JSON/CSV/Markdown exports, updated import pipeline, fuzzy search and highlighting, date/mood/tag/media/text filters, gallery selection and bulk actions.
- June: standalone preference export/restore and Day One/StoryPad JSON or ZIP imports. Existing native backup encryption, automatic backup scheduling, charging constraints, retention, cancellation and progress UI cover June's new backup behavior without introducing a second scheduler or backup format. Existing native restore/JSON import and Diarium import cover the overlapping import sources.
- Hybrid behavior retained: songs and cached local audio/covers, YouTube Music sharing, locations and map previews, custom spaces and people, tag/person autocomplete, calendar streaks, Markdown and keyboard preferences, PIN recovery, screen protection, developer logging, palette/font preferences and the runtime network switch. Searchable mood emojis remain available alongside upstream icon and color customization.
- The Android package remains `com.traxdinosaur.dailyyou`. Signing configuration and Flutter submodule revision are unchanged. Existing INTERNET/location permissions and network consent defaults are preserved; the pre-update hybrid already declared INTERNET in its main manifest. Audio recording permission and audio/video share intents were added for upstream media support.

Android output version codes now apply the same base-times-ten scale to universal and per-ABI APKs. The 1.1.0 universal APK uses `10010000`, exceeding the existing 1.0.0 ABI APK codes (`10000011`–`10000013`), so switching to the universal update does not request a downgrade.

June's Compose-only styling and internal Kotlin refactors are represented through the Flutter application's existing components. Presentation-specific import metadata such as source fonts, per-story colors and weather icons has no equivalent in the hybrid's entry model and is not imported. The new importers support journal text, dates, tags, favorite markers, local media and coordinates; they do not implement June's independent sync/schema design.

## Data compatibility

The hybrid schema advances from 9 to 10. Migration detects actual tables rather than relying on overlapping upstream/hybrid version numbers. It creates unified attachment and mood-scale tables when absent, converts legacy moods once, preserves media IDs/ranks, recognizes legacy video extensions, normalizes portable paths, and retains song/location/space/person/template associations.

Legacy video bytes are copied from Images into Video before orphan cleanup. Restoring an older archive uses its actual backed-up video bytes, including when a stale destination filename already exists. Cached covers and local song audio in SongCovers remain included in backup/restore. Failed video migration stops rather than reporting success and permitting cleanup.

Bulk deletion removes hybrid associations as well as upstream attachments/tags, refreshes hybrid caches, and records WebDAV tombstones. It preserves unselected entries and the reusable people/spaces themselves.

Preference backups use a separate versioned JSON document with an explicit allowlist. They exclude journal content, credentials, lock/recovery data, external paths, sync state, background schedules and network consent. All included values are validated before any preference is applied.

## Dependencies

The media/runtime dependencies and local external_opener/performance_hint packages come from the integrated Daily You source and its lockfile. Existing audioplayers support is retained for hybrid song previews. No proprietary service, analytics SDK, Google Play Services integration, update checker or Google Drive integration was added. Windows portability fixes close archive/database handles, normalize fixture paths and line endings, use the Windows CRT timezone API in tests, and avoid concurrent preferences-temp-file writes.

## Verification

| Check | Result |
| --- | --- |
| Baseline hybrid tests before changes | 363 passed |
| Final full Flutter test suite | 1,401 passed, zero failures |
| Final UI/settings/import focused suite | 127 passed |
| Entry-store and hybrid bulk-deletion suite | 13 passed |
| Final portable-import and legacy-backup restore suite | 8 passed |
| Dart analysis of lib, test, packages and tool | No issues found |
| fdroid debug APK | Built successfully |
| Final fdroid release APK | Built successfully, 41.0 MiB |
| APK identity | com.traxdinosaur.dailyyou, version 1.1.0, version code 10010000 |
| APK signature | v2 verified; certificate matches the existing v1.0.0 arm64 APK |

Delivery artifact: `build/app/outputs/flutter-apk/Daily-You-Hybrid-v1.1.0.apk`.

SHA-256: `d4ebb1a5383862a2238a28af894be33df1b68362b1be47238c67adb0b2a6994a`.

Source integration commit: `ba66d7c0` on local branch `feat/upstream-refresh-2026-11`. No remote push, publication, device installation or signing-configuration changes were performed. Build/test evidence is retained in the ignored `build/upstream-refresh-evidence` directory.

The Flutter/AGP toolchain emits a plugin compile-SDK diagnostic containing `2147483647`, along with Kotlin migration notices and untranslated-string counts. Both Android build modes succeeded with the existing compile SDK 37; the invalid diagnostic value was not applied to the project.

Physical-device smoke tests, live remote services and desktop packaging are unverified. No Android device/emulator was connected during this update. Windows desktop plugin symlink generation requires Developer Mode on this machine; dependency resolution, scoped Dart analysis, Flutter tests and Android builds can run without installing global tools or changing that system setting.
