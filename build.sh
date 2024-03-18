#!/usr/bin/env bash

set -e

# each entry in this array needs a corresponding one in the kernel_data dictionary below
declare -a kernels=(
	"hook-default-arm64" # Hook default kernel, source code stored in `kernel` dir in this repo
	"hook-default-amd64" # Hook default kernel, source code stored in `kernel` dir in this repo
	#"armbian-uefi-current-arm64" # Armbian generic current UEFI kernel, usually an LTS release like 6.6.y
	#"armbian-uefi-current-amd64" # Armbian generic current UEFI kernel, usually an LTS release like 6.6.y (Armbian calls it x86)
)

# method & arch are always required, others are method-specific
declare -A kernel_data=(
	["hook-default-arm64"]="['METHOD']='default' ['ARCH']='aarch64' ['KERNEL_MAJOR']='5' ['KERNEL_MINOR']='10' "
	["hook-default-amd64"]="['METHOD']='default' ['ARCH']='x86_64' ['KERNEL_MAJOR']='5' ['KERNEL_MINOR']='10' "
	#["armbian-uefi-current-arm64"]="['METHOD']='armbian' ['ARCH']='aarch64' ['ARMBIAN_KERNEL_ARTIFACT']='kernel-arm64-current' ['ARMBIAN_KERNEL_VERSION']='6.6.22-S6a64-D0696-Pdd93-C334eHfe66-HK01ba-Vc222-Bf200-R448a' "
	#["armbian-uefi-current-amd64"]="['METHOD']='armbian' ['ARCH']='x86_64' ['ARMBIAN_KERNEL_ARTIFACT']='kernel-x86-current' "
)

declare -g HOOK_OCI_BASE="quay.io/tinkerbellrpardini/kernel-"
declare -g ARMBIAN_OCI_BASE="ghcr.io/armbian/os/"

# Grab tooling needed: jq, from apt
[[ ! -f /usr/bin/jq ]] && apt update && apt install -y jq
# Grab tooling needed: envsubst, from gettext
[[ ! -f /usr/bin/envsubst ]] && apt update && apt install -y gettext-base

function resolve_latest_kernel_version_lts() { # Produces KERNEL_POINT_RELEASE
	if [[ ! -f kernel-releases.json ]]; then
		echo "Getting kernel-releases.json from kernel.org" >&2
		curl "https://www.kernel.org/releases.json" > kernel-releases.json
	else
		echo "Using disk cached kernel-releases.json" >&2
	fi

	# shellcheck disable=SC2002 # cat is not useless. my cat's stylistic
	POINT_RELEASE_TRI="$(cat kernel-releases.json | jq -r ".releases[].version" | grep -v -e "^next\-" -e "\-rc" | grep -e "^${KERNEL_MAJOR}\.${KERNEL_MINOR}\.")"
	POINT_RELEASE="$(echo "${POINT_RELEASE_TRI}" | cut -d '.' -f 3)"
	echo "POINT_RELEASE_TRI: ${POINT_RELEASE_TRI}" >&2
	echo "POINT_RELEASE: ${POINT_RELEASE}" >&2
	KERNEL_POINT_RELEASE="${KERNEL_POINT_RELEASE:-"${POINT_RELEASE}"}"
}

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

function build_kernel_armbian() {
	# smth else
	echo "Building armbian kernel" >&2

	declare oci_ref="${ARMBIAN_OCI_BASE}${ARMBIAN_KERNEL_ARTIFACT}"
	echo "Using OCI ref: ${oci_ref}" >&2

	# Get a list of tags from the ref using skopeo
	declare oci_version="${ARMBIAN_KERNEL_VERSION:-""}"

	if [[ "${oci_version}" == "" ]]; then
		echo "Getting most recent tag for ${oci_ref}" >&2
		oci_version="$(skopeo list-tags docker://${oci_ref} | jq -r ".Tags[]" | tail -1)"
		echo "Using most recent tag: ${oci_version}" >&2
	fi

	declare full_oci_ref="${oci_ref}:${oci_version}"
	echo "Using full OCI ref: ${full_oci_ref}" >&2

	# Now use ORAS to pull the .tar that's inside that ref

	# <WiP>

}

