function create_image_fat32_root_from_dir() {
	declare output_image="${1}"
	declare fat32_root_dir="${2}"
	declare partition_type="gpt" # or, "mbr"
	declare esp_partitition="no" # or, "yes" -- only for GPT; mark the fat32 partition as an ESP or not

	# Show whats about to be done
	log info "Creating FAT32 image '${output_image}' from '${fat32_root_dir}'..."
	log info "Partition type: ${partition_type}; ESP partition: ${esp_partitition}"

	# Prepare arguments to virt-make-fs as an array
	declare -a virt_make_fs_args=()
	#virt_make_fs_args+=("--verbose") # it is very, very verbose, but reveals how guestfs does the magic.
	virt_make_fs_args+=("--format=raw")
	virt_make_fs_args+=("--partition=${partition_type}")
	virt_make_fs_args+=("--type=vfat")
	virt_make_fs_args+=("--size=+32M")
	virt_make_fs_args+=("--label=hook")

	# Create a Dockerfile; install guestfs, which does the heavy lifting of creating the GPT image with a FAT32 partition
	# tl-dr: qemu in usermode, own kernel, /dev/loop. it's very, very slow, as no KVM is used since it's already inside a container.

	# A helper script, as escaping bash into a RUN command in Dockerfile is a pain; included in input_hash later
	mkdir -p "bootable"
	declare dockerfile_helper_filename="undefined.sh"
	produce_dockerfile_helper_apt_oras "bootable/" # will create the helper script in bootable/ directory; sets helper_name

	cat <<- EOD > "bootable/Dockerfile.autogen.helper.mkfat32.sh"
		#!/bin/bash
		set -e
		set -x

		# Hack: transform the initramfs using mkimage to a u-boot image
		#mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd -d /work/input/initramfs /work/input/initramfs.uimg
		#rm -fv /work/input/initramfs
		#ls -lah /work/input/initramfs.uimg

		# Hack: boot.cmd -> boot.scr
		if [ -f /work/input/boot.cmd ]; then
			echo "Converting boot.cmd to boot.scr..."
			mkimage -C none -A arm -T script -d /work/input/boot.cmd /work/input/boot.scr
		fi

		# Create a simple tar of the input directory
		cd /work/input; tar -cvf /work/input.tar .

		truncate -s 512M /output/fat32.img
		guestfish --rw  < /Dockerfile.autogen.helper.guestfish.script
		parted /output/fat32.img print
		sgdisk --print /output/fat32.img
		sgdisk --info=1 /output/fat32.img
	EOD

	cat <<- EOD > "bootable/Dockerfile.autogen.helper.guestfish.script"
		echo 'Adding image...'
		add /output/fat32.img
		echo 'Start the guestfish shell...'
		run
		echo 'List the partitions...'
		list-filesystems

		echo 'Create a GPT partition table...'
		part-init /dev/sda gpt

		echo 'Create a FAT32 partition with an offset'
		part-add /dev/sda p 2048 1048542

		echo 'Create a FAT32 filesystem with label hook...'
		mkfs vfat /dev/sda1 label:hook

		echo 'List the partitions and filesystems...'
		list-partitions
		list-filesystems

		echo 'Mount the FAT32 filesystem...'
		mount /dev/sda1 /
		echo 'Copy the contents of the input tar to the FAT32 filesystem...'
		tar-in /work/input.tar /

		echo 'Finished'
		list-partitions
		list-filesystems
		ll /

		echo 'Done.'
	EOD

	# Lets create a Dockerfile that will be used to obtain the artifacts needed, using ORAS binary
	declare -g mkfat32_dockerfile="bootable/Dockerfile.autogen.mkfat32"
	log info "Creating Dockerfile '${mkfat32_dockerfile}'... "
	cat <<- MKFAT32_DOCKERFILE > "${mkfat32_dockerfile}"
		FROM debian:stable AS downloader
		# Call the helper to install curl, oras, and the guestfs tools; also parted and gdisk
		ADD ./${dockerfile_helper_filename} /apt-oras-helper.sh
		RUN bash /apt-oras-helper.sh tree guestfs-tools guestfish parted gdisk u-boot-tools
		FROM downloader AS downloaded
		ADD ./${fat32_root_dir} /work/input
		RUN tree /work/input
		ADD ./Dockerfile.autogen.helper.guestfish.script /Dockerfile.autogen.helper.guestfish.script
		ADD ./Dockerfile.autogen.helper.mkfat32.sh /Dockerfile.autogen.helper.mkfat32.sh
		WORKDIR /output
		RUN bash /Dockerfile.autogen.helper.mkfat32.sh
		FROM scratch
		COPY --from=downloaded /output/* /
	MKFAT32_DOCKERFILE

	declare input_hash="" short_input_hash=""
	input_hash="$(cat "${mkfat32_dockerfile}" "kernel/${dockerfile_helper_filename}" | sha256sum - | cut -d ' ' -f 1)"
	short_input_hash="${input_hash:0:8}"
	log debug "Input hash for fat32: ${input_hash}"
	log debug "Short input hash for fat32: ${short_input_hash}"

	# Calculate the local image name for the fat32 image
	declare fat32img_oci_image="${HOOK_KERNEL_OCI_BASE}-mkfat32:${short_input_hash}"
	log debug "Using local image name for fat32 image: '${fat32img_oci_image}'"
	#bat --file-name=Dockerfile "${mkfat32_dockerfile}"

	# Now, build the D   ockerfile...
	log info "Building Dockerfile for fat32 image..."
	docker buildx build --load "--progress=${DOCKER_BUILDX_PROGRESS_TYPE}" -t "${fat32img_oci_image}" -f "${mkfat32_dockerfile}" bootable

	# Now get at the image inside the built Docker image
	log info "Extracting fat32 image from built Dockerfile... wait..."
	docker create --name "export-fat32img-${input_hash}" "${fat32img_oci_image}" "command_is_irrelevant_here_container_is_never_started"
	(docker export "export-fat32img-${input_hash}" | tar -xO "fat32.img" > "${output_image}") || true # don't fail -- otherwise container is left behind forever
	docker rm "export-fat32img-${input_hash}"
	log info "Extracted fat32 image to '${output_image}'"

}
