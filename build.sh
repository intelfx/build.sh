#!/bin/bash

# HACK: fix up $PATH in case we are running in a clean environment
# (/usr/bin/core_perl/pod2man)
if ! [[ ${BLD_HAS_PROFILE+set} ]]; then
	. /etc/profile
	#. $HOME/.profile
	. $HOME/.profile.pkgbuild
	export BLD_HAS_PROFILE=1
fi

. $HOME/bin/lib/lib.sh || exit

PKGBUILD_ROOT="$HOME/pkgbuild"
WORKDIR_ROOT="$HOME/.pkgbuild.work"
PKG_LIST="$PKGBUILD_ROOT/packages.txt"
MAKEPKG_CONF="/etc/aurutils/makepkg-custom.conf"
PACMAN_CONF="/etc/aurutils/pacman-custom.conf"
REPO_NAME="custom"
SCRATCH_ROOT="/mnt/ssd/Scratch/makepkg"

FETCH_ERR_LIST="$WORKDIR_ROOT/errors.fetch"

export UNATTENDED=1

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

	# FIXME read from package properties
	case "$pkg" in
	linux|linux-tools)
		# non-clean builds
		;;
	*)
		# build in a container
		aurbuild_args+=(
			-c -T
			--bind-rw "$SCRATCH_ROOT":/build
		)
		# optionally drop --clean here...
		makepkg_args_prepare=( --cleanbuild --clean )
		# ...and --cleanbuild here for a bit more spead and a bit less isolation
		makepkg_args_build=( --cleanbuild --clean )
		;;
	esac
	aurbuild_args+=( --remove --new )
	makepkg_args_prepare+=( "${ARGS_MAKEPKG[@]}" )
	makepkg_args_build+=( "${ARGS_MAKEPKG[@]}" )
}

aur_list() {
	curl -fsS 'https://aur.archlinux.org/rpc/' -G -d v=5 -d type=info -d arg="$1" \
		| jq -r 'if (.version == 5 and .type == "multiinfo") then .results[].Name else "AUR response: \(.)\n" | halt_error(1) end'
}

generate_srcinfo() {
	if ! test -e .SRCINFO -a .SRCINFO -nt PKGBUILD; then
		makepkg --printsrcinfo 2>/dev/null >.SRCINFO
	fi
}

run_repo() {
	aur repo \
		-d "$REPO_NAME" \
		--config "$PACMAN_CONF" \
		"$@"
}

run_build_dry() {
	# skip $aurbuild_args and $makepkg_args_build
	# (aur-build picks up `-c` and goes to sync the chroot, which is slow)
	aur build \
		-d "$REPO_NAME" \
		--pacman-conf "$PACMAN_CONF" \
		--makepkg-conf "$MAKEPKG_CONF" \
		--dry-run \
		"$@" \
	|| true
}

run_build() {
	aur build \
		-d "$REPO_NAME" \
		--pacman-conf "$PACMAN_CONF" \
		--makepkg-conf "$MAKEPKG_CONF" \
		"${aurbuild_args[@]}" \
		--margs "$(join ',' "${makepkg_args_build[@]}")" \
		"$@"
}

run_srcver() {
	# XXX: gross hack to skip repeatedly extracting packages that do not deserve it
	# XXX: however, append --verifysource to force makepkg to fetch the sources (if any)
	if ! grep -qE '^ *(function *)?pkgver *\( *\)' PKGBUILD; then
		makepkg_args_prepare+=( --verifysource --noextract )
	fi

	aur srcver \
		--margs --config,"$MAKEPKG_CONF" \
		--margs "$(join ',' "${makepkg_args_prepare[@]}")" \
		"$@"
}

build_one() {
	local pkg pkg_dir pkgbuild_dir
	declare -a aurbuild_args makepkg_args_prepare makepkg_args_build
	setup_one "$@" || return
	cd "$pkgbuild_dir" || return

	if ! run_build_dry | sponge | grep -qE '^build:'; then
		return
	fi
	run_build
}

