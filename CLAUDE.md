# Claude Review Guidance

This repository is the native iOS client for ConvoLab's learning-os-backed
flashcard study and Daily Audio experiences.

When reviewing pull requests:

- Prioritize correctness, runtime crashes, data loss, security, performance,
  accessibility, and missing tests.
- Respect the incremental rollout. Avoid broad rewrites or speculative
  abstractions unless the current slice creates a concrete defect.
- Treat Swift 6 concurrency warnings, actor-isolation violations, and unsafe
  cross-actor state as correctness issues.
- Keep SwiftUI views focused on presentation and user interaction. Networking,
  persistence, sync, media caching, and playback behavior belong in dedicated
  stores or services.
- Treat the SwiftData store as a local replica, not the authority. Offline
  mutation outboxes must be retry-safe and must not discard an operation until
  the server has confirmed it.
- Reviews and client-generated card mutations must retain stable client
  identifiers across retries.
- Flag server refresh behavior that can overwrite an unacknowledged local edit,
  skip tombstones, or advance a sync checkpoint before all entries are applied.
- Authentication tokens belong in Keychain with device-appropriate
  accessibility. Do not persist credentials in SwiftData or UserDefaults.
- Media downloads must use authenticated requests when required, move files
  atomically, validate successful HTTP responses, and keep cache metadata
  consistent with the filesystem.
- Daily Audio playback must remain safe across interruption, route changes,
  backgrounding, remote commands, and item replacement. Playback position is
  intentionally device-local.
- Preserve learning-os wire contracts exactly. Some compatibility endpoints
  return direct JSON while canonical Laravel resources use a `data` envelope.
- Keep review comments concise and actionable.
