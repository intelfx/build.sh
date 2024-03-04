#!/hint/bash

bld_ternary() {
	if [[ "$1" ]]; then
		echo "$2"
	elif [[ ${3+set} ]]; then
		echo "$3"
	fi
}
