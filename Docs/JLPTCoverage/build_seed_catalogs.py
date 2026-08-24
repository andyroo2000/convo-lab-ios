#!/usr/bin/env python3
"""Build the checked-in N5 seed catalogs from pinned, openly licensed sources."""

from __future__ import annotations

import csv
import hashlib
import io
import json
import subprocess
from pathlib import Path


WALLER_COMMIT = "b062d4e38c4bdd0950ae1d4ec55f04b176182e03"
GRAMMAR_COMMIT = "04014e06019fc9d4af76e6dbb64ec709fe863c4d"
WALLER_URL = (
    "https://raw.githubusercontent.com/stephenmk/yomitan-jlpt-vocab/"
    f"{WALLER_COMMIT}/original_data/n5.csv"
)
GRAMMAR_URL = (
    "https://raw.githubusercontent.com/jkindrix/japanese-language-data/"
    f"{GRAMMAR_COMMIT}/data/grammar/grammar.json"
)
GRAMMAR_PATTERN_CORRECTIONS = {
    "nanyoubi-day-of-week": "何曜日 / 曜日",
}


def fetch(url: str) -> str:
    return subprocess.run(
        ["curl", "-fsSL", url],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def write_vocabulary(output_directory: Path) -> int:
    source_rows = list(csv.DictReader(io.StringIO(fetch(WALLER_URL))))
    output_path = output_directory / "n5-vocabulary.csv"
    fieldnames = [
        "concept_id",
        "jlpt_level",
        "expression",
        "reading",
        "meaning",
        "source",
        "source_id",
        "review_status",
    ]
    with output_path.open("w", encoding="utf-8", newline="") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        for row in source_rows:
            expression = row["kanji"] or row["kana"]
            form_hash = hashlib.sha1(
                f"{expression}\0{row['kana']}".encode("utf-8")
            ).hexdigest()[:8]
            writer.writerow(
                {
                    "concept_id": f"n5-vocab-{row['jmdict_seq']}-{form_hash}",
                    "jlpt_level": "N5",
                    "expression": expression,
                    "reading": row["kana"],
                    "meaning": row["waller_definition"],
                    "source": "Jonathan Waller JLPT vocabulary list",
                    "source_id": row["jmdict_seq"],
                    "review_status": "seed",
                }
            )
    return len(source_rows)


def write_grammar(output_directory: Path) -> int:
    payload = json.loads(fetch(GRAMMAR_URL))
    source_rows = [
        row for row in payload["grammar_points"] if row["level"] == "N5"
    ]
    output_path = output_directory / "n5-grammar.csv"
    fieldnames = [
        "concept_id",
        "jlpt_level",
        "pattern",
        "meaning",
        "source",
        "source_id",
        "review_status",
    ]
    with output_path.open("w", encoding="utf-8", newline="") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        for row in source_rows:
            writer.writerow(
                {
                    "concept_id": f"n5-grammar-{row['id']}",
                    "jlpt_level": "N5",
                    "pattern": GRAMMAR_PATTERN_CORRECTIONS.get(
                        row["id"], row["pattern"]
                    ),
                    "meaning": row["meaning_en"],
                    "source": "Japanese Language Data",
                    "source_id": row["id"],
                    "review_status": row["review_status"],
                }
            )
    return len(source_rows)


def main() -> None:
    output_directory = Path(__file__).resolve().parent
    vocabulary_count = write_vocabulary(output_directory)
    grammar_count = write_grammar(output_directory)
    print(f"Wrote {vocabulary_count} vocabulary concepts")
    print(f"Wrote {grammar_count} grammar concepts")


if __name__ == "__main__":
    main()
