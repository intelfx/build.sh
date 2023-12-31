#!/bin/bash

# HACK: fix up $PATH once we are running in clean environment
# (/usr/bin/core_perl/pod2man)
if [[ ${BLD_REEXECUTED+set} && ! ${BLD_HAS_PROFILE+set} ]]; then
	. /etc/profile
	#. $HOME/.profile
	. $HOME/.profile.pkgbuild
	export BLD_HAS_PROFILE=1
fi

. $HOME/bin/lib/lib.sh || exit
shopt -s nullglob

#
# constants
#

PKGBUILD_ROOT="$HOME/pkgbuild"
TARGETS_FILE="$PKGBUILD_ROOT/packages.txt"

WORKDIR_ROOT="$HOME/.pkgbuild.work"
WORKDIR_MAX_AGE_SEC=3600
REPO_NAME="custom"
MAKEPKG_CONF="/etc/aurutils/makepkg-$REPO_NAME.conf"
PACMAN_CONF="/etc/aurutils/pacman-$REPO_NAME.conf"
SCRATCH_ROOT="/mnt/ssd/Scratch/makepkg"
CCACHE_ROOT="/mnt/ssd/Scratch/makepkg-ccache"
SCCACHE_ROOT="/mnt/ssd/Scratch/makepkg-sccache"
CONTAINERS_ROOT="/mnt/ssd/Scratch/makepkg-containers"
unset CHROOT_PATH  # NOTE: queried and set below

# XXX: host-specific hardcodes
SYSTEMD_RUN=(
	sudo systemd-run
)
SYSTEMD_RUN_ARGS=(
	-p Slice=system-cpu.slice
	-p CPUSchedulingPolicy=batch
	-p Nice=18
	-E SSH_AUTH_SOCK
)

#
# arguments & usage
#

_usage() {
	cat <<EOF
Usage: $0 foobar
EOF
}

declare -A ARGS=(
	[--sub:]=ARG_SUBROUTINE
	[--margs:]="ARGS_MAKEPKG split=, append pass=ARGS_PASS"
	[--exclude:]="ARGS_EXCLUDE split=, append pass=ARGS_PASS"
	[--rebuild]="ARG_REBUILD pass=ARGS_PASS"
	[--no-pull]="ARG_NOPULL pass=ARGS_PASS"
	[--no-chroot]="ARG_NO_CHROOT pass=ARGS_PASS"
	[--keep-chroot]="ARG_KEEP_CHROOT pass=ARGS_PASS"
	[--reuse-chroot]="ARG_REUSE_CHROOT pass=ARGS_PASS"
	[--isolate-chroot]="ARG_ISOLATE_CHROOT pass=ARGS_PASS"
	[--unclean]="ARG_UNCLEAN pass=ARGS_PASS"
	[--no-ccache]="ARG_NO_CCACHE pass=ARGS_PASS"
	[--reset]=ARG_RESET
	[--continue]=ARG_CONTINUE
	[--]=ARG_TARGETS
)
parse_args ARGS "$@" || usage

# convert some arguments from a user-preferred form into the
# developer-preferred form
if (( (ARG_NO_CHROOT + ARG_KEEP_CHROOT + ARG_REUSE_CHROOT) > 1 )); then
	usage "--no-chroot, --keep-chroot and --reuse-chroot are mutually exclusive"
elif [[ ${ARG_NO_CHROOT+set} ]]; then
	ARG_CHROOT=no
elif [[ ${ARG_KEEP_CHROOT+set} ]]; then
	ARG_CHROOT=keep
elif [[ ${ARG_REUSE_CHROOT+set} ]]; then
	ARG_CHROOT=reuse
else
	ARG_CHROOT=transient
fi

if [[ ${ARG_NO_CHROOT+set} && ${ARG_ISOLATE_CHROOT+set} ]]; then
	usage "--no-chroot and --isolate-chroot are mutually exclusive"
fi

