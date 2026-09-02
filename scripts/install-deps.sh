#!/usr/bin/env bash
#
# Fetch the pinned Solidity dependencies into lib/.
#
# The import paths in contracts/Money.sol and test/Money.t.sol
#   import "forge-std/Test.sol";
#   import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
# are resolved by remappings.txt, which points at lib/forge-std/src/ and
# lib/openzeppelin-contracts/contracts/. This script is what puts those two
# checkouts there, at exactly the versions the project is tested against.
#
# Pinned on purpose:
#   forge-std             v1.9.4
#   openzeppelin-contracts v4.9.6   <-- v4, never v5. OpenZeppelin v5 moved
#                                       Pausable to utils/ and made Ownable
#                                       take an initialOwner constructor
#                                       argument; both changes break Money.sol.
#
# Usage:  make install     (or)   ./scripts/install-deps.sh
#
set -euo pipefail

FORGE_STD_TAG="v1.9.4"
OZ_TAG="v4.9.6"

cd "$(dirname "$0")/.."

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required" >&2
  exit 1
fi

fetch() {
  local name="$1" url="$2" tag="$3" dest="lib/$1"

  if [ -d "$dest/.git" ]; then
    echo "==> $name: already present, checking out $tag"
    git -C "$dest" fetch --tags --depth 1 origin "$tag"
  else
    echo "==> $name: cloning $tag"
    rm -rf "$dest"
    mkdir -p lib
    git clone --depth 1 --branch "$tag" --recurse-submodules "$url" "$dest"
    return
  fi

  git -C "$dest" checkout --quiet "$tag"
  git -C "$dest" submodule update --init --recursive --depth 1
}

fetch "forge-std" "https://github.com/foundry-rs/forge-std" "$FORGE_STD_TAG"
fetch "openzeppelin-contracts" "https://github.com/OpenZeppelin/openzeppelin-contracts" "$OZ_TAG"

echo
echo "Dependencies installed:"
echo "  lib/forge-std                @ $FORGE_STD_TAG"
echo "  lib/openzeppelin-contracts   @ $OZ_TAG"
echo
echo "Next:  forge build  &&  forge test -vvv"
