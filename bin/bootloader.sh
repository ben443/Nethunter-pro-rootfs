#!/bin/sh

SCRIPT="$0"
DEVICE="$1"

CONFIG="$(dirname ${SCRIPT})/configs/${DEVICE}.toml"
if ! [ -f "${CONFIG}" ]; then
    echo "ERROR: No configuration for device type '${DEVICE}'!"
    exit 1
fi

bootimg_offsets() {
    local BOOTIMG="$1"

    local VERSION="$(echo "${BOOTIMG}" | jq -r 'if .version then .version else 0 end' -)"
    local KERNEL="$(echo "${BOOTIMG}" | jq -r '.kernel + .base' -)"
    local RAMDISK="$(echo "${BOOTIMG}" | jq -r '.ramdisk + .base' -)"
    local SECOND="$(echo "${BOOTIMG}" | jq -r '.second + .base' -)"
    local TAGS="$(echo "${BOOTIMG}" | jq -r '.tags + .base' -)"
    local PAGE_SIZE="$(echo "${BOOTIMG}" | jq -r '.pagesize' -)"
    local DTB="$(echo "${BOOTIMG}" | jq -r 'if .dtb then .dtb + .base else "" end' -)"

    local ARGS="--kernel_offset ${KERNEL} --ramdisk_offset ${RAMDISK}"
    ARGS="${ARGS} --second_offset ${SECOND} --tags_offset ${TAGS}"
    ARGS="${ARGS} --pagesize ${PAGE_SIZE}"

    if [ "${VERSION}" != "0" ]; then
        ARGS="${ARGS} --header_version ${VERSION}"
    fi

    if [ "${DTB}" ]; then
        ARGS="${ARGS} --dtb_offset ${DTB}"
    fi

    echo "${ARGS}"
}

resolve_kernel_version() {
    for kernel_path in /boot/vmlinuz-*; do
        [ -f "${kernel_path}" ] || continue
        version="${kernel_path#/boot/vmlinuz-}"
        if [ -f "/boot/initrd.img-${version}" ] || \
           [ -f "/boot/initramfs-${version}.img" ]
        then
            printf '%s\n' "${version}"
        fi
    done | sort -V | tail -1
}

resolve_ramdisk_path() {
    version="$1"
    for candidate in "/boot/initrd.img-${version}" "/boot/initramfs-${version}.img"; do
        [ -f "${candidate}" ] && printf '%s\n' "${candidate}" && return 0
    done
    return 1
}

resolve_dtb_path() {
    dtb_name="$1"
    for candidate in \
        "/usr/lib/linux-image-${KERNEL_VERSION}/qcom/${dtb_name}" \
        "/usr/lib/linux-image-${KERNEL_VERSION}/${dtb_name}" \
        "/usr/lib/modules/${KERNEL_VERSION}/${dtb_name}" \
        "/usr/lib/modules/${KERNEL_VERSION}/kernel/arch/arm64/boot/dts/qcom/${dtb_name}"
    do
        [ -f "${candidate}" ] && printf '%s\n' "${candidate}" && return 0
    done
    return 1
}

ROOTPART=$(grep -P '^UUID.*[ \t]/[ \t]' /etc/fstab | awk '{print $1}')

if [ "${ROOTPART}" = "UUID=" ]; then
    # This means we're using an encrypted rootfs
    ROOTPART="/dev/mapper/root"
fi
KERNEL_VERSION="$(resolve_kernel_version)"
[ -n "${KERNEL_VERSION}" ] || {
    echo "ERROR: Unable to locate a bootable kernel and initramfs pair" >&2
    exit 1
}
RAMDISK_PATH="$(resolve_ramdisk_path "${KERNEL_VERSION}")"

# Parse config for generic parameters for the current SoC
SOC=$(tomlq -r "if .chipset then .chipset else \"${DEVICE}\" end" ${CONFIG})
MKBOOTIMG_ARGS="$(bootimg_offsets "$(tomlq -r '.bootimg' ${CONFIG})")"

for i in $(seq 0 $(tomlq -r '.device | length - 1' ${CONFIG})); do
    # Parse device-specific parameters
    VENDOR=$(tomlq -r ".device[$i].vendor" ${CONFIG})
    MODEL=$(tomlq -r ".device[$i].model" ${CONFIG})
    VARIANT=$(tomlq -r "if .device[$i].variant then .device[$i].variant else \"\" end" ${CONFIG})
    DEVICE_SOC=$(tomlq -r "if .device[$i].chipset then .device[$i].chipset else \"${SOC}\" end" ${CONFIG})
    APPEND=$(tomlq -r "if .device[$i].append then .device[$i].append else \"\" end" ${CONFIG})
    # Extract device-specific bootimg parameters in JSON format for processing by `bootimg_offsets()`
    DEVICE_BOOTIMG=$(tomlq -r "if .device[$i].bootimg then .device[$i].bootimg else \"\" end" ${CONFIG})

    CMDLINE="mobile.qcomsoc=qcom/${DEVICE_SOC} mobile.vendor=${VENDOR} mobile.model=${MODEL}"
    if [ "${VARIANT}" ]; then
        CMDLINE="${CMDLINE} mobile.variant=${VARIANT}"
        FULLMODEL="${MODEL}-${VARIANT}"
    else
        FULLMODEL="${MODEL}"
    fi
    DTB_FILE="$(resolve_dtb_path "${DEVICE_SOC}-${VENDOR}-${FULLMODEL}.dtb")"
    ROOT_CMDLINE="mobile.root=${ROOTPART}"

    LOGLEVEL="quiet"
    # Include additional cmdline args if specified
    if [ "${APPEND}" ]; then
        CMDLINE="${CMDLINE} ${APPEND}"
        if echo "${APPEND}" | grep -q 'mobile.root='; then
            ROOT_CMDLINE=""
        fi
        if echo "${APPEND}" | grep -q "console="; then
            LOGLEVEL="loglevel=7"
        fi
    fi

    if [ "${DEVICE_BOOTIMG}" ]; then
        BOOTIMG_ARGS="$(bootimg_offsets "${DEVICE_BOOTIMG}")"
    else
        BOOTIMG_ARGS="${MKBOOTIMG_ARGS}"
    fi

    if echo "${BOOTIMG_ARGS}" | grep -q "dtb_offset"; then
        [ -n "${DTB_FILE}" ] || {
            echo "ERROR: Unable to locate DTB for ${FULLMODEL}" >&2
            exit 1
        }
        BOOTIMG_ARGS="${BOOTIMG_ARGS} --dtb ${DTB_FILE}"
    fi

    echo "Creating boot image for ${FULLMODEL}..."
    cat /boot/vmlinuz-${KERNEL_VERSION} ${DTB_FILE} > /tmp/kernel-dtb

    # Create the bootimg as it's the only format recognized by the Android bootloader
    mkbootimg -o /boot_${FULLMODEL}_`date +%Y%m%d`.img ${BOOTIMG_ARGS} \
        --kernel /tmp/kernel-dtb --ramdisk ${RAMDISK_PATH} \
        --cmdline "${ROOT_CMDLINE} ${CMDLINE} init=/sbin/init ro ${LOGLEVEL} splash"
done