if ! [[ ${ARG_NO_CCACHE+set} ]]; then
	CHROOT_PKGS+=(
		ccache sccache
	)
fi

#
# functions
#

bld_has_workdir() {
	[[ ${BLD_WORKDIR+set} ]]
}

bld_make_workdir() {
	if bld_has_workdir; then
		return
	fi

	mkdir -p "$WORKDIR_ROOT"

	local workdir
	workdir="$(mktemp -d -p "$WORKDIR_ROOT")"
	ln -rsf "$workdir" -T "$WORKDIR_ROOT/last"
	log "Starting session $(basename "$workdir")"

	export BLD_WORKDIR="$workdir"
}

bld_use_workdir() {
	if bld_has_workdir; then
		return
	fi

	local workdir
	workdir="$(realpath -qe "$WORKDIR_ROOT/$1")"
	log "Entering session $(basename "$workdir")"

	export BLD_WORKDIR="$workdir"
}

bld_remove_workdir() {
	rm -rf "$WORKDIR_ROOT/$1"
}

bld_check_workdir() {
	[[ -d "$WORKDIR_ROOT/$1" ]]
}

bld_check_workdir_file() {
	[[ -f "$WORKDIR_ROOT/$1/$2" ]]
}

bld_check_workdir_file_nonempty() {
	[[ -f "$WORKDIR_ROOT/$1/$2" && -s "$WORKDIR_ROOT/$1/$2" ]]
}

bld_check_workdir_get_filename() {
	echo "$WORKDIR_ROOT/$1/$2"
}

bld_check_workdir_get_file() {
	cat "$WORKDIR_ROOT/$1/$2"
}

bld_workdir_file() {
	echo "$BLD_WORKDIR/$1"
}

bld_workdir_check_dir() {
	[[ -d "$BLD_WORKDIR/$1" ]]
}

bld_workdir_put_dir() {
	mkdir -p "$BLD_WORKDIR/$1"
}

bld_workdir_clean_dir() {
	rm -rf "$BLD_WORKDIR/$1"
	mkdir -p "$BLD_WORKDIR/$1"
}

bld_workdir_list_dir() {
	if ! [[ -e "$BLD_WORKDIR/$1" ]]; then
		return 0
	fi
	find "$BLD_WORKDIR/$1/" -mindepth 1 -maxdepth 1 -printf '%P\n'
}

bld_workdir_check_file() {
	[[ -f "$BLD_WORKDIR/$1" ]]
}

bld_workdir_get_file() {
	if ! [[ -e "$BLD_WORKDIR/$1" ]]; then
		err "bld_workdir_get_file: file does not exist: $BLD_WORKDIR/$1"
	fi
	cat "$BLD_WORKDIR/$1"
}

bld_workdir_put_file() {
	TMPDIR="$BLD_WORKDIR" sponge "$BLD_WORKDIR/$1"
}

bld_workdir_put_mark() {
	touch "$BLD_WORKDIR/$1"
}

bld_workdir_mark_finished() {
	bld_workdir_put_mark ".finished"
}

bld_workdir_update_timestamp() {
	touch "$(bld_workdir_file ".timestamp")"
}

bld_not_want_workdir() {
	bld_check_workdir "$1" || return 0
	bld_check_workdir_file "$1" ".finished" && return 0
	bld_check_workdir_file_nonempty "$1" "targets" || return 0
	return 1
}

