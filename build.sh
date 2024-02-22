#!/bin/bash

BLD_ROOT_DIR="$(dirname "$BASH_SOURCE")"
BLD_CONFIG_DEFAULT="$BLD_ROOT_DIR/config.sh"

. "$BLD_ROOT_DIR/libbuild/libbuild.sh" || exit


#
# arguments & usage
#

_usage_common_syntax="Usage: $BLD_ARGV0 [-c|--config CONFIG]"
_usage_common_options="
Global options:
	-h|--help		Print this usage help
	-c|--config CONFIG 	Path to main configuration file or directory
"

_usage() {
	cat <<EOF
$BLD_ARGV0 -- opinionated package builder

$_usage_common_syntax [OPTIONS...] [PACKAGES...]
$_usage_common_options

Meta options:
	--reset
	--continue[=SESSION]

Package selection options:
	--exclude PACKAGE[,...]

Behavior modifiers:
	--rebuild
	--no-pull
	--no-fetch
	--no-build

Build environment options:
	--no-ccache
	--no-chroot
	--keep-chroot
	--reuse-chroot
	--isolate-chroot
	--unclean

Build process options:
	--margs MAKEPKG-ARG[,...]
EOF
}

declare -A ARGS=(
	[-h|--help]=ARG_HELP
	[--verbose]="ARG_VERBOSE pass=ARGS_PASS"
	[--debug]="ARG_DEBUG pass=ARGS_PASS"
	[--config:]="ARG_CONFIG pass=ARGS_PASS"
	[--sub:]=ARG_SUBROUTINE
	[--margs:]="ARGS_MAKEPKG split=, append pass=ARGS_PASS"
	[--exclude:]="ARGS_EXCLUDE split=, append pass=ARGS_PASS"
	[--rebuild]="ARG_REBUILD pass=ARGS_PASS"
	[--no-pull]="ARG_NOPULL pass=ARGS_PASS"
	[--no-fetch]="ARG_NOFETCH pass=ARGS_PASS"
	[--no-build]='ARG_NOBUILD pass=ARGS_PASS'
	[--no-chroot]="ARG_NO_CHROOT pass=ARGS_PASS"
	[--keep-chroot]="ARG_KEEP_CHROOT pass=ARGS_PASS"
	[--reuse-chroot]="ARG_REUSE_CHROOT pass=ARGS_PASS"
	[--isolate-chroot]="ARG_ISOLATE_CHROOT pass=ARGS_PASS"
	[--unclean]="ARG_UNCLEAN pass=ARGS_PASS"
	[--no-ccache]="ARG_NO_CCACHE pass=ARGS_PASS"
	[--reset]=ARG_RESET
	[--continue::]="ARG_CONTINUE default="
	[--]=ARG_TARGETS
)

parse_args ARGS "$@" || usage ""

if (( ARG_HELP )); then
	usage
fi

if (( ARG_DEBUG )); then
	set -x
	LIBSH_DEBUG=1
elif (( ARG_VERBOSE )); then
	LIBSH_DEBUG=1
fi


#
# config
#

source "${ARG_CONFIG-$BLD_CONFIG_DEFAULT}"


#
# constants
#

: ${PKGBUILD_ROOT="$HOME/pkgbuild"}
: ${TARGETS_FILE="$PKGBUILD_ROOT/packages.txt"}

: ${WORKDIR_ROOT="$HOME/.pkgbuild.work"}
: ${WORKDIR_MAX_AGE_SEC=3600}
: ${WORKDIR_HARD_MAX_AGE_SEC=86400}
: ${REPO_NAME=custom}
: ${MAKEPKG_CONF="/etc/aurutils/makepkg-$REPO_NAME.conf"}
: ${PACMAN_CONF="/etc/aurutils/makepkg-$REPO_NAME.conf"}
: ${SCRATCH_ROOT="/var/tmp/makepkg"}
: ${CCACHE_ROOT="/var/tmp/makepkg-ccache"}
: ${SCCACHE_ROOT="/var/tmp/makepkg-sccache"}
: ${CONTAINERS_ROOT="/var/tmp/makepkg-containers"}
unset CHROOT_PATH  # NOTE: queried and set below

