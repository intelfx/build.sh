#!/bin/bash

set -eo pipefail
shopt -s lastpipe
shopt -s extglob
shopt -s nullglob

# load lib.sh

# shellcheck source=../lib/lib.sh
source "${BASH_SOURCE%/*}/../lib/lib.sh"

# load libbuild

__libbuild="${BASH_SOURCE}.d"
if ! [[ -d "$__libbuild" ]]; then
	echo "libbuild.sh: libbuild.sh.d does not exist!" >&2
	return 1
fi
source "$__libbuild/init.sh" || return
for __libbuild_file in "$__libbuild"/*.sh; do
	if [[ "$__libbuild_file" != "$__libbuild/init.sh" ]]; then
		source "$__libbuild_file" || return
	fi
done
unset __libbuild __libbuild_file
