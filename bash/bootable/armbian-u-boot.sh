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
		# Call the helper to install curl, oras, and dpkg-dev
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
	input_hash="$(cat "${armbian_uboot_extract_dockerfile}" "kernel/${dockerfile_helper_filename}" | sha256sum - | cut -d ' ' -f 1)"
	short_input_hash="${input_hash:0:8}"
	log info "Input hash for u-boot: ${input_hash}"
	log info "Short input hash for u-boot: ${short_input_hash}"

	# Calculate the local image name for the u-boot extraction
	declare uboot_oci_image="${HOOK_KERNEL_OCI_BASE}-armbian-uboot:${short_input_hash}"
	log info "Using local image name for u-boot extraction: '${uboot_oci_image}'"

	bat --file-name "Dockerfile" "${armbian_uboot_extract_dockerfile}"

	# Now, build the Dockerfile...
	log info "Building Dockerfile for u-boot extraction..."
	docker buildx build --load "--progress=${DOCKER_BUILDX_PROGRESS_TYPE}" -t "${uboot_oci_image}" -f "${armbian_uboot_extract_dockerfile}" bootable

	# Now get at the binaries inside the built image
	log debug "Docker might emit a warning about mismatched platforms below. It's safe to ignore; the image in question only contains uboot binaries, for the correct arch, even though the image might have been built & tagged on a different arch."
	docker create --name "export-uboot-${input_hash}" "${uboot_oci_image}" "command_is_irrelevant_here_container_is_never_started"
	(docker export "export-uboot-${input_hash}" | tar -xO "uboot-${BOARD}-${BRANCH}.tar.gz" > "bootable/uboot-${BOARD}-${BRANCH}.tar.gz") || true # don't fail -- otherwise container is left behind forever
	docker rm "export-uboot-${input_hash}"
	log info "Extracted u-boot binaries to 'bootable/uboot-${BOARD}-${BRANCH}.tar.gz'"
	ls -laht "bootable/uboot-${BOARD}-${BRANCH}.tar.gz"

}
