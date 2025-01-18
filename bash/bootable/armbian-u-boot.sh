# A few scenarios we want to support:
# A) UEFI bootable media; GPT + ESP, FAT32, GRUB, kernel/initrd, grub.conf + some kernel command line.
# B) RPi 3b/4/5 bootable media; GPT, non-ESP partition, FAT32, kernel/initrd, config.txt, cmdline.txt + some kernel command line.
# C) Rockchip bootable media; GPT, non-ESP partition, FAT32, extlinux.conf + some kernel command line; write u-boot bin on top of GPT via Armbian sh
# D) Amlogic bootable media; MBR, FAT32, extlinux.conf + some kernel command line; write u-boot bin on top of MBR via Armbian sh

# General process:
# Obtain extra variables from environment (BOARD/BRANCH for armbian); optional.
# Obtain the latest Armbian u-boot version from the OCI registry, using Skopeo.
# 1) (C/D) Obtain the u-boot artifact binaries using ORAS, given the version above; massage using Docker and extract the binaries.
# 1) (A) Obtain grub somehow; LinuxKit has them ready-to-go in a Docker image.
# 1) (B) Obtain the rpi firmware files (bootcode.bin, start.elf, fixup.dat) from the RaspberryPi Foundation
# 2) Prepare the FAT32 contents; kernel/initrd, grub.conf, config.txt, cmdline.txt, extlinux.conf depending on scenario
# 3) Create a GPT+ESP, GTP+non-ESP, or MBR partition table image with the contents of the FAT32 (use libguestfs)
# 4) For the scenarios with u-boot, write u-boot binaries to the correct offsets in the image.

