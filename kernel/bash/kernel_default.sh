#!/usr/bin/env bash

set -e

function calculate_kernel_version_default() {
	# Calculate the input DEFCONFIG
	declare -g INPUT_DEFCONFIG="defconfig-${KERNEL_MAJOR}.${KERNEL_MINOR}.y-${ARCH}"
	if [[ ! -f "kernel/${INPUT_DEFCONFIG}" ]]; then
		echo "ERROR: kernel/${INPUT_DEFCONFIG} does not exist, check inputs/envs" >&2
		exit 1
	fi

	# Grab the latest version from kernel.org
	declare -g KERNEL_POINT_RELEASE=""
	resolve_latest_kernel_version_lts

	# Calculate a version and hash for the OCI image
	# Hash the Dockerfile and the input defconfig together
	declare input_hash="" short_input_hash=""
	input_hash="$(cat "kernel/${INPUT_DEFCONFIG}" "kernel/Dockerfile" | sha256sum - | cut -d ' ' -f 1)"
	short_input_hash="${input_hash:0:8}"
	kernel_oci_version="${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}-${short_input_hash}"
	kernel_oci_image="${HOOK_OCI_BASE}${kernel_id}:${kernel_oci_version}"
}

function build_kernel_default() {
	echo "Building default kernel" >&2

	declare -a build_args=(
		"--build-arg" "KERNEL_MAJOR=${KERNEL_MAJOR}"
		"--build-arg" "KERNEL_MINOR=${KERNEL_MINOR}"
		"--build-arg" "KERNEL_VERSION=${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}"
		"--build-arg" "KERNEL_SERIES=${KERNEL_MAJOR}.${KERNEL_MINOR}.y"
		"--build-arg" "KERNEL_POINT_RELEASE=${KERNEL_POINT_RELEASE}"
		"--build-arg" "INPUT_DEFCONFIG=${INPUT_DEFCONFIG}"
	)
	echo "Will build with: ${build_args[*]}" >&2

	(
		cd kernel
		docker buildx build --load --progress=plain "${build_args[@]}" -t "${kernel_oci_image}" .
	)

}
