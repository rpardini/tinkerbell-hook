#!/usr/bin/env bash

function obtain_linuxkit_binary_cached() {
	# Grab linuxkit from official GitHub releases; account for arm64/amd64 differences

	declare -g -r linuxkit_version="${linuxkit_version:-"1.0.1"}"
	declare linuxkit_arch=""
	# determine the arch to download from current arch
	case "$(uname -m)" in
		"x86_64") linuxkit_arch="amd64" ;;
		"aarch64") linuxkit_arch="arm64" ;;
		*) echo "ERROR: ARCH $(uname -m) not supported by linuxkit? check https://github.com/linuxkit/linuxkit/releases" >&2 && exit 1 ;;
	esac

	declare linuxkit_down_url="https://github.com/linuxkit/linuxkit/releases/download/v${linuxkit_version}/linuxkit-linux-${linuxkit_arch}"
	declare -g -r linuxkit_bin="./linuxkit-linux-${linuxkit_arch}-${linuxkit_version}"

	# Download using curl if not already present
	if [[ ! -f "${linuxkit_bin}" ]]; then
		echo "Downloading linuxkit from ${linuxkit_down_url} to file ${linuxkit_bin}" >&2
		curl -sL "${linuxkit_down_url}" -o "${linuxkit_bin}"
		chmod +x "${linuxkit_bin}"
	fi

	# Show the binary's version
	echo "LinuxKit binary version: ('0.8+' reported for 1.2.0, bug?): $("${linuxkit_bin}" version | xargs echo -n)" >&2

}

