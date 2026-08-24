# JLPT coverage catalog discovery

This directory contains the first versioned N5 concept catalogs for the proposed
study-time coverage analytics.

## Ready-to-use seed catalogs

- `n5-vocabulary.csv`: 684 vocabulary concepts from the pinned Jonathan Waller
  N5 list.
- `n5-grammar.csv`: 77 grammar concepts from the pinned Japanese Language Data
  N5 dataset.

These files are deliberately approximate. They are suitable denominators for a
rough coverage experiment, not authoritative JLPT specifications.

## Book-derived review queues

- `n5-book-vocabulary-candidates.tsv`: OCR-derived surface forms from the
  photographed word index (`IMG_2697.HEIC` through `IMG_2700.HEIC`). It contains
  700 deduplicated candidates; 460 have a conservative direct or lemma match to
  the Waller seed, while 240 remain in the review queue. These are not part of
  the denominator until reviewed and normalized. Obvious OCR fragments are
  intentionally retained so review does not silently discard source material.
- `n5-book-grammar-candidates.csv`: cleaned patterns from the photographed
  sentence-pattern index (`IMG_2695.HEIC` and `IMG_2696.HEIC`). It contains 89
  transcribed patterns. These are useful for finding omissions, aliases, or
  distinct senses in the 77-point grammar seed; semantic reconciliation is
  still pending.

The photographed table of contents is `IMG_2694.HEIC`. The original photos stay
in the user's Downloads folder and are not copied into the repository.

## Proposed v0 behavior

Use only rows in the two seed catalogs for the first denominator. Match cards
against the book-derived files during classifier development, but do not count
`needs_review` rows until they are reconciled with a seed concept or promoted to
a new stable concept.

This gives us a stable baseline immediately while preserving the broader book
material for a later union. It also prevents OCR mistakes or duplicate polite
forms from inflating the score.

## Schema notes

- Concept IDs are stable within this catalog version.
- Vocabulary uses a canonical expression plus its kana reading.
- Grammar preserves the source pattern notation.
- `review_status=seed` means the vocabulary row is ready for the rough v0
  denominator.
- The grammar source currently marks every row `draft`; that status is preserved
  rather than overstating its review quality.
- Candidate rows retain their source image for auditing.

Run `python3 build_seed_catalogs.py` to regenerate the two seed catalogs from the
pinned source revisions. Run `python3 validate_catalogs.py` to verify row counts,
unique IDs, required fields, denominator boundaries, and photographed-page
provenance.

See `ATTRIBUTION.md` for licenses and exact upstream revisions.
