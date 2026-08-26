#!/usr/bin/env bash
# Interface-localization gate (macOS Phase 1, zh-Hant-TW).
#
# Validates the Apple-standard .strings / .stringsdict resource pipeline for
# both the source of truth and the built app bundle:
#
#   scripts/check_localizations.sh --source-manifest <out.json>
#     Validate Sources/HushType/Resources: exactly en.lproj + zh-Hant-TW.lproj
#     (stale/unknown locale dirs are rejected), all five required tables,
#     plutil lint, en/zh-Hant-TW key parity, recursive format signatures
#     (including .stringsdict variants), and cross-check every key against the
#     frozen Gate B manifest (table, English value, placeholders). Emits the
#     semantic manifest (parsed key sets, values, plural variants, recursive
#     format signatures) to <out.json> for destination comparison.
#
#   scripts/check_localizations.sh --dest <Contents/Resources dir> \
#       --source-manifest <source.json>
#     Validate the built bundle the same way (against its own .lproj dirs)
#     and require the semantic manifest to equal the source manifest.
#
# Any failure is fatal (set -e; no `|| true`). Stale output in a previous
# bundle can never mask missing or malformed source resources: the Makefile
# removes the exact destination locale dirs before copying, and the
# destination manifest must equal the source manifest.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/Sources/HushType/Resources"
DEST=""
SRC_MANIFEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-manifest) SRC_MANIFEST="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SRC_MANIFEST" ]]; then
  echo "error: --source-manifest is required" >&2
  exit 2
fi

if [[ -n "$DEST" ]]; then
  TARGET="$DEST"
  MODE="dest"
else
  TARGET="$SRC"
  MODE="source"
fi

python3 - "$MODE" "$TARGET" "$SRC_MANIFEST" "$ROOT/Resources/LOCALIZATION_MANIFEST_zh-Hant-TW.json" <<'PYEOF'
import json
import pathlib
import plistlib
import re
import subprocess
import sys

mode, target, manifest_path, catalog_path = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4])
base = pathlib.Path(target)
errors = []

LOCALES = ["en", "zh-Hant-TW"]
TABLES = ["Localizable", "Localizable.stringsdict", "Templates", "InfoPlist", "ServicesMenu"]


def table_file(table):
    # Table names double as filenames: "Localizable" -> Localizable.strings,
    # "Localizable.stringsdict" -> Localizable.stringsdict (no double ext).
    return table if table.endswith("stringsdict") else f"{table}.strings"


def table_kind(table):
    return "stringsdict" if table.endswith("stringsdict") else "strings"


def fail(msg):
    errors.append(msg)


# ---- C-format signature -------------------------------------------------
def sig(s):
    """Ordered list of conversion tokens; %% -> ['%%'], %1$@ -> [1,'@']."""
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "%":
            j = i + 1
            if j < n and s[j] == "%":
                out.append(["%%"])
                i = j + 1
                continue
            pos = None
            m = re.match(r"(\d+)\$", s[j:])
            if m:
                pos = int(m.group(1))
                j += m.end()
            spec = re.match(r"([-+ #0]*)[0-9]*(\.[0-9]+)?([lhqt])*([@dDiIoOuUxXfFeEgGaAcsp])", s[j:])
            if not spec:
                raise ValueError(f"bad conversion in {s!r}")
            out.append([pos, spec.group(4)])
            i = j + spec.end()
        else:
            i += 1
    return out


def norm(items):
    def one(x):
        return [0, x[0]] if len(x) == 1 else [(x[0] or 0), x[1]]
    return sorted(map(one, items))


# ---- file parsing -------------------------------------------------------
def plutil_lint(path):
    r = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
    return r.returncode == 0


def parse_strings(path):
    r = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError:
        return None


def parse_stringsdict(path):
    try:
        with open(path, "rb") as f:
            top = plistlib.load(f)
    except Exception:
        return None
    return top if isinstance(top, dict) else None