bld_want_workdir() {
	# basic checks
	bld_not_want_workdir "$1" && return 1

	# if --reset, never use a workdir
	if [[ ${ARG_RESET+set} ]]; then
		return 1
	fi

	# check timestamp
	# (if --continue, keep going)
	if bld_check_workdir_file "$1" ".timestamp"; then
		local a="$(stat -c '%Y' "$(bld_check_workdir_get_filename "$1" ".timestamp")")"
		local b="$(date '+%s')"
		if ! (( a > b - WORKDIR_MAX_AGE_SEC )); then
			if [[ ${ARG_CONTINUE+set} ]]; then
				warn "bld: workdir $1 older than ${WORKDIR_MAX_AGE_SEC}s (continuing anyway)"
			else
				log "bld: not using workdir $1 -- older than ${WORKDIR_MAX_AGE_SEC}s"
				return 1
			fi
		fi
	fi

	# check targets consistency
	# (if --continue, keep going, unless there is a gross mismatch)
	if bld_check_workdir_file "$1" "targets_file"; then
		# workdir has implicit targets -- verify they did not change
		if [[ ${ARG_TARGETS+set} ]]; then
			if [[ ${ARG_CONTINUE+set} ]]; then
				warn "bld: not using workdir $1 -- explicit targets set"
			else
				log "bld: not using workdir $1 -- explicit targets set"
			fi
			return 1
		fi
		local a="$(bld_check_workdir_get_file "$1" "targets_file")"
		local b="$(cat_config "$TARGETS_FILE")"
		if ! [[ $a == $b ]]; then
			if [[ ${ARG_CONTINUE+set} ]]; then
				warn "bld: workdir $1 has different targets (continuing anyway)"
			else
				log "bld: not using workdir $1 -- targets file changed"
				return 1
			fi
		fi
	elif bld_check_workdir_file "$1" "targets_list"; then
		# workdir has explicit targets -- verify they either did not change, or are absent
		if ! [[ ${ARG_TARGETS+set} ]]; then
			return 0
		fi
		local a="$(bld_check_workdir_get_file "$1" "targets_list")"
		local b="$(print_array "${ARG_TARGETS[@]}")"
		if ! [[ $a == $b ]]; then
			if [[ ${ARG_CONTINUE+set} ]]; then
				warn "bld: not using workdir $1 -- explicit targets changed"
			else
				log "bld: not using workdir $1 -- explicit targets changed"
			fi
			return 1
		fi
	else
		err "bld: bad workdir $1 -- targets_{file,list} not present"
		return 1
	fi
	return 0
}

bld_setup() {
	# just print the global settings
	log "Working directory:  $BLD_WORKDIR"
	log "Build directory:    $SCRATCH_ROOT"
	log "PKGBUILD directory: $PKGBUILD_ROOT"
	log "Targets list file:  $TARGETS_FILE"
	log "Target repo name:   $REPO_NAME"
	log "pacman.conf:        $PACMAN_CONF"
	log "makepkg.conf:       $MAKEPKG_CONF"

	if ! [[ ${ARG_NO_CCACHE+set} ]]; then
		MAKEPKG_CONF_CCACHE="$BLD_WORKDIR/makepkg+ccache.conf"

		cp -f "$MAKEPKG_CONF" -T "$MAKEPKG_CONF_CCACHE" -n
		cat >>"$MAKEPKG_CONF_CCACHE" <<EOF

#########################################################################
# build.sh CCACHE CONFIGURATION
#########################################################################
BUILDENV+=( ccache )
export RUSTC_WRAPPER="/usr/bin/sccache"
export CCACHE_DIR="$CCACHE_ROOT"
export CCACHE_CONFIGPATH="$CCACHE_ROOT/ccache.conf"
export SCCACHE_DIR="$SCCACHE_ROOT"
export SCCACHE_CONF="$SCCACHE_ROOT/sccache.conf"
export SCCACHE_IDLE_TIMEOUT=60
export CCACHE_BASEDIR="\$BUILDDIR"
EOF
		ltrap "rm -f '$MAKEPKG_CONF_CCACHE'"
		# pass $MAKEPKG_CONF_CCACHE to subprocesses, which will
		# then be read in setup_one()
		# FIXME this is dirty
		export MAKEPKG_CONF_CCACHE

		log "makepkg.conf (ccache): $MAKEPKG_CONF_CCACHE"
	fi
}

