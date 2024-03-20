#!/usr/bin/env bash

function build_hook_linuxkit_container() {
	declare container_dir="${1}"
	declare -n output_var="${2}" # bash name reference, kind of an output var but weird

	declare local_image_name="tinkerbell-hook-${container_dir}:latest-${ARCH}"

	echo "Going to build container ${local_image_name} from ${container_dir}" >&2
}
