#!/bin/bash

set -eo pipefail
shopt -s lastpipe
shopt -s extglob
shopt -s nullglob

BLD_ROOT_DIR="$(dirname "$(realpath "$BASH_SOURCE")")"
BLD_CONFIG_DIR="$BLD_ROOT_DIR/config"

# shellcheck source=./libbuild/libbuild.sh
. "$BLD_ROOT_DIR/libbuild/libbuild.sh"


#
# arguments & usage
#

_usage_common_syntax="Usage: $BLD_ARGV0 [-c|--config CONFIG]"
_usage_common_options="
Global options:
	-h|--help		Print this usage help
	-c|--config CONFIG 	Path to main configuration file or directory,
				or name to be searched
"

_usage() {
	cat <<EOF
$BLD_ARGV0 -- opinionated package builder :: repo health check tool

$_usage_common_syntax [OPTIONS...] [PACKAGES...]
$_usage_common_options
EOF
}

declare -A ARGS=(
	[-h\|--help]=ARG_HELP
	[--verbose]='ARG_VERBOSE pass=ARGS_PASS'
	[--debug]='ARG_DEBUG pass=ARGS_PASS'
	[-c\|--config:]='ARG_CONFIG'
	[--config-file:]='ARGS_CONFIG_FILES append'
	# ['--']='ARG_TARGETS'
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

if [[ ${ARGS_CONFIG_FILES+set} ]]; then
	# if --config-file is used, load the specified files directly
	for file in "${ARGS_CONFIG_FILES[@]}"; do
		bld_config_load_file "$file"
	done
else
	# otherwise, load a user-specified profile: load default.sh first, then
	# resolve the profile name specified on the command line (or in default.sh)

	# shellcheck source=./config/default.sh
	bld_config_load_nofail "default"

	# default.sh may have set BLD_CONFIG; command-line --config overrides it
	if [[ ${ARG_CONFIG+set} ]]; then
		bld_config_load "$ARG_CONFIG"
	elif [[ ${BLD_CONFIG+set} ]]; then
		bld_config_load "$BLD_CONFIG"
	else
		die "No configuration profile specified"
	fi

fi

# pass loaded config files to subprocesses
ARGS_PASS+=( "${BLD_LOADED_CONFIG_ARGS[@]}" )


#
# constants
#

: "${PKGBUILD_ROOT="$HOME/pkgbuild"}"
: "${TARGETS_FILE="$PKGBUILD_ROOT/packages.txt"}"

: "${REPO_NAME=custom}"
: "${MAKEPKG_CONF="/etc/aurutils/makepkg-$REPO_NAME.conf"}"
: "${PACMAN_CONF="/etc/aurutils/makepkg-$REPO_NAME.conf"}"

[[ ${REPO_OFFICIAL+set} ]] || \
REPO_OFFICIAL=( {core,extra,community,multilib}{,-testing} )


#
# functions
#

generate_srcinfo() {
	if ! [[ .SRCINFO -nt PKGBUILD ]]; then
		aur build--pkglist --srcinfo >.SRCINFO
	fi
}
export -f generate_srcinfo

generate_srcinfo_json() {
	if ! [[ .SRCINFO.json -nt .SRCINFO ]]; then
		parse_srcinfo --json <.SRCINFO >.SRCINFO.json
	fi
}
export -f generate_srcinfo_json

vergreater() {
	(( $(vercmp "$@") > 0 ))
}


#
# main
#

# target repo: pkgname->pkgbase
declare -A MY_PKG_NAME_BASE
# target repo: pkgname->"fullname" ($repo/$pkgname)
declare -A MY_PKG_NAME_FULLNAME
# target repo: pkgname->pkgver
declare -A MY_PKG_NAME_VER
# target repo: set of known pkgbase (pkgbase->"1")
declare -A MY_PKG_BASE_IDX

# official repo: pkgname->pkgbase
declare -A ARCH_PKG_NAME_BASE
# official repo: pkgname->"fullname" ($repo/$pkgname)
declare -A ARCH_PKG_NAME_FULLNAME
# official repo: pkgname->pkgver
declare -A ARCH_PKG_NAME_VER
# official repo: set of known pkgbase (pkgbase->"1")
declare -A ARCH_PKG_BASE_IDX

# AUR: pkgname->pkgbase
declare -A AUR_PKG_NAME_BASE
# AUR: pkgname->"fullname" (aur/$pkgname)
declare -A AUR_PKG_NAME_FULLNAME
# AUR: pkgname->pkgver
declare -A AUR_PKG_NAME_VER
# AUR: set of known pkgbase (pkgbase->"1")
declare -A AUR_PKG_BASE_IDX

# XXX: to remove
PKGS=
REPO_VER=

# Targets list
declare -a BLD_TARGETS
# Targets list (pkgnames)
declare -a BLD_TARGETS_NAMES

# targets: set of known pkgbase (pkgbase->"1")
declare -A TARGET_PKG_BASE_IDX
# targets: pkgname->pkgbase
declare -A TARGET_PKG_NAME_BASE
# targets: pkgbase->pkgnames (space-separated)
declare -A TARGET_PKG_BASE_NAMES

# PKGBUILDs on disk
declare -a DISK_PKG_DIRS
# PKGBUILDs on disk: reverse mapping: directory->pkgbase
declare -A DISK_PKG_DIR_BASE
# PKGBUILDs on disk: reverse mapping: directory->expected pkgbase, based on path only
declare -A DISK_PKG_DIR_BASE_EXPECTED
# PKGBUILDs on disk: pkgname->pkgbase
declare -A DISK_PKG_NAME_BASE
# PKGBUILDs on disk: pkgbase->pkgnames (space-separated)
declare -A DISK_PKG_BASE_NAMES
# PKGBUILDs on disk: pkgbase->directory
declare -A DISK_PKG_BASE_DIR
# PKGBUILDs on disk: pkgname->directory
declare -A DISK_PKG_NAME_DIR
# PKGBUILDs on disk: directory->configured upstream type (either "aur", "arch", "unknown", or "multiple", or empty)
# (represents remotes *added* to the git repository of a given PKGBUILD)
declare -A DISK_PKG_DIR_UPSTREAM
# PKGBUILDs on disk: directory->current HEAD upstream type (either "aur", "arch", "unknown", or empty)
# (represents the remote that is being tracked by the currently checked-out branch)
declare -A DISK_PKG_DIR_UPSTREAM_HEAD

#
# 1. Find all PKGBUILDs on disk and build relevant indices over on-disk files.
#

LIBSH_LOG_PREFIX="[on-disk]"

log "Listing PKGBUILDs @ ${PKGBUILD_ROOT@Q}"
timer_start
find "$PKGBUILD_ROOT" -mindepth 2 -maxdepth 2 -type f -name PKGBUILD -printf '%h\n' \
| sort -u \
| readarray -t DISK_PKG_DIRS

# Filter ignored PKGBUILDs in a separate step
find "$PKGBUILD_ROOT" -mindepth 2 -maxdepth 2 -type f -name "$BLD_IGNORE_FILE" -printf '%h\n' \
| sort -u \
| readarray -t DISK_PKG_DIRS_IGNORED
print_array "${DISK_PKG_DIRS[@]}" \
| grep -Fvxf <(print_array "${DISK_PKG_DIRS_IGNORED[@]}") \
| readarray -t DISK_PKG_DIRS

timer_end
log "Listing PKGBUILDs took $(timer_delta_fmt)"
log "Found ${#DISK_PKG_DIRS[@]} PKGBUILDs (${#DISK_PKG_DIRS_IGNORED[@]} ignored)"

log "Updating .SRCINFOs"
timer_start
print_array "${DISK_PKG_DIRS[@]}" \
| parallel --bar 'cd {} && generate_srcinfo && generate_srcinfo_json'
timer_end
log "Updating .SRCINFOs took $(timer_delta_fmt)"

log "Parsing .SRCINFOs"
# jq_srcinfo() {
# 	jq "$@" <<<"$srcinfo_json"
# }
timer_start
for dir in "${DISK_PKG_DIRS[@]}"; do
	if [[ -e "$dir/$BLD_IGNORE_FILE" ]]; then
		die "Internal error @ ${dir@Q}: $BLD_IGNORE_FILE exists"
	fi

	pkgbase_expected="${dir##*/}"

	# parse_srcinfo --json <"$dir/.SRCINFO" \
	# | { IFS= read -r -d '' srcinfo_json ||:; }
	# jq_srcinfo -r '.pkgbase' | IFS= read -r pkgbase
	# jq_srcinfo -r '.packages | keys[]' | readarray -t pkgnames

	cat "$dir/.SRCINFO.json" \
	| jq -r '.pkgbase, (.packages | keys[])' \
	| readarray -t tmp
	pkgbase="${tmp[0]}"
	pkgnames=("${tmp[@]:1}")

	if ! [[ $pkgbase ]]; then
		err "Bad on-disk pkgbase @ ${dir@Q}: empty pkgbase"
		continue
	fi
	if ! [[ ${pkgnames+set} ]]; then
		err "Bad on-disk pkgbase @ ${dir@Q}: no pkgnames"
		continue
	fi

	if [[ $pkgbase != "$pkgbase_expected" ]]; then
		# contains $pkgbase twice to simplify reading
		err "Misplaced on-disk pkgbase ${pkgbase@Q}: path=${dir@Q}, found=${pkgbase@Q}, expected=${pkgbase_expected@Q}"
		continue
	fi
	if [[ "${DISK_PKG_BASE_DIR["$pkgbase"]+set}" ]]; then
		path1="${DISK_PKG_BASE_DIR["$pkgbase"]}"
		err "Duplicate on-disk pkgbase ${pkgbase@Q}: path1=${path1@Q}, path2=${dir@Q}"
		continue
	fi
	for pkgname in "${pkgnames[@]}"; do
		if [[ ${DISK_PKG_NAME_DIR["$pkgname"]+set} ]]; then
			path1="${DISK_PKG_NAME_DIR["$pkgname"]}"
			pkgbase1="${DISK_PKG_DIR_BASE["$path1"]}"
			err "Duplicate on-disk pkgname ${pkgname@Q}: pkgbase1=$pkgbase1 @ ${path1@Q}, pkgbase2=$pkgbase @ ${dir@Q}"
			continue
		fi
	done

	if [[ -e "$dir/.git" ]]; then
		if ! git -C "$dir" rev-parse --verify --quiet HEAD &>/dev/null; then
			err "Invalid git directory @ ${dir@Q}"
			continue
		fi

		declare -A remotes=()
		declare -A remotes_idx=()
		declare -a remotes_uniq=()
		head_remote_name=""
		head_remote=""

		# read URLs of all remotes
		git -C "$dir" remote | while IFS= read -r remote; do
			git -C "$dir" remote get-url "$remote" | IFS= read -r url

			case "$url" in
			git://gitlab.archlinux.org/*) ;&
			http*://gitlab.archlinux.org/*) ;&
			git@gitlab.archlinux.org:*)
				remotes["$remote"]="arch" ;;
			git://aur.archlinux.org/*) ;&
			http*://aur.archlinux.org/*) ;&
			aur@aur.archlinux.org:*)
				remotes["$remote"]="aur" ;;
			*)
				remotes["$remote"]="unknown" ;;
			esac

			remotes_idx["$remote"]=1
		done
		remotes_uniq=("${!remotes_idx[@]}")

		# get name of remote associated with the checked-out branch
		if git -C "$dir" rev-parse \
			--abbrev-ref \
			--symbolic-full-name \
			'@{u}' \
			2>/dev/null \
			| IFS= read -r head_remote_name; then
			head_remote="${remotes["$head_remote_name"]}"
		fi

		if (( ${#remotes_uniq[@]} > 1 )); then
			DISK_PKG_DIR_UPSTREAM["$dir"]="multiple"
		elif (( ${#remotes_uniq[@]} )); then
			DISK_PKG_DIR_UPSTREAM["$dir"]="${remotes_uniq[0]}"
		fi
		if [[ $head_remote ]]; then
			DISK_PKG_DIR_UPSTREAM_HEAD["$dir"]="$head_remote"
		fi
	fi

	DISK_PKG_DIR_BASE["$dir"]="$pkgbase"
	DISK_PKG_DIR_BASE_EXPECTED["$dir"]="$pkgbase_expected"
	DISK_PKG_BASE_DIR["$pkgbase"]="$dir"
	DISK_PKG_BASE_NAMES["$pkgbase"]="${pkgnames[*]}"
	for pkgname in "${pkgnames[@]}"; do
		DISK_PKG_NAME_BASE["$pkgname"]="$pkgbase"
		DISK_PKG_NAME_DIR["$pkgname"]="$dir"
	done
done
timer_end
log "Parsing .SRCINFOs took $(timer_delta_fmt)"
log "Found ${#DISK_PKG_DIR_BASE[@]} PKGBUILDs"
log "Found ${#DISK_PKG_NAME_DIR[@]} pkgnames in ${#DISK_PKG_BASE_DIR[@]} pkgbases"

#
# 2. Read targets (pkgbases that we intend to build into the custom repo)
#    and correlate them with on-disk PKGBUILDs.
#

LIBSH_LOG_PREFIX="[targets]"

log "Loading targets"
timer_start
cat_config "$TARGETS_FILE" | readarray -t BLD_TARGETS
for pkgbase in "${BLD_TARGETS[@]}"; do
	if ! [[ ${DISK_PKG_BASE_DIR["$pkgbase"]+set} ]]; then
		err "Bad target pkgbase ${pkgbase@Q}: pkgbase not found on disk"
		continue
	fi

	read -ra pkgnames <<<"${DISK_PKG_BASE_NAMES["$pkgbase"]}"
	BLD_TARGETS_NAMES+=( "${pkgnames[@]}" )

	TARGET_PKG_BASE_IDX["$pkgbase"]="1"
	TARGET_PKG_BASE_NAMES["$pkgbase"]="${pkgnames[*]}"
	for pkgname in "${pkgnames[@]}"; do
		TARGET_PKG_NAME_BASE["$pkgname"]="$pkgbase"
	done
done
timer_end
log "Loading targets took $(timer_delta_fmt)"
log "Targeting ${#TARGET_PKG_NAME_BASE[@]} pkgnames in ${#TARGET_PKG_BASE_IDX[@]} pkgbases"

#
# 3. Query existing contents of the custom repo and the official repos.
#    Do it in the same pass for efficiency.
#

LIBSH_LOG_PREFIX="[repo]"

log "Loading repository contents"
timer_start
expac -S '%r %e %n %v' \
| while read -r repo pkgbase pkgname pkgver; do
	if [[ "$repo" == "$REPO_NAME" ]]; then
		dbg "----- [$pkgbase] $repo/$pkgname = $pkgver"
		MY_PKG_NAME_BASE["$pkgname"]="$pkgbase"
		MY_PKG_NAME_FULLNAME["$pkgname"]="$repo/$pkgname"
		MY_PKG_NAME_VER["$pkgname"]="$pkgver"
		MY_PKG_BASE_IDX["$pkgbase"]="1"
	elif ! in_array "$repo" "${REPO_OFFICIAL[@]}"; then
		# other custom repositories -- ignore
		:
	elif ! [[ "${ARCH_PKG_NAME_VER["$pkgname"]}" ]]; then
		# only accept first encountered official repo
		dbg "[off] [$pkgbase] $repo/$pkgname = $pkgver"
		ARCH_PKG_NAME_BASE["$pkgname"]="$pkgbase"
		ARCH_PKG_NAME_FULLNAME["$pkgname"]="$repo/$pkgname"
		ARCH_PKG_NAME_VER["$pkgname"]="$pkgver"
		ARCH_PKG_BASE_IDX["$pkgbase"]="1"
	fi
done
timer_end
log "Loading repository contents took $(timer_delta_fmt)"
log "[$REPO_NAME]: found ${#MY_PKG_NAME_BASE[@]} packages in ${#MY_PKG_BASE_IDX[@]} pkgbases"
log "(official): found ${#ARCH_PKG_NAME_BASE[@]} packages in ${#ARCH_PKG_BASE_IDX[@]} pkgbases"

#
# 3a. Query existing contents of the AUR.
#     It is not possible to dump the contents of the entire AUR,
#     so request information about all pkgnames that we potentially know.
#
# FIXME: AUR is queried in terms of pkgnames, so it is not possible to query
#        information about a pkgbase that is in targets but is not fetched.
#

LIBSH_LOG_PREFIX="[AUR]"

# Compute all known pkgnames (in PKGBUILDs on disk, in targets, in custom repo)
print_array \
	"${!DISK_PKG_NAME_BASE[@]}" \
	"${!TARGET_PKG_NAME_BASE[@]}" \
	"${!MY_PKG_NAME_BASE[@]}" \
| sort -u \
| readarray -t KNOWN_PKG_NAMES

log "Querying AUR about ${#KNOWN_PKG_NAMES[@]} packages"
timer_start
aur query -t info "${KNOWN_PKG_NAMES[@]}" \
| jq -r '.results[] | "\(.PackageBase) \(.Name) \(.Version)"' | while read -r pkgbase pkgname pkgver; do
	dbg "[AUR] [$pkgbase] $pkgname = $pkgver"
	AUR_PKG_BASE_IDX["$pkgbase"]="1"
	AUR_PKG_NAME_BASE["$pkgname"]="$pkgbase"
	AUR_PKG_NAME_FULLNAME["$pkgname"]="aur/$pkgname"
	AUR_PKG_NAME_VER["$pkgname"]="$pkgver"
done
timer_end
log "Querying AUR took $(timer_delta_fmt)"
log "AUR: found ${#AUR_PKG_NAME_BASE[@]} packages in ${#AUR_PKG_BASE_IDX[@]} pkgbases"

exit 1
