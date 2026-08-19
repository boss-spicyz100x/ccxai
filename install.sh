#!/usr/bin/env bash
# Put `ccx` on PATH for normal shells.
#
# Without this, ccx only works inside Claude Code: the plugin loader adds
# plugins/ccx/bin to PATH for its own session, so every other shell needs the
# full path to the script.
#
# Installs a SYMLINK, not a copy, so edits to the repo are live -- this is a tool
# under active development, and a stale copy on PATH is its own bug.
#
#   ./install.sh                 # -> ~/.local/bin/ccx (or the first PATH dir that works)
#   CCX_PREFIX=~/bin ./install.sh
#   ./install.sh --uninstall
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/plugins/ccx/bin/ccx"
[[ -x "$SRC" ]] || { echo "install: $SRC is missing or not executable" >&2; exit 1; }

# Prefer an explicit prefix, then a dir that is already on PATH, then a default.
pick_prefix() {
  if [[ -n "${CCX_PREFIX:-}" ]]; then printf '%s' "${CCX_PREFIX/#\~/$HOME}"; return; fi
  local d
  for d in "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in *":$d:"*) printf '%s' "$d"; return ;; esac
  done
  printf '%s' "$HOME/.local/bin"
}
PREFIX="$(pick_prefix)"
DEST="$PREFIX/ccx"

if [[ "${1:-}" == "--uninstall" ]]; then
  if [[ -L "$DEST" ]]; then rm -f "$DEST"; echo "removed $DEST"
  else echo "nothing to remove at $DEST (not a symlink)"; fi
  exit 0
fi

mkdir -p "$PREFIX"

# Refuse to clobber a real file. A symlink we own is fine to replace; anything
# else might be someone's actual binary.
if [[ -e "$DEST" && ! -L "$DEST" ]]; then
  echo "install: $DEST exists and is not a symlink -- refusing to overwrite" >&2
  exit 1
fi
ln -sfn "$SRC" "$DEST"
echo "linked $DEST -> $SRC"

# `ccx` re-invokes itself through "$0" for fanout, so the symlink has to be
# executable as an entry point, not just resolvable.
if ! "$DEST" --help >/dev/null 2>&1 && ! "$DEST" help >/dev/null 2>&1; then
  if ! "$DEST" 2>&1 | grep -q 'ccx'; then
    echo "install: $DEST did not run as expected" >&2
    exit 1
  fi
fi
echo "verified: $DEST runs"

case ":$PATH:" in
  *":$PREFIX:"*) echo "on PATH already" ;;
  *)
    echo
    echo "NOTE: $PREFIX is not on your PATH. Add it:"
    echo "  fish: fish_add_path $PREFIX"
    echo "  zsh:  echo 'export PATH=\"$PREFIX:\$PATH\"' >> ~/.zshrc"
    ;;
esac
