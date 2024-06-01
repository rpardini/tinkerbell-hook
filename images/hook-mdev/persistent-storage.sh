#!/bin/sh

echo "STARTING persistent-storage script with MDEV='${MDEV}' ACTION='${ACTION}' all params: $*" >&2

symlink_action() {
	case "$ACTION" in
		add) ln -sf "$1" "$2" ;;
		remove) rm -f "$2" ;;
	esac
}

sanitise_file() {
	sed -E -e 's/^\s+//' -e 's/\s+$//' -e 's/ /_/g' "$@" 2> /dev/null
}

sanitise_string() {
	echo "$@" | sanitise_file
}

blkid_encode_string() {
	# Rewrites string similar to libblk's blkid_encode_string
	# function which is used by udev/eudev.
	echo "$@" | sed -e 's| |\\x20|g'
}

: ${SYSFS:=/sys}

# cdrom symlink
case "$MDEV" in
	sr* | xvd*)
		caps="$(cat $SYSFS/block/$MDEV/capability 2> /dev/null)"
		if [ $((0x${caps:-0} & 8)) -gt 0 ] || [ "$(cat $SYSFS/block/$MDEV/removable 2> /dev/null)" = "1" ]; then
			symlink_action $MDEV cdrom
		fi
		;;
esac

# /dev/block symlinks
mkdir -p block
if [ -f "$SYSFS/class/block/$MDEV/dev" ]; then
	maj_min=$(sanitise_file "$SYSFS/class/block/$MDEV/dev")
	symlink_action ../$MDEV block/${maj_min}
fi

# by-id symlinks
mkdir -p disk/by-id

if [ -f "$SYSFS/class/block/$MDEV/partition" ]; then
	# This is a partition of a device, find out its parent device
	_parent_dev="$(basename $(${SBINDIR:-/usr/bin}/readlink -f "$SYSFS/class/block/$MDEV/.."))"

	partition=$(cat $SYSFS/class/block/$MDEV/partition 2> /dev/null)
	case "$partition" in
		[0-9]*) partsuffix="-part$partition" ;;
	esac
	# Get name, model, serial, wwid from parent device of the partition
	_check_dev="$_parent_dev"
else
	_check_dev="$MDEV"
fi

model=$(sanitise_file "$SYSFS/class/block/$_check_dev/device/model")
name=$(sanitise_file "$SYSFS/class/block/$_check_dev/device/name")
serial=$(sanitise_file "$SYSFS/class/block/$_check_dev/device/serial")
# Special case where block devices have serials attached to the block itself, like virtio-blk
: ${serial:=$(sanitise_file "$SYSFS/class/block/$_check_dev/serial")}
wwid=$(sanitise_file "$SYSFS/class/block/$_check_dev/wwid")
echo "INITIAL wwid: '${wwid}'" >&2
: ${wwid:=$(sanitise_file "$SYSFS/class/block/$_check_dev/device/wwid")}
echo "DEVICE wwid: '${wwid}'" >&2

# Sets variables LABEL, PARTLABEL, PARTUUID, TYPE, UUID depending on
# blkid output (busybox blkid will not provide PARTLABEL or PARTUUID)
eval $(blkid /dev/$MDEV | cut -d: -f2-)