# ---- structural checks --------------------------------------------------
lproj_dirs = sorted(p.name for p in base.iterdir() if p.is_dir() and p.name.endswith(".lproj")) if base.is_dir() else []
expected_dirs = sorted(f"{t}.lproj" for t in LOCALES)
if lproj_dirs != expected_dirs:
    fail(f"locale dirs must be exactly {expected_dirs}; found {lproj_dirs} (stale/extra/missing .lproj rejected)")

manifest = {"locales": LOCALES, "tables": {}}
for table in TABLES:
    kind = table_kind(table)
    manifest["tables"][table] = {}
    for locale in LOCALES:
        f = base / f"{locale}.lproj" / table_file(table)
        if not f.is_file():
            fail(f"missing required table: {f}")
            manifest["tables"][table][locale] = None
            continue
        if not plutil_lint(f):
            fail(f"lint failed: {f}")
            manifest["tables"][table][locale] = None
            continue
        data = parse_stringsdict(f) if kind == "stringsdict" else parse_strings(f)
        if data is None:
            fail(f"unparseable: {f}")
            manifest["tables"][table][locale] = None
            continue
        manifest["tables"][table][locale] = data

# ---- locale parity + recursive signatures -------------------------------
for table in TABLES:
    en = manifest["tables"][table].get("en")
    zh = manifest["tables"][table].get("zh-Hant-TW")
    if not isinstance(en, dict) or not isinstance(zh, dict):
        continue
    en_keys, zh_keys = set(en), set(zh)
    if en_keys != zh_keys:
        fail(f"{table}: key parity mismatch; en-only={sorted(en_keys - zh_keys)} zh-only={sorted(zh_keys - en_keys)}")
    for key in sorted(en_keys & zh_keys):
        if table.endswith("stringsdict"):
            en_node, zh_node = en[key], zh[key]
            en_c = en_node.get("count") if isinstance(en_node, dict) else None
            zh_c = zh_node.get("count") if isinstance(zh_node, dict) else None
            if not isinstance(en_c, dict) or not isinstance(zh_c, dict):
                fail(f"{table}[{key}]: malformed plural node (count dict required)")
                continue
            if "other" not in en_c or "other" not in zh_c:
                fail(f"{table}[{key}]: 'other' variant required in both locales")
                continue
            for variant in ("one", "other"):
                if variant in en_c and variant in zh_c:
                    try:
                        a, b = norm(sig(en_c[variant])), norm(sig(zh_c[variant]))
                    except ValueError as e:
                        fail(f"{table}[{key}] {variant}: {e}")
                        continue
                    if a != b:
                        fail(f"{table}[{key}] {variant}: signature mismatch en={en_c[variant]!r} zh={zh_c[variant]!r}")
            if "one" in en_c and "one" not in zh_c:
                # zh may collapse to invariant 'other'; its signature must
                # still match the English variant it replaces.
                try:
                    if norm(sig(en_c["one"])) != norm(sig(zh_c["other"])):
                        fail(f"{table}[{key}]: collapsed zh 'other' signature differs from en 'one'")
                except ValueError as e:
                    fail(f"{table}[{key}]: {e}")
        else:
            try:
                a, b = norm(sig(en[key])), norm(sig(zh[key]))
            except ValueError as e:
                fail(f"{table}[{key}]: {e}")
                continue
            if a != b:
                fail(f"{table}[{key}]: signature mismatch en={en[key]!r} zh={zh[key]!r}")

# ---- cross-check against the frozen Gate B catalog -----------------------
catalog = json.load(open(catalog_path, encoding="utf-8"))
catalog_entries = {(e["table"], e["key"]): e for e in catalog["entries"]}

