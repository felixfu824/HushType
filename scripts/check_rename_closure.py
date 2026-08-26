#!/usr/bin/env python3
"""Fail when an unapproved HushType residue survives the Lamitype rename."""

from __future__ import annotations

import argparse
import fnmatch
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parents[1]
RESIDUE = re.compile(r"hushtype", re.IGNORECASE)


@dataclass(frozen=True)
class Rule:
    name: str
    file_pattern: str
    content_pattern: str
    expected: int


# Rules match content spans, never whole rg-style output lines. Counts are
# frozen so removing one intended survivor cannot mask adding another.
RULES = [
    Rule("swiftpm product", "Makefile", r"PRODUCT_NAME = HushType", 1),
    Rule("module source paths", "Makefile", r"Sources/HushType", 1),
    Rule("transition kill", "Makefile", r"killall HushType", 2),
    Rule("transition app removal", "Makefile", r"/Applications/HushType\.app", 2),
    Rule("transition clean", "Makefile", r"HushType\.(?:app|dmg)", 4),
    Rule("transition status copy", "Makefile", r"Uninstalled HushType and Lamitype", 1),
    Rule("stable signing identifiers", "Makefile", r"com\.felix\.hushtype(?:\.[A-Za-z0-9.$$()\"-]+)?", 6),
    Rule("module imports", "Tests/HushTypeTests/*.swift", r"@testable import HushType", 17),
    Rule("module source references", "Tests/HushTypeTests/*.swift", r"Sources/HushType", 5),
    Rule("migration fixture old root", "Tests/HushTypeTests/AppSupportMigrationTests.swift", r'appendingPathComponent\("HushType"', 1),
    Rule("coexistence fixture old app", "Tests/HushTypeTests/CoexistenceGuardTests.swift", r"/Applications/HushType\.app", 1),
    Rule("stable test defaults", "Tests/HushTypeTests/*.swift", r'"hushtype\.[A-Za-z0-9.]+"', 34),
    Rule("stable test source fixture", "Tests/HushTypeTests/LocalizationMenuTests.swift", r'hushtype\.liveCaption\.panelFrame\.v3', 1),
    Rule("stable test bundle identifiers", "Tests/HushTypeTests/*.swift", r"com\.felix\.hushtype(?:\.fixture)?", 2),
    Rule("module script references", "scripts/*", r"Sources/HushType", 7),
    Rule("script logger subsystem", "scripts/*.swift", r'com\.felix\.hushtype', 1),
    Rule("bundle identifier", "Resources/Info.plist", r"com\.felix\.hushtype", 1),
    Rule("catalog module paths", "Resources/LOCALIZATION_MANIFEST_zh-Hant-TW.json", r"Sources/HushType", 413),
    Rule("source logger subsystems", "Sources/HushType/*.swift", r'com\.felix\.hushtype', 45),
    Rule("stable defaults", "Sources/HushType/AppConfig.swift", r"hushtype\.[A-Za-z0-9.]+", 22),
    Rule("localization default comment", "Sources/HushType/Localization.swift", r"hushtype\.interfaceLanguage", 1),
    Rule("stable usage keys", "Sources/HushType/CloudUsageTracker.swift", r'hushtype\.cloud\.[A-Za-z0-9.<>-]+', 6),
    Rule("stable caption frame keys", "Sources/HushType/LiveCaptionWindow.swift", r'"hushtype\.liveCaption\.panelFrame(?:\.v[23])?"', 3),
    Rule("stable cloud cap identifier", "Sources/HushType/AppDelegate.swift", r'hushtype-cloud-cap-', 1),
    Rule("dispatch system audio label", "Sources/HushType/SystemAudioSource.swift", r'"hushtype\.systemAudio\.io"', 1),
    Rule("dispatch backend label", "Sources/HushType/OpenAITranslateBackend.swift", r'"hushtype\.openaiBackend\.state"', 1),
    Rule("dispatch reachability label", "Sources/HushType/OpenAITranscribeEngine.swift", r'"hushtype\.cloudDictation\.reachability"', 1),
    Rule("dispatch caption label", "Sources/HushType/LiveCaptionManager.swift", r'"hushtype\.liveCaption\.postProcessing"', 1),
    Rule("multipart boundary", "Sources/HushType/OpenAITranscribeEngine.swift", r'"HushTypeBoundary-', 1),
    Rule("legacy migration literal", "Sources/HushType/AppSupportMigration.swift", r'appendingPathComponent\("HushType"', 1),
    Rule("legacy repo redirect comment", "Sources/HushType/VersionChecker.swift", r"felixfu824/HushType", 1),
    Rule("coexistence continuity copy", "Sources/HushType/CoexistenceGuard.swift", r"(?:Lamitype and HushType cannot run together|old HushType\.app)", 2),
    Rule("old TCC repair fallback", "Sources/HushType/OnboardingManager.swift", r"(?:Reset Old HushType Entry\?|This clears HushType[^\n]+)", 2),
    Rule("old TCC setup fallback", "Sources/HushType/OnboardingSetupWindowController.swift", r"(?:Reset Old HushType Entry|Use reset if you installed HushType[^\n]+)", 2),
    Rule("old TCC repair copy en", "Sources/HushType/Resources/en.lproj/Localizable.strings", r'"(?:permission\.accessibility\.(?:reset_old|reset_help)|alert\.accessibility_reset\.(?:title|message))" = "[^"\n]*HushType[^"\n]*(?:\\n[^"\n]*)?"', 4),
    Rule("old TCC repair copy zh", "Sources/HushType/Resources/zh-Hant-TW.lproj/Localizable.strings", r'"(?:permission\.accessibility\.(?:reset_old|reset_help)|alert\.accessibility_reset\.(?:title|message))" = "[^"\n]*HushType[^"\n]*(?:\\n[^"\n]*)?"', 4),
    Rule("catalog old TCC repair entries", "Resources/LOCALIZATION_MANIFEST_zh-Hant-TW.json", r'\{"table":"Localizable","key":"(?:permission\.accessibility\.(?:reset_old|reset_help)|alert\.accessibility_reset\.(?:title|message))"[^\n]+', 4),
    Rule("readme stable defaults", "README*.md", r"(?:com\.felix\.hushtype|hushtype\.[A-Za-z0-9.]+|com\.yourname\.hushtype|group\.com\.yourname\.hushtype)", 53),
    Rule("readme continuity", "README*.md", r"[^\n]*(?:formerly HushType|old HushType|舊 HushType|Reset Old HushType|/Applications/HushType\.app)[^\n]*", 6),
    Rule("readme iOS companion", "README*.md", r"[^\n]*(?:HushType keyboard|HushType 鍵盤|HushType KB|Open HushType|開啟 HushType|HushType app|HushType App|\*\*HushType\*\*|Keyboards > HushType)[^\n]*", 24),
]


