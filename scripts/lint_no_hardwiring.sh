#!/usr/bin/env bash
set -euo pipefail

run_self_test=0
if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test=1
  base=""
else
  base="${1:-${HARDWIRING_BASE_SHA:-}}"
fi
if [[ $run_self_test -eq 0 && -z "$base" ]]; then
  echo "usage: $0 BASE_COMMIT (or set HARDWIRING_BASE_SHA)" >&2
  exit 2
fi
if [[ $run_self_test -eq 0 ]] && ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  git fetch --no-tags --depth=1 origin "$base"
fi
if [[ $run_self_test -eq 0 ]] && ! git merge-base "$base" HEAD >/dev/null 2>&1; then
  echo "The hardwiring lint base must share history with HEAD; fetch the base branch history before running." >&2
  exit 2
fi

python3 - "$base" "$run_self_test" <<'PY'
import re
import hashlib
import subprocess
import sys
from pathlib import Path

base, run_self_test = sys.argv[1], sys.argv[2] == "1"
roots = (
    "host-mac/RemoteDesktopHost/Agent/",
    "host-mac/RemoteDesktopHost/ComputerUse/",
    "host-mac/RemoteDesktopHost/LocalModel/",
)
terms = {
    "gmail": r"gmail",
    "mail.google": r"mail\.google",
    "drive.google": r"drive\.google",
    "dropbox": r"dropbox",
    "doordash": r"doordash",
    "kayak": r"kayak",
    "flight": r"flight",
    "calculator": r"calculator",
    "compose": r"compose",
    "bart": r"bart",
    "board review": r"board\s+review",
    "textedit": r"textedit",
    "finder": r"finder",
}
patterns = {name: re.compile(r"(?<![A-Za-z0-9_])" + pattern + r"(?![A-Za-z0-9_])", re.I)
            for name, pattern in terms.items()}


def changed_lines(diff: str) -> dict[str, set[int]]:
    result: dict[str, set[int]] = {}
    path = None
    current = 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
            result.setdefault(path, set())
        elif line.startswith("@@"):
            match = re.search(r"\+(\d+)(?:,(\d+))?", line)
            current = int(match.group(1)) if match else 0
        elif line.startswith("+") and not line.startswith("+++"):
            if path is not None:
                result[path].add(current)
                current += 1
        elif line.startswith(" "):
            current += 1
    return result


def swift_string_lines(source: str) -> dict[int, str]:
    """Return only Swift string-literal text, skipping comments and code."""
    found: dict[int, list[str]] = {}
    i, line, n = 0, 1, len(source)
    while i < n:
        if source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
            continue
        if source.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if source[i] == "\n": line += 1
                    i += 1
            continue
        start = i
        while i < n and source[i] == "#": i += 1
        hashes = i - start
        if i < n and source[i] == '"':
            multiline = source.startswith('"""', i)
            quote = '"""' if multiline else '"'
            closing = quote + "#" * hashes
            i += len(quote)
            escaped = False
            while i < n:
                if not escaped and source.startswith(closing, i):
                    i += len(closing)
                    break
                char = source[i]
                if char == "\n":
                    line += 1
                else:
                    found.setdefault(line, []).append(char)
                if hashes == 0 and char == "\\" and not escaped:
                    escaped = True
                else:
                    escaped = False
                i += 1
            continue
        if source[start] == "\n": line += 1
        i = start + 1
    return {number: "".join(chars) for number, chars in found.items()}


def approved_catalog_value(path: str, line: str, term: str) -> bool:
    if path != "host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift":
        return False
    if term == "calculator":
        # Only the reviewed Apple-signed catalog identity, never routing text.
        return line.strip() in {
            'canonicalName: "Calculator",',
            'aliases: ["Calculator"],',
            'bundleIdentifiers: ["com.apple.calculator"]),',
        }
    if term not in {"finder", "textedit"}:
        return False
    return bool(re.match(r"\s*(?:canonicalName|aliases|bundleIdentifiers)\s*:", line))


