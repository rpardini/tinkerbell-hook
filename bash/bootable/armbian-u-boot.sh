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
	log info "Building Armbian u-boot for Rockchip"

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

	# ghcr.io/armsurvivors/armbian-release/uboot-mekotronics-r58x-pro-vendor:25.01.07-armsurvivors-714
	declare uboot_oci_package_name="uboot-${BOARD}-${BRANCH}"
	log info "Using Armbian u-boot package: '${uboot_oci_package_name}'"

	declare uboot_oci_package="${ARMBIAN_BASE_ORAS_REF}/${uboot_oci_package_name}"
	log info "Using Armbian u-boot OCI package: '${uboot_oci_package}'"

	# if UBOOT_VERSION is set, use it; otherwise obtain the latest one from the OCI registry via Skopeo
	if [[ -z "${UBOOT_VERSION}" ]]; then
		log info "UBOOT_VERSION is unset, obtaining the most recently pushed-to tag of ${uboot_oci_package}"
		declare latest_tag_for_docker_image
		get_latest_tag_for_docker_image_using_skopeo "${uboot_oci_package}"  ".\-S..." # regex to match the tag, like "2017.09-Sxxxx"
		UBOOT_VERSION="${latest_tag_for_docker_image}"
		log info "Using most recent Armbian u-boot tag: ${UBOOT_VERSION}"
	fi









}
