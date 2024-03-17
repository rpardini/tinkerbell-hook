#!/usr/bin/env bash

set -e

# each entry in this array needs a corresponding one in the kernel_data dictionary below
declare -a kernels=(
	#"hook-default-arm64"         # Hook default kernel, source code stored in `kernel` dir in this repo
	#"hook-default-amd64"         # Hook default kernel, source code stored in `kernel` dir in this repo
	"armbian-uefi-current-arm64" # Armbian generic current UEFI kernel, usually an LTS release like 6.6.y
	"armbian-uefi-current-amd64" # Armbian generic current UEFI kernel, usually an LTS release like 6.6.y (Armbian calls it x86)
)

# method & arch are required
declare -A kernel_data=(
	["hook-default-arm64"]="method='default' arch='aarch64' KERNEL_MAJOR='5' KERNEL_MINOR='10'"
	["hook-default-amd64"]="method='default' arch='x86_64' KERNEL_MAJOR='5' KERNEL_MINOR='10'"
	["armbian-uefi-current-arm64"]="method='armbian' arch='aarch64'"
	["armbian-uefi-current-amd64"]="method='armbian' arch='x86_64'"
)

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
	declare KERNEL_POINT_RELEASE="${KERNEL_POINT_RELEASE:-"${POINT_RELEASE}"}"
}

function build_kernel_default() {
	# Calculate the input DEFCONFIG
	INPUT_DEFCONFIG="defconfigs/${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}-x86_64"
	if [[ ! -f "${INPUT_DEFCONFIG}" ]]; then
		echo "ERROR: ${INPUT_DEFCONFIG} does not exist, check inputs/envs" >&2
		exit 1
	fi
}

function build_kernel_armbian() {
	# smth else
	:
}

# Grab linuxkit from official GitHub releases; account for arm64/amd64 differences

case "${1:-"build"}" in
	gha-matrix)
		# This is a GitHub Actions matrix build, so we need to produce a JSON array of objects, one for each kernel. Doing this is bash is painful.
		declare output_json="["
		declare -i counter=0
		for kernel in "${kernels[@]}"; do
			declare kernel_data_str="${kernel_data[${kernel}]}"
			declare -A kernel_data
			eval "kernel_data=(${kernel_data_str})"
			declare arch="${kernel_data[arch]}"
			output_json+="{\"kernel\":\"${kernel}\",\"arch\":\"${arch}\"}" # Possibly include a runs-on here if CI ever gets arm64 runners
			[[ $counter -lt $((${#kernels[@]} - 1)) ]] && output_json+="," # append a comma if not the last element
			counter+=1
		done
		output_json+="]"
		
		# Set a GitHub Actions output using the new recommended syntax, write to a file
		
		
		
		;;

	kernel-config)
		# bail if not interactive (stdin is a terminal)
		[[ ! -t 0 ]] && echo "not interactive, can't configure" >&2 && exit 1

		echo "Would configure a kernel" >&2
		#docker buildx build --progress=plain -t k8s-avengers/el-kernel-lts:builder --target kernelconfigured "${build_args[@]}" .
		#docker run -it --rm -v "$(pwd):/host" k8s-avengers/el-kernel-lts:builder bash -c "echo 'Config ${INPUT_DEFCONFIG}' && make menuconfig && make savedefconfig && cp defconfig /host/${INPUT_DEFCONFIG} && echo 'Saved ${INPUT_DEFCONFIG}'"
		;;

	build2)
		docker buildx build --progress=plain -t k8s-avengers/el-kernel-lts:rpms "${build_args[@]}" .

		declare outdir="out-${KERNEL_MAJOR}.${KERNEL_MINOR}-${FLAVOR}-el${EL_MAJOR_VERSION}"
		docker run -it -v "$(pwd)/${outdir}:/host" k8s-avengers/el-kernel-lts:rpms sh -c "cp -rpv /out/* /host/"
		;;

	checkbuildandpush)
		set -x
		echo "BASE_OCI_REF: ${BASE_OCI_REF}" >&2 # Should end with a slash, or might have prefix, don't assume
		docker pull quay.io/skopeo/stable:latest

		declare FULL_VERSION="el${EL_MAJOR_VERSION}-${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}-${KERNEL_RPM_VERSION}"
		declare image_versioned="${BASE_OCI_REF}el-kernel-lts:${FULL_VERSION}"
		declare image_latest="${BASE_OCI_REF}el-kernel-lts:el${EL_MAJOR_VERSION}-${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}.y-latest"
		declare image_builder="${BASE_OCI_REF}el-kernel-lts:el${EL_MAJOR_VERSION}-${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}-builder"

		echo "image_versioned: '${image_versioned}'" >&2
		echo "image_latest: '${image_latest}'" >&2
		echo "image_builder: '${image_builder}'" >&2

		# Set GH output with the full version
		echo "FULL_VERSION=${FULL_VERSION}" >> "${GITHUB_OUTPUT}"

		# Use skopeo to check if the image_versioned tag already exists, if so, skip the build
		declare ALREADY_BUILT="no"
		if docker run quay.io/skopeo/stable:latest inspect "docker://${image_versioned}"; then
			echo "Image '${image_versioned}' already exists, skipping build." >&2
			ALREADY_BUILT="yes"
		fi

		echo "ALREADY_BUILT=${ALREADY_BUILT}" >> "${GITHUB_OUTPUT}"

		if [[ "${ALREADY_BUILT}" == "yes" ]]; then
			exit 0
		fi

		# build & tag up to the kernelconfigured stage as the image_builder
		docker buildx build --progress=plain -t "${image_builder}" --target kernelconfigured "${build_args[@]}" .

		# build final stage & push
		docker buildx build --progress=plain -t "${image_versioned}" "${build_args[@]}" .
		docker push "${image_versioned}"

		# tag & push the latest
		docker tag "${image_versioned}" "${image_latest}"
		docker push "${image_latest}"

		# push the builder
		if [[ "${PUSH_BUILDER_IMAGE:-"no"}" == "yes" ]]; then
			docker push "${image_builder}"
		fi

		# Get the built rpms out of the image and into our 'out' dir
		declare outdir="out"
		docker run -v "$(pwd)/${outdir}:/host" "${image_versioned}" sh -c "cp -rpv /out/* /host/"

		echo "Showing out dir:" >&2
		ls -lahR "${outdir}" >&2

		# Prepare a 'dist' dir with flat binary (not source) RPMs across all arches.
		echo "Preparing dist dir" >&2
		mkdir -p dist
		cp -v out/RPMS/*/*.rpm dist/
		ls -lahR "dist" >&2
		;;

esac

echo "Success." >&2
exit 0
