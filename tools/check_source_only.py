#!/usr/bin/env python3
"""Audit a public source tree, without printing any detected secret values."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


EXCLUDED_PREFIXES = (
    "data/", "build/", "converted/", "GameData/", ".agents/", ".codex/",
    "engine/siglus_rs/images/", "engine/siglus_rs/manual/",
    "engine/siglus_rs/crates/siglus_cfx_decompiler/reference_hlsl/",
)
EXCLUDED_FILES = {
    "engine/siglus_rs/define/shader.cfx",
    "engine/siglus_rs/crates/siglus_cfx_decompiler/assets/shader.cfx",
    "docs/CRASH-AUDIT.md", "docs/ENGINE-NOTES.md",
}
PRIVATE_NAMES = {"agents.md", "claude.md", "implementation_plan.md", "key.toml", ".team"}
FORBIDDEN_SUFFIXES = {
    ".metallib", ".gxp", ".pck", ".dat", ".g00", ".gan", ".ovk", ".nwa", ".wmv", ".omv",
    ".sav", ".dbs", ".tcc", ".cgm", ".exe", ".dll", ".ipa", ".zip",
    ".p12", ".pfx", ".pem", ".key", ".p8", ".cer", ".keystore",
    ".mobileprovision", ".provisionprofile", ".certsigningrequest",
}
SECRET_PATTERNS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"github_pat_[A-Za-z0-9_]{25,}"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(rb"AKIA[A-Z0-9]{16}"),
    re.compile(rb"sk-proj-[A-Za-z0-9_-]{30,}"),
)


def excluded(path):
    p = Path(path)
    return (path.startswith(EXCLUDED_PREFIXES) or path in EXCLUDED_FILES
            or p.name.lower() in PRIVATE_NAMES or p.name.startswith(".env")
            or p.suffix.lower() in FORBIDDEN_SUFFIXES)


def audit(root):
    root = Path(root).resolve()
    failures = []
    if (root / ".git").exists():
        names = subprocess.check_output(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root
        ).decode().split("\0")
        files = [root / name for name in sorted(set(names)) if name and (root / name).is_file()]
    else:
        files = [p for p in root.rglob("*") if p.is_file() and ".git" not in p.relative_to(root).parts]
    for file in files:
        name = file.relative_to(root).as_posix()
        if excluded(name):
            failures.append((name, "excluded game, private, or distribution file"))
        data = file.read_bytes()
        if any(pattern.search(data) for pattern in SECRET_PATTERNS):
            failures.append((name, "credential pattern"))
        if re.search(rb"0000[0-9A-F]{4}-[0-9A-F]{16}", data):
            failures.append((name, "physical device identifier"))
        if (re.search(rb"org\.local\.(?:clannad|eustia)\.[A-Z0-9]{10}", data)
                or re.search(rb"/Users/[A-Za-z0-9_-]+/", data)):
            failures.append((name, "local signing or workstation configuration"))
    font_dir = root / "engine/siglus_rs/crates/siglus_scene_vm/assets/fonts"
    try:
        manifest = json.loads((font_dir / "SOURCE.json").read_text())
        digest = hashlib.sha256((font_dir / "default.ttf").read_bytes()).hexdigest()
        if digest != manifest["static_sha256"]:
            failures.append(("default.ttf", "font differs from licensed source manifest"))
        if "SIL OPEN FONT LICENSE" not in (font_dir / "OFL.txt").read_text():
            failures.append(("OFL.txt", "missing open font license"))
    except (OSError, ValueError, KeyError):
        failures.append(("assets/fonts", "missing font provenance or license"))
    return files, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    files, failures = audit(args.root)
    for name, reason in failures:
        print(f"FAIL {name}: {reason}")
    if failures:
        raise SystemExit(1)
    print(f"SOURCE_ONLY_OK: {len(files)} files; no game data, credentials, or private device configuration")


if __name__ == "__main__":
    main()
