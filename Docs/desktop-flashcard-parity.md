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

### Cloze fronts

1. Derive the blank from canonical `{{c1::answer}}` markup, even when a stale
   `clozeDisplayText` still contains the markup.
2. Show the prompt image first when one exists.
3. Show `clozeResolvedHint` beneath the sentence.

### Recognition and production backs

1. Heading: `expressionReading`, then `expression`; `cueReading` is the imported
   fallback.
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

## Review tray

The four grades are Again, Hard, Good, and Easy. Each grade displays the next
scheduled interval above its label. The session header reports failed, queued
review, and new counts separately.

## Offline behavior

All media for the active queue and the five-day new-card reserve is downloaded.
Card faces must prefer the validated local file and only stream when the media
is not cached and the network is available.
