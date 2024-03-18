#!/usr/bin/env bash

set -e

function build_kernel_armbian() {
	# smth else
	echo "Building armbian kernel" >&2

	declare oci_ref="${ARMBIAN_OCI_BASE}${ARMBIAN_KERNEL_ARTIFACT}"
	echo "Using OCI ref: ${oci_ref}" >&2

	# Get a list of tags from the ref using skopeo
	declare oci_version="${ARMBIAN_KERNEL_VERSION:-""}"

	if [[ "${oci_version}" == "" ]]; then
		echo "Getting most recent tag for ${oci_ref}" >&2
		oci_version="$(skopeo list-tags docker://${oci_ref} | jq -r ".Tags[]" | tail -1)"
		echo "Using most recent tag: ${oci_version}" >&2
	fi

	declare full_oci_ref="${oci_ref}:${oci_version}"
	echo "Using full OCI ref: ${full_oci_ref}" >&2

	# Now use ORAS to pull the .tar that's inside that ref

	# <WiP>

}