update_one() {
	eval "$(ltraps)"
	local pkg pkg_dir pkgbuild_dir
	declare -a aurbuild_args makepkg_args_prepare makepkg_args_build

	setup_one_pre "$@"

	if ! [[ -d "$pkg_dir" ]]; then
		cd "$(dirname "$pkg_dir")"
		if asp list-all | sponge | grep -q -Fx "$pkg"; then
			asp checkout "$pkg" || return
		elif aur_list "$pkg" | sponge | grep -q -Fx "$pkg"; then
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
			return 1
		fi
	fi

	if [[ -e .git ]]; then
		# rollback pkgver=, pkgrel= updates
		local pkgbuild="$pkgbuild_dir/PKGBUILD"
		if ! git diff-index --quiet HEAD -- "$pkgbuild"; then
			local pkgbuild_diff="$(mktemp)"
			local pkgbuild_bak="$(mktemp -p "$pkgbuild_dir")"
			ltrap "rm -f '$pkgbuild_diff' '$pkgbuild_bak'"
			cp -a "$pkgbuild" "$pkgbuild_bak"
			(
			set -eo pipefail
			git diff "$pkgbuild" \
				| sed -r \
					-e ' /^\+(pkgver|pkgrel)=/d' \
					-e 's/^\-(pkgver|pkgrel)=/ \1=/' \
				>"$pkgbuild_diff"
			git checkout -f "$pkgbuild"
			git apply --recount --allow-empty "$pkgbuild_diff"
			) || { cat "$pkgbuild_diff"; mv "$pkgbuild_bak" "$pkgbuild"; return 1; }
			lruntrap
		fi
		# rollback local modifications to .SRCINFO
		local srcinfo="$pkgbuild_dir/.SRCINFO"
		if ! git ls-files --error-unmatch "$srcinfo" &>/dev/null; then
			rm -f "$srcinfo"
		elif ! git diff --quiet HEAD -- "$srcinfo"; then
			git reset "$srcinfo"
			git checkout -f "$srcinfo"
		fi

		case "$pkg" in
		linux|linux-tools)
			local git_pull=( git pull --no-ff --no-rebase )
			local git_pull_abort=( git merge --abort )
			;;
		*)
			local git_pull=( git pull --no-ff --rebase )
			local git_pull_abort=( git rebase --abort )
			;;
		esac

		# pull PKGBUILD tree (if there is any)
		if (( ARG_NOPULL == 0 )) && git rev-parse --verify --quiet '@{u}' &>/dev/null; then
			local upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
			local remote="${upstream%%/*}"
			local _asproot="${ASPROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/asp}"
			case "$(git config remote.$remote.url)" in
			"$_asproot")
				# resolve the true package name we are tracking in ABS
				local asppkg="${upstream##*/}"
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
				flock -x -w 10 "$_asproot/.asp" asp update "$asppkg" || return
				;;
			esac

			if ! "${git_pull[@]}" --autostash; then
				"${git_pull_abort[@]}" ||:
				git stash pop ||:
				err "failed to update: $pkg ($pkg_dir)"
				return 1
			fi
		fi
	fi

	cd "$pkgbuild_dir" || return
	run_srcver || return

	# pkgrel= was reset above
	# bump pkgrel= if --rebuild is indicated, or match to repo contents otherwise (to prevent building a package with a lower pkgrel than repo contents)

	generate_srcinfo

	local pkg_old pkg_old_ver pkg_old_rel
	run_repo | sponge | awk -v pkgbase=$pkg 'BEGIN { FS="\t" } $3 == pkgbase { print $4; exit }' | read pkg_old
	pkg_old_rel="${pkg_old##*-}"
	pkg_old_ver="${pkg_old%-*}"
	dbg "$pkg: repo: pkgver=$pkg_old_ver, pkgrel=$pkg_old_rel (version=$pkg_old)"

	local pkg_cur pkg_cur_epoch pkg_cur_ver pkg_cur_rel
	# FIXME: proper .SRCINFO parser
	# FIXME: split package handling
	sed -nr 's|^\tepoch = (.+)$|\1|p' .SRCINFO | head -n1 | read pkg_cur_epoch
	sed -nr 's|^\tpkgver = (.+)$|\1|p' .SRCINFO | head -n1 | read pkg_cur_ver
	sed -nr 's|^\tpkgrel = (.+)$|\1|p' .SRCINFO | head -n1 | read pkg_cur_rel
	pkg_cur_ver="${pkg_cur_epoch:+$pkg_cur_epoch:}$pkg_cur_ver"
	pkg_cur="$pkg_cur_ver-$pkg_cur_rel"
	dbg "$pkg:     repo: pkgver=$pkg_old_ver, pkgrel=$pkg_old_rel"
	dbg "$pkg: PKGBUILD: pkgver=$pkg_cur_ver, pkgrel=$pkg_cur_rel"

	local pkg_new_rel="$pkg_old_rel"
	if [[ "$pkg_old_ver" == "$pkg_cur_ver" ]]; then
		if (( ARG_REBUILD )); then
			pkg_new_rel="$(( pkg_old_rel + 1 ))"
		fi
		if (( pkg_new_rel > pkg_cur_rel )); then
			log "$pkg: PKGBUILD: same pkgver=$pkg_cur_ver, setting pkgrel=$pkg_new_rel"
			sed -r "s|^pkgrel=.+$|pkgrel=$pkg_new_rel|" -i PKGBUILD
		else
			dbg "$pkg: PKGBUILD: same pkgver, leaving pkgrel=$pkg_cur_rel"
		fi
	else
		dbg "$pkg: PKGBUILD: updated pkgver, leaving pkgrel=$pkg_cur_rel"
	fi
}