function build_bootable_armbian_uboot_rockchip() {
	declare hook_id="${bootable_info['INVENTORY_ID']}"
	# UBOOT_TYPE can be either extlinux or bootscript; defaults to bootscript
	declare uboot_type="${bootable_info['UBOOT_TYPE']:-"bootscript"}"

	log info "Building Armbian u-boot for Rockchip for hook ${hook_id} with type ${uboot_type}"

	# if BOARD is unset, bail
	if [[ -z "${BOARD}" ]]; then
		log error "BOARD is unset; please pass BOARD=xxx in the command line or env-var"
		exit 2
	fi

	# if BRANCH is unset, bail
	if [[ -z "${BRANCH}" ]]; then
		log error "BRANCH is unset; please pass BRANCH=xxx in the command line or env-var"
		exit 2
	fi

	# Prepare the base working directory in bootable/
	declare bootable_dir="rockchip-uboot-${BOARD}-${BRANCH}"
	declare bootable_base_dir="bootable/${bootable_dir}"
	rm -rf "${bootable_base_dir}"
	mkdir -p "${bootable_base_dir}"

	declare uboot_oci_package_name="uboot-${BOARD}-${BRANCH}"
	log info "Using Armbian u-boot package: '${uboot_oci_package_name}'"

	declare output_uboot_tarball="${bootable_base_dir}/uboot.tar.gz"

	obtain_armbian_uboot_tar_gz_from_oci # takes uboot_oci_package_name, BOARD, BRANCH, UBOOT_VERSION, ARMBIAN_BASE_ORAS_REF and output_uboot_tarball

	# Extract the tarball so we can get at the metadata files inside
	declare uboot_extract_dir="${bootable_base_dir}/uboot-files"
	mkdir -p "${uboot_extract_dir}"
	tar -C "${uboot_extract_dir}" --strip-components=1 -xzf "${output_uboot_tarball}"
	#tree "${uboot_extract_dir}"

	# Source the platform_install.sh (defines function write_uboot_platform <uboot-bin-dir> <output-device-or-file>)
	declare platform_install_sh="${uboot_extract_dir}/platform_install.sh"
	# shellcheck disable=SC1090
	source "${platform_install_sh}"

	# Source the metadata.sh file; declares UBOOT_PARTITION_TYPE, UBOOT_KERNEL_DTB, UBOOT_KERNEL_SERIALCON, UBOOT_EXTLINUX_PREFER, UBOOT_EXTLINUX_CMDLINE
	declare metadata_sh="${uboot_extract_dir}/u-boot-metadata.sh"
	# shellcheck disable=SC1090
	source "${metadata_sh}"

	log info "u-boot UBOOT_PARTITION_TYPE: ${UBOOT_PARTITION_TYPE}"
	log info "u-boot UBOOT_KERNEL_DTB: ${UBOOT_KERNEL_DTB}"
	log info "u-boot UBOOT_KERNEL_SERIALCON: ${UBOOT_KERNEL_SERIALCON}"
	log info "u-boot UBOOT_EXTLINUX_PREFER: ${UBOOT_EXTLINUX_PREFER}"
	log info "u-boot UBOOT_EXTLINUX_CMDLINE: ${UBOOT_EXTLINUX_CMDLINE}"
	log info "u-boot uboot_type: ${uboot_type}"

	# Prepare a directory that will be the root of the FAT32 partition
	declare fat32_root_dir="${bootable_base_dir}/fat32-root"
	mkdir -p "${fat32_root_dir}"

	# Kernel and initrd go directly in the root of the FAT32 partition
	cp -vp "out/hook/vmlinuz-${hook_id}" "${fat32_root_dir}/vmlinuz"
	cp -vp "out/hook/initramfs-${hook_id}" "${fat32_root_dir}/initramfs"

	declare -i initramfs_size_bytes
	initramfs_size_bytes=$(stat --format="%s" "${fat32_root_dir}/initramfs")

	# DTBs go into a dtb subdirectory
	mkdir -p "${fat32_root_dir}/dtb"
	# Extract the DTB .tar.gz into the root of the FAT32 partition; skip the first directory of the path of the extracted files
	tar -C "${fat32_root_dir}/dtb" --strip-components=1 -xzf "out/hook/dtbs-${hook_id}.tar.gz"
	# Get rid of any directories named 'overlays' in the DTB directory
	find "${fat32_root_dir}/dtb" -type d -name 'overlays' -exec rm -rf {} \;

	# @TODO: Prepare an extlinux.conf or boot.scr file with the kernel command line; this is board-specific
	# it also might require the metadata files from the uboot tarball, as those have details eg the exact DTB to use, console information, etc.
	write_uboot_script_or_extlinux "${fat32_root_dir}"

	# Show the state
	tree "${bootable_base_dir}"
	du -h -d 1 "${bootable_base_dir}"

	# Use a Dockerfile to assemble a GPT image, with a single FAT32 partition, containing the files in the fat32-root directory
	# This is common across all GPT-based bootable media; the only difference is the ESP flag, which is set for UEFI bootable media but not for Rockchip/RaspberryPi
	# The u-boot binaries are written _later_ in the process, after the image is created, using Armbian's helper scripts.
	create_image_fat32_root_from_dir "${bootable_base_dir}/bootable-media-${BOARD}-${BRANCH}.img" "${bootable_dir}/fat32-root"

	log info "Show info about produced image..."
	ls -lah "${bootable_base_dir}/bootable-media-${BOARD}-${BRANCH}.img"

	# Deploy u-boot binaries to the image; use the function defined in the platform_install.sh script
	# They should only use 'dd' or such
	log info "Writing u-boot binaries to the image..."
	set -x
	write_uboot_platform "${uboot_extract_dir}" "${bootable_base_dir}/bootable-media-${BOARD}-${BRANCH}.img"
	set +x

	log info "Show info about produced image (with written u-boot)..."
	ls -lah "${bootable_base_dir}/bootable-media-${BOARD}-${BRANCH}.img"

	log info "Done building Armbian u-boot for Rockchip for hook ${hook_id} with type ${uboot_type}"

	return 0
}

