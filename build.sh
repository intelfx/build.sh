#!/bin/bash

# HACK: fix up $PATH in case we are running in a clean environment
# (/usr/bin/core_perl/pod2man)
. /etc/profile || exit
. $HOME/bin/lib/lib.sh || exit

PKGBUILD_ROOT="$HOME/build"
WORKDIR_ROOT="$HOME/build.work"
PKG_LIST="$PKGBUILD_ROOT/packages.txt"
MAKEPKG_CONF="$PKGBUILD_ROOT/makepkg.conf"

FETCH_ERR_LIST="$WORKDIR_ROOT/errors.fetch"

setup_one_pre() {
	pkg="$1"
	pkg_dir="$PKGBUILD_ROOT/$pkg"
}

setup_one() {
	setup_one_pre "$@"

	if ! [[ -d "$pkg_dir" ]]; then
		err "pkgbase does not exist: $pkg ($pkg_dir)"
		return 1
	fi

	cd "$pkg_dir"

	if [[ -f PKGBUILD ]]; then
		pkgbuild_dir="$pkg_dir"
	elif [[ -f trunk/PKGBUILD ]]; then
		pkgbuild_dir="$pkg_dir/trunk"
	else
		err "PKGBUILD does not exist: $pkg ($pkg_dir)"
		return 1
	fi
}

build_one() {
	local pkg pkg_dir pkgbuild_dir
	setup_one "$@" || return
	cd "$pkgbuild_dir" || return
	aur build --makepkg-conf "$MAKEPKG_CONF" --no-sync --margs -s,--noconfirm
}

aur_list() {
	curl -fsS 'https://aur.archlinux.org/rpc/' -G -d v=5 -d type=info -d arg="$1" \
		| jq -r 'if (.version == 5 and .type == "multiinfo") then .results[].Name else "AUR response: \(.)\n" | halt_error(1) end'
}

update_one() {
	local pkg pkg_dir pkgbuild_dir

	setup_one_pre "$@"

	if ! [[ -d "$pkg_dir" ]]; then
		cd "$(dirname "$pkg_dir")"
		if asp list-all | grep -q -Fx "$pkg"; then
			asp checkout "$pkg" || return
		elif aur_list "$pkg" | grep -q -Fx "$pkg"; then
			git clone "https://aur.archlinux.org/$pkg" || return
		else
			err "pkgbase could not be found: $pkg"
			return 1
		fi
	fi

	setup_one "$@" || return

	if [[ -e prepare.sh ]]; then
		if ! ./prepare.sh; then
			err "failed to execute prepare.sh: $pkg ($pkg_dir)"
		fi
	fi

	if [[ -e .git ]]; then
		local _asproot="${ASPROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/asp}"
		case "$(git config remote.origin.url)" in
		"$_asproot")
			# Since recently, invoking more than one `asp update` simultaneously breaks something within Git:
			#
			# From https://github.com/archlinux/svntogit-packages
			#  * branch              packages/pulseaudio -> FETCH_HEAD
			# error: could not lock config file /home/operator/.cache/asp/.git/config: File exists
			# error: Unable to write upstream branch configuration
			# hint:
			# hint: After fixing the error cause you may try to fix up
			# hint: the remote tracking information by invoking
			# hint: "git branch --set-upstream-to=packages/packages/gstreamer-vaapi".
			# error: could not lock config file /home/operator/.cache/asp/.git/config: File exists
			# error: Unable to write upstream branch configuration
			# hint:
			# hint: After fixing the error cause you may try to fix up
			# hint: the remote tracking information by invoking
			# hint: "git branch --set-upstream-to=packages/packages/pulseaudio".
			#
			#asp update "$pkg" || return
			flock -x -w 10 "$_asproot/.asp" asp update "$pkg" || return
			;;
		esac

		if git rev-parse --verify --quiet '@{u}'; then
			if ! git pull --rebase --autostash; then
				git rebase --abort || true
				err "failed to update: $pkg ($pkg_dir)"
				return 1
			fi
		fi
	fi

	cd "$pkgbuild_dir" || return
	makepkg --config "$MAKEPKG_CONF" -od --noconfirm
}