function get_kernel_info_dict() { 
	declare kernel="${1}"
	declare kernel_data_str="${kernel_data[${kernel}]}"
	if [[ -z "${kernel_data_str}" ]]; then
		echo "ERROR: No kernel data found for '${kernel}'" >&2
		exit 1
	fi
	echo "Kernel data for '${kernel}': ${kernel_data_str}" >&2
	eval "kernel_info=(${kernel_data_str})"
	# Post process
	kernel_info['BUILD_FUNC']="build_kernel_${kernel_info['METHOD']}"
	kernel_info['VERSION_FUNC']="calculate_kernel_version_${kernel_info['METHOD']}"
}

function set_kernel_vars_from_info_dict() {
	# Loop over the keys in kernel_info dictionary
	for key in "${!kernel_info[@]}"; do
		declare -g "${key}"="${kernel_info[${key}]}"
		echo "Set ${key} to ${kernel_info[${key}]}" >&2
	done
}

# Grab linuxkit from official GitHub releases; account for arm64/amd64 differences

case "${1:-"build"}" in
	gha-matrix)
		# This is a GitHub Actions matrix build, so we need to produce a JSON array of objects, one for each kernel. Doing this in bash is painful.
		declare output_json="[" full_json=""
		declare -i counter=0
		for kernel in "${kernels[@]}"; do
			declare -A kernel_info
			get_kernel_info_dict "${kernel}"

			output_json+="{\"kernel\":\"${kernel}\",\"arch\":\"${kernel_info[ARCH]}\"}" # Possibly include a runs-on here if CI ever gets arm64 runners
			[[ $counter -lt $((${#kernels[@]} - 1)) ]] && output_json+=","              # append a comma if not the last element
			counter+=1
		done
		output_json+="]"
		full_json="$(echo "${output_json}" | jq -c .)" # Pass it through jq for correctness check & compaction

		# If under GHA, set a GHA output variable
		if [[ -z "${GITHUB_OUTPUT}" ]]; then
			echo "Would have set GHA output kernels_json to: ${full_json}" >&2
		else
			echo "kernels_json=${full_json}" >> "${GITHUB_OUTPUT}"
		fi
		;;

	kernel-config)
		# bail if not interactive (stdin is a terminal)
		[[ ! -t 0 ]] && echo "not interactive, can't configure" >&2 && exit 1
		echo "Would configure a kernel" >&2
		#docker buildx build --progress=plain -t k8s-avengers/el-kernel-lts:builder --target kernelconfigured "${build_args[@]}" .
		#docker run -it --rm -v "$(pwd):/host" k8s-avengers/el-kernel-lts:builder bash -c "echo 'Config ${INPUT_DEFCONFIG}' && make menuconfig && make savedefconfig && cp defconfig /host/${INPUT_DEFCONFIG} && echo 'Saved ${INPUT_DEFCONFIG}'"
		;;

	kernel-build)
		declare kernel_id="${2:-"hook-default-arm64"}"
		declare -A kernel_info
		declare kernel_oci_version="" kernel_oci_image=""
		get_kernel_info_dict "${kernel_id}"
		set_kernel_vars_from_info_dict
		
		echo "Kernel calculate version method: ${kernel_info[VERSION_FUNC]}" >&2
		"${kernel_info[VERSION_FUNC]}"
		
		# @TODO: once we've the version, we can determine if it is already available in the OCI registry; if so, just pull and skip building.
		
		echo "Kernel build method: ${kernel_info[BUILD_FUNC]}" >&2
		"${kernel_info[BUILD_FUNC]}"

		#docker buildx build --progress=plain -t k8s-avengers/el-kernel-lts:rpms "${build_args[@]}" .

		#declare outdir="out-${KERNEL_MAJOR}.${KERNEL_MINOR}-${FLAVOR}-el${EL_MAJOR_VERSION}"
		#docker run -it -v "$(pwd)/${outdir}:/host" k8s-avengers/el-kernel-lts:rpms sh -c "cp -rpv /out/* /host/"
		;;

esac

echo "Success." >&2
exit 0
