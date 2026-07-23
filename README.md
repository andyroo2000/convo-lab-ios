# ConvoLab for iOS

A native, local-first iOS client for the ConvoLab study experience, backed by
[learning-os](https://github.com/andyroo2000/learning-os).

## Scope

The first release targets iOS 26 and focuses on:

- Email/password authentication with a mobile bearer token stored in Keychain.
- Offline flashcard study with retry-safe review-event replay.
- Local card creation and editing when the operation does not require generated media.
- Automatic media preparation for the active queue plus five days of new cards.
- Daily Audio creation while online and downloaded, background-capable playback offline.
- Native SwiftUI navigation and controls with ConvoLab's visual character.

Anki import is intentionally out of scope. WaniKani setup and manual sync are planned as
the first fast-follow; the local models preserve the backend's study metadata so adding it
does not require a storage migration.

## Requirements

- Xcode 26.3 or later
- iOS 26 simulator or device
- A running or deployed learning-os API

## Configuration

The checked-in debug configuration points at `http://127.0.0.1:8000`. To use another API,
copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `API_BASE_URL`.
Both checked-in configurations automatically include the ignored local override.

The release URL is deliberately an invalid placeholder until the production learning-os
hostname is selected.

## Build

```bash
xcodebuild \
  -project ConvoLab.xcodeproj \
  -scheme ConvoLab \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

## Offline model

The device stores cards, Daily Audio metadata, media-cache records, a sync checkpoint, and
an ordered mutation outbox in SwiftData. Reviews use learning-os client event IDs and batch
replay. Card mutations use client-generated ULIDs. Server feed entries are applied only
after pending local writes have been pushed, avoiding a stale pull overwriting an offline
edit.

The five-day preparation target is:

`active due cards + (daily new-card limit × 5)`

Only referenced media is downloaded. Daily Audio tracks are downloaded after opening a
ready practice and remain local until removed through storage management.