bld_target_get_dir() {
	local pkgbase="$1"
	# TODO: scan and collect packages from subdirs
	local dir="$PKGBUILD_ROOT/$pkgbase"
	# do not check for existence or locate PKGBUILD
	echo "$dir"
}

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
		case "$ARG_CHROOT" in
		no) ;;
		keep) aurbuild_args+=( -c ) ;;
		reuse) aurbuild_args+=( -c --cargs-no-default ) ;;
		transient) aurbuild_args+=( -c -T ) ;;
		*) die "Internal error: $(declare -p ARG_CHROOT)" ;;
		esac

		if [[ $ARG_CHROOT != no ]]; then
			if ! [[ ${ARG_ISOLATE_CHROOT+set} ]]; then
				aurbuild_args+=(
					--bind-rw "$SCRATCH_ROOT":/build
					--bind-rw "$CONTAINERS_ROOT":/build/.local/share/containers
				)
			fi
			if ! [[ ${ARG_NO_CCACHE+set} ]]; then
				aurbuild_args+=(
					--bind-rw "$CCACHE_ROOT"
					--bind-rw "$SCCACHE_ROOT"
				)
			fi

			# XXX ridiculously ugly host-dependent hack for launching
			# podman containers inside systemd-nspawn because kernel
			# wants to see a full proc on the host (inside the nspawn)
			# prior to allowing a mount of proc inside of the userns
			# (and nspawn obscures parts of proc by overmounting
			#  without an option to prevent that)
			#
			# The fun begins when there's more than one layer of
			# nspawn in the mix, which means we gotta pass an
			# unobscured proc from the top level.
			aurbuild_args+=(
				--bind-rw /proc2:/proc2
				--bind-rw /sys2:/sys2
			)
		fi

		if ! [[ ${ARG_UNCLEAN+set} ]]; then
			# optionally drop --clean here...
			makepkg_args_prepare=( --cleanbuild --clean )
			# ...and --cleanbuild here for a bit more spead and a bit less isolation
			makepkg_args_build=( --cleanbuild --clean )
		else
			makepkg_args_prapare=()
			makepkg_args_build=()
		fi
	esac
	aurbuild_args+=( --remove )
	makepkg_args_prepare+=( "${ARGS_MAKEPKG[@]}" )
	makepkg_args_build+=( "${ARGS_MAKEPKG[@]}" )

	# FIXME this is dirty
	if ! [[ ${ARG_NO_CCACHE+set} ]]; then
		MAKEPKG_CONF="$MAKEPKG_CONF_CCACHE"
		aurbuild_args+=(
			-I ccache
			-I sccache
		)
	fi
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

bld_aur_repo() {
	aur repo \
		-d "$REPO_NAME" \
		--config "$PACMAN_CONF" \
		"$@"
}

bld_aur_chroot() {
	aur chroot \
		--suffix "$REPO_NAME" \
		--pacman-conf "$PACMAN_CONF" \
		--makepkg-conf "$MAKEPKG_CONF" \
		"$@"
}