[[ ${EXTRA_BIND_DIRS+set} ]] || \
EXTRA_BIND_DIRS=(
)

# XXX set this to EXTRA_BIND_APIVFS=("/proc:/proc2" "/sys:/sys2") if intending
# to run podman (or any other containers w/ userns) from PKGBUILDs in chrooted
# (systemd-nspawned) builds;
# if bld is running in a systemd-nspawn itself, pass /proc:/proc2 and /sys:/sys2
# from the top level into _this_ systemd-nspawn (or bind them from inside)
# and then set this to EXTRA_BIND_APIVFS=("/proc2:/proc2" "/sys2:/sys2").
#
# XXX this does not work, you need to patch devtools
#
# For details, see below...
#[[ ${EXTRA_BIND_APIVFS+set} ]] || \
#EXTRA_BIND_APIVFS=(
#)

[[ ${SYSTEMD_RUN+set} ]] || \
SYSTEMD_RUN=(
	sudo systemd-run
)

[[ ${SYSTEMD_RUN_ARGS+set} ]] || \
SYSTEMD_RUN_ARGS=(
)

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

	local workdir workname worklabel
	workdir="$(mktemp -d -p "$WORKDIR_ROOT" "$(date -Iminutes).XXX")"
	workname="${workdir#$WORKDIR_ROOT/}"
	worklabel="$workname"

	if ! bld_lock_workdir "$workname"; then
		die "failed to lock newly created workdir $worklabel"
	fi

	(
	# lock in a subshell
	if ! bld_check_workdir "last" || { bld_unlock; bld_lock_workdir "last" --nonblock; }; then
		ln -rsf "$workdir" -T "$WORKDIR_ROOT/last"
	else
		log "not updating workdir $(bld_workdir_label last) -- locked"
	fi
	)

	log "starting session $worklabel"

	export BLD_WORKDIR="$workdir"
	export BLD_WORKDIR_NAME="$workname"
}

