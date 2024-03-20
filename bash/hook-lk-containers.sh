#!/usr/bin/env bash

function build_hook_linuxkit_container() {
	declare container_dir="${1}"
	declare -n output_var="${2}" # bash name reference, kind of an output var but weird

	# Lets hash the contents of the directory and use that as a tag
	declare container_files_hash
	container_files_hash="$(find "${container_dir}" -type f -print0 | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
	declare container_files_hash_short="${container_files_hash:0:8}"

	declare local_image_name="tinkerbell-local-${container_dir}:${container_files_hash_short}-${ARCH}"
	echo "Going to build container ${local_image_name} from ${container_dir} for platform ${DOCKER_ARCH}" >&2

	(
		cd "${container_dir}" || exit 1
		docker buildx build -t "${local_image_name}" --load --platform "linux/${DOCKER_ARCH}" .
	)

	echo "Built ${local_image_name} from ${container_dir} for platform ${DOCKER_ARCH}" >&2
	output_var="${local_image_name}"
	return 0
}