def scoped_files() -> list[pathlib.Path]:
    paths: set[pathlib.Path] = {ROOT / "Makefile", ROOT / "README.md", ROOT / "README.en.md"}
    for directory in ("Sources", "Tests", "Resources", "scripts"):
        paths.update(
            path
            for path in (ROOT / directory).rglob("*")
            if path.is_file() and path != pathlib.Path(__file__).resolve()
        )
    return sorted(paths)


def relative(path: pathlib.Path) -> str:
    return path.relative_to(ROOT).as_posix()


def read_text(path: pathlib.Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None


def filename_gate(errors: list[str]) -> None:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    survivors = []
    for raw in result.stdout.splitlines():
        path = ROOT / raw
        if not path.exists() or not RESIDUE.search(raw):
            continue
        if raw.startswith(("Sources/HushType/", "Tests/HushTypeTests/", "iOS/")):
            continue
        survivors.append(raw)
    if survivors:
        errors.append("branded filenames remain: " + ", ".join(survivors))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", action="store_true")
    args = parser.parse_args()

    texts: dict[str, str] = {}
    residue_spans: dict[str, list[tuple[int, int]]] = {}
    for path in scoped_files():
        text = read_text(path)
        if text is None:
            continue
        name = relative(path)
        texts[name] = text
        residue_spans[name] = [(match.start(), match.end()) for match in RESIDUE.finditer(text)]

    covered: dict[str, set[int]] = {name: set() for name in texts}
    errors: list[str] = []
    inventory: list[tuple[str, int]] = []
    for rule in RULES:
        regex = re.compile(rule.content_pattern, re.MULTILINE)
        count = 0
        for name, text in texts.items():
            if not fnmatch.fnmatch(name, rule.file_pattern):
                continue
            for allowed in regex.finditer(text):
                count += 1
                for index, residue in enumerate(residue_spans[name]):
                    if allowed.start() <= residue[0] and residue[1] <= allowed.end():
                        covered[name].add(index)
        inventory.append((rule.name, count))
        if rule.expected >= 0 and count != rule.expected:
            errors.append(f"{rule.name}: expected {rule.expected}, found {count}")

    for name, spans in residue_spans.items():
        text = texts[name]
        for index, (start, end) in enumerate(spans):
            if index in covered[name]:
                continue
            line = text.count("\n", 0, start) + 1
            context_start = text.rfind("\n", 0, start) + 1
            context_end = text.find("\n", end)
            if context_end < 0:
                context_end = len(text)
            errors.append(f"unapproved residue {name}:{line}: {text[context_start:context_end]}")

    filename_gate(errors)

    if args.inventory:
        for name, count in inventory:
            print(f"{count:4}  {name}")
    if errors:
        print("rename closure FAILED:")
        for error in errors:
            print(" -", error)
        return 1
    print("rename closure OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