def catalog_value(e, locale):
    v = e["english"] if locale == "en" else e["zh-Hant-TW"]
    if isinstance(v, dict):
        return v
    # TRANSLATION_DECISIONS_zh-Hant-TW.md overlay: wins over the frozen
    # catalog ONLY for the named entries (D2-D6).
    t, k = e["table"], e["key"]
    D2 = ("Localizable", k) in {
        ("Localizable", "caption.accessibility.session_cost"),
        ("Localizable", "alert.caption.connection_lost.title"),
        ("Localizable", "alert.caption.cloud_start_failed.title"),
        ("Localizable", "alert.cloud_caption_disclosure.title"),
    }
    if D2:
        v = v.replace("Cloud Live Caption", "Live Translated Caption")
        v = v.replace("雲端即時字幕", "即時翻譯字幕")
    if (t, k) == ("Localizable", "notification.caption.auto_stop.title"):  # D3
        v = "Live Translated Caption auto-stopped" if locale == "en" else "即時翻譯字幕已自動停止"
    if (t, k) == ("Templates", "template.openai.overview"):  # D5
        v = v.replace("Live Caption Engine settings", "Translated Caption Settings")
        v = v.replace("即時字幕引擎設定", "翻譯字幕設定")
    if (t, k) == ("Templates", "template.live_caption.backpressure"):  # D6
        v = v.replace("a cold first-cold transcribe", "the first cold transcription")
    return v


def contains_long_dash(value):
    if isinstance(value, str):
        return "\u2013" in value or "\u2014" in value
    if isinstance(value, dict):
        return any(contains_long_dash(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_long_dash(item) for item in value)
    return False


# The Settings revamp deliberately standardized punctuation in the two
# Localizable catalogs. Keep this invariant in the ordinary l10n gate so a
# future manifest edit cannot silently reintroduce either long-dash codepoint.
for table in ("Localizable", "Localizable.stringsdict"):
    for locale in LOCALES:
        value = manifest["tables"][table].get(locale)
        if contains_long_dash(value):
            fail(f"{table} {locale}: U+2013/U+2014 long dash is forbidden")

for (table, key), e in catalog_entries.items():
    got_en = manifest["tables"][table]["en"].get(key) if isinstance(manifest["tables"][table].get("en"), dict) else None
    got_zh = manifest["tables"][table]["zh-Hant-TW"].get(key) if isinstance(manifest["tables"][table].get("zh-Hant-TW"), dict) else None
    for locale, got in (("en", got_en), ("zh-Hant-TW", got_zh)):
        want = catalog_value(e, locale)
        if table.endswith("stringsdict"):
            # Catalog stores variant objects directly; resources wrap them in
            # a count node with the Int/'l' spec keys.
            want_c = want if isinstance(want, dict) else None
            got_c = got.get("count") if isinstance(got, dict) else None
            if not isinstance(want_c, dict) or not isinstance(got_c, dict):
                fail(f"catalog {table}[{key}] {locale}: variant object expected")
                continue
            want_full = dict(want_c)
            want_full["NSStringFormatSpecTypeKey"] = "NSStringFormatSpecTypeInt"
            want_full["NSStringFormatValueTypeKey"] = "l"
            if want_full != got_c:
                fail(f"catalog {table}[{key}] {locale}: plural variants differ from resources\n  catalog={json.dumps(want_c, ensure_ascii=False, sort_keys=True)}\n  resource={json.dumps(got_c, ensure_ascii=False, sort_keys=True)}")
        else:
            if got != want:
                fail(f"catalog {table}[{key}] {locale}: value differs from resources\n  catalog={want!r}\n  resource={got!r}")

# ---- stale-key detection: resource keys not in catalog --------------------
for table in TABLES:
    got = manifest["tables"][table].get("en")
    if not isinstance(got, dict):
        continue
    for key in got:
        if (table, key) not in catalog_entries:
            fail(f"stale resource key not in frozen catalog: {table}[{key}]")

# ---- emit / compare semantic manifest ------------------------------------
serialized = json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=1)
if mode == "source":
    pathlib.Path(manifest_path).write_text(serialized + "\n", encoding="utf-8")
else:
    prev = pathlib.Path(manifest_path).read_text(encoding="utf-8")
    if prev != serialized + "\n" and prev != serialized:
        fail("destination semantic manifest differs from source manifest (stale or divergent bundle resources)")

if errors:
    print("localization validation FAILED:")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print(f"localization validation OK ({mode}: {base})")
PYEOF