function linuxkit_build() {
	declare -A kernel_info
	declare kernel_oci_version="" kernel_oci_image=""
	get_kernel_info_dict "${kernel_id}"
	set_kernel_vars_from_info_dict

	echo "Kernel calculate version method: ${kernel_info[VERSION_FUNC]}" >&2
	"${kernel_info[VERSION_FUNC]}"

	# Ensure OUTPUT_ID is set
	if [[ "${OUTPUT_ID}" == "" ]]; then
		echo "ERROR: \${OUTPUT_ID} is not set after ${kernel_info[VERSION_FUNC]}" >&2
		exit 1
	fi

	# If the image is in the local docker cache, skip building
	if [[ -n "$(docker images -q "${kernel_oci_image}")" ]]; then
		echo "Kernel image ${kernel_oci_image} already in local cache; trying a pull to update, but tolerate failures..." >&2
		docker pull "${kernel_oci_image}" || echo "Pull failed, using local image ${kernel_oci_image}" >&2
	else
		# Pull the kernel from the OCI registry
		echo "Pulling kernel from ${kernel_oci_image}" >&2
		docker pull "${kernel_oci_image}"
		# @TODO: if pull fails, build like build-kernel would.
	fi

	# Build the containers in this repo used in the LinuxKit YAML;
	build_all_hook_linuxkit_containers # sets HOOK_CONTAINER_BOOTKIT_IMAGE, HOOK_CONTAINER_DOCKER_IMAGE, HOOK_CONTAINER_MDEV_IMAGE

	# Template the linuxkit configuration file.
	# - You'd think linuxkit would take --build-args or something by now, but no.
	# - Linuxkit does have @pkg but that's only useful in its own repo (with pkgs/ dir)
	# - envsubst doesn't offer a good way to escape $ in the input, so we pass the exact list of vars to consider, so escaping is not needed

	# shellcheck disable=SC2016 # I'm using single quotes to avoid shell expansion, envsubst wants the dollar signs.
	# shellcheck disable=SC2002 # Again, no, I love my cat, leave me alone
	cat "hook.template.yaml" |
		HOOK_KERNEL_IMAGE="${kernel_oci_image}" HOOK_KERNEL_ID="${kernel_id} from ${kernel_oci_image}" \
			HOOK_CONTAINER_BOOTKIT_IMAGE="${HOOK_CONTAINER_BOOTKIT_IMAGE}" \
			HOOK_CONTAINER_DOCKER_IMAGE="${HOOK_CONTAINER_DOCKER_IMAGE}" \
			HOOK_CONTAINER_MDEV_IMAGE="${HOOK_CONTAINER_MDEV_IMAGE}" \
			envsubst '$HOOK_KERNEL_IMAGE $HOOK_KERNEL_ID $HOOK_CONTAINER_BOOTKIT_IMAGE $HOOK_CONTAINER_DOCKER_IMAGE $HOOK_CONTAINER_MDEV_IMAGE' > "hook.${kernel_id}.yaml"

	declare -g linuxkit_bin=""
	obtain_linuxkit_binary_cached # sets "${linuxkit_bin}"

	declare lk_output_dir="out/linuxkit-${kernel_id}"
	mkdir -p "${lk_output_dir}"

	declare -a lk_args=(
		"--docker"
		"--arch" "${kernel_info['DOCKER_ARCH']}"
		"--format" "kernel+initrd"
		"--name" "hook"
		"--dir" "${lk_output_dir}"
		"hook.${kernel_id}.yaml" # the linuxkit configuration file
	)

	echo "Building Hook with kernel ${kernel_id} using linuxkit: ${lk_args[*]}" >&2
	"${linuxkit_bin}" build "${lk_args[@]}"

	# @TODO: allow a "run" stage here.

	# rename outputs
	mv -v "${lk_output_dir}/hook-kernel" "${lk_output_dir}/vmlinuz-${OUTPUT_ID}"
	mv -v "${lk_output_dir}/hook-initrd.img" "${lk_output_dir}/initramfs-${OUTPUT_ID}"
	rm "${lk_output_dir}/hook-cmdline"

	# prepare out/hook dir with the kernel/initramfs pairs; this makes it easy to deploy to /opt/hook eg for stack chart (or nibs)
	mkdir -p "out/hook"
	mv -v "${lk_output_dir}/vmlinuz-${OUTPUT_ID}" "out/hook/vmlinuz-${OUTPUT_ID}"
	mv -v "${lk_output_dir}/initramfs-${OUTPUT_ID}" "out/hook/initramfs-${OUTPUT_ID}"

	declare -a output_files=("vmlinuz-${OUTPUT_ID}" "initramfs-${OUTPUT_ID}")

	# We need to extract /dtbs.tar.gz from the kernel image; linuxkit itself knows nothing about dtbs.
	# Export a .tar of the image using docker to stdout, read a single file from stdin and output it
	docker create --name "export-dtb-${OUTPUT_ID}" "${kernel_oci_image}" "command_is_irrelevant_here_container_is_never_started"
	(docker export "export-dtb-${OUTPUT_ID}" | tar -xO "dtbs.tar.gz" > "${lk_output_dir}/dtbs-${OUTPUT_ID}.tar.gz") || true # don't fail -- otherwise container is left behind forever
	docker rm "export-dtb-${OUTPUT_ID}"

	# Now process "${lk_output_dir}/dtbs-${OUTPUT_ID}.tar.gz so every file in it is prefixed with the path dtbs-${OUTPUT_ID}/
	# This is so that the tarball can be extracted in /boot/dtbs-${OUTPUT_ID} and not pollute /boot with a ton of dtbs
	declare dtbs_tmp_dir="${lk_output_dir}/extract-dtbs-${OUTPUT_ID}"
	mkdir -p "${dtbs_tmp_dir}"
	tar -xzf "${lk_output_dir}/dtbs-${OUTPUT_ID}.tar.gz" -C "${dtbs_tmp_dir}"
	# Get a count of .dtb files in the extracted dir
	declare -i dtb_count
	dtb_count=$(find "${dtbs_tmp_dir}" -type f -name "*.dtb" | wc -l)
	echo "Kernel includes ${dtb_count} DTB files..." >&2
	# If more than zero, let's tar them up adding a prefix
	if [[ $dtb_count -gt 0 ]]; then
		tar -czf "out/hook/dtbs-${OUTPUT_ID}.tar.gz" -C "${dtbs_tmp_dir}" --transform "s,^,dtbs-${OUTPUT_ID}/," .
		output_files+=("dtbs-${OUTPUT_ID}.tar.gz")
	else
		echo "No DTB files found in kernel image." >&2
	fi
	rm -rf "${dtbs_tmp_dir}"
	rm "${lk_output_dir}/dtbs-${OUTPUT_ID}.tar.gz"

	rmdir "${lk_output_dir}"

	# tar the files into out/hook.tar in such a way that vmlinuz and initramfs are at the root of the tar; pigz it
	# Those are the artifacts published to the GitHub release
	tar -cvf- -C "out/hook" "${output_files[@]}" | pigz > "out/hook-${OUTPUT_ID}.tar.gz"
}
