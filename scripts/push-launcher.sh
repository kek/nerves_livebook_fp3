#!/usr/bin/env bash
#
# Copy notebooks/launcher.livemd onto the phone.
#
#   scripts/push-launcher.sh          # as a notebook, to edit and run in Livebook
#   scripts/push-launcher.sh --app    # as a Livebook app that starts at boot
#
# Both copies are the same file. Livebook deploys apps from
# /data/livebook/apps when it starts, so reboot the phone after --app.
#
# Close the notebook in Livebook first, or its autosave overwrites the copy.
#
# The phone has no SFTP, so the file goes over SSH as base64 and IEx
# writes it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_DIR/notebooks/launcher.livemd"
HOST="${NERVES_HOST:-nerves.local}"

case "${1:-}" in
  "") dest="/data/livebook/notebooks/launcher.livemd" ;;
  --app) dest="/data/livebook/apps/launcher.livemd" ;;
  *)
    echo "usage: $0 [--app]" >&2
    exit 1
    ;;
esac

b64="$(base64 < "$SOURCE" | tr -d '\n')"
ssh "$HOST" "File.mkdir_p!(Path.dirname(\"$dest\")); File.write!(\"$dest\", Base.decode64!(\"$b64\"))"
echo "Wrote $dest on $HOST"
