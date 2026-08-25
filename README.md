# ConvoLab for iOS

A native, local-first iOS client for the ConvoLab study experience, backed by
[learning-os](https://github.com/andyroo2000/learning-os).

## Scope

The first release targets iOS 26 and focuses on:

- Email/password authentication with a mobile bearer token stored in Keychain.
- Invite-code account creation, profile/password management, and account deletion.
- Offline flashcard study with retry-safe review-event replay.
- Local card creation and editing when the operation does not require generated media.
- Incremental inbound card sync plus a server-selected five-day offline reserve.
- Automatic media preparation for the active queue and offline reserve.
- Daily Audio creation while online and downloaded, background-capable playback offline.
- Native SwiftUI navigation and controls with ConvoLab's visual character.

Anki import is intentionally out of scope. WaniKani setup, manual sync, and adaptive
furigana are available through the study settings.

## Requirements

- Xcode 26.3 or later
- iOS 26 simulator or device
- A running or deployed learning-os API

## Configuration

The checked-in debug configuration points at `http://127.0.0.1:8000`. To use another API,
copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `API_BASE_URL`.
Both checked-in configurations automatically include the ignored local override.

Before signing in from the simulator, start the neighboring learning-os checkout:

```bash
cd ../learning-os
composer run dev
```

The Laravel server should report that it is listening on `http://127.0.0.1:8000`.

The release configuration points at the production ConvoLab edge, which forwards native
API routes to learning-os.

Builds installed on Andrew's physical devices must always use the production API. Use the
Release configuration or explicitly override `API_BASE_URL` with
`https://convo-lab.com`, and verify the built app's `Info.plist` before installing it.

## Build

```bash
xcodebuild \
  -project ConvoLab.xcodeproj \
  -scheme ConvoLab \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

## Tests

The shared `ConvoLab` scheme runs unit and native UI tests on an iOS simulator:

```bash
xcodebuild test \
  -project ConvoLab.xcodeproj \
  -scheme ConvoLab \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  -parallel-testing-enabled NO
```

UI tests launch through an isolated, Debug-only composition entry point. Fixture
launches do not construct the production `AppModel`, open normal SwiftData stores,
or register production audio services. The fixture entry point is compiled out of
Release archives.

## Offline model

The device stores cards, Daily Audio metadata, media-cache records, sync checkpoints, and
ordered mutation outboxes in SwiftData. Every local record is scoped to the authenticated
account, and switching or signing out clears all in-memory state. Reviews use learning-os
client event IDs and replay safely. Card mutations use client-generated ULIDs. Pending
local writes are pushed before the incremental card feed is pulled, avoiding a stale pull
overwriting an offline edit. If a checkpoint expires, the client rebuilds clean server
state while retaining unsynced local changes.

The five-day preparation target is:

`active due cards + (daily new-card limit × 5)`

Learning OS selects scheduled cards due during the next five days plus five days of new
cards. Scheduled reserve cards become active when their due time arrives; future new cards
remain reserved until the server introduces them. Only referenced media is downloaded.
Daily Audio tracks remain local until removed through storage management.