function write_uboot_script_or_extlinux() {
	# choose with a case based on uboot_type
	case "${uboot_type}" in
		"extlinux")
			log info "Writing extlinux.conf..."
			write_uboot_extlinux "${@}"
			;;

		"bootscript")
			log info "Writing boot.scr..."
			write_uboot_script "${@}"
			;;

		*)
			log error "Unknown uboot_type: ${uboot_type}"
			exit 1
			;;
	esac
}

function write_uboot_script() {
	declare fat32_root_dir="${1}"
	declare boot_cmd_file="${fat32_root_dir}/boot.cmd"
	cat <<- BOOT_CMD > "${boot_cmd_file}"
		# Hook u-boot bootscript; mkimage -C none -A arm -T script -d /boot.cmd /boot.scr
		echo "Starting Tinkerbell Hook boot script..."
		printenv
		setenv kernel_addr_r "0x20000000"
		setenv ramdisk_addr_r "0x40000000"
		test -n "\${distro_bootpart}" || distro_bootpart=1
		echo "Boot script loaded from \${devtype} \${devnum}:\${distro_bootpart}"
		setenv bootargs "${UBOOT_EXTLINUX_CMDLINE}"
		echo "Booting with: \${bootargs}"

		echo "Loading initramfs... \${ramdisk_addr_r} /uinitrd"
		load \${devtype} \${devnum}:\${distro_bootpart} \${ramdisk_addr_r} /uinitrd
		echo "Loading kernel... \${kernel_addr_r} /vmlinuz"
		load \${devtype} \${devnum}:\${distro_bootpart} \${kernel_addr_r} /vmlinuz
		echo "Loading dtb... \${fdt_addr_r} /dtb/${UBOOT_KERNEL_DTB}"
		load \${devtype} \${devnum}:\${distro_bootpart} \${fdt_addr_r} /dtb/${UBOOT_KERNEL_DTB}

		fdt addr \${fdt_addr_r}
		fdt resize 65536

		echo "Booting: booti \${kernel_addr_r} \${ramdisk_addr_r} \${fdt_addr_r} - args: \${bootargs}"
		booti \${kernel_addr_r} \${ramdisk_addr_r} \${fdt_addr_r}
	BOOT_CMD

	command -v bat && bat --file-name "boot.scr" "${boot_cmd_file}"

	return 0
}

function write_uboot_extlinux() {
	declare fat32_root_dir="${1}"
	mkdir -p "${fat32_root_dir}/extlinux"
	declare extlinux_conf="${fat32_root_dir}/extlinux/extlinux.conf"
	cat <<- EXTLINUX_CONF > "${extlinux_conf}"
		DEFAULT hook
		LABEL hook
			linux /vmlinuz
			initrd /initramfs
			append ${UBOOT_EXTLINUX_CMDLINE} console=${UBOOT_KERNEL_SERIALCON},1500000
			fdt /dtb/${UBOOT_KERNEL_DTB}
	EXTLINUX_CONF
	# @TODO: fdtdir when UBOOT_KERNEL_DTB is unset

	command -v bat && bat --file-name "extlinux.conf" "${extlinux_conf}"

	return 0
}

