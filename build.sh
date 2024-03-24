#!/usr/bin/env bash

# less insane bash error control
set -o pipefail
set -e

source bash/common.sh
source bash/linuxkit.sh
source bash/hook-lk-containers.sh
source kernel/bash/common.sh
source kernel/bash/kernel_default.sh
source kernel/bash/kernel_armbian.sh

# each entry in this array needs a corresponding one in the kernel_data dictionary-of-stringified-dictionaries below
declare -a kernels=(
	# Hook's own kernel, in kernel/ directory
	"hook-default-arm64" # Hook default kernel, source code stored in `kernel` dir in this repo -- currently v5.10.213
	"hook-default-amd64" # Hook default kernel, source code stored in `kernel` dir in this repo -- currently v5.10.213

	# External kernels, taken from Armbian's OCI repos. Those are "exotic" kernels for certain SoC's.
	# edge = (release candidates or stable but rarely LTS, more aggressive patching)
	# current = (LTS kernels, stable-ish patching)
	"armbian-meson64-edge"    # Armbian meson64 (Amlogic) edge Khadas VIM3/3L, Radxa Zero/2, LibreComputer Potatos, and many more -- right now v6.7.10
	"armbian-bcm2711-current" # Armbian bcm2711 (Broadcom) current, from RaspberryPi Foundation with many CNCF-landscape fixes and patches; for the RaspberryPi 3b+/4b/5 -- v6.6.22
	"armbian-rockchip64-edge" # Armbian rockchip64 (Rockchip) edge, for many rk356x/3399 SoCs. Not for rk3588! -- right now v6.7.10

	# EFI capable (edk2 or such, not u-boot+EFI) machines might use those:
	"armbian-uefi-arm64-edge" # Armbian generic edge UEFI kernel - right now v6.8.1
	"armbian-uefi-x86-edge"   # Armbian generic edge UEFI kernel (Armbian calls it x86) - right now v6.8.1
)

# method & arch are always required, others are method-specific. excuse the syntax; bash has no dicts of dicts
declare -A kernel_data=(

	["hook-default-arm64"]="['METHOD']='default' ['ARCH']='aarch64' ['KERNEL_MAJOR']='5' ['KERNEL_MINOR']='10' ['KCONFIG']='generic' "
	["hook-default-amd64"]="['METHOD']='default' ['ARCH']='x86_64' ['KERNEL_MAJOR']='5' ['KERNEL_MINOR']='10' ['KCONFIG']='generic' "

	# Armbian kernels, check https://github.com/orgs/armbian/packages?tab=packages&q=kernel- for possibilities
	# nb: when no ARMBIAN_KERNEL_VERSION, will use the first tag returned, high traffic, low cache rate.
	#     One might set eg ['ARMBIAN_KERNEL_VERSION']='6.7.10-S9865-D7cc9-P277e-C9b73H61a9-HK01ba-Ve377-Bf200-R448a' to use a fixed version.
	["armbian-meson64-edge"]="['METHOD']='armbian' ['ARCH']='aarch64' ['ARMBIAN_KERNEL_ARTIFACT']='kernel-meson64-edge' "
	["armbian-bcm2711-current"]="['METHOD']='armbian' ['ARCH']='aarch64' ['ARMBIAN_KERNEL_ARTIFACT']='kernel-bcm2711-current' "
	["armbian-rockchip64-edge"]="['METHOD']='armbian' ['ARCH']='aarch64' ['ARMBIAN_KERNEL_ARTIFACT']='kernel-rockchip64-edge' "

	# Armbian Generic UEFI kernels
	["armbian-uefi-arm64-edge"]="['METHOD']='armbian' ['ARCH']='aarch64' ['ARMBIAN_KERNEL_ARTIFACT']='kernel-arm64-edge' "
	["armbian-uefi-x86-edge"]="['METHOD']='armbian' ['ARCH']='x86_64' ['ARMBIAN_KERNEL_ARTIFACT']='kernel-x86-edge' "
)

#declare -g HOOK_KERNEL_OCI_BASE="${HOOK_KERNEL_OCI_BASE:-"quay.io/tinkerbellrpardini/kernel-"}"
#declare -g HOOK_LK_CONTAINERS_OCI_BASE="${HOOK_LK_CONTAINERS_OCI_BASE:-"quay.io/tinkerbellrpardini/linuxkit-"}"
declare -g HOOK_KERNEL_OCI_BASE="${HOOK_KERNEL_OCI_BASE:-"ghcr.io/rpardini/tinkerbell/kernel-"}"
declare -g HOOK_LK_CONTAINERS_OCI_BASE="${HOOK_LK_CONTAINERS_OCI_BASE:-"ghcr.io/rpardini/tinkerbell/linuxkit-"}"

declare -g SKOPEO_IMAGE="${SKOPEO_IMAGE:-"quay.io/skopeo/stable:latest"}"

install_dependencies

declare -r -g kernel_id="${2:-"hook-default-amd64"}"

case "${1:-"build"}" in
	gha-matrix)
		output_gha_matrixes
		;;

	linuxkit-containers)
		build_all_hook_linuxkit_containers
		;;

	kernel-config | config-kernel)
		kernel_configure_interactive
		;;

	kernel-build | build-kernel)
		kernel_build
		;;

	build | linuxkit) # Build Hook proper, using the specified kernel
		linuxkit_build
		;;

	*)
		echo "Unknown command: ${1}; try build / kernel-build / kernel-config / linuxkit-containers / gha-matrix" >&2
		exit 1
		;;

esac

echo "Success." >&2
exit 0
