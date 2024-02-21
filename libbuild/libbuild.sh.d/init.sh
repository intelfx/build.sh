#!/hint/bash

export BLD_ROOT_DIR="$(realpath -qm --strip "$BASH_SOURCE/../../..")"
export PATH="$BLD_ROOT_DIR/lib:$PATH"
