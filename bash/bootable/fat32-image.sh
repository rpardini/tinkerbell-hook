function create_image_fat32_root_from_dir() {
	declare output_dir="${1}"
	declare output_filename="${2}"
	declare fat32_root_dir="${3}"
	declare partition_type="${partition_type:-"gpt"}"  # or, "mbr"
	declare esp_partitition="${esp_partitition:-"no"}" # or, "yes" -- only for GPT; mark the fat32 partition as an ESP or not
	declare output_image="${output_dir}/${output_filename}"

	# Show whats about to be done
	log info "Creating FAT32 image '${output_image}' from '${fat32_root_dir}'..."
	log info "Partition type: ${partition_type}; ESP partition: ${esp_partitition}"

	# Create a Dockerfile; install parted and mtools
	mkdir -p "bootable"
	declare dockerfile_helper_filename="undefined.sh"
	produce_dockerfile_helper_apt_oras "bootable/" # will create the helper script in bootable/ directory; sets helper_name

	# Lets create a Dockerfile that will be used to create the FAT32 image
	cat <<- MKFAT32_SCRIPT > "bootable/Dockerfile.autogen.helper.mkfat32.sh"
		#!/bin/bash
		set -e
		set -x

		# Hack: transform the initramfs using mkimage to a u-boot image # @TODO refactor this out of here
		mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd -d /work/input/initramfs /work/input/uinitrd
		#rm -f /work/input/initramfs
		ls -lah /work/input/uinitrd

		# Hack: boot.cmd -> boot.scr
		if [ -f /work/input/boot.cmd ]; then
			echo "Converting boot.cmd to boot.scr..."
			mkimage -C none -A arm -T script -d /work/input/boot.cmd /work/input/boot.scr
		fi

		truncate -s 512M /output/fat32.img
		parted /output/fat32.img mklabel ${partition_type}
		parted -a optimal /output/fat32.img mkpart primary fat32 16MiB 100%
		if [ "${partition_type}" == "gpt" ] && [ "${esp_partitition}" == "yes" ]; then
			parted /output/fat32.img set 1 esp on;
		fi
		mformat -i /output/fat32.img@@16M -F -v HOOK ::
		mcopy -i /output/fat32.img@@16M -s /work/input/* ::
		# list all the files in the fat32.img
		mdir -i /output/fat32.img@@16M -s

		parted /output/fat32.img print
		sgdisk --print /output/fat32.img
		sgdisk --info=1 /output/fat32.img
		mv -v /output/fat32.img /output/${output_filename}
	MKFAT32_SCRIPT

	# Lets create a Dockerfile that will be used to obtain the artifacts needed, using ORAS binary
	declare -g mkfat32_dockerfile="bootable/Dockerfile.autogen.mkfat32"
	log info "Creating Dockerfile '${mkfat32_dockerfile}'... "
	cat <<- MKFAT32_DOCKERFILE > "${mkfat32_dockerfile}"
		FROM debian:stable AS builder
		# Call the helper to install curl, oras, parted, and mtools
		ADD ./${dockerfile_helper_filename} /apt-oras-helper.sh
		RUN bash /apt-oras-helper.sh parted mtools tree u-boot-tools gdisk
		ADD ./${fat32_root_dir} /work/input
		RUN tree /work/input
		ADD ./Dockerfile.autogen.helper.mkfat32.sh /Dockerfile.autogen.helper.mkfat32.sh
		WORKDIR /output
		RUN bash /Dockerfile.autogen.helper.mkfat32.sh
		FROM scratch
		COPY --from=builder /output/* /
	MKFAT32_DOCKERFILE

	declare input_hash="" short_input_hash=""
	input_hash="$(cat "${mkfat32_dockerfile}" "kernel/${dockerfile_helper_filename}" | sha256sum - | cut -d ' ' -f 1)"
	short_input_hash="${input_hash:0:8}"
	log debug "Input hash for fat32: ${input_hash}"
	log debug "Short input hash for fat32: ${short_input_hash}"

	# Calculate the local image name for the fat32 image
	declare fat32img_oci_image="${HOOK_KERNEL_OCI_BASE}-mkfat32:${short_input_hash}"
	log debug "Using local image name for fat32 image: '${fat32img_oci_image}'"

	# Now, build the Dockerfile and output the fat32 image directly
	log info "Building Dockerfile for fat32 image and outputting directly to '${output_image}'..."
	docker buildx build --output "type=local,dest=${output_dir}" "--progress=${DOCKER_BUILDX_PROGRESS_TYPE}" -t "${fat32img_oci_image}" -f "${mkfat32_dockerfile}" bootable

	# Ensure the output image is named correctly; grab its size
	if [ -f "${output_image}" ]; then
		declare fat32img_size
		fat32img_size="$(du -h "${output_image}" | cut -f 1)"
		log info "Built fat32 image '${output_image}' (${fat32img_size})"
	else
		log error "Failed to build fat32 image, missing '${output_image}'"
		exit 1
	fi
}
