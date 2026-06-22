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

# pkgname suffixes treated as VCS/dynamic-version for the fuzzy outdated check
[[ ${VCS_SUFFIXES+set} ]] || \
VCS_SUFFIXES=( git nightly )


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
# reporting framework
#
# Checks never print: they call `add_finding <category> <pkgbase-key> <fields...>`,
# and a single `render` pass owns all formatting. This keeps each check a
# self-contained block and the rendering centralized.
#

# category -> severity (error|warning|advisory)
declare -A FINDING_SEVERITY=(
	[structural]=error
	[dup_target]=error
	[missing_pkgbuild]=error
	[not_built]=warning
	[disk_orphan]=warning
	[repo_orphan]=warning
	[split_mismatch]=warning
	[name_migration]=warning
	[debug_orphan]=warning
	[debug_mismatch]=warning
	[pkgset_arch]=warning
	[pkgset_aur]=warning
	[upstream_mismatch]=warning
	[outdated]=warning
	[outdated_fuzzy]=advisory
)
# category -> human-readable section title
declare -A FINDING_TITLE=(
	[structural]="Structural errors (pkgbase skipped)"
	[dup_target]="Duplicate targets"
	[missing_pkgbuild]="Missing PKGBUILDs (targeted, no source on disk)"
	[not_built]="Not built (targeted, source present, absent from repo)"
	[disk_orphan]="PKGBUILD orphans (on disk, not targeted, not built)"
	[repo_orphan]="Package orphans (in repo, not targeted)"
	[split_mismatch]="Split-package drift (disk vs repo)"
	[name_migration]="pkgname migrated between pkgbases (repo behind disk)"
	[debug_orphan]="Orphan debug packages (host pkgname not in repo)"
	[debug_mismatch]="Stale debug packages (version differs from host)"
	[pkgset_arch]="pkgname-set mismatch vs Arch"
	[pkgset_aur]="pkgname provider mismatch vs AUR"
	[upstream_mismatch]="Upstream tracking mismatch"
	[outdated]="Outdated packages"
	[outdated_fuzzy]="Outdated VCS packages (advisory; pkgver not directly comparable)"
)
# category -> tab-separated header row
declare -A FINDING_COLS=(
	[structural]=$'OBJECT\tPROBLEM'
	[dup_target]=$'PKGBASE\tNOTE'
	[missing_pkgbuild]=$'PKGBASE\tIN_REPO'
	[not_built]=$'PKGBASE\tPKGNAMES'
	[disk_orphan]=$'PKGBASE\tPATH\tPKGNAMES'
	[repo_orphan]=$'PKGBASE\tPKGNAMES\tON_DISK'
	[split_mismatch]=$'PKGBASE\tDELTA\tNOTE'
	[name_migration]=$'PKGNAME\tREPO_BASE\tDISK_BASE'
	[debug_orphan]=$'PKGNAME\tDEBUG_VER\tMISSING_HOST'
	[debug_mismatch]=$'PKGNAME\tDEBUG_VER\tHOST_VER'
	[pkgset_arch]=$'PKGBASE\tDELTA\tPROVIDED_BY'
	[pkgset_aur]=$'PKGNAME\tDISK_BASE\tAUR_BASE'
	[upstream_mismatch]=$'PKGBASE\tTRACKS\tACTUAL\tNOTE'
	[outdated]=$'PKGNAME\tREPO_VER\tUPSTREAM_VER\tSOURCE'
	[outdated_fuzzy]=$'PKGNAME\tREPO_VER\tUPSTREAM_VER\tSOURCE'
)
# render order (also the order checks run)
declare -a FINDING_ORDER=(
	structural dup_target missing_pkgbuild not_built
	disk_orphan repo_orphan split_mismatch name_migration
	debug_orphan debug_mismatch
	pkgset_arch pkgset_aur upstream_mismatch outdated outdated_fuzzy
)