bld_use_workdir() {
	if bld_has_workdir; then
		return
	fi

	local workdir workname worklabel
	workdir="$(realpath -qe "$WORKDIR_ROOT/$1")"
	workname="$(realpath -qe --relative-to="$WORKDIR_ROOT" --relative-base="$WORKDIR_ROOT" "$WORKDIR_ROOT/$1")"
	worklabel="$(bld_workdir_label "$1")"

	if ! [[ $workname != /* ]]; then
		die "invalid workdir: $1"
	fi

	if ! bld_lock_workdir "$workname" --nonblock; then
		err "failed to lock workdir $worklabel"
		return 1
	fi

	log "entering session $worklabel"

	export BLD_WORKDIR="$workdir"
	export BLD_WORKDIR_NAME="$workname"
}

bld_lock_workdir() {
	local lockfile
	lockfile="$(bld_check_workdir_get_filename "$1" ".lock")"
	shift 1

	touch "$lockfile"
	if ! [[ -e /dev/fd/9 ]]; then
		exec 9<"$lockfile"
	elif ! [[ $lockfile -ef /dev/fd/9 ]]; then
		die "attempting to lock another workdir"
	fi
	if ! flock "$@" 9; then
		exec 9<&-
		return 1
	fi
}

bld_lock_workdir_trap() {
	ltrap "bld_unlock_workdir '$1'"
	bld_lock_workdir "$@" || { rc=$?; luntrap; return $rc; }
}

bld_unlock_workdir() {
	local lockfile
	lockfile="$(bld_check_workdir_get_filename "$1" ".lock")"
	shift 1

	if ! [[ "$lockfile" -ef /dev/fd/9 ]]; then
		err "not unlocking workdir $(bld_workdir_label "$1") -- not locked"
		return 1
	fi
	exec 9<&-
}

bld_unlock() {
	if ! [[ -e /dev/fd/9 ]]; then
		err "not unlocking workdir -- not locked"
		return 1
	fi
	exec 9<&-
}

bld_workdir_label() {
	local workdir
	workdir="$(realpath --relative-to="$WORKDIR_ROOT" --relative-base="$WORKDIR_ROOT" "$WORKDIR_ROOT/$1")"
	if [[ $workdir == $1 ]]; then
		echo "$1"
	else
		echo "$1 ($workdir)"
	fi
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

bld_check_workdir_stat_file() {
	[[ -e "$WORKDIR_ROOT/$1/$2" ]] && stat "$WORKDIR_ROOT/$1/$2" -c "$3" "${@:4}"
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
		return 1
	fi
	cat "$BLD_WORKDIR/$1"
}

bld_workdir_get_file_name() {
	if ! [[ -e "$BLD_WORKDIR/$1" ]]; then
		err "bld_workdir_get_file: file does not exist: $BLD_WORKDIR/$1"
		return 1
	fi
	echo "$BLD_WORKDIR/$1"
}

bld_workdir_put_file() {
	TMPDIR="$BLD_WORKDIR" sponge "$BLD_WORKDIR/$1"
}

bld_workdir_delete_file() {
	rm -f "$BLD_WORKDIR/$1"
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
	# is workdir inaccessible?
	bld_check_workdir "$1" || return 0
	# is workdir finished?
	! bld_check_workdir_file "$1" ".finished" || return 0
	# does workdir have no targets?
	bld_check_workdir_file_nonempty "$1" "targets" || return 0
	# does workdir have no timestamp?
	bld_check_workdir_file "$1" ".timestamp" || return 0

	local a b 
	a="$(bld_check_workdir_stat_file "$1" ".timestamp" '%Y')" || return 0
	b="$(date '+%s')"
	# is workdir _VERY_ old?
	(( a > b - WORKDIR_HARD_MAX_AGE_SEC )) || return 0

	return 1
}

bld_want_workdir() {
	# if --reset, never use a workdir
	if [[ ${ARG_RESET+set} ]]; then
		return 1
	fi

	# basic checks
	bld_not_want_workdir "$1" && return 1

	local label
	label="$(bld_workdir_label "$1")"

	# check lock
	eval "$(ltraps)"
	if ! bld_lock_workdir_trap "$1" --nonblock; then
		log "not using workdir $label -- locked"
		return 1
	fi

	# check timestamp
	# (if --continue, keep going)
	local a b 
	a="$(bld_check_workdir_stat_file "$1" ".timestamp" '%Y')"
	b="$(date '+%s')"
	if ! (( a > b - WORKDIR_MAX_AGE_SEC )); then
		if [[ ${ARG_CONTINUE+set} ]]; then
			warn "workdir $label older than ${WORKDIR_MAX_AGE_SEC}s (continuing anyway)"
		else
			log "not using workdir $label -- older than ${WORKDIR_MAX_AGE_SEC}s"
			return 1
		fi
	fi

	# check targets consistency
	# (if --continue, keep going, unless there is a gross mismatch)
	if bld_check_workdir_file "$1" "targets_file"; then
		# workdir has implicit targets -- verify they did not change
		if [[ ${ARG_TARGETS+set} ]]; then
			if [[ ${ARG_CONTINUE+set} ]]; then
				warn "not using workdir $label -- explicit targets set"
			else
				log "not using workdir $label -- explicit targets set"
			fi
			return 1
		fi
		local a="$(bld_check_workdir_get_file "$1" "targets_file")"
		local b="$(cat_config "$TARGETS_FILE")"
		if ! [[ $a == $b ]]; then
			if [[ ${ARG_CONTINUE+set} ]]; then
				warn "workdir $label has different targets (continuing anyway)"
			else
				log "not using workdir $label -- targets file changed"
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
				warn "not using workdir $label -- explicit targets changed"
			else
				log "not using workdir $label -- explicit targets changed"
			fi
			return 1
		fi
	else
		err "bad workdir $label -- targets_{file,list} not present"
		return 1
	fi

	# return locked
	luntrap
	return 0
}

bld_setup_workdir() {
	# cleanup finished workdirs
	find "$WORKDIR_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | while read name; do
		if bld_not_want_workdir "$name"; then
			log "removing obsolete session $name"
			bld_remove_workdir "$name"
		fi
	done

	# NOTE: $ARG_CONTINUE is used both as a session name (when nonempty)
	#       and as a behavior modifier inside bld_want_workdir() (when set).
	#       Since we generally want to use the session we were given (i. e.
	#       we want that modifier when handling an explicitly given workdir),
	#       it all works out.
	if [[ ${ARG_CONTINUE:+nonempty} ]]; then
		if bld_want_workdir "$ARG_CONTINUE" && bld_use_workdir "$ARG_CONTINUE"; then
			return
		else
			die "failed to enter session $ARG_CONTINUE"
		fi
	elif bld_want_workdir last && bld_use_workdir last; then
		return
	else
		bld_make_workdir
	fi
}

bld_check_vars() {
	bld_workdir_check_file "vars"
}

bld_check_vars_loaded() {
	[[ ${BLD_LOADED_VARS+set} ]]
}

bld_reset_vars() {
	bld_workdir_delete_file "vars"
	declare -g -A BLD_SAVED_VARS=()
	unset BLD_LOADED_VARS
}

bld_mark_vars() {
	local arg
	for arg; do
		BLD_SAVED_VARS["$arg"]=1
	done
}

bld_commit_vars() {
	# marker variable for bld_check_vars_loaded()
	# NOTE: this way, it will also evaluate true after _saving_ vars
	#       as opposed to _loading_ them, but arguably this is right
	#       because save + load is idempotent
	BLD_LOADED_VARS=1
	BLD_SAVED_VARS[BLD_LOADED_VARS]=1

	# ignore non-existent variables
	{ declare -p \
		BLD_SAVED_VARS \
		"${!BLD_SAVED_VARS[@]}" \
		2>/dev/null || true; } \
	| sed -r 's|^declare\>|& -g|' \
	| bld_workdir_put_file "vars"
}

bld_save_vars() {
	bld_mark_vars "$@"
	bld_commit_vars
}

bld_load_vars() {
	local vars
	vars="$(bld_workdir_get_file_name "vars")"
	source "$vars"
}

bld_setup() {
	if bld_check_vars_loaded; then
		die "bld_setup() called twice!"
	fi

	if ! [[ ${ARG_NO_CCACHE+set} ]]; then
		local f="makepkg+ccache.conf"
		cat "$MAKEPKG_CONF" - <<EOF | bld_workdir_put_file "$f"

#########################################################################
# build.sh CCACHE CONFIGURATION
#########################################################################
BUILDENV+=( ccache )
export RUSTC_WRAPPER="/usr/bin/sccache"
export CCACHE_DIR="$CCACHE_ROOT"
export CCACHE_CONFIGPATH="$CCACHE_ROOT/ccache.conf"
export SCCACHE_DIR="$SCCACHE_ROOT"
export SCCACHE_CONF="$SCCACHE_ROOT/sccache.conf"

# Unholy hack because makechrootpkg _appends_ BUILDDIR= to the makepkg.conf,
# and we want the final \$BUILDDIR, not the one that's set by this point.
trap 'export CCACHE_BASEDIR="\$BUILDDIR"' RETURN
EOF

		MAKEPKG_CONF="$(bld_workdir_get_file_name "$f")"
		log "makepkg.conf (ccache): $MAKEPKG_CONF"
	fi

	log "working directory:  $BLD_WORKDIR"
	log "build directory:    $SCRATCH_ROOT"
	log "PKGBUILD directory: $PKGBUILD_ROOT"
	log "targets list file:  $TARGETS_FILE"
	log "target repo name:   $REPO_NAME"
	log "pacman.conf:        $PACMAN_CONF"
	log "makepkg.conf:       $MAKEPKG_CONF"
	log "chroot:             ${ARG_CHROOT}${ARG_ISOLATE_CHROOT+,isolated}"

	bld_reset_vars

	# Save arguments
	bld_mark_vars \
		ARGS_MAKEPKG \
		ARGS_EXCLUDE \
		ARG_REBUILD \
		ARG_NOPULL \
		ARG_NOFETCH \
		ARG_NOBUILD \
		ARG_NO_CHROOT \
		ARG_KEEP_CHROOT \
		ARG_REUSE_CHROOT \
		ARG_ISOLATE_CHROOT \
		ARG_UNCLEAN \
		ARG_NO_CCACHE \
		ARG_RESET \
		ARG_CONTINUE \

	# Save computed variables
	bld_mark_vars \
		MAKEPKG_CONF \
		CHROOT_PKGS \
		CHROOT_PATH \

	bld_commit_vars
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
	linux|linux-*)
		# non-clean builds
		local ARG_UNCLEAN=1
		;;
	*)
		;;
	esac

	# set up chroot
	case "$ARG_CHROOT" in
	no) ;;
	keep) aurbuild_args+=( -c ) ;;
	reuse) aurbuild_args+=( -c --cargs-no-default ) ;;
	transient) aurbuild_args+=( -c -T ) ;;
	*) die "internal error: $(declare -p ARG_CHROOT)" ;;
	esac

	# configure chroot
	if [[ $ARG_CHROOT != no ]]; then
		if ! [[ ${ARG_ISOLATE_CHROOT+set} ]]; then
			aurbuild_args+=(
				--bind-rw "$SCRATCH_ROOT":/build
				--bind-rw "$CONTAINERS_ROOT":/build/.local/share/containers
			)

			local dir
			for dir in "${EXTRA_BIND_DIRS[@]}"; do
				aurbuild_args+=(
					--bind "$dir:$dir"
				)
			done
		fi
		if ! [[ ${ARG_NO_CCACHE+set} ]]; then
			aurbuild_args+=(
				--bind-rw "$CCACHE_ROOT"
				--bind-rw "$SCCACHE_ROOT"
			)
			aurbuild_args+=(
				-I ccache
				-I sccache
			)
		fi

		# XXX ridiculously ugly host-dependent hack for launching
		# podman containers inside systemd-nspawn because kernel
		# wants to see an unobscured proc _somewhere_ prior to
		# allowing podman to mount a new proc inside the userns
		# "you need a /proc mount to be fully visible before you
		# can mount a new proc"
		# (cf. https://github.com/containers/podman/issues/9813)
		# and nspawn obscures parts of proc by overmounting
		# without an option to prevent that.
		#
		# The fun begins when there's more than one layer of
		# nspawn in the mix, which means we gotta pass an
		# unobscured proc from the top level.
		#
		# XXX podman also needs --system-call-filter @keyring,
		# so we have to patch devtools anyway...

		#local dir
		#for dir in "${EXTRA_BIND_APIVFS[@]}"; do
		#	aurbuild_args+=(
		#		--bind-rw "$dir"
		#	)
		#done
	fi

	# set up srcdir cleanup
	if ! [[ ${ARG_UNCLEAN+set} ]]; then
		# optionally drop --clean here...
		makepkg_args_prepare=( --cleanbuild --clean )
		# ...and --cleanbuild here for a bit more spead and a bit less isolation
		makepkg_args_build=( --cleanbuild --clean )
	else
		makepkg_args_prepare=()
		makepkg_args_build=()
	fi

	# add default, config and command-line args
	aurbuild_args+=( --remove "${EXTRA_AURBUILD_ARGS[@]}" )
	makechrootpkg_args+=( "${EXTRA_MAKECHROOTPKG_ARGS[@]}" )
	makepkg_args_prepare+=( "${EXTRA_MAKEPKG_ARGS[@]}" "${ARGS_MAKEPKG[@]}" )
	makepkg_args_build+=( "${EXTRA_MAKEPKG_ARGS[@]}" "${ARGS_MAKEPKG[@]}" )
}

aur_list() {
	curl -fsS 'https://aur.archlinux.org/rpc/' -G -d v=5 -d type=info -d arg="$1" \
		| jq -r 'if (.version == 5 and .type == "multiinfo") then .results[].Name else "AUR response: \(.)\n" | halt_error(1) end'
}

generate_srcinfo() {
	if [[ .SRCINFO -ot PKGBUILD ]]; then
		aur build--pkglist --srcinfo >.SRCINFO
	fi
}

pkgver_extract() {
	local arg="$1"
	declare -n pkgver="$2" pkgrel="$3"
	pkgver="${arg%-*}"
	pkgrel="${arg##*-}"
}

bld_aur_repo() {
	aur repo \
		-d "$REPO_NAME" \
		--config "$PACMAN_CONF" \
		--root "$PACMAN_DB_PATH" \
		"$@" \
	| sponge
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
	{ aur build \
		-d "$REPO_NAME" \
		--pacman-conf "$PACMAN_CONF" \
		--makepkg-conf "$MAKEPKG_CONF" \
		--dry-run \
		"$@" \
	|| true; } \
	| sponge
}

bld_aur_build() {
	aur build \
		-d "$REPO_NAME" \
		--pacman-conf "$PACMAN_CONF" \
		--makepkg-conf "$MAKEPKG_CONF" \
		"${aurbuild_args[@]}" \
		--margs "$(join ',' "${makepkg_args_build[@]}")" \
		--cargs "$(join ',' "${makechrootpkg_args[@]}")" \
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
		die "workdir inconsistent -- '${id}-ok' record contains unknown packages (n=${#aliens[@]}): ${aliens[*]}"
	fi
	set_difference_a BLD_PHASE_ERR targets aliens
	if [[ ${aliens+set} ]]; then
		die "workdir inconsistent -- '${id}-err' record contains unknown packages (n=${#aliens[@]}): ${aliens[*]}"
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
		errf "${msgs[die_failed]}"
	elif (( !rc && err )); then
		errf "${msgs[die_missed]}"
	elif (( rc && !err )); then
		errf "${msgs[die_rc]}"
	fi
	if (( rc || err )); then
		err "(Run $BLD_ARGV0 --continue=${BLD_WORKDIR_NAME@Q} to retry)"
		exit 1
	fi
}

#
# subroutines
#

bld_sub_build() {
	local pkg pkg_dir pkgbuild_dir
	declare -a aurbuild_args makechrootpkg_args makepkg_args_prepare makepkg_args_build
	setup_one "$@"
	cd "$pkgbuild_dir"

	if ! bld_aur_build_dry | grep -qE '^build:'; then
		BLD_OK=1
		return
	fi
	bld_aur_build

	BLD_OK=1
}

bld_sub_fetch() {
	eval "$(ltraps)"
	local pkg pkg_dir pkgbuild_dir
	declare -a aurbuild_args makechrootpkg_args makepkg_args_prepare makepkg_args_build

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
			git reset --quiet "$pkgbuild"
			git checkout --quiet "$pkgbuild"
			git apply --quiet --recount --allow-empty "$pkgbuild_diff"
			luntrap
			lruntrap
		fi
		# rollback local modifications to .SRCINFO
		local srcinfo="$pkgbuild_dir/.SRCINFO"
		if ! git ls-files --error-unmatch "$srcinfo" &>/dev/null; then
			rm -f "$srcinfo"
		elif ! git diff --quiet HEAD -- "$srcinfo"; then
			git reset --quiet "$srcinfo"
			git checkout --quiet "$srcinfo"
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

	# extract existing custom repo contents
	local pkg_old pkg_old_ver pkg_old_rel
	bld_aur_repo --format '%R\t%b\t%v\n' \
	| awk -v pkgbase=$pkg 'BEGIN { FS="\t" } $2 == pkgbase { print $3; exit }' \
	| read pkg_old \
		|| true
	pkgver_extract "$pkg_old" pkg_old_ver pkg_old_rel

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
		-E BLD_ARGV0="$BLD_ARGV0" \
		"$BASH_SOURCE" "$@"
fi

eval "$(globaltraps)"
BLD_OK=0

# Load variables if we are in a subprocess
if bld_has_workdir; then
	bld_load_vars
fi

# Execute a subroutine if requested
if [[ $ARG_SUBROUTINE == fetch ]]; then
	if (( ${#ARG_TARGETS[@]} != 1 )); then
		die "bad usage: $0 ${@@Q}"
	fi
	ltrap "bld_sub_fetch__exit"
	bld_sub_fetch "${ARG_TARGETS[@]}"
	exit $(( BLD_OK ? 0 : 1 ))
elif [[ $ARG_SUBROUTINE == build ]]; then
	if (( ${#ARG_TARGETS[@]} != 1 )); then
		die "bad usage: $0 ${@@Q}"
	fi
	ltrap "bld_sub_build__exit"
	bld_sub_build "${ARG_TARGETS[@]}"
	exit $(( BLD_OK ? 0 : 1 ))
elif [[ ${ARG_SUBROUTINE+set} ]]; then
	die "bad usage: $0 ${@@Q}"
fi

# Prepare workdir
if ! bld_has_workdir; then
	bld_setup_workdir
fi
bld_workdir_update_timestamp

# Load/compute settings
bld_setup

# Update chroot
# TODO move it somewhere before the variables are exported in bld_setup()
#      so that we can write out everything at once
if [[ $ARG_CHROOT != no ]]; then
	# This used to say `bld_aur_chroot --create --update -- -uu`,
	# but `aur chroot --create` interprets positional arguments as
	# packages to install instead of default groups, so this fails
	# if the chroot actually needs to be created.
	if ! bld_aur_chroot --path &>/dev/null; then
		bld_aur_chroot --create
	else
		bld_aur_chroot --update -- -uu
	fi

	CHROOT_PATH="$(bld_aur_chroot --path)"
	log "chroot path:        $CHROOT_PATH"
	bld_save_vars CHROOT_PATH  # TODO get rid of this, see above

	# XXX host-specific overrides
	log "chroot: hacking up subuid and subgid"
	cat <<EOF | sudo sponge "$CHROOT_PATH/etc/subuid"
builduser:100000:65536
EOF
	cat <<EOF | sudo sponge "$CHROOT_PATH/etc/subgid"
builduser:100000:65536
EOF
	
	# XXX host-specific overrides
	log "chroot: hacking up /etc/containers/storage.conf"
	sudo install -dm755 "$CHROOT_PATH/etc/containers"
	cat <<EOF | sudo sponge "$CHROOT_PATH/etc/containers/storage.conf"
[storage]
  driver_priority = [ "btrfs", "overlay" ]
EOF
	
	# XXX host-specific overrides
	log "chroot: hacking up meson"
	sudo install -Dm755 "$HOME/bin/wrappers/meson" "$CHROOT_PATH/usr/local/bin/meson"
fi

# Find path to the sync database that we could query
PACMAN_CONF_ARGS=( -c "$PACMAN_CONF" )
if [[ $ARG_CHROOT != no ]]; then
	PACMAN_CONF_ARGS+=( -R "$CHROOT_PATH" )
fi
pacman-conf "${PACMAN_CONF_ARGS[@]}" --repo-list \
| readarray -t PACMAN_DB_REPOS
pacman-conf "${PACMAN_CONF_ARGS[@]}" DBPath \
| read PACMAN_DB_PATH
PACMAN_DB_PATH="${PACMAN_DB_PATH%%/}/sync"
log "pacman database:    $PACMAN_DB_PATH"
log "pacman repos:       $(join ", " "${PACMAN_DB_REPOS[@]}")"
bld_save_vars \
	PACMAN_DB_PATH \
	PACMAN_DB_REPOS \

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

if [[ ${ARG_NOFETCH+set} ]]; then
	die "--no-fetch set, aborting as instructed"
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
	local -a parallel_args
	if bld_workdir_check_file "targets_list"; then
		parallel_args+=( -j1 --tty )
	else
		parallel_args+=( -j$(nproc) --bar )
	fi
	parallel "${parallel_args[@]}" "$0 ${ARGS_PASS[@]@Q} --sub=fetch {}" ::: "$@" || rc=$?
}
bld_phase BLD_TARGETS FETCH_MSGS _phase_fetch

if [[ ${ARG_NOBUILD+set} ]]; then
	die "--no-build set, aborting as instructed"
fi

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
