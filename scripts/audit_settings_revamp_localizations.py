#!/usr/bin/env python3
"""Audit the unified Settings localization disposition contract.

The source of truth is the single 188-row inventory in section 6 of
GTM/UI_REVAMP_SPEC.md.  This gate deliberately validates the inventory as a
union, rather than maintaining a second hand-written list in the script.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
RESOURCE_ROOT = ROOT / "Sources/HushType/Resources"
MANIFEST_PATH = ROOT / "Product_WS/LOCALIZATION_MANIFEST_zh-Hant-TW.json"
LOCALES = ("en", "zh-Hant-TW")
ACTIVE_DISPOSITIONS = frozenset(("reuse", "retranslate", "new"))
ALL_DISPOSITIONS = frozenset((*ACTIVE_DISPOSITIONS, "retire"))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Audit the Settings revamp localization inventory."
    )
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--expected-total", required=True, type=int)
    parser.add_argument("--expected-reuse", required=True, type=int)
    parser.add_argument("--expected-retranslate", required=True, type=int)
    parser.add_argument("--expected-retire", required=True, type=int)
    parser.add_argument("--expected-new", required=True, type=int)
    return parser.parse_args()


def resolve_input(path: Path) -> Path:
    return path if path.is_absolute() else ROOT / path


def parse_inventory(path: Path) -> list[tuple[str, str]]:
    text = path.read_text(encoding="utf-8")
    try:
        section = text.split("**單一聯集盤點表**", 1)[1]
        section = section.split("**API 金鑰讀取器的真實輸出**", 1)[0]
    except IndexError as error:
        raise ValueError("cannot find the section 6 single-union inventory") from error

    rows = re.findall(
        r"^\| `([^`]+)` \| (reuse|retranslate|retire|new) \|",
        section,
        flags=re.MULTILINE,
    )
    if not rows:
        raise ValueError("section 6 inventory has no disposition rows")
    return rows


def parse_strings(path: Path) -> dict[str, str]:
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise ValueError(f"{path}: plutil failed: {result.stderr.strip()}")
    parsed = json.loads(result.stdout)
    if not isinstance(parsed, dict) or not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in parsed.items()
    ):
        raise ValueError(f"{path}: expected a string-to-string property list")
    return parsed


def parse_stringsdict(path: Path) -> dict[str, Any]:
    with path.open("rb") as stream:
        parsed = plistlib.load(stream)
    if not isinstance(parsed, dict):
        raise ValueError(f"{path}: expected a dictionary property list")
    return parsed


def plural_variants(node: Any) -> dict[str, str] | None:
    if not isinstance(node, dict):
        return None
    count = node.get("count")
    if not isinstance(count, dict):
        return None
    variants = {
        variant: value
        for variant, value in count.items()
        if variant not in {
            "NSStringFormatSpecTypeKey",
            "NSStringFormatValueTypeKey",
        }
    }
    if not variants or not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in variants.items()
    ):
        return None
    return variants


def load_catalogs() -> dict[str, dict[str, dict[str, Any]]]:
    catalogs: dict[str, dict[str, dict[str, Any]]] = {}
    for locale in LOCALES:
        locale_root = RESOURCE_ROOT / f"{locale}.lproj"
        catalogs[locale] = {
            "Localizable": parse_strings(locale_root / "Localizable.strings"),
            "Localizable.stringsdict": parse_stringsdict(
                locale_root / "Localizable.stringsdict"
            ),
        }
    return catalogs


def source_literals() -> tuple[str, list[Path]]:
    paths = sorted((ROOT / "Sources/HushType").rglob("*.swift"))
    return "\n".join(path.read_text(encoding="utf-8") for path in paths), paths


def main() -> int:
    args = parse_args()
    errors: list[str] = []

    try:
        inventory = parse_inventory(resolve_input(args.spec))
        catalogs = load_catalogs()
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        source_text, source_paths = source_literals()
    except (OSError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        print(f"settings localization audit FAILED:\n - {error}")
        return 1

    inventory_keys = [key for key, _ in inventory]
    duplicates = sorted(
        key for key, count in Counter(inventory_keys).items() if count != 1
    )
    if duplicates:
        errors.append(f"inventory keys must be unique; duplicates={duplicates}")

    dispositions = Counter(disposition for _, disposition in inventory)
    expected = {
        "reuse": args.expected_reuse,
        "retranslate": args.expected_retranslate,
        "retire": args.expected_retire,
        "new": args.expected_new,
    }
    if len(inventory) != args.expected_total:
        errors.append(
            f"inventory total is {len(inventory)}; expected {args.expected_total}"
        )
    if dict(dispositions) != expected:
        errors.append(
            f"disposition counts are {dict(dispositions)}; expected {expected}"
        )
    unknown = sorted(set(dispositions) - ALL_DISPOSITIONS)
    if unknown:
        errors.append(f"unknown dispositions: {unknown}")

    entries = manifest.get("entries") if isinstance(manifest, dict) else None
    if not isinstance(entries, list):
        errors.append("frozen manifest must contain an entries array")
        entries = []

    manifest_by_key: dict[str, list[dict[str, Any]]] = {}
    manifest_pairs: Counter[tuple[Any, Any]] = Counter()
    for entry in entries:
        if not isinstance(entry, dict):
            errors.append("frozen manifest contains a non-object entry")
            continue
        key = entry.get("key")
        table = entry.get("table")
        if isinstance(key, str):
            manifest_by_key.setdefault(key, []).append(entry)
        manifest_pairs[(table, key)] += 1
    duplicate_manifest_pairs = sorted(
        f"{table}[{key}]"
        for (table, key), count in manifest_pairs.items()
        if count != 1
    )
    if duplicate_manifest_pairs:
        errors.append(
            "frozen manifest has duplicate table/key entries: "
            + ", ".join(duplicate_manifest_pairs)
        )

    for key, disposition in inventory:
        locations: list[str] = []
        for table in ("Localizable", "Localizable.stringsdict"):
            if all(key in catalogs[locale][table] for locale in LOCALES):
                locations.append(table)
            elif any(key in catalogs[locale][table] for locale in LOCALES):
                errors.append(f"{key}: {table} is present in only one locale")

        source_pattern = re.compile(rf'"{re.escape(key)}"')
        has_source_literal = bool(source_pattern.search(source_text))
        manifest_entries = manifest_by_key.get(key, [])

        if disposition == "retire":
            if locations:
                errors.append(
                    f"{key}: retired key remains in catalog table(s) {locations}"
                )
            if manifest_entries:
                errors.append(f"{key}: retired key remains in frozen manifest")
            if has_source_literal:
                errors.append(f"{key}: retired key remains in Swift source")
            continue

        if len(locations) != 1:
            errors.append(
                f"{key}: active key must exist in exactly one table for both locales; "
                f"found {locations}"
            )
            continue
        table = locations[0]
        matching_manifest = [
            entry for entry in manifest_entries if entry.get("table") == table
        ]
        if len(matching_manifest) != 1 or len(manifest_entries) != 1:
            errors.append(
                f"{key}: expected one frozen-manifest entry in {table}; "
                f"found {[(entry.get('table'), entry.get('key')) for entry in manifest_entries]}"
            )
        else:
            entry = matching_manifest[0]
            for locale, field in (("en", "english"), ("zh-Hant-TW", "zh-Hant-TW")):
                resource_value = catalogs[locale][table][key]
                if table == "Localizable.stringsdict":
                    resource_value = plural_variants(resource_value)
                    if resource_value is None:
                        errors.append(
                            f"{key}: malformed {locale} stringsdict plural node"
                        )
                        continue
                if entry.get(field) != resource_value:
                    errors.append(
                        f"{key}: frozen manifest {field} differs from {locale} {table}; "
                        f"manifest={entry.get(field)!r} resource={resource_value!r}"
                    )

        if not has_source_literal:
            errors.append(
                f"{key}: {disposition} key has no exact string-literal call site "
                f"under Sources/HushType"
            )

    for locale in LOCALES:
        for filename in ("Localizable.strings", "Localizable.stringsdict"):
            path = RESOURCE_ROOT / f"{locale}.lproj" / filename
            text = path.read_text(encoding="utf-8")
            for character, name in (("\u2013", "U+2013"), ("\u2014", "U+2014")):
                if character in text:
                    errors.append(f"{path}: forbidden {name} remains")

    if errors:
        print("settings localization audit FAILED:")
        for error in errors:
            print(" -", error)
        return 1

    print(
        "settings localization audit OK "
        f"(total={len(inventory)}, reuse={dispositions['reuse']}, "
        f"retranslate={dispositions['retranslate']}, "
        f"retire={dispositions['retire']}, new={dispositions['new']}, "
        f"swift_files={len(source_paths)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
