from __future__ import annotations

import re
import subprocess
from pathlib import Path

PATTERNS = {
    "private-key": re.compile("BEGIN " + "(?:RSA |EC |OPENSSH )?PRIVATE KEY"),
    "github-token": re.compile("gh" + r"(?:p|o|u|s|r)_[A-Za-z0-9]{30,}"),
    "github-fine-grained-token": re.compile("github_" + r"pat_[A-Za-z0-9_]{50,}"),
    "huggingface-token": re.compile("h" + r"f_[A-Za-z0-9]{30,}"),
    "openai-token": re.compile("s" + r"k-[A-Za-z0-9_-]{30,}"),
    "aws-access-key": re.compile("AK" + r"IA[0-9A-Z]{16}"),
}
TEXT_SUFFIXES = {".py", ".ts", ".tsx", ".js", ".json", ".yaml", ".yml", ".toml", ".md", ".ps1", ".sh", ".env", ".txt"}


def main() -> None:
    names = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
    findings: list[str] = []
    for name in names:
        if not name:
            continue
        path = Path(name)
        if path.suffix.lower() not in TEXT_SUFFIXES and path.name != ".env":
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for label, pattern in PATTERNS.items():
            if pattern.search(text):
                findings.append(f"{name}: {label}")
    if findings:
        raise SystemExit("Potential committed secrets found:\n" + "\n".join(findings))
    print(f"secret-scan=passed files={len(names)}")


if __name__ == "__main__":
    main()

