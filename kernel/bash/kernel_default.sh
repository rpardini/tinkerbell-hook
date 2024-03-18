#!/usr/bin/env bash

set -e

function calculate_kernel_version_default() {
	# Make sure kernel_id is defined or exit with an error; using a one liner
	: "${kernel_id:?"ERROR: kernel_id is not defined"}"

	# Calculate the input DEFCONFIG
	declare -g INPUT_DEFCONFIG="${KCONFIG}-${KERNEL_MAJOR}.${KERNEL_MINOR}.y-${ARCH}"
	if [[ ! -f "kernel/configs/${INPUT_DEFCONFIG}" ]]; then
		echo "ERROR: kernel/configs/${INPUT_DEFCONFIG} does not exist, check inputs/envs" >&2
		exit 1
	fi

	# Calculate the KERNEL_ARCH from ARCH; also what is the cross-compiler package needed for the arch
	declare -g KERNEL_ARCH="" KERNEL_CROSS_COMPILE_PKGS="" KERNEL_OUTPUT_IMAGE=""
	case "${ARCH}" in
		"x86_64")
			KERNEL_ARCH="x86"
			KERNEL_CROSS_COMPILE_PKGS="crossbuild-essential-amd64"
			KERNEL_CROSS_COMPILE="x86_64-linux-gnu-"
			KERNEL_OUTPUT_IMAGE="arch/x86_64/boot/bzImage"
			;;
		"aarch64")
			KERNEL_ARCH="arm64"
			KERNEL_CROSS_COMPILE_PKGS="crossbuild-essential-arm64"
			KERNEL_CROSS_COMPILE="aarch64-linux-gnu-"
			KERNEL_OUTPUT_IMAGE="arch/arm64/boot/Image"
			;;
		*) echo "ERROR: ARCH ${ARCH} not supported" >&2 && exit 1 ;;
	esac

	# Grab the latest version from kernel.org
	declare -g KERNEL_POINT_RELEASE=""
	resolve_latest_kernel_version_lts

	# Calculate a version and hash for the OCI image
	# Hash the Dockerfile and the input defconfig together
	declare input_hash="" short_input_hash=""
	input_hash="$(cat "kernel/configs/${INPUT_DEFCONFIG}" "kernel/Dockerfile" | sha256sum - | cut -d ' ' -f 1)"
	short_input_hash="${input_hash:0:8}"
	kernel_oci_version="${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}-${short_input_hash}"
	kernel_oci_image="${HOOK_OCI_BASE}${kernel_id}:${kernel_oci_version}"

	# Log the obtained version & images to stderr
	echo "Kernel arch: ${KERNEL_ARCH} (for ARCH ${ARCH})" >&2
	echo "Kernel version: ${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}" >&2
	echo "Kernel OCI version: ${kernel_oci_version}" >&2
	echo "Kernel OCI image: ${kernel_oci_image}" >&2
	echo "Kernel cross-compiler: ${KERNEL_CROSS_COMPILE} (in pkgs ${KERNEL_CROSS_COMPILE_PKGS})"
}

function common_build_args_kernel_default() {
	build_args+=(
		"--build-arg" "KERNEL_OUTPUT_IMAGE=${KERNEL_OUTPUT_IMAGE}"
		"--build-arg" "KERNEL_CROSS_COMPILE_PKGS=${KERNEL_CROSS_COMPILE_PKGS}" # This is not used in the Dockerfile, to maximize cache hits
		"--build-arg" "KERNEL_CROSS_COMPILE=${KERNEL_CROSS_COMPILE}"
		"--build-arg" "KERNEL_ARCH=${KERNEL_ARCH}"
		"--build-arg" "KERNEL_MAJOR=${KERNEL_MAJOR}"
		"--build-arg" "KERNEL_MAJOR_V=v${KERNEL_MAJOR}.x"
		"--build-arg" "KERNEL_MINOR=${KERNEL_MINOR}"
		"--build-arg" "KERNEL_VERSION=${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}"
		"--build-arg" "KERNEL_SERIES=${KERNEL_MAJOR}.${KERNEL_MINOR}.y"
		"--build-arg" "KERNEL_POINT_RELEASE=${KERNEL_POINT_RELEASE}"
		"--build-arg" "INPUT_DEFCONFIG=${INPUT_DEFCONFIG}"
	)
}

function configure_kernel_default() {
	echo "Configuring default kernel" >&2

	declare -a build_args=()
	common_build_args_kernel_default
	echo "Will configure with: ${build_args[*]}" >&2

	declare configurator_image="hook-kernel-configurator:latest"
	(
		cd kernel
		# Build the "kernel-configurator" target from the Dockerfile, tag it as "hook-kernel-configurator:latest"
		docker buildx build --load --progress=plain "${build_args[@]}" -t "${kernel_oci_image}" --target kernel-configurator -t "${configurator_image}" .
		# Run the built container; mount kernel/configs as /host
		cat <<- INSTRUCTIONS
			*** Starting a shell in the Docker kernel-configurator stage.
			*** The config ${INPUT_DEFCONFIG} is already in place in .config (and already expanded).
			*** You can run "make menuconfig" to interactively configure the kernel.
			*** After configuration, you should run "make savedefconfig" to obtain a "defconfig" file.
			*** You can then run "cp -v defconfig /host/${INPUT_DEFCONFIG}" to copy it to the build host for commiting.
		INSTRUCTIONS

		docker run -it --rm -v "$(pwd)/configs:/host" "${configurator_image}"
	)
}

function build_kernel_default() {
	echo "Building default kernel" >&2
	declare -a build_args=()
	common_build_args_kernel_default
	echo "Will build with: ${build_args[*]}" >&2

	(
		cd kernel
		docker buildx build --load --progress=plain "${build_args[@]}" -t "${kernel_oci_image}" .
	)

}
