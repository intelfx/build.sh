#!/hint/bash

# Global array tracking config files that have been loaded into this session.
declare -g -a BLD_LOADED_CONFIGS=()

# Stores the name and path of the currently used config, for logging purposes.
declare -g BLD_CONFIG_NAME BLD_CONFIG_FILE

# Contains --config-file arguments for each config file that has been loaded into this session.
declare -g -a BLD_LOADED_CONFIG_ARGS=()

# bld_config_resolve NAME
#
# Outputs the resolved path of a config by NAME, if one can be found, otherwise
# returns 1. NAME may be a path (which is used as-is) or a bare name (which is
# looked up under BLD_CONFIG_DIR, with and without a .sh suffix).
bld_config_resolve() {
	local name="$1"

	[[ $name ]] || return
	realpath -qes "$name" && return
	[[ $name != */* ]] || return
	realpath -qes "$BLD_CONFIG_DIR/$name" && return
	realpath -qes "$BLD_CONFIG_DIR/$name.sh" && return

	return 1
}

# bld_config_load NAME
#
# Loads a config by NAME, resolving the name via bld_config_resolve.
# Returns 1 if the config cannot be found.
bld_config_load() {
	local name="$1" path

	if ! path="$(bld_config_resolve "$name")"; then
		return 1
	fi
	bld_config_load_file "$path"
}

bld_config_load_nofail() {
	local name="$1" path

	if ! path="$(bld_config_resolve "$name")"; then
		return 0
	fi
	bld_config_load_file "$path"
}

# bld_config_load_file PATH
#
# Loads a config file by PATH without any name-based resolution.
# Paths to loaded config files are appended to BLD_LOADED_CONFIGS.
# Aborts if the config file does not exist.
bld_config_load_file() {
	local file="$1" path
	if ! path="$(realpath -qes "$file")"; then
		die "config file not found: ${file@Q}"
	fi

	# Re-derive the name of the config file for logging purposes.
	local name
	name="${file##*/}"
	name="${name%.sh}"
	if [[ $name != default && ! ($BLD_CONFIG_NAME || $BLD_CONFIG_FILE) ]]; then
		BLD_CONFIG_NAME="$name"
		BLD_CONFIG_FILE="$path"
	fi

	# shellcheck source=/dev/null
	source "$path"
	BLD_LOADED_CONFIGS+=( "$path" )
	BLD_LOADED_CONFIG_ARGS+=( --config-file "$path" )
}
