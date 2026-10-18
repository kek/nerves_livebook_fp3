#!/usr/bin/env bash
#
# Fix NixOS-only breakage in a from-source nerves_system_fp3 build that
# can't be expressed as a Buildroot BR2_GLOBAL_PATCH_DIR patch (see
# nerves_system_fp3's patches/ dir for the ones that could be). Both
# issues below get reintroduced every time Buildroot re-extracts the
# package fresh, e.g. after `mix deps.compile nerves_system_fp3 --force`,
# so the fix has to be reapplied each time rather than just once.
#
# Run after a deps.compile fails with one of the errors described below,
# then re-run the same deps.compile command.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$root/deps/nerves_system_fp3/.nerves/artifacts/nerves_system_fp3-portable-*"
fixed=0

# host-fakedate installs package/fakedate/fakedate (an upstream Buildroot
# file, not ours to patch via BR2_GLOBAL_PATCH_DIR) as $(HOST_DIR)/bin/date,
# shebang `#!/bin/bash`. NixOS has no /bin/bash, so every later host build
# step that shells out to `date` fails.
for date_bin in $artifacts/host/bin/date; do
  [ -e "$date_bin" ] || continue
  if head -1 "$date_bin" | grep -qx '#!/bin/bash'; then
    sed -i '1s,.*,#!/usr/bin/env bash,' "$date_bin"
    echo "fixed $date_bin"
    fixed=$((fixed + 1))
  fi
done

# Erlang/OTP's erts build looks up .hrl/.md deps across lib/*/src by
# basename only, relying on them being symlinked into every directory
# that needs them — a step its own Makefiles normally do from a vendored
# header pool that isn't part of the release tarball, breaking under
# whatever's different about NixOS's build (observed: "No rule to make
# target 'inet_boot.hrl'"). Fails the same way for both host-erlang (used
# while cross-compiling) and the target erlang build.
link_erlang_headers() {
  local erl_dir="$1" srcdir depsmk f found
  for srcdir in $(find "$erl_dir/lib" -maxdepth 2 -type d -name src) "$erl_dir/erts/preloaded/src"; do
    depsmk="$srcdir/deps/deps.mk"
    [ -f "$depsmk" ] || continue
    for f in $(grep -oE '[^[:space:]:\\]+\.(hrl|md)' "$depsmk" | xargs -rn1 basename | sort -u); do
      [ -e "$srcdir/$f" ] && continue
      found=$(find "$erl_dir/lib" "$erl_dir/erts" -iname "$f" -not -path "*/preloaded/src/*" -not -path "$srcdir/*" 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        ln -sf "$(realpath --relative-to="$srcdir" "$found")" "$srcdir/$f"
        echo "linked $f (in $srcdir)"
        fixed=$((fixed + 1))
      fi
    done
  done
}

for erl_dir in $artifacts/build/erlang-[0-9]* $artifacts/build/host-erlang-[0-9]*; do
  [ -d "$erl_dir" ] || continue
  link_erlang_headers "$erl_dir"
done

# Any C++ host tool Buildroot builds from source (patchelf, ninja,
# gperf, gengetopt, lzip, and host-erlang's own beam.smp — its BeamAsm
# JIT is written in C++) links dynamically against libstdc++, which
# isn't on NixOS's default linker search path (nothing is — every path
# on NixOS is a hashed store path), so the binary it just built can't
# even run ("error while loading shared libraries"). patchelf itself
# has a real fix for this on nerves_system_fp3's nixos-build-patches
# branch (statically linking libstdc++/libgcc) but it's not adopted by
# this project yet, and the same fix isn't practical for every other
# package here, so just rpath-patch every affected binary instead —
# using the Nix shell's own patchelf, since Buildroot's own might be
# one of the binaries that needs fixing.
nix_patchelf="$(command -v patchelf || true)"
nix_libstdcxx_dir="$(command -v g++ >/dev/null && dirname "$(g++ -print-file-name=libstdc++.so)" || true)"
if [ -n "$nix_patchelf" ] && [ -n "$nix_libstdcxx_dir" ] && [ -e "$nix_libstdcxx_dir/libstdc++.so.6" ]; then
  for host_dir in $artifacts/host; do
    [ -d "$host_dir" ] || continue
    while IFS= read -r -d '' bin; do
      file "$bin" 2>/dev/null | grep -q 'ELF.*dynamically linked' || continue
      ldd "$bin" 2>/dev/null | grep -q 'libstdc++.so.6 => not found' || continue
      "$nix_patchelf" --add-rpath "$nix_libstdcxx_dir" "$bin"
      echo "rpath-patched $bin"
      fixed=$((fixed + 1))
    done < <(find "$host_dir" -type f -perm -u+x -print0)
  done
else
  echo "COULD NOT FIX: no patchelf/g++ on PATH to rpath-patch host tools against libstdc++"
fi

if [ "$fixed" -eq 0 ]; then
  echo "nothing to fix"
fi
