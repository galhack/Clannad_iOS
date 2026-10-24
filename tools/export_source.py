#!/usr/bin/env python3
"""Export an audited public snapshot without copying private Git history."""

import argparse
from pathlib import Path
import shutil
import subprocess

from check_source_only import audit, excluded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    dest = args.output.resolve()
    if dest == root or root.is_relative_to(dest):
        parser.error("output must not replace the source checkout or its parents")
    if dest.exists() and any(dest.iterdir()):
        parser.error("output must be a new or empty directory; existing files are never overwritten")
    dest.mkdir(parents=True, exist_ok=True)
    selected = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root
    ).decode().split("\0")
    copied = set()
    for name in sorted(set(selected)):
        if not name or excluded(name) or not (root / name).is_file():
            continue
        target = dest / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, target)
        copied.add(name)
    # Exported documentation describes public evidence only. Private device
    # logs and the full local validation history stay in the development tree.
    public_validation = root / "docs/PUBLIC-VALIDATION.md"
    if public_validation.exists():
        shutil.copy2(public_validation, dest / "docs/VALIDATION.md")
    upstream_readme = dest / "engine/siglus_rs/README.md"
    upstream_readme.write_text(
        "# siglus_rs — vendored source\n\n"
        "Upstream: https://github.com/xmoezzz/siglus_rs, revision 5f358ef1.\n\n"
        "This source is licensed under MPL-2.0; see LICENSE-MPL-2.0. "
        "Port modifications are described in ../../docs/ENGINE-PATCHES.md.\n\n"
        "Game screenshots, proprietary manuals, compiled reference shaders "
        "and extracted shader reference output are omitted from this source-only export. "
        "The application loads game content from the player's separately purchased copy.\n"
    )
    files, failures = audit(dest)
    for name, reason in failures:
        print(f"FAIL {name}: {reason}")
    if failures:
        raise SystemExit(1)
    print(f"PUBLIC_SOURCE_OK: {len(files)} files exported to {dest}")


if __name__ == "__main__":
    main()
