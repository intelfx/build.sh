#!/hint/bash

export BLD_ROOT_DIR="$(realpath -qm --strip "$BASH_SOURCE/../../..")"
export PATH="$BLD_ROOT_DIR/lib:$PATH"

# Remember original $0 for error messages
if ! [[ ${BLD_ARGV0+set} ]]; then
	# Apparently, interpreted execution on Linux provides no way
	# to acquire the original $0 with which the script was invoked.
	# (https://stackoverflow.com/a/37369285/857932)
	# Try to re-derive it.
	for BLD_ARGV0 in "${0##*/}" "$0" "${BASH_SOURCE[2]}"; do
		if [[ "$(command -v "$BLD_ARGV0")" -ef "${BASH_SOURCE[2]}" ]]; then
			break
		fi
	done
	export BLD_ARGV0
fi

# HACK: fix up $PATH once we are running in clean environment
# (/usr/bin/core_perl/pod2man)
if [[ ${BLD_REEXECUTED+set} && ! ${BLD_HAS_PROFILE+set} ]]; then
	. /etc/profile
	#. $HOME/.profile
	. $HOME/.profile.pkgbuild
	export BLD_HAS_PROFILE=1
fi

LIBSH_LOG_PREFIX="$BLD_ARGV0"
