#!/usr/bin/env bash
#
# Compile Elixir files into the running phone, without a firmware update.
#
#   scripts/hot-load.sh lib/nerves_livebook_fp3/launcher.ex [more.ex ...]
#
# Each file is compiled on the phone and its modules replace the loaded
# ones. Running processes pick up the new code on their next call into the
# module: a running launcher redraws with the new render/1 at its next
# refresh. mount/1 doesn't run again, and state from the old code is kept,
# so a change to the state's shape needs a reboot.
#
# The change lives in memory only. A reboot goes back to the firmware's
# code, so ship it with `mix firmware && mix upload` when it works.
#
# The phone has no SFTP, so each file goes over SSH as base64.

set -euo pipefail

HOST="${NERVES_HOST:-nerves.local}"

if [ $# -eq 0 ]; then
  echo "usage: $0 FILE.ex [FILE.ex ...]" >&2
  exit 1
fi

code=""
for file in "$@"; do
  b64="$(base64 < "$file" | tr -d '\n')"
  code+="Code.compile_string(Base.decode64!(\"$b64\"), \"$file\") |> Enum.each(fn {mod, _} -> IO.puts(\"loaded #{inspect(mod)}\") end); "
done

ssh "$HOST" "$code"
