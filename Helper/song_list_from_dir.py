#!/usr/bin/env python3
"""Extract Artist - Title lines from audio files under a directory."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

AUDIO_EXTS = {
    ".mp3",
    ".m4a",
    ".m4b",
    ".aac",
    ".flac",
    ".alac",
    ".wav",
    ".aiff",
    ".aif",
    ".ogg",
    ".opus",
    ".wma",
}


def ensure_mutagen():
    try:
        import mutagen  # noqa: F401
        return
    except ImportError:
        pass

    import subprocess

    venv_dir = Path(__file__).resolve().parent / ".songlist-venv"
    venv_python = venv_dir / "bin" / "python"
    if not venv_python.exists():
        print("Creating local venv + installing mutagen (one-time)…", file=sys.stderr)
        subprocess.check_call([sys.executable, "-m", "venv", str(venv_dir)], stdout=sys.stderr)
        subprocess.check_call(
            [str(venv_python), "-m", "pip", "install", "--upgrade", "pip"],
            stdout=sys.stderr,
        )
        subprocess.check_call(
            [str(venv_python), "-m", "pip", "install", "mutagen"],
            stdout=sys.stderr,
        )
    # Re-exec inside the venv so imports resolve.
    os.execv(str(venv_python), [str(venv_python), *sys.argv])


def clean(value: str | None) -> str:
    if not value:
        return ""
    text = str(value).strip()
    text = re.sub(r"[\r\n\t]+", " ", text)
    return text.strip(" -")


def first_tag(audio, *keys: str) -> str:
    for key in keys:
        if key not in audio:
            continue
        raw = audio[key]
        if isinstance(raw, list):
            if not raw:
                continue
            item = raw[0]
        else:
            item = raw
        # ID3 frames expose .text
        if hasattr(item, "text"):
            parts = [clean(p) for p in item.text if p]
            if parts:
                return parts[0]
        text = clean(item)
        if text:
            return text
    return ""


def tags_from_file(path: Path) -> tuple[str, str]:
    from mutagen import File as MutagenFile

    audio = MutagenFile(path, easy=True)
    if audio is None:
        return "", ""
    artist = first_tag(audio, "artist", "albumartist", "performer")
    title = first_tag(audio, "title")
    if artist or title:
        return artist, title

    # Non-easy fallback for odd containers
    audio = MutagenFile(path)
    if audio is None:
        return "", ""
    artist = first_tag(
        audio,
        "TPE1",
        "TPE2",
        "©ART",
        "aART",
        "ARTIST",
        "ALBUMARTIST",
    )
    title = first_tag(audio, "TIT2", "©nam", "TITLE")
    return artist, title


def fallback_from_path(path: Path) -> tuple[str, str]:
    stem = path.stem
    # Strip leading track numbers: "01 - Title", "01. Title", "01 Title"
    stem = re.sub(r"^\d{1,3}[\s.\-_]+", "", stem).strip()

    if " - " in stem:
        left, right = stem.split(" - ", 1)
        return clean(left), clean(right)

    # Artist/Album/Track.ext or Artist/Track.ext
    parent = path.parent.name
    grand = path.parent.parent.name if path.parent.parent != path.parent else ""
    if parent and parent not in {".", ""} and not re.fullmatch(r"\d{1,4}", parent):
        # Prefer parent as album, grandparent as artist when depth looks like Artist/Album
        if grand and grand not in {".", ""} and not re.fullmatch(r"\d{1,4}", grand):
            # If filename has no artist, use grandparent
            return clean(grand), clean(stem)
        return clean(parent), clean(stem)

    return "Unknown Artist", clean(stem) or path.name


def iter_audio_files(root: Path, *, follow_symlinks: bool = True):
    """Recursively yield audio files under root (os.walk is more reliable on SMB)."""
    root = Path(root)
    for dirpath, dirnames, filenames in os.walk(
        root,
        topdown=True,
        followlinks=follow_symlinks,
    ):
        dirnames.sort()
        filenames.sort()
        for name in filenames:
            path = Path(dirpath) / name
            if path.suffix.lower() in AUDIO_EXTS and path.is_file():
                yield path


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Recursively list songs as 'Artist - Title' from a directory of audio files."
        )
    )
    parser.add_argument("directory", type=Path, help="Music directory to scan (recursive)")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Write to this .txt file instead of stdout",
    )
    parser.add_argument(
        "--unique",
        action="store_true",
        help="Drop duplicate Artist - Title lines (keep first)",
    )
    parser.add_argument(
        "--sort",
        action="store_true",
        help="Sort lines alphabetically",
    )
    parser.add_argument(
        "--no-follow-symlinks",
        action="store_true",
        help="Do not descend into symlinked folders",
    )
    args = parser.parse_args()

    root = args.directory.expanduser().resolve()
    if not root.is_dir():
        print(f"Not a directory: {root}", file=sys.stderr)
        return 1

    ensure_mutagen()

    lines: list[str] = []
    seen: set[str] = set()
    scanned = 0
    tagged = 0
    print(f"Scanning recursively: {root}", file=sys.stderr)

    for path in iter_audio_files(
        root,
        follow_symlinks=not args.no_follow_symlinks,
    ):
        scanned += 1
        if scanned % 250 == 0:
            print(f"… {scanned} audio files so far", file=sys.stderr)
        try:
            artist, title = tags_from_file(path)
        except Exception as exc:  # noqa: BLE001 - keep scanning
            print(f"warn: {path}: {exc}", file=sys.stderr)
            artist, title = "", ""

        if artist and title:
            tagged += 1
        else:
            fb_artist, fb_title = fallback_from_path(path)
            artist = artist or fb_artist
            title = title or fb_title

        line = f"{artist} - {title}"
        if args.unique:
            key = line.casefold()
            if key in seen:
                continue
            seen.add(key)
        lines.append(line)

    if args.sort:
        lines.sort(key=lambda s: s.casefold())

    text = "\n".join(lines) + ("\n" if lines else "")
    if args.output:
        args.output.write_text(text, encoding="utf-8")
        print(
            f"Wrote {len(lines)} songs ({tagged}/{scanned} tagged) → {args.output}",
            file=sys.stderr,
        )
    else:
        sys.stdout.write(text)
        print(
            f"# {len(lines)} songs ({tagged}/{scanned} tagged)",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
