# -*- coding: utf-8 -*-
"""Create the GitHub-ready source archive (no build outputs, no binaries).

Usage: python tools/make_github_zip.py
"""
from __future__ import annotations

import hashlib
import pathlib
import zipfile

VERSION = "1.0.0"
TOP = f"AirMicHub-WindowsPort-{VERSION}"
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "dist" / f"{TOP}-github.zip"
SKIP_DIRS = {"bin", "obj", "dist", "artifacts", ".vs", ".git"}
INCLUDE_EXT = {
    ".cs", ".csproj", ".sln", ".props", ".xaml", ".ps1", ".md", ".html",
    ".js", ".webmanifest", ".svg", ".ico", ".png", ".manifest", ".json",
    ".yml", ".yaml", ".txt", ".py",
}
INCLUDE_NAMES = {".gitignore", ".editorconfig"}


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(ROOT.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(ROOT)
            if any(part in SKIP_DIRS for part in relative.parts):
                continue
            if path.suffix.lower() not in INCLUDE_EXT and path.name not in INCLUDE_NAMES:
                continue
            if path.name.endswith(".user"):
                continue
            info = zipfile.ZipInfo(f"{TOP}/{relative.as_posix()}", date_time=(2026, 11, 21, 12, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())
            count += 1

    digest = hashlib.sha256(OUT.read_bytes()).hexdigest().upper()
    print(f"files={count} bytes={OUT.stat().st_size} sha256={digest}")

    sums = ROOT / "dist" / "SHA256SUMS.txt"
    existing = []
    if sums.exists():
        existing = [
            line for line in sums.read_text(encoding="ascii").splitlines()
            if line.strip() and not line.endswith(OUT.name)
        ]
    existing.append(f"{digest}  {OUT.name}")
    sums.write_text("\n".join(existing) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()