function obtain_armbian_uboot_tar_gz_from_oci() {

	declare uboot_oci_package="${ARMBIAN_BASE_ORAS_REF}/${uboot_oci_package_name}"
	log info "Using Armbian u-boot OCI package: '${uboot_oci_package}'"

	# if UBOOT_VERSION is set, use it; otherwise obtain the latest one from the OCI registry via Skopeo
	if [[ -z "${UBOOT_VERSION}" ]]; then
		log info "UBOOT_VERSION is unset, obtaining the most recently pushed-to tag of ${uboot_oci_package}"
		declare latest_tag_for_docker_image
		get_latest_tag_for_docker_image_using_skopeo "${uboot_oci_package}" ".\-S..." # regex to match the tag, like "2017.09-Sxxxx"
		UBOOT_VERSION="${latest_tag_for_docker_image}"
		log info "Using most recent Armbian u-boot tag: ${UBOOT_VERSION}"
	fi

	declare uboot_oci_ref="${uboot_oci_package}:${UBOOT_VERSION}"
	log info "Using Armbian u-boot OCI ref: '${uboot_oci_ref}'"

	# Obtain the relevant u-boot files from the Armbian OCI artifact; use a Dockerfile+ image + extraction to do so.
	# The armbian-uboot is a .deb package inside an OCI artifact.
	# A helper script, as escaping bash into a RUN command in Dockerfile is a pain; included in input_hash later
	mkdir -p "bootable"
	declare dockerfile_helper_filename="undefined.sh"
	produce_dockerfile_helper_apt_oras "bootable/" # will create the helper script in bootable/ directory; sets helper_name

	# Lets create a Dockerfile that will be used to obtain the artifacts needed, using ORAS binary
	declare -g armbian_uboot_extract_dockerfile="bootable/Dockerfile.autogen.armbian.uboot-${BOARD}-${BRANCH}-${UBOOT_VERSION}"
	log info "Creating Dockerfile '${armbian_uboot_extract_dockerfile}'... "
	cat <<- ARMBIAN_ORAS_UBOOT_DOCKERFILE > "${armbian_uboot_extract_dockerfile}"
		FROM debian:stable AS downloader
		# Call the helper to install curl, oras
		ADD ./${dockerfile_helper_filename} /apt-oras-helper.sh
		RUN bash /apt-oras-helper.sh
		FROM downloader AS downloaded
		WORKDIR /armbian/uboot
		WORKDIR /armbian/deb
		RUN oras pull "${uboot_oci_ref}"
		RUN dpkg-deb --extract linux-u-boot-*.deb /armbian/uboot
		WORKDIR /armbian/uboot
		WORKDIR /armbian/output/uboot-${BOARD}-${BRANCH}
		RUN cp -vp /armbian/uboot/usr/lib/linux-u-boot-*/* .
		RUN cp -vp /armbian/uboot/usr/lib/u-boot/platform_install.sh .
		WORKDIR /armbian/output
		RUN tar -czf uboot-${BOARD}-${BRANCH}.tar.gz uboot-${BOARD}-${BRANCH}
		RUN rm -rf uboot-${BOARD}-${BRANCH}
		FROM scratch
		COPY --from=downloaded /armbian/output/* /
	ARMBIAN_ORAS_UBOOT_DOCKERFILE

	declare input_hash="" short_input_hash=""
	input_hash="$(cat "${armbian_uboot_extract_dockerfile}" "bootable/${dockerfile_helper_filename}" | sha256sum - | cut -d ' ' -f 1)"
	short_input_hash="${input_hash:0:8}"
	log debug "Input hash for u-boot: ${input_hash}"
	log debug "Short input hash for u-boot: ${short_input_hash}"

	# Calculate the local image name for the u-boot extraction
	declare uboot_oci_image="${HOOK_KERNEL_OCI_BASE}-armbian-uboot:${short_input_hash}"
	log debug "Using local image name for u-boot extraction: '${uboot_oci_image}'"

	# Now, build the Dockerfile...
	log info "Building Dockerfile for u-boot extraction..."
	docker buildx build --load "--progress=${DOCKER_BUILDX_PROGRESS_TYPE}" -t "${uboot_oci_image}" -f "${armbian_uboot_extract_dockerfile}" bootable

	# Now get at the binaries inside the built image
	log info "Extracting u-boot binaries from built Dockerfile... wait..."
	docker create --name "export-uboot-${input_hash}" "${uboot_oci_image}" "command_is_irrelevant_here_container_is_never_started"
	(docker export "export-uboot-${input_hash}" | tar -xO "uboot-${BOARD}-${BRANCH}.tar.gz" > "${output_uboot_tarball}") || true # don't fail -- otherwise container is left behind forever
	docker rm "export-uboot-${input_hash}"
	log info "Extracted u-boot binaries to '${output_uboot_tarball}'"

}
