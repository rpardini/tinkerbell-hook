function create_image_fat32_root_from_dir() {
	declare output_image="${1}"
	declare fat32_root_dir="${2}"
	declare partition_type="gpt" # or, "mbr"
	declare esp_partitition="no" # or, "yes" -- only for GPT; mark the fat32 partition as an ESP or not

	# Show whats about to be done
	log info "Creating FAT32 image '${output_image}' from '${fat32_root_dir}'..."
	log info "Partition type: ${partition_type}; ESP partition: ${esp_partitition}"

	# Create a Dockerfile; install guestfs.

	# Obtain the relevant fat32 files from the Armbian OCI artifact; use a Dockerfile+ image + image to do so.
	# The armbian-fat32img is a .deb package inside an OCI artifact.
	# A helper script, as escaping bash into a RUN command in Dockerfile is a pain; included in input_hash later
	mkdir -p "bootable"
	declare dockerfile_helper_filename="undefined.sh"
	produce_dockerfile_helper_apt_oras "bootable/" # will create the helper script in bootable/ directory; sets helper_name

	# Lets create a Dockerfile that will be used to obtain the artifacts needed, using ORAS binary
	declare -g mkfat32_dockerfile="bootable/Dockerfile.autogen.mkfat32"
	log info "Creating Dockerfile '${mkfat32_dockerfile}'... "
	cat <<- MKFAT32_DOCKERFILE > "${mkfat32_dockerfile}"
		FROM debian:stable AS downloader
		# Call the helper to install curl, oras, and the guestfs tools; also parted and gdisk
		ADD ./${dockerfile_helper_filename} /apt-oras-helper.sh
		RUN bash /apt-oras-helper.sh tree guestfs-tools parted gdisk
		FROM downloader AS downloaded
		ADD ./${fat32_root_dir} /work/input
		RUN tree /work/input
		WORKDIR /output

		# Use guestfs to create a GPT image with a single FAT32 partition
		RUN virt-make-fs --verbose --format=raw --partition=gpt --type=vfat --size=+32M --label=hook /work/input /output/fat32.img

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

	# Now, build the Dockerfile...
	log info "Building Dockerfile for fat32 image..."
	docker buildx build --load "--progress=${DOCKER_BUILDX_PROGRESS_TYPE}" -t "${fat32img_oci_image}" -f "${mkfat32_dockerfile}" bootable

	# Now get at the binaries inside the built image
	log info "Extracting fat32 binaries from built Dockerfile... wait..."
	log debug "Docker might emit a warning about mismatched platforms below. It's safe to ignore; the image in question only contains fat32img binaries, for the correct arch, even though the image might have been built & tagged on a different arch."
	docker create --name "export-fat32img-${input_hash}" "${fat32img_oci_image}" "command_is_irrelevant_here_container_is_never_started"
	(docker export "export-fat32img-${input_hash}" | tar -xO "fat32.img" > "${output_image}") || true # don't fail -- otherwise container is left behind forever
	docker rm "export-fat32img-${input_hash}"
	log info "Extracted fat32 binaries to '${output_image}'"
	ls -laht "${output_image}"

}