ARG_MODE_FETCH=0
ARG_REBUILD=0
ARGS_PASS=()
ARGS_EXCLUDE=()
ARGS_MAKEPKG=()

ARGS=$(getopt -o '' --long 'sub-fetch' -n "${0##*/}" -- "$@")
eval set -- "$ARGS"
unset ARGS

while :; do
	case "$1" in
	'--sub-fetch')
		ARG_MODE_FETCH=1
		shift
		;;
	'--')
		shift
		break
		;;
	*)
		die "Internal error"
		;;
	esac
done

cat_if_exists() {
	local arg
	declare -a args
	for arg; do
		if [[ -e "$arg" ]]; then
			args+=( "$arg" )
		fi
	done
	if (( ${#args[@]} )); then
		cat "${args[@]}"
	fi
}

if (( ARG_MODE_FETCH )); then
	if ! (( $# == 1 )); then
		die "Bad usage: $0 --sub-fetch PACKAGE (expected 1 argument, got $#)"
	fi

	update_one "$1" && rc=0 || rc=$?
	if (( rc )); then (
		exec 9<>"$WORKDIR_ROOT/lock"
		flock -n 9

		{ cat_if_exists "$FETCH_ERR_LIST.new"; echo "$1"; } | sort -u | sponge "$FETCH_ERR_LIST.new"
	) fi
	exit $rc
else
	if (( $# )); then
		PKGBUILDS=( "$@" )
	else
		cat "$PKG_LIST" \
			| sed -r 's|[[:space:]]*#.*||g' \
			| grep -vE "^$" \
			| readarray -t PKGBUILDS
	fi

	print_array "${PKGBUILDS[@]}" | grep -Fvxf <(print_array "${ARGS_EXCLUDE[@]}") | readarray -t PKGBUILDS
fi

#
# main
#

if [[ -e "$FETCH_ERR_LIST" ]]; then
	fetch_err_stamp="$(stat -c '%Y' "$FETCH_ERR_LIST")"
	now_stamp="$(date '+%s')"
	packages_stamp="$(stat -c '%Y' "$PKG_LIST")"
	if ! (( fetch_err_stamp > now_stamp - 3600 )); then
		err "Ignoring fetch status file, older than 1h"
		rm -f "$FETCH_ERR_LIST"
	elif ! (( fetch_err_stamp > packages_stamp )); then
		err "Ignoring fetch status file, older than packages.txt"
		rm -f "$FETCH_ERR_LIST"
	fi
fi

if [[ -e "$FETCH_ERR_LIST" ]]; then
	cat "$FETCH_ERR_LIST" \
		| { grep -Fvxf <(print_array "${ARGS_EXCLUDE[@]}") || true; } \
		| readarray -t FETCH_PKGBUILDS
	log "continuing incomplete update"
	print_array "${FETCH_PKGBUILDS[@]}" >&2
else
	FETCH_PKGBUILDS=( "${PKGBUILDS[@]}" )
fi


if (( ${#FETCH_PKGBUILDS[@]} )); then
	parallel --bar "$0 ${ARGS_PASS[*]} --sub-fetch {}" ::: "${FETCH_PKGBUILDS[@]}" && rc=0 || rc=$?
else
	rc=0
fi

if (( rc )); then
	mv "$FETCH_ERR_LIST.new" "$FETCH_ERR_LIST"
	cat "$FETCH_ERR_LIST" | \
		readarray -t failed
	rc="${#failed[@]}"

	err "failed to update some packages (count=$rc)"
	print_array "${failed[@]}" >&2
	exit 1
else
	rm -f "$FETCH_ERR_LIST"
fi

rc=0
failed=()
set +e
for p in "${PKGBUILDS[@]}"; do
	build_one "$p"
	if (( $? )); then (( rc += 1 )); failed+=( $p ); fi
done
set -e

if (( rc )); then
	err "failed to build some packages (count=$rc)"
	print_array "${failed[@]}" >&2
	exit 1
fi