bld_aur_build_dry() {
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

bld_aur_build() {
	aur build \
		-d "$REPO_NAME" \
		--pacman-conf "$PACMAN_CONF" \
		--makepkg-conf "$MAKEPKG_CONF" \
		"${aurbuild_args[@]}" \
		--margs "$(join ',' "${makepkg_args_build[@]}")" \
		"$@"
}

bld_aur_srcver() {
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


#
# subroutine driver
# (harness that invokes a single subroutine for given targets,
# tracking progress and errors)
#

bld_phase_load_status() {
	declare -n targets="$1"
	declare -n msgs="$2"

	local id="${msgs[id]}"

	bld_workdir_list_dir "${id}-ok" | readarray -t BLD_PHASE_OK
	bld_workdir_list_dir "${id}-err" | readarray -t BLD_PHASE_ERR

	declare -a aliens
	set_difference_a BLD_PHASE_OK targets aliens
	if [[ ${aliens+set} ]]; then
		die "Workdir inconsistent -- '${id}-ok' record contains unknown packages (n=${#aliens[@]}): ${aliens[*]}"
	fi
	set_difference_a BLD_PHASE_ERR targets aliens
	if [[ ${aliens+set} ]]; then
		die "Workdir inconsistent -- '${id}-err' record contains unknown packages (n=${#aliens[@]}): ${aliens[*]}"
	fi

	set_difference_a targets BLD_PHASE_OK BLD_PHASE_TODO
	set_difference_a BLD_PHASE_TODO BLD_PHASE_ERR BLD_PHASE_MISSING
}

bld_phase() {
	declare -n targets="$1"
	declare -n msgs="$2"
	local fn="$3"

	bld_phase_load_status "$1" "$2"

	if [[ ${BLD_PHASE_OK+set} && ${BLD_PHASE_TODO+set} ]]; then
		logf "${msgs[todo_partial]}" "${#BLD_PHASE_OK[@]}" "${#BLD_PHASE_TODO[@]}"
	elif [[ ${BLD_PHASE_TODO+set} ]]; then
		logf "${msgs[todo]}" "${#BLD_PHASE_TODO[@]}"
	else
		logf "${msgs[todo_empty]}"
	fi

	bld_workdir_put_dir "${msgs[id]}-ok"
	bld_workdir_clean_dir "${msgs[id]}-err"

	local rc=0
	if [[ ${BLD_PHASE_TODO+set} ]]; then
		"$fn" "${BLD_PHASE_TODO[@]}" || rc=$?
	fi

	bld_phase_load_status "$1" "$2"

	local err=0
	if [[ ${BLD_PHASE_ERR+set} ]]; then
		err=1
		errf "${msgs[failed]}" "${#BLD_PHASE_ERR[@]}"
		err "$(join ", " "${BLD_PHASE_ERR[@]}")"
	fi
	if [[ ${BLD_PHASE_MISSING+set} ]]; then
		err=1
		errf "${msgs[missed]}" "${#BLD_PHASE_MISSING[@]}"
		err "$(join ", " "${BLD_PHASE_MISSING[@]}")"
	fi

	if (( rc && err )); then
		dief "${msgs[die_failed]}"
	elif (( !rc && err )); then
		dief "${msgs[die_missed]}"
	elif (( rc && !err )); then
		dief "${msgs[die_rc]}"
	fi
}

#
# subroutines
#

bld_sub_build() {
	local pkg pkg_dir pkgbuild_dir
	declare -a aurbuild_args makepkg_args_prepare makepkg_args_build
	setup_one "$@"
	cd "$pkgbuild_dir"

	if ! bld_aur_build_dry | sponge | grep -qE '^build:'; then
		BLD_OK=1
		return
	fi
	bld_aur_build

	BLD_OK=1
}

bld_sub_fetch() {
	eval "$(ltraps)"
	local pkg pkg_dir pkgbuild_dir
	declare -a aurbuild_args makepkg_args_prepare makepkg_args_build

	setup_one_pre "$@"

	if ! [[ -d "$pkg_dir" ]]; then
		cd "$(dirname "$pkg_dir")"
		if asp list-all | sponge | grep -q -Fx "$pkg"; then
			asp checkout "$pkg"
		elif aur_list "$pkg" | sponge | grep -q -Fx "$pkg"; then
			git clone "https://aur.archlinux.org/$pkg"
		else
			err "pkgbase could not be found: $pkg"
			return 1
		fi
	fi

	setup_one "$@"

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
			ltrap "rm -f '$pkgbuild_bak' '$pkgbuild_diff'"
			ltrap "mv -f '$pkgbuild_bak' '$pkgbuild'"
			cp -a "$pkgbuild" "$pkgbuild_bak"
			git diff "$pkgbuild" \
				| sed -r \
					-e ' /^\+(pkgver|pkgrel)=/d' \
					-e 's/^\-(pkgver|pkgrel)=/ \1=/' \
				>"$pkgbuild_diff"
			git checkout -f "$pkgbuild"
			git apply --recount --allow-empty "$pkgbuild_diff"
			luntrap
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
				#asp update "$pkg"
				flock -x -w 10 "$_asproot/.asp" asp update "$asppkg"
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

	cd "$pkgbuild_dir"
	bld_aur_srcver

	# pkgrel= was reset above
	# bump pkgrel= if --rebuild is indicated, or match to repo contents otherwise (to prevent building a package with a lower pkgrel than repo contents)

	generate_srcinfo

	local pkg_old pkg_old_ver pkg_old_rel
	bld_aur_repo --table | sponge | awk -v pkgbase=$pkg 'BEGIN { FS="\t" } $3 == pkgbase { print $4; exit }' | read pkg_old \
		|| true
	pkg_old_rel="${pkg_old##*-}"
	pkg_old_ver="${pkg_old%-*}"

	local pkg_cur pkg_cur_epoch pkg_cur_ver pkg_cur_rel
	# FIXME: proper .SRCINFO parser
	# FIXME: split package handling
	sed -nr 's|^\tepoch = (.+)$|\1|p' .SRCINFO | head -n1 | read pkg_cur_epoch \
		|| true
	sed -nr 's|^\tpkgver = (.+)$|\1|p' .SRCINFO | head -n1 | read pkg_cur_ver \
		|| die "no pkgver in .SRCINFO: $PWD/.SRCINFO"
	sed -nr 's|^\tpkgrel = (.+)$|\1|p' .SRCINFO | head -n1 | read pkg_cur_rel \
		|| die "no pkgrel in .SRCINFO: $PWD/.SRCINFO"
	pkg_cur_ver="${pkg_cur_epoch:+$pkg_cur_epoch:}$pkg_cur_ver"
	pkg_cur="$pkg_cur_ver-$pkg_cur_rel"
	dbg "$pkg:     repo: pkgver=$pkg_old_ver, pkgrel=$pkg_old_rel (input=$pkg_old)"
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

	BLD_OK=1
}

bld_sub_fetch__exit() {
	if (( BLD_OK )); then
		bld_workdir_put_mark "fetch-ok/${ARG_TARGETS}"
	else
		bld_workdir_put_mark "fetch-err/${ARG_TARGETS}"
	fi
}

bld_sub_build__exit() {
	if (( BLD_OK )); then
		bld_workdir_put_mark "build-ok/${ARG_TARGETS}"
	else
		bld_workdir_put_mark "build-err/${ARG_TARGETS}"
	fi
}


#
# main
#

# Reexecute in clean environment
if ! [[ ${BLD_REEXECUTED+set} ]]; then
	exec "${SYSTEMD_RUN[@]}" \
		--pty \
		--same-dir \
		--wait \
		--collect \
		--service-type=exec \
		"${SYSTEMD_RUN_ARGS[@]}" \
		-p User=$(id -un) \
		-E BLD_REEXECUTED=1 \
		"$BASH_SOURCE" "$@"
fi

eval "$(globaltraps)"
BLD_OK=0

# Execute a subroutine if requested
if [[ $ARG_SUBROUTINE == fetch ]]; then
	if (( ${#ARG_TARGETS[@]} != 1 )); then
		die "Bad usage: $0 ${@@Q}"
	fi
	ltrap "bld_sub_fetch__exit"
	bld_sub_fetch "${ARG_TARGETS[@]}"
	exit $(( BLD_OK ? 0 : 1 ))
elif [[ $ARG_SUBROUTINE == build ]]; then
	if (( ${#ARG_TARGETS[@]} != 1 )); then
		die "Bad usage: $0 ${@@Q}"
	fi
	ltrap "bld_sub_build__exit"
	bld_sub_build "${ARG_TARGETS[@]}"
	exit $(( BLD_OK ? 0 : 1 ))
elif [[ ${ARG_SUBROUTINE+set} ]]; then
	die "Bad usage: $0 ${@@Q}"
fi

# Prepare workdir
if ! bld_has_workdir; then
	# cleanup finished workdirs
	find "$WORKDIR_ROOT" -mindepth 1 -maxdepth 1 -type d | while read d; do
		name="$(basename "$d")"
		if bld_not_want_workdir "$name"; then
			log "Cleaning obsolete workdir $name"
			bld_remove_workdir "$name"
		fi
	done

	# TODO: look for other workdirs to continue, not just last
	if bld_want_workdir last; then
		bld_use_workdir last
	else
		bld_make_workdir
	fi
fi
bld_workdir_update_timestamp

# Load/compute settings
bld_setup

# Update chroot
if [[ $ARG_CHROOT != no ]]; then
	bld_aur_chroot --create --update
	CHROOT_PATH="$(bld_aur_chroot --path)"

	log "Hacking up subuid and subgid at $CHROOT_PATH"
	cat <<EOF | sudo sponge "$CHROOT_PATH/etc/subuid"
builduser:100000:65536
EOF
	cat <<EOF | sudo sponge "$CHROOT_PATH/etc/subgid"
builduser:100000:65536
EOF
	
	log "Hacking up /etc/containers/storage.conf at $CHROOT_PATH"
	sudo install -dm755 "$CHROOT_PATH/etc/containers"
	cat <<EOF | sudo sponge "$CHROOT_PATH/etc/containers/storage.conf"
[storage]
  driver_priority = [ "btrfs", "overlay" ]
EOF
fi

# Load targets
if bld_workdir_check_file "targets"; then
	bld_workdir_get_file "targets" | readarray -t BLD_TARGETS
else
	if [[ ${ARG_TARGETS+set} ]]; then
		BLD_TARGETS=( "${ARG_TARGETS[@]}" )
		print_array "${BLD_TARGETS[@]}" | bld_workdir_put_file "targets_list"
	else
		cat_config "$TARGETS_FILE" | readarray -t BLD_TARGETS
		print_array "${BLD_TARGETS[@]}" | bld_workdir_put_file "targets_file"
	fi

	set_difference_a BLD_TARGETS ARGS_EXCLUDE BLD_TARGETS
	print_array "${BLD_TARGETS[@]}" | bld_workdir_put_file "targets"
fi

# Fetch targets
# TODO: dependency resolution
declare -A FETCH_MSGS=(
	[id]='fetch'  # should match <id>-ok, <id>-err directories
	[todo]='Updating (%d targets)'
	[todo_partial]='Updating (%d targets fetched, %d targets left)'
	[todo_empty]='Nothing to fetch'
	[failed]='Failed to fetch %d packages:'
	[missed]='Did not fetch %d packages:'
	[die_failed]='Failed to fetch some packages, aborting'
	[die_missed]='Missed some packages while fetching, aborting'
	[die_rc]='Encountered other errors while fetching, aborting'
)
_phase_fetch() {
	parallel --bar "$0 ${ARGS_PASS[@]@Q} --sub=fetch {}" ::: "$@" || rc=$?
}
bld_phase BLD_TARGETS FETCH_MSGS _phase_fetch

# Build targets
# TODO: determine which targets need to be built
declare -A BUILD_MSGS=(
	[id]='build'  # should match <id>-ok, <id>-err directories
	[todo]='Building (%d targets)'
	[todo_partial]='Building (%d targets built, %d targets left)'
	[todo_empty]='Nothing to build'
	[failed]='Failed to build %d packages:'
	[missed]='Did not build %d packages:'
	[die_failed]='Failed to build some packages, aborting'
	[die_missed]='Missed some packages while building, aborting'
	[die_rc]='Encountered other errors while building, aborting'
)
_phase_build() {
	local p
	for p; do
		"$0" "${ARGS_PASS[@]}" --sub=build "$p" || rc=$?  # keep going
	done
}
bld_phase BLD_TARGETS BUILD_MSGS _phase_build

bld_workdir_mark_finished
