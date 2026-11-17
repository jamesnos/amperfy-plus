#!/usr/bin/env bash
# List songs from a folder as "Artist - Title" lines.
#
# Usage:
#   ./Helper/song-list-from-dir.sh "/path/to/music"
#   ./Helper/song-list-from-dir.sh "smb://192.168.190.184/D/Music/01 Raw/Norihisa Ipod"
#   ./Helper/song-list-from-dir.sh "smb://…" -o ~/Downloads/Norihisa.txt --unique --sort
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${SCRIPT_DIR}/song_list_from_dir.py"

usage() {
  cat <<'EOF'
Usage: song-list-from-dir.sh <directory|smb-url> [-o out.txt] [--unique] [--sort]

Recursively scans the folder (and subfolders) for audio files.
Resolves smb://… to a /Volumes mount when possible, then prints:
  Artist - Title
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

INPUT="$1"
shift

resolve_path() {
  local raw="$1"

  # Already a local path
  if [[ "$raw" != smb://* ]]; then
    echo "$raw"
    return 0
  fi

  # smb://host/share/rest…
  local without="${raw#smb://}"
  local host="${without%%/*}"
  local after_host="${without#"$host"}"
  after_host="${after_host#/}"
  local share="${after_host%%/*}"
  local rest="${after_host#"$share"}"
  rest="${rest#/}"

  local candidates=()
  # Common macOS mount layouts
  [[ -n "$share" ]] && candidates+=("/Volumes/${share}/${rest}")
  candidates+=("/Volumes/${host}/${rest}")
  candidates+=("/Volumes/${host}/${share}/${rest}")
  # Share letter dropped (\\\\server\\D → volume named for host, path starts at Music)
  if [[ "$share" =~ ^[A-Za-z]$ ]]; then
    candidates+=("/Volumes/${host}/${rest}")
  fi

  local c
  for c in "${candidates[@]}"; do
    # Trim trailing slash noise
    c="${c%/}"
    if [[ -d "$c" ]]; then
      echo "$c"
      return 0
    fi
  done

  echo "Could not map SMB URL to a mounted folder:" >&2
  echo "  $raw" >&2
  echo "Tried:" >&2
  for c in "${candidates[@]}"; do
    echo "  - $c" >&2
  done
  echo "Mount the share in Finder first (⌘K), then retry." >&2
  return 1
}

DIR="$(resolve_path "$INPUT")"
exec python3 "$PY" "$DIR" "$@"
