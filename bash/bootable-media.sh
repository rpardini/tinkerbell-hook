function build_bootable_media() {
	log info "would build build_bootable_media: '${*}'"

	declare -r -g bootable_id="${1}" # read-only variable from here
	#obtain_bootable_data_from_id "${bootable_id}" # Gather the information about the inventory_id now; this will exit if the inventory_id is not found

	declare -g -A bootable_info=()
	get_bootable_info_dict "${bootable_id}"

	# Dump the bootable_info dict
	log info "bootable_info: $(declare -p bootable_info)"

	# Get the kernel info from the bootable_info INVENTORY_ID
	declare -g -A kernel_info=()
	get_kernel_info_dict "${bootable_info['INVENTORY_ID']}"
	log info "kernel_info: $(declare -p kernel_info)"



}


function get_bootable_info_dict() {
	declare bootable="${1}"
	declare bootable_data_str="${bootable_inventory_dict[${bootable}]}"
	if [[ -z "${bootable_data_str}" ]]; then
		log error "No bootable data found for '${bootable}'; valid ones are: ${bootable_inventory_ids[*]} "
		exit 1
	fi
	log debug "Bootable data for '${bootable}': ${bootable_data_str}"
	eval "bootable_info=(${bootable_data_str})"

	# Post process; calculate bash function names given the handler
	bootable_info['BOOTABLE_BUILD_FUNC']="build_bootable_${bootable_info['HANDLER']}"

	# Ensure bootable_info a valid TAG
	if [[ -z "${bootable_info['TAG']}" ]]; then
		log error "No TAG found for bootable '${bootable}'"
		exit 1
	fi

}
