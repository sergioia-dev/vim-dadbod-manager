#!/usr/bin/env bash
# Run the vim-dadbod-manager test suite headlessly.
#
#   ./test/run.sh                       # result/bin/nvim, else nvim from PATH
#   NVIM_BIN=/path/to/nvim ./test/run.sh
#
# NVIM_BIN rather than NVIM: nvim exports NVIM as the address of its server
# socket, so it is not a usable override name.
#
# vim-dadbod must be available on the runtimepath; the drawer itself is vendored
# in this plugin. The nvim wrapper built by this flake (result/bin/nvim) provides
# vim-dadbod.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
repo="$(cd "$root/../.." && pwd)"  # the plugin lives in <repo>/plugins/

# The flake builds the wrapper at the repository root (this plugin is the only
# thing that needs it): its packpath has vim-dadbod and this plugin, and no
# second drawer. Rebuild it with "nix build ." after changing the plugin.
if [[ -n "${NVIM_BIN:-}" ]]; then
  nvim="$NVIM_BIN"
elif [[ -x "$repo/result/bin/nvim" ]]; then
  nvim="$repo/result/bin/nvim"
else
  nvim="$(command -v nvim || true)"
fi
printf 'test/run.sh: nvim=%s\n' "$nvim" >&2

if [[ -z "$nvim" || ! -x "$nvim" ]]; then
  echo "test/run.sh: no nvim found; set NVIM_BIN=/path/to/nvim" >&2
  exit 2
fi

output="$("$nvim" --headless -u "$here/minimal_init.vim" \
  -c "source $here/dbui_multidb_spec.vim" 2>&1)"
status=$?

printf '%s\n' "$output"

if [[ $status -ne 0 ]]; then
  echo "test/run.sh: nvim exited with status $status" >&2
  exit "$status"
fi

if ! grep -q 'RESULT: ok' <<< "$output"; then
  echo "test/run.sh: the suite did not report success" >&2
  exit 1
fi

echo "test/run.sh: ok"
