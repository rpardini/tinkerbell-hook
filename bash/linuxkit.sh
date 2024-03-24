#!/usr/bin/env bash

function obtain_linuxkit_binary_cached() {
	# Grab linuxkit from official GitHub releases; account for arm64/amd64 differences

	declare linuxkit_arch=""
	# determine the arch to download from current arch
	case "$(uname -m)" in
		"x86_64") linuxkit_arch="amd64" ;;
		"aarch64") linuxkit_arch="arm64" ;;
		*) log error "ERROR: ARCH $(uname -m) not supported by linuxkit? check https://github.com/linuxkit/linuxkit/releases" && exit 1 ;;
	esac

	declare linuxkit_down_url="https://github.com/linuxkit/linuxkit/releases/download/v${LINUXKIT_VERSION}/linuxkit-linux-${linuxkit_arch}"
	declare -g linuxkit_bin="./linuxkit-linux-${linuxkit_arch}-${LINUXKIT_VERSION}"

	# Download using curl if not already present
	if [[ ! -f "${linuxkit_bin}" ]]; then
		log info "Downloading linuxkit from ${linuxkit_down_url} to file ${linuxkit_bin}"
		curl -sL "${linuxkit_down_url}" -o "${linuxkit_bin}"
		chmod +x "${linuxkit_bin}"
	fi

	# Show the binary's version
	log info "LinuxKit binary version: ('0.8+' reported for 1.2.0, bug?): $("${linuxkit_bin}" version | xargs echo -n)"

}

function linuxkit_build() {
	declare -A kernel_info
	declare kernel_oci_version="" kernel_oci_image=""
	get_kernel_info_dict "${kernel_id}"
	set_kernel_vars_from_info_dict

	log debug "Kernel calculate version method: ${kernel_info[VERSION_FUNC]}"
	"${kernel_info[VERSION_FUNC]}"

	# Ensure OUTPUT_ID is set
	if [[ "${OUTPUT_ID}" == "" ]]; then
		log error "\${OUTPUT_ID} is not set after ${kernel_info[VERSION_FUNC]}"
		exit 1
	fi

	# If the image is in the local docker cache, skip building
	if [[ -n "$(docker images -q "${kernel_oci_image}")" ]]; then
		log info "Kernel image ${kernel_oci_image} already in local cache; trying a pull to update, but tolerate failures..."
		docker pull "${kernel_oci_image}" || log warn "Pull failed, using local image ${kernel_oci_image}"
	else
		# Pull the kernel from the OCI registry
		log info "Pulling kernel from ${kernel_oci_image}"
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

	log info "Building Hook with kernel ${kernel_id} using linuxkit: ${lk_args[*]}"
	"${linuxkit_bin}" build "${lk_args[@]}"

	if [[ "${LK_RUN}" == "qemu" ]]; then
		linuxkit_run_qemu
		return 0
	fi

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
	log info "Kernel includes ${dtb_count} DTB files..."
	# If more than zero, let's tar them up adding a prefix
	if [[ $dtb_count -gt 0 ]]; then
		tar -czf "out/hook/dtbs-${OUTPUT_ID}.tar.gz" -C "${dtbs_tmp_dir}" --transform "s,^,dtbs-${OUTPUT_ID}/," .
		output_files+=("dtbs-${OUTPUT_ID}.tar.gz")
	else
		log info "No DTB files found in kernel image."
	fi
	rm -rf "${dtbs_tmp_dir}"
	rm "${lk_output_dir}/dtbs-${OUTPUT_ID}.tar.gz"

	rmdir "${lk_output_dir}"

	# tar the files into out/hook.tar in such a way that vmlinuz and initramfs are at the root of the tar; pigz it
	# Those are the artifacts published to the GitHub release
	tar -cvf- -C "out/hook" "${output_files[@]}" | pigz > "out/hook-${OUTPUT_ID}.tar.gz"
}

function linuxkit_run_qemu() {
	declare lk_output_dir="out/linuxkit-${kernel_id}"
	# Todo this is common everywhere, just do it in build.sh
	declare -A kernel_info
	declare kernel_oci_version="" kernel_oci_image=""
	get_kernel_info_dict "${kernel_id}"
	set_kernel_vars_from_info_dict

	declare -g linuxkit_bin=""
	obtain_linuxkit_binary_cached # sets "${linuxkit_bin}"

	# apt install qemu-system-x86 if no /usr/bin/qemu-system-x86_64
	# apt install ovmf if no /usr/share/OVMF/OVMF_CODE.fd

	# --fw string              Path to OVMF firmware for UEFI boot

	declare -a lk_run_args=(
		"run" "qemu"
		"--arch" "${kernel_info['ARCH']}" # Not DOCKER_ARCH
		"--kernel"                        # Boot image is kernel+initrd+cmdline 'path'-kernel/-initrd/-cmdline
		"--uefi"                          # Use UEFI boot
		"--cpus" "2"                      # Use 2 CPU's
		"--mem" "2048"                    # Use 2GB of RAM
	)

	# x86, debian
	lk_run_args+=("--fw" "/usr/share/OVMF/OVMF_CODE.fd")

	# only if we know of a tink-server instance and a MAC address
	declare -a lk_run_kernel_cmdline=(
		"tink_worker_image=quay.io/tinkerbell/tink-worker:latest"
		"tinkerbell_tls=false"
		"grpc_authority=192.168.66.75:42113"
		"syslog_host=192.168.66.75"
		"worker_id=52:54:00:01:03:02"
		"hw_addr=52:54:00:01:03:02"
	)
	lk_run_kernel_cmdline+=("console=ttyS0")

	echo -n "${lk_run_kernel_cmdline[*]}" > "${lk_output_dir}/hook-cmdline"

	lk_run_args+=("${lk_output_dir}/hook") # Path to run; will add -kernel, -initrd, -cmdline

	log info "Running LinuxKit in QEMU with '${lk_run_args[*]}'"
	log info "Running LinuxKit in QEMU with kernel cmdline'${lk_run_kernel_cmdline[*]}'"

	"${linuxkit_bin}" "${lk_run_args[@]}"
}
