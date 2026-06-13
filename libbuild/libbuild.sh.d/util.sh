#!/hint/bash

maybe_env() {
	local -a env
	while (( $# )); do
		case "$1" in
		--) shift; break ;;
		*) env+=( "$1" ) ;;
		esac
		shift
	done

	if [[ ${env+set} ]]; then
		env "${env[@]}" "$@"
	else
		"$@"
	fi
}
