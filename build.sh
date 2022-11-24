#!/bin/bash -e

# HACK: fix up $PATH in case we are running in a clean environment
# (/usr/bin/core_perl/pod2man)
. /etc/profile || exit
. $HOME/bin/lib/lib.sh || exit

PKGBUILD_ROOT="$HOME/build"
LOG_ROOT="$HOME/build.logs"
PKG_LIST="$PKGBUILD_ROOT/packages.txt"
MAKEPKG_CONF="$PKGBUILD_ROOT/makepkg.conf"

cat "$PKG_LIST" \
	| sed -r 's|[[:space:]]*#.*||g' \
	| grep -vE "^$" \
	| readarray -t PKGBUILDS

setup_one() {
	pkg="$1"
	pkg_dir="$PKGBUILD_ROOT/$pkg"

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

	setup_one "$@" || return

	if [[ -e .git ]]; then
		case "$(git config remote.origin.url)" in
		"${ASPROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/asp}")
			asp update "$pkg"
			;;
		esac

		if git rev-parse --verify --quiet '@{u}'; then
			if ! git pull --rebase --autostash; then
				git rebase --abort || true
				err "failed to update: $pkg ($pkg_dir)"
			fi
		fi
	fi

	cd "$pkgbuild_dir" || return
	makepkg --config "$MAKEPKG_CONF" -od --noconfirm
}

rm -rf "$LOG_ROOT"/*.log
mkdir -p "$LOG_ROOT"

rc=0
failed=()
set +e
for p in "${PKGBUILDS[@]}"; do
	update_one "$p"
	if (( $? )); then (( rc += 1 )); failed+=( $p ); fi
done
set -e

if (( rc )); then
	err "failed to update some packages (count=$rc)"
	printf "%s\n" "${failed[@]}" >&2
	exit 1
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
	printf "%s\n" "${failed[@]}" >&2
	exit 1
fi