if [ -n "$wwid" ]; then
	case "$MDEV" in
		nvme*) symlink_action ../../$MDEV disk/by-id/nvme-${wwid}${partsuffix} ;;
		sd*) symlink_action ../../$MDEV disk/by-id/scsi-${wwid}${partsuffix} ;;
		sr*) symlink_action ../../$MDEV disk/by-id/scsi-ro-${wwid}${partsuffix} ;;
		vd*) symlink_action ../../$MDEV disk/by-id/virtio-${wwid}${partsuffix} ;;
	esac
	case "$wwid" in
		naa.*) symlink_action ../../$MDEV disk/by-id/wwn-0x${wwid#naa.}${partsuffix} ;;
	esac
fi

# If no model or no serial is available, lets parse the wwid and try to use it.
# Read the WWID from the file
wwid_raw=$(cat /sys/class/block/sda/device/wwid)

# Ensure we have a non-empty WWID
if [ -n "$wwid_raw" ]; then
	# Remove leading and trailing spaces
	wwid_raw=$(echo "$wwid_raw" | sed 's/^ *//;s/ *$//')

	# Extract the prefix (first field)
	prefix=$(echo "$wwid_raw" | awk '{print $1}')

	# Remove the prefix from the wwid string
	rest=$(echo "$wwid_raw" | sed "s/^$prefix *//")

	# Extract the serial (last field)
	serial=$(echo "$rest" | awk '{print $NF}')

	# Remove the serial from the rest of the string
	rest=$(echo "$rest" | sed "s/ $serial$//")

	# Replace any remaining spaces in the rest part with underscores
	model=$(echo "$rest" | tr ' ' '_')

	# Remove consecutive underscores
	model=$(echo "$model" | sed 's/__*/_/g')

	# Remove leading and trailing underscores
	model=$(echo "$model" | sed 's/^_//;s/_$//')

	# Replace periods in the prefix with dashes
	prefix=$(echo "$prefix" | sed 's/\./-/g')

	# Construct the final identifier
	identifier="${prefix}-${model}_${serial}"

	echo "WWID parsing came up with identifier='${identifier}', prefix='${prefix}' model='${model}', serial='${serial}'" >&2
else
	echo "WWID is empty or not found" >&2
fi

if [ -n "$serial" ]; then
	echo "GOT SERIAL: serial='${serial}' model='${model}' and wwid='${wwid}'" >&2
	if [ -n "$model" ]; then
		case "$MDEV" in
			nvme*) symlink_action ../../$MDEV disk/by-id/nvme-${model}_${serial}${partsuffix} ;;
			sr*) symlink_action ../../$MDEV disk/by-id/ata-ro-${model}_${serial}${partsuffix} ;;
			sd*) symlink_action ../../$MDEV disk/by-id/ata-${model}_${serial}${partsuffix} ;;
			vd*) symlink_action ../../$MDEV disk/by-id/virtio-${model}_${serial}${partsuffix} ;;
		esac
	fi
	if [ -n "$name" ]; then
		case "$MDEV" in
			mmcblk*) symlink_action ../../$MDEV disk/by-id/mmc-${name}_${serial}${partsuffix} ;;
		esac
	fi

	# virtio-blk
	case "$MDEV" in
		vd*) symlink_action ../../$MDEV disk/by-id/virtio-${serial}${partsuffix} ;;
	esac
fi

# by-label, by-partlabel, by-partuuid, by-uuid symlinks
if [ -n "$LABEL" ]; then
	mkdir -p disk/by-label
	symlink_action ../../$MDEV disk/by-label/"$(blkid_encode_string "$LABEL")"
fi
if [ -n "$PARTLABEL" ]; then
	mkdir -p disk/by-partlabel
	symlink_action ../../$MDEV disk/by-partlabel/"$(blkid_encode_string "$PARTLABEL")"
fi
if [ -n "$PARTUUID" ]; then
	mkdir -p disk/by-partuuid
	symlink_action ../../$MDEV disk/by-partuuid/"$PARTUUID"
fi
if [ -n "$UUID" ]; then
	mkdir -p disk/by-uuid
	symlink_action ../../$MDEV disk/by-uuid/"$UUID"
fi

# nvme EBS storage symlinks
if [ "${MDEV#nvme}" != "$MDEV" ] && [ "$model" = "Amazon_Elastic_Block_Store" ] && command -v nvme > /dev/null; then
	n=30
	while [ $n -gt 0 ]; do
		ebs_alias=$(nvme id-ctrl -b /dev/$_check_dev |
			dd bs=32 skip=96 count=1 2> /dev/null |
			sed -nre '/^(\/dev\/)?(s|xv)d[a-z]{1,2} /p' |
			tr -d ' ')
		if [ -n "$ebs_alias" ]; then
			symlink_action "$MDEV" ${ebs_alias#/dev/}$partition
			break
		fi
		n=$((n - 1))
		sleep 0.1
	done
fi

# backwards compatibility with /dev/usbdisk for /dev/sd*
if [ "${MDEV#sd}" != "$MDEV" ]; then
	sysdev=$(readlink $SYSFS/class/block/$MDEV)
	case "$sysdev" in
		*usb[0-9]*)
			# require vfat for devices without partition
			if ! [ -e $SYSFS/block/$MDEV ] || [ TYPE="vfat" ]; then # @TODO: rpardini: upstream bug here? should be $TYPE
				symlink_action $MDEV usbdisk
			fi
			;;
	esac
fi

echo "FINISHED persistent-storage script with MDEV='${MDEV}' ACTION='${ACTION}' all params: $*" >&2