# storage
declare -A FINDINGS         # category -> newline-joined TSV rows
declare -A FINDINGS_COUNT   # category -> count
declare -A FINDINGS_BY_BASE # pkgbase -> space-joined unique category tags

# $1: category  $2: pkgbase key (for the by-pkgbase index)  $3..: row fields
add_finding() {
	local cat="$1" base="$2"
	shift 2
	local IFS=$'\t'
	FINDINGS["$cat"]+="$*"$'\n'
	(( ++FINDINGS_COUNT["$cat"] ))
	[[ " ${FINDINGS_BY_BASE["$base"]-} " == *" $cat "* ]] \
		|| FINDINGS_BY_BASE["$base"]+=" $cat"
}

# Render the full report to stdout (progress logs stay on stderr).
# Sets FINDING_RC to 1 if any error-severity finding was recorded.
FINDING_RC=0
render() {
	local cat n base sev
	local errs=0 warns=0 advs=0

	for cat in "${FINDING_ORDER[@]}"; do
		n="${FINDINGS_COUNT["$cat"]-0}"
		(( n )) || continue
		sev="${FINDING_SEVERITY["$cat"]}"
		case "$sev" in
		error)    (( errs += n )) ;;
		warning)  (( warns += n )) ;;
		advisory) (( advs += n )) ;;
		esac

		echo
		echo "=== ${FINDING_TITLE["$cat"]} [$sev] ($n) ==="
		{
			echo "${FINDING_COLS["$cat"]}"
			printf '%s' "${FINDINGS["$cat"]}" | sort
		} | column -L -t -s$'\t'
	done

	if (( ${#FINDINGS_BY_BASE[@]} )); then
		echo
		echo "=== Findings by pkgbase (${#FINDINGS_BY_BASE[@]}) ==="
		for base in "${!FINDINGS_BY_BASE[@]}"; do
			printf '%s\t%s\n' "$base" "${FINDINGS_BY_BASE["$base"]# }"
		done | sort | column -L -t -s$'\t'
	fi

	echo
	if (( errs + warns + advs )); then
		echo "=== Summary: $errs error(s), $warns warning(s), $advs advisory ==="
	else
		echo "=== Summary: no findings ==="
	fi

	(( errs )) && FINDING_RC=1
	return 0
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
# target repo: set of known pkgname (pkgname->"1"), normal and debug packages
declare -A MY_PKG_NAME_IDX
declare -A MY_PKG_NAME_IDX_DEBUG
# target repo: pkgbase->pkgnames (space-separated), normal and debug packages
declare -A MY_PKG_BASE_NAMES
declare -A MY_PKG_BASE_NAMES_DEBUG

# official repo: pkgname->pkgbase
declare -A ARCH_PKG_NAME_BASE
# official repo: pkgname->"fullname" ($repo/$pkgname)
declare -A ARCH_PKG_NAME_FULLNAME
# official repo: pkgname->pkgver
declare -A ARCH_PKG_NAME_VER
# official repo: set of known pkgbase (pkgbase->"1")
declare -A ARCH_PKG_BASE_IDX
# official repo: pkgbase->pkgnames (space-separated); complete, used for set-diff
declare -A ARCH_PKG_BASE_NAMES

# AUR: pkgname->pkgbase
declare -A AUR_PKG_NAME_BASE
# AUR: pkgname->"fullname" (aur/$pkgname)
declare -A AUR_PKG_NAME_FULLNAME
# AUR: pkgname->pkgver
declare -A AUR_PKG_NAME_VER
# AUR: set of known pkgbase (pkgbase->"1")
declare -A AUR_PKG_BASE_IDX

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
# PKGBUILDs on disk: pkgbase->full version (informational only -- the on-disk
# PKGBUILD is not guaranteed up-to-date, the build tool refreshes it just-in-time)
declare -A DISK_PKG_BASE_VER
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
	| jq -r '
		.pkgbase,
		((if .epoch then (.epoch|tostring)+":" else "" end)
			+ (.pkgver|tostring) + "-" + (.pkgrel|tostring)),
		(.packages | keys[])' \
	| readarray -t tmp
	pkgbase="${tmp[0]}"
	pkgver="${tmp[1]}"
	pkgnames=("${tmp[@]:2}")

	if ! [[ $pkgbase ]]; then
		err "Bad on-disk pkgbase @ ${dir@Q}: empty pkgbase"
		add_finding structural "$dir" "$dir" "empty pkgbase"
		continue
	fi
	if ! [[ ${pkgnames+set} ]]; then
		err "Bad on-disk pkgbase @ ${dir@Q}: no pkgnames"
		add_finding structural "$pkgbase" "$dir" "no pkgnames"
		continue
	fi

	if [[ $pkgbase != "$pkgbase_expected" ]]; then
		# contains $pkgbase twice to simplify reading
		err "Misplaced on-disk pkgbase ${pkgbase@Q}: path=${dir@Q}, found=${pkgbase@Q}, expected=${pkgbase_expected@Q}"
		add_finding structural "$pkgbase" "$dir" "misplaced pkgbase: found ${pkgbase@Q}, expected ${pkgbase_expected@Q}"
		continue
	fi
	if [[ "${DISK_PKG_BASE_DIR["$pkgbase"]+set}" ]]; then
		path1="${DISK_PKG_BASE_DIR["$pkgbase"]}"
		err "Duplicate on-disk pkgbase ${pkgbase@Q}: path1=${path1@Q}, path2=${dir@Q}"
		add_finding structural "$pkgbase" "$pkgbase" "duplicate pkgbase: also at ${path1@Q}"
		continue
	fi
	for pkgname in "${pkgnames[@]}"; do
		if [[ ${DISK_PKG_NAME_DIR["$pkgname"]+set} ]]; then
			path1="${DISK_PKG_NAME_DIR["$pkgname"]}"
			pkgbase1="${DISK_PKG_DIR_BASE["$path1"]}"
			err "Duplicate on-disk pkgname ${pkgname@Q}: pkgbase1=$pkgbase1 @ ${path1@Q}, pkgbase2=$pkgbase @ ${dir@Q}"
			add_finding structural "$pkgbase" "$pkgbase" "duplicate pkgname ${pkgname@Q}: also in pkgbase ${pkgbase1@Q}"
			continue
		fi
	done

	if [[ -e "$dir/.git" ]]; then
		if ! git -C "$dir" rev-parse --verify --quiet HEAD &>/dev/null; then
			err "Invalid git directory @ ${dir@Q}"
			add_finding structural "$pkgbase" "$dir" "invalid git directory (no HEAD)"
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
		if head_ref="$(git -C "$dir" symbolic-ref -q HEAD 2>/dev/null)" \
		&& head_remote_name="$(git -C "$dir" for-each-ref \
			--format='%(upstream:remotename)' "$head_ref" 2>/dev/null)" \
		&& [[ $head_remote_name ]]; then
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
	DISK_PKG_BASE_VER["$pkgbase"]="$pkgver"
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
	# Index every target regardless of disk presence so the coverage check
	# (phase B) sees the complete set of targeted pkgbases. A target with no
	# PKGBUILD on disk surfaces there as `missing_pkgbuild`.
	if [[ ${TARGET_PKG_BASE_IDX["$pkgbase"]+set} ]]; then
		add_finding dup_target "$pkgbase" "$pkgbase" "listed more than once in targets"
		continue
	fi
	TARGET_PKG_BASE_IDX["$pkgbase"]="1"

	if ! [[ ${DISK_PKG_BASE_DIR["$pkgbase"]+set} ]]; then
		dbg "Bad target pkgbase ${pkgbase@Q}: pkgbase not found on disk (-> missing_pkgbuild)"
		continue
	fi

	read -ra pkgnames <<<"${DISK_PKG_BASE_NAMES["$pkgbase"]}"
	BLD_TARGETS_NAMES+=( "${pkgnames[@]}" )

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
		# *-debug (detached debug symbols) packages are always named
		# after $pkgbase and do not follow the split
		# (and never exist on disk)
		if [[ $pkgname == "$pkgbase-debug" \
		   && ! ${DISK_PKG_NAME_BASE["$pkgname"]+set} ]]; then
			MY_PKG_NAME_IDX_DEBUG["$pkgname"]="1"
			MY_PKG_BASE_NAMES_DEBUG["$pkgbase"]+=" $pkgname"
		else
			MY_PKG_NAME_IDX["$pkgname"]="1"
			MY_PKG_BASE_NAMES["$pkgbase"]+=" $pkgname"
		fi
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
		ARCH_PKG_BASE_NAMES["$pkgbase"]+=" $pkgname"
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
	"${!MY_PKG_NAME_IDX[@]}" \
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

#
# 4. Checks. Each phase only reads indices and calls `add_finding`; all output
#    is produced by `render` at the end.
#

LIBSH_LOG_PREFIX="[check]"
log "Running checks"
timer_start

# Helper: trimmed pkgnames of a pkgbase from a "names" map (leading-space safe).
names_of() {
	local -n _map="$1"
	read -ra "${2:?}" <<<"${_map["$3"]-}"
}

#
# B. Coverage: classify every known pkgbase by (Target, Disk, Repo) presence.
#
print_array \
	"${!TARGET_PKG_BASE_IDX[@]}" \
	"${!DISK_PKG_BASE_DIR[@]}" \
	"${!MY_PKG_BASE_IDX[@]}" \
| sort -u \
| readarray -t ALL_PKG_BASES

for base in "${ALL_PKG_BASES[@]}"; do
	# empty-or-"1" so both `(( … ))` and `bld_ternary` read them correctly
	t="${TARGET_PKG_BASE_IDX["$base"]+1}"
	d="${DISK_PKG_BASE_DIR["$base"]+1}"
	r="${MY_PKG_BASE_IDX["$base"]+1}"

	if (( t )) && (( ! d )); then
		# targeted but no PKGBUILD on disk -> cannot build
		add_finding missing_pkgbuild "$base" "$base" "$(bld_ternary "$r" yes no)"
	elif (( t && d && ! r )); then
		add_finding not_built "$base" "$base" "${DISK_PKG_BASE_NAMES["$base"]}"
	elif (( ! t && d && ! r )); then
		add_finding disk_orphan "$base" "$base" "${DISK_PKG_BASE_DIR["$base"]}" "${DISK_PKG_BASE_NAMES["$base"]}"
	elif (( ! t && r )); then
		read -ra names \
			<<<"${MY_PKG_BASE_NAMES["$base"]} ${MY_PKG_BASE_NAMES_DEBUG["$base"]}"
		add_finding repo_orphan "$base" "$base" "${names[*]}" \
			"$(bld_ternary "$d" "${DISK_PKG_BASE_DIR["$base"]-}" no)"
	fi
	# (t && d && r) is healthy; nothing to report.
done

#
# C1. Disk<->Repo composition for healthy targets: split-package drift.
#
for base in "${!TARGET_PKG_BASE_IDX[@]}"; do
	[[ ${DISK_PKG_BASE_DIR["$base"]+set} && ${MY_PKG_BASE_IDX["$base"]+set} ]] || continue

	names_of DISK_PKG_BASE_NAMES dnames "$base"
	names_of MY_PKG_BASE_NAMES rnames "$base"
	set_difference_a dnames rnames only_disk
	set_difference_a rnames dnames only_repo

	for pkgname in "${only_disk[@]}"; do
		add_finding split_mismatch "$base" "$base" "missing: $pkgname" "built by pkgbase but absent from repo"
	done
	for pkgname in "${only_repo[@]}"; do
		# pkgnames that moved to another on-disk pkgbase are name_migration, not stale
		[[ ${DISK_PKG_NAME_BASE["$pkgname"]+set} ]] && continue
		add_finding split_mismatch "$base" "$base" "stale: $pkgname" "in repo, not built by any on-disk pkgbase"
	done
done

# name migration: repo pkgname whose on-disk pkgbase differs from the repo's
for pkgname in "${!MY_PKG_NAME_IDX[@]}"; do
	disk_base="${DISK_PKG_NAME_BASE["$pkgname"]-}"
	[[ $disk_base ]] || continue
	repo_base="${MY_PKG_NAME_BASE["$pkgname"]}"
	[[ $disk_base != "$repo_base" ]] || continue
	add_finding name_migration "$repo_base" "$pkgname" "$repo_base" "$disk_base"
done

#
# F. Debug-package consistency (repo-internal). A `$pkgbase-debug` is a derived
#    artifact (not in .SRCINFO). It is always named after $pkgbase (not split),
#    and must be identical in version to other pkgnames.
#
#    (We do not flag a *missing* debug package: it is not required that each
#     package is built with options=(debug).)
#
for pkgname in "${!MY_PKG_NAME_IDX_DEBUG[@]}"; do
	pkgbase="${MY_PKG_NAME_BASE["$pkgname"]}"
	debug_ver="${MY_PKG_NAME_VER["$pkgname"]}"
	read -ra hosts <<<"${MY_PKG_BASE_NAMES["$pkgbase"]}"

	if ! [[ ${hosts+set} ]]; then
		add_finding debug_orphan "$pkgbase" "$pkgname" "$debug_ver" "$pkgbase"
	elif [[ $debug_ver != "${MY_PKG_NAME_VER["$hosts"]}" ]]; then
		add_finding debug_mismatch "$pkgbase" "$pkgname" "$debug_ver" "${MY_PKG_NAME_VER["$hosts"]}"
	fi
done

#
# C2-arch. Disk<->Arch composition: true symmetric difference (Arch is complete).
#
for base in "${!DISK_PKG_BASE_DIR[@]}"; do
	[[ ${ARCH_PKG_BASE_IDX["$base"]+set} ]] || continue

	names_of DISK_PKG_BASE_NAMES dnames "$base"
	names_of ARCH_PKG_BASE_NAMES anames "$base"
	set_difference_a dnames anames only_disk
	set_difference_a anames dnames only_arch

	for pkgname in "${only_arch[@]}"; do
		# arch ships pkgname under this pkgbase; do we build it (under any pkgbase)?
		prov="${DISK_PKG_NAME_BASE["$pkgname"]-}"
		add_finding pkgset_arch "$base" "$base" "+arch: $pkgname" \
			"$(bld_ternary "$prov" "we build it as $prov" "not built by us")"
	done
	for pkgname in "${only_disk[@]}"; do
		# we build pkgname under this pkgbase; where does arch put it, if anywhere?
		prov="${ARCH_PKG_NAME_BASE["$pkgname"]-}"
		add_finding pkgset_arch "$base" "$base" "-arch: $pkgname" \
			"$(bld_ternary "$prov" "arch ships it as $prov" "not in arch")"
	done
done

#
# C2-aur. Disk<->AUR provider consistency only (RPC cannot enumerate a pkgbase).
#         Only pkgname->pkgbase disagreements are sound; additions are invisible.
#
for pkgname in "${!DISK_PKG_NAME_BASE[@]}"; do
	aur_base="${AUR_PKG_NAME_BASE["$pkgname"]-}"
	[[ $aur_base ]] || continue
	disk_base="${DISK_PKG_NAME_BASE["$pkgname"]}"
	[[ $aur_base != "$disk_base" ]] || continue
	add_finding pkgset_aur "$disk_base" "$pkgname" "$disk_base" "$aur_base"
done

#
# D. Provenance: what the checkout tracks vs where the pkgbase actually lives.
#
for base in "${!DISK_PKG_BASE_DIR[@]}"; do
	dir="${DISK_PKG_BASE_DIR["$base"]}"
	head="${DISK_PKG_DIR_UPSTREAM_HEAD["$dir"]-}"
	# only concrete tracked remotes are checkable; skip unknown/multiple/none
	[[ $head == arch || $head == aur ]] || continue

	in_arch="${ARCH_PKG_BASE_IDX["$base"]+1}"
	in_aur="${AUR_PKG_BASE_IDX["$base"]+1}"
	actual=""
	[[ $in_arch ]] && actual="arch"
	[[ $in_aur ]] && actual="${actual:+$actual+}aur"
	actual="${actual:-none}"

	note=
	if [[ $head == aur ]]; then
		if   (( in_arch )); then note="adopted by Arch -- switch to tracking Arch"
		elif (( in_aur  )); then continue  # tracks aur, in aur: ok
		else                     note="gone from AUR (deleted/renamed upstream)"
		fi
	else # head == arch
		if   (( in_arch )); then continue  # tracks arch, in arch: ok
		elif (( in_aur  )); then note="dropped from Arch to AUR"
		else                     note="gone from Arch (deleted/renamed upstream)"
		fi
	fi
	add_finding upstream_mismatch "$base" "$base" "$head" "$actual" "$note"
done

#
# E1. Freshness: repo pkgname vs upstream of the same name (Arch preferred).
#
for pkgname in "${!MY_PKG_NAME_IDX[@]}"; do
	repover="${MY_PKG_NAME_VER["$pkgname"]}"
	archver="${ARCH_PKG_NAME_VER["$pkgname"]-}"
	aurver="${AUR_PKG_NAME_VER["$pkgname"]-}"

	if [[ $archver ]] && vergreater "$archver" "$repover"; then
		add_finding outdated "${MY_PKG_NAME_BASE["$pkgname"]}" \
			"$pkgname" "$repover" "$archver" "${ARCH_PKG_NAME_FULLNAME["$pkgname"]}"
	elif [[ $aurver ]] && vergreater "$aurver" "$repover"; then
		add_finding outdated "${MY_PKG_NAME_BASE["$pkgname"]}" \
			"$pkgname" "$repover" "$aurver" "${AUR_PKG_NAME_FULLNAME["$pkgname"]}"
	fi
done

#
# E2. Fuzzy freshness: strip a VCS suffix and re-run the outdated check (advisory).
#
for pkgname in "${!MY_PKG_NAME_IDX[@]}"; do
	base_name=
	for suf in "${VCS_SUFFIXES[@]}"; do
		if [[ $pkgname == *-"$suf" ]]; then
			base_name="${pkgname%-"$suf"}"
			break
		fi
	done
	[[ $base_name ]] || continue

	repover="${MY_PKG_NAME_VER["$pkgname"]}"
	archver="${ARCH_PKG_NAME_VER["$base_name"]-}"
	aurver="${AUR_PKG_NAME_VER["$base_name"]-}"

	if [[ $archver ]] && vergreater "$archver" "$repover"; then
		add_finding outdated_fuzzy "${MY_PKG_NAME_BASE["$pkgname"]}" \
			"$pkgname" "$repover" "$archver" "${ARCH_PKG_NAME_FULLNAME["$base_name"]}"
	elif [[ $aurver ]] && vergreater "$aurver" "$repover"; then
		add_finding outdated_fuzzy "${MY_PKG_NAME_BASE["$pkgname"]}" \
			"$pkgname" "$repover" "$aurver" "${AUR_PKG_NAME_FULLNAME["$base_name"]}"
	fi
done

timer_end
log "Running checks took $(timer_delta_fmt)"

#
# 5. Report.
#
LIBSH_LOG_PREFIX="[report]"
render
exit "$FINDING_RC"
