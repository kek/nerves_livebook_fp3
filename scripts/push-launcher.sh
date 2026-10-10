#!/usr/bin/env bash
#
# Copy notebooks/launcher.livemd onto the phone, to /data/livebook/notebooks.
#
#   scripts/push-launcher.sh
#
# Close the notebook in Livebook first, or its autosave overwrites the copy.
#
# The phone has no SFTP, so the file goes over SSH as base64 and IEx
# writes it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_DIR/notebooks/launcher.livemd"
DEST="/data/livebook/notebooks/launcher.livemd"
HOST="${NERVES_HOST:-nerves.local}"

b64="$(base64 < "$SOURCE" | tr -d '\n')"
ssh "$HOST" "File.write!(\"$DEST\", Base.decode64!(\"$b64\"))"
echo "Wrote $DEST on $HOST"
