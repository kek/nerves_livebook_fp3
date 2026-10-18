#!/usr/bin/env bash
#
# Fix NixOS-only breakage in host tools that `mix deps.compile
# nerves_system_fp3 --force` builds from source, for issues that can't be
# expressed as a Buildroot BR2_GLOBAL_PATCH_DIR patch (see
# nerves_system_fp3's patches/ dir for the ones that could be).
#
# host-fakedate installs package/fakedate/fakedate (an upstream Buildroot
# file, not ours to patch via BR2_GLOBAL_PATCH_DIR) as $(HOST_DIR)/bin/date,
# shebang `#!/bin/bash`. NixOS has no /bin/bash, so every later host build
# step that shells out to `date` fails. Buildroot re-extracts/rebuilds this
# fresh each time `--force` clears the artifact cache, so the fix has to be
# reapplied each time rather than just once.
#
# Run after a `mix deps.compile nerves_system_fp3 --force` that failed with
# "/bin/bash: No such file or directory" pointing at a host/bin/date
# wrapper, then re-run the same deps.compile command.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixed=0

for date_bin in "$root"/deps/nerves_system_fp3/.nerves/artifacts/nerves_system_fp3-portable-*/host/bin/date; do
  [ -e "$date_bin" ] || continue
  if head -1 "$date_bin" | grep -qx '#!/bin/bash'; then
    sed -i '1s,.*,#!/usr/bin/env bash,' "$date_bin"
    echo "fixed $date_bin"
    fixed=$((fixed + 1))
  fi
done

if [ "$fixed" -eq 0 ]; then
  echo "nothing to fix (no host/bin/date with a #!/bin/bash shebang found)"
fi