# These exact legacy literal fragments predate the lint and are not new routing.
# Pin the complete extracted literal text so edits or copied strings are scanned.
PINNED_LEGACY_LITERALS = {
    ("host-mac/RemoteDesktopHost/ComputerUse/ComputerUseFaraModel.swift", "finder"):
        "703d6a66c317ba16a5189b858feae46ceab7a9a298a8930777569f8a8ab6b6b6",
    ("host-mac/RemoteDesktopHost/ComputerUse/ComputerUseFaraModel.swift", "flight"):
        "098093089eecf1a7889ed3060c3f761fc528314c4c5e4c5c613ed74fbbb32cc0",
}


def approved_pinned_literal(path: str, value: str, term: str) -> bool:
    expected = PINNED_LEGACY_LITERALS.get((path, term))
    return expected is not None and hashlib.sha256(value.encode("utf-8")).hexdigest() == expected


def violations(path: str, source: str, lines: set[int]) -> list[tuple[int, str]]:
    literals = swift_string_lines(source)
    result = []
    source_lines = source.splitlines()
    for number in sorted(lines):
        value = literals.get(number, "")
        for term, pattern in patterns.items():
            if pattern.search(value) and not approved_catalog_value(path, source_lines[number - 1], term) \
                    and not approved_pinned_literal(path, value, term):
                result.append((number, term))
    return result


def self_test() -> None:
    code = '''
let prompt = "Find a flight to Lisbon"
let route = #"https://mail.google.test"#
let many = """The board review task"""
let namedApp = "Finder"
let inFlight = true
// "Gmail" and "Dropbox" are comments
'''
    lines = set(range(1, len(code.splitlines()) + 1))
    got = violations("host-mac/RemoteDesktopHost/ComputerUse/Example.swift", code, lines)
    if {(term) for _, term in got} != {"flight", "mail.google", "board review", "finder"}:
        raise SystemExit(f"hardwiring scanner self-test failed: {got}")
    catalog = 'canonicalName: "Finder"\naliases: ["Gmail"]'
    got = violations("host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift",
                     catalog, {1, 2})
    if got != [(2, "gmail")]:
        raise SystemExit(f"catalog exception self-test failed: {got}")
    path = "host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift"
    assert approved_catalog_value(path, 'canonicalName: "Calculator",', "calculator")
    assert approved_catalog_value(path, 'aliases: ["Calculator"],', "calculator")
    assert approved_catalog_value(path, 'bundleIdentifiers: ["com.apple.calculator"]),', "calculator")
    assert not approved_catalog_value(path, 'let route = "Calculator"', "calculator")
    assert not approved_catalog_value(path, 'aliases: ["Calculator", "Other"],', "calculator")
    path = "host-mac/RemoteDesktopHost/ComputerUse/ComputerUseFaraModel.swift"
    source = Path(path).read_text(encoding="utf-8")
    literals = swift_string_lines(source)
    for (exception_path, term), _ in PINNED_LEGACY_LITERALS.items():
        candidates = [value for value in literals.values() if patterns[term].search(value)]
        if exception_path != path or not any(approved_pinned_literal(path, value, term) for value in candidates):
            raise SystemExit(f"pinned legacy literal exception self-test failed: {term}")
        approved = next(value for value in candidates if approved_pinned_literal(path, value, term))
        if approved_pinned_literal(path, approved + " changed", term):
            raise SystemExit(f"pinned legacy literal mutation self-test failed: {term}")
    print("hardwiring scanner self-test passed")


if run_self_test:
    self_test()
    sys.exit(0)

diff = subprocess.check_output(
    ["git", "diff", "--no-ext-diff", "--unified=0", f"{base}...HEAD", "--",
     *roots], text=True)
changed = changed_lines(diff)
problems = []
for path, numbers in changed.items():
    if not path.endswith(".swift") or not numbers:
        continue
    source = Path(path).read_text(encoding="utf-8")
    problems.extend((path, line, term) for line, term in violations(path, source, numbers))
if problems:
    print("Task-, site-, or app-specific routing literals were added to shipping Swift:", file=sys.stderr)
    for path, line, term in problems:
        print(f"{path}:{line}: {term}", file=sys.stderr)
    sys.exit(1)
print(f"No denied hardwiring literals in {sum(bool(v) for v in changed.values())} changed production Swift file(s).")
PY
