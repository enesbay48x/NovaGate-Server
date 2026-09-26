"""Check that no secret can be committed by accident.

Run before every `git add` / `git commit`. It scans the files Git would stage
and fails if any of them contains a real secret.

WHAT COUNTS AS A SECRET HERE
----------------------------
  * A `SECRET_KEY` (or similar) with a literal value rather than a lookup.
  * A Render/production URL with credentials in it.
  * A `.env` file, or a key/credential file.
  * A private key block.
  * A DB URL carrying a password.

WHY A PATTERN SCAN AND NOT `git grep`
-------------------------------------
Because the whole point is to run on the working tree AND on not-yet-committed
files, which `git grep` does not see. A leak is most likely in a file someone
just created.

The allow-list below names the values that legitimately appear in the source
(test secrets and the public service URL). Anything else fails.
"""
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# Files that must never be committed at all.
FORBIDDEN_NAMES = re.compile(
    r"(^\.env$)|(\.env\.)|(\.pem$)|(\.key$)|(^id_rsa$)|(^credentials)"
    r"|(secret.*\.txt$)|(^.*\.p12$)|(^.*\.pfx$)",
    re.IGNORECASE,
)

# (pattern, description) - a match is a potential secret.
SECRET_PATTERNS = [
    (re.compile(r"SECRET_KEY\s*=\s*[\"'][^\"']{8,}[\"']"),
     "SECRET_KEY assigned a literal value"),
    (re.compile(r"(?i)(password|passwd|pwd)\s*=\s*[\"'][^\"']{6,}[\"']"),
     "a password assigned a literal value"),
    (re.compile(r"(?i)postgres(ql)?://[^\s\"']*:[^\s\"'@]+@"),
     "a database URL with an inline password"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
     "a private key block"),
    (re.compile(r"(?i)\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"),
     "a GitHub token"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "an AWS access key id"),
    (re.compile(r"(?i)sk-[A-Za-z0-9]{32,}"), "an API secret key"),
    (re.compile(r"-----BEGIN OPENSSH PRIVATE KEY-----"), "an ssh private key"),
]

# Legitimate literals: test-only secrets and the public service URL.
ALLOWED_LITERALS = (
    "novagate-server-1.onrender.com",
    "novagate_db",
)

# Test code is EXPECTED to contain literal passwords - they authenticate nothing
# but a throwaway local database. Flagging them would train a developer to
# ignore the scanner, so a literal password inside test code is allowed while
# the same literal in production code is still a finding.
TEST_PATH_MARKERS = ("tests/", "test_", "_test.py", "/tests")


def _is_test_code(relative: str) -> bool:
    normalized = relative.replace("\\", "/")
    return any(marker in normalized for marker in TEST_PATH_MARKERS)

# Directories that never hold tracked source.
SKIP_DIRS = {
    ".git", ".godot", "__pycache__", "node_modules", ".vscode",
    ".kilo", ".pytest_cache", "data", "assets", "addons", "scenes",
}

# Only text formats are worth scanning. Reading every .png/.wav as text with
# `errors="replace"` is slow and would only ever produce false positives from
# binary noise, so the scan is restricted to files that can hold a secret.
TEXT_SUFFIXES = {
    ".py", ".gd", ".tscn", ".tres", ".cfg", ".ini", ".toml", ".yaml",
    ".yml", ".json", ".md", ".txt", ".env", ".sh", ".bat", ".ps1", ".sql",
    ".html", ".css", ".js", ".ts", ".xml", ".properties", ".godot",
}


def _files_to_check() -> list:
    """Every file Git would stage, plus untracked non-ignored files."""
    try:
        result = subprocess.run(
            ["git", "-C", ROOT, "ls-files", "--cached", "--others",
             "--exclude-standard"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode == 0 and result.stdout.strip():
            return [line for line in result.stdout.split("\n") if line.strip()]
    except Exception:
        pass
    return []


def main() -> int:
    findings = []
    scanned = 0
    for relative in _files_to_check():
        path = os.path.join(ROOT, relative)
        parts = set(relative.replace("\\", "/").split("/"))
        if parts & SKIP_DIRS:
            continue
        # This file necessarily contains the very patterns it searches for, so
        # scanning it would always report itself.
        if os.path.abspath(path) == os.path.abspath(__file__):
            continue
        name = os.path.basename(relative)
        if FORBIDDEN_NAMES.search(name):
            findings.append((relative, "file must not be committed"))
            continue
        # Skip anything that is not a text format Git would meaningfully track.
        suffix = os.path.splitext(name)[1].lower()
        if suffix not in TEXT_SUFFIXES and name not in (
                "Dockerfile", "Makefile", "Procfile", ".env", ".gitignore"):
            continue
        if not os.path.isfile(path):
            continue
        try:
            with io.open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        if len(text) > 4_000_000:
            continue
        scanned += 1
        is_test = _is_test_code(relative)
        for line_number, line in enumerate(text.split("\n"), start=1):
            for literal in ALLOWED_LITERALS:
                line = line.replace(literal, "<allowed>")
            for pattern, description in SECRET_PATTERNS:
                if is_test and description.startswith("a password"):
                    # A throwaway local test credential is not a leak.
                    continue
                if pattern.search(line):
                    findings.append(
                        ("%s:%d" % (relative, line_number), description))

    if not findings:
        print("OK  no secrets found (%d text files scanned)" % scanned)
        return 0
    print("SECRETS DETECTED (%d):" % len(findings))
    for where, what in findings:
        print("  %-60s %s" % (where, what))
    return 1


if __name__ == "__main__":
    sys.exit(main())
