# Desktop flashcard parity

The desktop ConvoLab study experience is the behavioral source of truth for the
native app. Its persisted card types are:

- `recognition`
- `production`
- `cloze`

Text, audio, and image-led cards are presentation variants of those types. They
are not separate API card types.

## Card faces

### Recognition and production fronts

1. If the prompt has media but no cue text, the media is the prompt.
2. Helper meaning is hidden on media-led prompts.
3. An image-only production prompt may show one of the Japanese part-of-speech
   labels: `名詞`, `動詞`, `形容詞`, `副詞`, or `表現`.
4. Otherwise, show prompt image, prompt audio, cue text, then cue meaning.
5. When `cueReading` or `expressionReading` resolves to the same plain text as
   `cueText`, use that annotated value so front-side furigana renders. Ignore a
   reading that belongs to different text.

### Cloze fronts

1. Derive the blank from canonical `{{c1::answer}}` markup, even when a stale
   `clozeDisplayText` still contains the markup.
2. Show the prompt image first when one exists.
3. Show `clozeResolvedHint` beneath the sentence.
4. When `restoredTextReading` aligns with `restoredText`, preserve its ruby
   annotations outside the active blank without revealing the blanked answer.

### Recognition and production backs

1. Heading: `expressionReading`, then the imported `cueReading` fallback, then
   plain `expression`.
2. Answer audio and pitch accent appear below the heading.
3. Answer image wins over the prompt image; the prompt image is reused when
   there is no answer image.
4. Text details appear in this order: restored text, meaning, Japanese example,
   English example, notes.

### Cloze backs

1. Heading: `restoredTextReading`, then `restoredText`.
2. Answer audio and pitch accent appear below the heading.
3. Reuse the same answer-image fallback as other cards.
4. Show meaning, then notes.

## Furigana

Bracket readings (`会社[かいしゃ]`) and Anki-style parenthetical readings
(`会社(かいしゃ)`) render as ruby text on matching front prompts, answer
headings, and Japanese detail text. Particles and okurigana remain outside the
ruby annotation.

Readings are visible by default. The native client downloads the effective
known-kanji set from learning-os and stores it per user for offline study. A
reading is hidden only when every kanji in its annotated word is known; an
iteration mark does not require its own knowledge entry. WaniKani connection
tokens are submitted to learning-os and are never stored on the device.

Resolved pitch-accent payloads render only on the answer face and are persisted
with the local card for offline review. When a card has no resolved payload,
revealing the answer may ask learning-os to resolve it; failure or lack of a
network never blocks the card or grading.

## Card library and editor

The library creates and edits recognition, production, and cloze cards while
offline. Recognition and production cards expose separate prompt and answer
text, reading, meaning, examples, and notes. Cloze cards use canonical
`{{c1::answer}}` prompt markup plus restored text, restored-text reading,
meaning, and notes. Existing card types cannot be changed.

New-card creation distinguishes the desktop modes: text recognition, audio
recognition, text production, image production, and cloze. Text recognition,
text production, and cloze remain offline-first direct creates. Audio
recognition and image production enter the learning-os manual draft queue,
poll until ready, and expose preview media regeneration before committing the
canonical card. Draft commits retain one client-generated card ULID across
retries, reconcile the committed card locally, and then delete the transient
server draft.

Saving an existing card merges the edited fields into its full payload so
server-managed scheduling data, generated audio, images, and pitch accent are
preserved. A recognition card whose only prompt is audio keeps the desktop
audio-led contract: prompt text fields stay hidden and only answer fields are
edited. Image-led cards retain their image and expose any helper label while
allowing cue text to remain empty. Creates and updates enter the same persisted
sync outbox as reviews and remain visible after relaunch.

The editor shows current answer audio before its audio settings. It exposes the
same nine Japanese Fish Audio voices as desktop, defaulting to Ren, plus an
optional phonetic audio override. Saving preserves those settings for every
supported card type. Existing cards can ask learning-os to regenerate answer
audio; the returned card is persisted immediately, the new audio replaces any
cached file for the same stable media URL, and playback starts from the
downloaded file. Regeneration is unavailable for a new unsynced card and fails
normally while offline without discarding local edits.

The editor previews current front and back images, derives the same natural
real-world prompt as desktop, and supports no image, front, back, and
front-and-back placement. The generated-image workflow uses one current image
reference, moving or duplicating it onto the selected faces and explicitly
clearing the other face. Legacy cards with genuinely different front and back
images retain both on unrelated saves until the user changes image placement or
regenerates. Existing synced cards can ask learning-os to regenerate the image
from a non-empty prompt of at most 1,000 characters. The returned image
reference is persisted immediately and its bytes are downloaded before the
operation succeeds, so the regenerated card remains usable offline.

## Review tray

The four grades are Again, Hard, Good, and Easy. Each grade displays the next
scheduled interval above its label. A compact replay control precedes the
grades and replays the same locally resolved answer-audio file as the answer
face; it remains disabled when the card has no offline-playable answer audio.
The session header reports failed, queued review, and new counts separately.
Queued and new counts reflect the currently loaded session cards; failed count
reconciles the loaded failures with the authoritative overview and decrements
optimistically after an offline review.

## Offline behavior

All media for the active queue and the five-day new-card reserve is downloaded.
Card faces must prefer the validated local file and only stream when the media
is not cached and the network is available. A card is counted as ready offline
only when every audio and image URL declared by its payload resolves to a local
file; text-only cards are ready without a download.

Review results are also applied to the local card snapshot before they enter the
sync outbox. The native schedule mirrors learning-os starter intervals and state
transitions: Again returns as relearning after ten minutes, Hard returns after
one day, Good after three days, and Easy after seven days. Locally due cards are
restored in review-before-new order on launch and while a study screen remains
open, so an Again card can return without a network connection. A card becoming
due during an active session is appended between reviews instead of replacing
the card currently on screen. Repeated offline reviews of the same card are
replayed in review-time order when reconstructing failed counts.
