#!/usr/bin/env bash

set -e

source kernel/bash/common.sh
source kernel/bash/kernel_default.sh
source kernel/bash/kernel_armbian.sh

# each entry in this array needs a corresponding one in the kernel_data dictionary below
declare -a kernels=(
	"hook-default-arm64" # Hook default kernel, source code stored in `kernel` dir in this repo
	"hook-default-amd64" # Hook default kernel, source code stored in `kernel` dir in this repo
	#"armbian-uefi-current-arm64" # Armbian generic current UEFI kernel, usually an LTS release like 6.6.y
	#"armbian-uefi-current-amd64" # Armbian generic current UEFI kernel, usually an LTS release like 6.6.y (Armbian calls it x86)
)

# method & arch are always required, others are method-specific
declare -A kernel_data=(
	["hook-default-arm64"]="['METHOD']='default' ['ARCH']='aarch64' ['KERNEL_MAJOR']='5' ['KERNEL_MINOR']='10' ['KCONFIG']='generic' "
	["hook-default-amd64"]="['METHOD']='default' ['ARCH']='x86_64' ['KERNEL_MAJOR']='5' ['KERNEL_MINOR']='10' ['KCONFIG']='generic' "
	#["armbian-uefi-current-arm64"]="['METHOD']='armbian' ['ARCH']='aarch64' ['ARMBIAN_KERNEL_ARTIFACT']='kernel-arm64-current' ['ARMBIAN_KERNEL_VERSION']='6.6.22-S6a64-D0696-Pdd93-C334eHfe66-HK01ba-Vc222-Bf200-R448a' "
	#["armbian-uefi-current-amd64"]="['METHOD']='armbian' ['ARCH']='x86_64' ['ARMBIAN_KERNEL_ARTIFACT']='kernel-x86-current' "
)

declare -g HOOK_OCI_BASE="quay.io/tinkerbellrpardini/kernel-"

# Grab tooling needed: jq, from apt
[[ ! -f /usr/bin/jq ]] && apt update && apt install -y jq
# Grab tooling needed: envsubst, from gettext
[[ ! -f /usr/bin/envsubst ]] && apt update && apt install -y gettext-base

# Grab linuxkit from official GitHub releases; account for arm64/amd64 differences

declare -r -g kernel_id="${2:-"hook-default-amd64"}"

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

		declare -A kernel_info
		declare kernel_oci_version="" kernel_oci_image=""
		get_kernel_info_dict "${kernel_id}"
		set_kernel_vars_from_info_dict

		echo "Kernel calculate version method: ${kernel_info[VERSION_FUNC]}" >&2
		"${kernel_info[VERSION_FUNC]}"

		echo "Kernel config method: ${kernel_info[CONFIG_FUNC]}" >&2
		"${kernel_info[CONFIG_FUNC]}"
		;;

	kernel-build)
		declare -A kernel_info
		declare kernel_oci_version="" kernel_oci_image=""
		get_kernel_info_dict "${kernel_id}"
		set_kernel_vars_from_info_dict

		echo "Kernel calculate version method: ${kernel_info[VERSION_FUNC]}" >&2
		"${kernel_info[VERSION_FUNC]}"

		# @TODO: once we've the version, we can determine if it is already available in the OCI registry; if so, just pull and skip building/pushing

		echo "Kernel build method: ${kernel_info[BUILD_FUNC]}" >&2
		"${kernel_info[BUILD_FUNC]}"

		# Push it to the OCI registry
		echo "Kernel built; pushing to ${kernel_oci_image}" >&2
		docker push "${kernel_oci_image}" || true

		;;

	build) # Build Hook proper, using the specified kernel
		declare -A kernel_info
		declare kernel_oci_version="" kernel_oci_image=""
		get_kernel_info_dict "${kernel_id}"
		set_kernel_vars_from_info_dict

		echo "Kernel calculate version method: ${kernel_info[VERSION_FUNC]}" >&2
		"${kernel_info[VERSION_FUNC]}"
		
		
		# If the image is in the local docker cache, skip building
		if [[ -n "$(docker images -q "${kernel_oci_image}")" ]]; then
			echo "Kernel image ${kernel_oci_image} already in local cache; skipping pull" >&2
		else
			# Pull the kernel from the OCI registry
			echo "Pulling kernel from ${kernel_oci_image}" >&2
			docker pull "${kernel_oci_image}" || true
			# @TODO: if pull fails, build like build-kernel would.
		fi


		# Template the linuxkit configuration file.
		# - You'd think linuxkit would take --build-args or something by now, but no.
		# - Linuxkit does have @pkg but that's only useful in its own repo (with pkgs/ dir)
		# - envsubst doesn't offer a good way to escape $ in the input, so we pass the exact list of vars to consider, so escaping is not needed

		cat hook.template.yaml |
			HOOK_KERNEL_IMAGE="${kernel_oci_image}" HOOK_KERNEL_ID="${kernel_id}" \
				envsubst '$HOOK_KERNEL_IMAGE $HOOK_KERNEL_ID' > "hook.${kernel_id}.yaml"
		;;

esac

echo "Success." >&2
exit 0