unset ARG_SUBROUTINE
ARG_REBUILD=0
ARG_NOPULL=0
ARGS_PASS=()
ARGS_EXCLUDE=()
ARGS_MAKEPKG=()
ARG_RESET=0

ARGS=$(getopt -o '' --long 'sub:,rebuild,exclude:,margs:,no-pull,reset' -n "${0##*/}" -- "$@") || die "Invalid usage"
eval set -- "$ARGS"
unset ARGS

pass() {
	local n="$1"
	shift
	ARGS_PASS+=( "${@:1:$n}" )
}
while :; do
	case "$1" in
	'--sub')
		ARG_SUBROUTINE="$2"
		shift 2
		;;
	'--reset')
		ARG_RESET=1
		shift 1
		;;
	'--no-pull')
		ARG_NOPULL=1
		pass 1 "$@"
		shift 1
		;;
	'--rebuild')
		ARG_REBUILD=1
		pass 1 "$@"
		shift 1
		;;
	'--exclude')
		readarray -t -O "${#ARGS_EXCLUDE[@]}" ARGS_EXCLUDE <<< "${2//,/$'\n'}"
		shift 2
		;;
	'--margs')
		ARGS_MAKEPKG+=( "$2" )
		pass 2 "$@"
		shift 2
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

#
# subroutines
#

if [[ $ARG_SUBROUTINE == fetch ]]; then
	if ! (( $# == 1 )); then
		die "Bad usage: $0 ${@@Q}"
	fi

	rc=0
	set +e
	update_one "$1"
	rc=$?
	set -e

	if (( rc )); then (
		exec 9<>"$WORKDIR_ROOT/lock"
		flock -n 9
		echo "$1" >> "$FETCH_ERR_LIST.new"
	) fi
	exit $rc
elif [[ ${ARG_SUBROUTINE+set} ]]; then
	die "Bad usage: $0 --sub='$ARG_SUBROUTINE'"
fi

#
# main
#

if (( ARG_RESET )); then
	rm -rf "$WORKDIR_ROOT"
fi

if (( $# )); then
	PKGBUILDS=( "$@" )
else
	cat "$PKG_LIST" \
		| sed -r 's|[[:space:]]*#.*||g' \
		| grep -vE "^$" \
		| readarray -t PKGBUILDS
fi

print_array "${PKGBUILDS[@]}" | grep -Fvxf <(print_array "${ARGS_EXCLUDE[@]}") | readarray -t PKGBUILDS

mkdir -p "$WORKDIR_ROOT"
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


rc=0
set +e
if (( ${#FETCH_PKGBUILDS[@]} )); then
	parallel --bar "$0 ${ARGS_PASS[*]@Q} --sub=fetch {}" ::: "${FETCH_PKGBUILDS[@]}" && rc=0 || rc=$?
else
	rc=$?
fi
set -e

if (( rc )) && [[ -e "$FETCH_ERR_LIST.new" ]]; then
	mv "$FETCH_ERR_LIST.new" "$FETCH_ERR_LIST"
	cat "$FETCH_ERR_LIST" \
		| sort -u \
		| readarray -t failed
	rc="${#failed[@]}"

	err "failed to update some packages (count=$rc)"
	print_array "${failed[@]}" >&2
	exit 1
elif (( rc )); then
	err "failed to run fetch"
	exit 1
fi
rm -f "$FETCH_ERR_LIST"{,.new}

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
