#!/hint/bash

PKGBUILD_ROOT="$HOME/pkgbuild"
TARGETS_FILE="$PKGBUILD_ROOT/packages.txt"

WORKDIR_ROOT="$HOME/.pkgbuild.work"
WORKDIR_MAX_AGE_SEC=3600
REPO_NAME="custom"
MAKEPKG_CONF="/etc/aurutils/makepkg-$REPO_NAME.conf"
PACMAN_CONF="/etc/aurutils/pacman-$REPO_NAME.conf"
SCRATCH_ROOT="/mnt/ssd/Scratch/makepkg"
CCACHE_ROOT="/mnt/ssd/Cache/makepkg-ccache"
SCCACHE_ROOT="/mnt/ssd/Cache/makepkg-sccache"
CONTAINERS_ROOT="/mnt/ssd/Cache/makepkg-containers"

EXTRA_AURBUILD_ARGS=()
EXTRA_MAKECHROOTPKG_ARGS=()
EXTRA_MAKEPKG_ARGS=()

EXTRA_BIND_DIRS=(
	#/path/to/local/git
)

SYSTEMD_RUN=(
	sudo systemd-run
)
SYSTEMD_RUN_ARGS=(
	-p CPUSchedulingPolicy=batch
	-p Nice=18
)

CCACHE_CONFIG="
max_size = 100G
compression = false
file_clone = true
inode_cache = true
"

SCCACHE_CONFIG="
[cache.disk]
dir = \"$SCCACHE_ROOT\"
size = 107374182400 # 100 GiB

[cache.disk.preprocessor_cache_mode]
# Whether to use the preprocessor cache mode
# use_preprocessor_cache_mode = true
# # Whether to use file times to check for changes
# file_stat_matches = true
# # Whether to also use ctime (file status change) time to check for changes
# use_ctime_for_stat = true
# # Whether to ignore \`__TIME__\` when caching
# ignore_time_macros = false
# # Whether to skip (meaning not cache, only hash) system headers
# skip_system_headers = false
# # Whether hash the current working directory
# hash_working_directory = true
#
# # vim: ft=toml:
"
