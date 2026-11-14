# Changelog

## 1.1.0 — 2026-11-15

- Synchronize Daily You through v3.10.0 and its current gallery/search improvements.
- Add unified media recording/playback, richer statistics and mood customization, responsive layouts, fuzzy search, gallery filters and bulk actions.
- Add June-inspired app-settings export/restore and Day One/StoryPad imports.
- Preserve hybrid songs, offline media, maps, locations, people, spaces and privacy/editor preferences.
- Safely migrate legacy hybrid media/moods and restore cached song files and older video backups.
- Preserve the existing app ID and signing configuration for in-place upgrades.
- Fix universal APK version codes so updates also install over the older per-architecture APKs.

See [UPSTREAM_SYNC.md](UPSTREAM_SYNC.md) for source revisions, compatibility decisions and verification limits.

Validation: 1,401 Flutter tests pass; scoped Dart analysis reports no issues; debug and signed release APKs build. The release APK's package ID, version code and signing certificate were checked against the previous installation artifacts. Physical-device testing remains unverified.
