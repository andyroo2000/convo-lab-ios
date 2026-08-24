#!/usr/bin/env python3
"""Validate the checked-in N5 seed catalogs and book review queues."""

from __future__ import annotations

import csv
from pathlib import Path


CATALOG_DIRECTORY = Path(__file__).resolve().parent


def read_rows(filename: str, delimiter: str = ",") -> list[dict[str, str]]:
    with (CATALOG_DIRECTORY / filename).open(
        encoding="utf-8", newline=""
    ) as input_file:
        return list(csv.DictReader(input_file, delimiter=delimiter))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"Catalog validation failed: {message}")


def main() -> None:
    vocabulary = read_rows("n5-vocabulary.csv")
    grammar = read_rows("n5-grammar.csv")
    book_vocabulary = read_rows("n5-book-vocabulary-candidates.tsv", "\t")
    book_grammar = read_rows("n5-book-grammar-candidates.csv")

    require(len(vocabulary) == 684, "expected 684 vocabulary seed rows")
    require(
        len({row["concept_id"] for row in vocabulary}) == len(vocabulary),
        "vocabulary concept IDs must be unique",
    )
    require(
        all(
            row["jlpt_level"] == "N5"
            and row["expression"]
            and row["reading"]
            and row["meaning"]
            and row["review_status"] == "seed"
            for row in vocabulary
        ),
        "vocabulary seed rows have invalid required fields",
    )

    require(len(grammar) == 77, "expected 77 grammar seed rows")
    require(
        len({row["concept_id"] for row in grammar}) == len(grammar),
        "grammar concept IDs must be unique",
    )
    require(
        all(
            row["jlpt_level"] == "N5"
            and row["pattern"]
            and row["meaning"]
            and row["review_status"] == "draft"
            for row in grammar
        ),
        "grammar seed rows have invalid required fields",
    )

    require(
        len(book_vocabulary) == 700,
        "expected 700 photographed-book vocabulary candidates",
    )
    require(
        len({row["expression"] for row in book_vocabulary})
        == len(book_vocabulary),
        "book vocabulary expressions must be unique",
    )
    require(
        all(row["review_status"] == "needs_review" for row in book_vocabulary),
        "book vocabulary must remain outside the denominator until reviewed",
    )
    require(
        {int(row["source_page"]) for row in book_vocabulary}
        <= set(range(120, 127)),
        "book vocabulary source pages must be between 120 and 126",
    )

    require(
        len(book_grammar) == 89,
        "expected 89 photographed-book grammar candidates",
    )
    require(
        len({row["pattern"] for row in book_grammar}) == len(book_grammar),
        "book grammar patterns must be unique",
    )
    require(
        {int(row["source_page"]) for row in book_grammar}
        <= {108, 109, 110, 111},
        "book grammar source pages must be between 108 and 111",
    )
    require(
        {"〜てもいい", "疑問詞＋も〜ない", "連体修飾"}
        <= {row["pattern"] for row in book_grammar},
        "manually verified grammar corrections are missing",
    )

    print("Catalog validation passed")
    print(
        "vocabulary=684 grammar=77 "
        "book_vocabulary_candidates=700 book_grammar_candidates=89"
    )


if __name__ == "__main__":
    main()
