#!/bin/bash -e

. bin/funcs.sh

device="pinephone"
environment="phosh"
hostname="fossfrog"
username="kali"
password="8888"
mobian_suite="trixie"
IMGSIZE=5   # GBs
MIRROR='http://http.kali.org/kali'

while getopts "cbt:e:h:u:p:s:m:M:" opt
do
    case "$opt" in
        t ) device="$OPTARG" ;;
        e ) environment="$OPTARG" ;;
        h ) hostname="$OPTARG" ;;
        u ) username="$OPTARG" ;;
        p ) password="$OPTARG" ;;
        s ) custom_script="$OPTARG" ;;
        m ) mobian_suite="$OPTARG" ;;
        M ) MIRROR="$OPTARG" ;;
        c ) compress=1 ;;
        b ) blockmap=1 ;;
    esac
done

BOOTLOADER_DEVICE="$device"
DEVICE_PACKAGES=""

case "$device" in
  "pinephone"|"pinetab"|"sunxi" )
    arch="arm64"
    family="sunxi"
    SERVICES="eg25-manager"
    PACKAGES="megapixels"
    ;;
  "pinephonepro"|"pinetab2"|"rockchip" )
    arch="arm64"
    family="rockchip"
    SERVICES="eg25-manager"
    PACKAGES="megapixels megapixels-config-pinephonepro"
    ;;
  "pocof1"|"oneplus6"|"oneplus6t"|"sdm845"|"qcom"|"sm8250"|"r8q" )
    arch="arm64"
    family="qcom"
    SERVICES="qrtr-ns rmtfs pd-mapper tqftpserv qcom-modem-setup droid-juicer"
    PACKAGES="pulseaudio yq qbootctl"
    PARTITIONS=1
    SPARSE=1
    [ "$device" = "r8q" ] && DEVICE_PACKAGES="firmware-qcom-soc firmware-atheros"
    ;;
  "nothingphone1"|"sm7325" )
    arch="arm64"
    family="sm7325"
    SERVICES="qrtr-ns rmtfs pd-mapper tqftpserv qcom-modem-setup droid-juicer"
    PACKAGES="pulseaudio yq qbootctl"
    PARTITIONS=1
    SPARSE=1
    ;;
  * )
    echo "Unsupported device ${device}"
    exit 1
    ;;
esac

PACKAGES="${PACKAGES} kali-linux-core wget vim binutils rsync systemd-timesyncd systemd-repart"
DPACKAGES="${family}-support"
[ -n "${DEVICE_PACKAGES}" ] && DPACKAGES="${DPACKAGES} ${DEVICE_PACKAGES}"

case "${environment}" in
    phosh)
        PACKAGES="${PACKAGES} phosh-phone phrog portfolio-filemanager"
        SERVICES="${SERVICES} greetd"
        ;;
    plasma-mobile)
        PACKAGES="${PACKAGES} plasma-mobile qmlkonsole"
        SERVICES="${SERVICES} plasma-mobile"
        ;;
    xfce|lxde|gnome|kde)
        PACKAGES="${PACKAGES} kali-desktop-${environment}"
        ;;
esac

IMG="kali_${environment}_${device}_`date +%Y%m%d`.img"
ROOTFS_TAR="kali_${environment}_${device}_`date +%Y%m%d`.tgz"
ROOTFS="kali_rootfs_tmp"

### START BUILDING ###
banner
echo '____________________BUILD_INFO____________________'
echo "Device: $device"
echo "Environment: $environment"
echo "Hostname: $hostname"
echo "Username: $username"
echo "Password: $password"
echo "Mobian Suite: $mobian_suite"
echo "Family: $family"
echo "Custom Script: $custom_script"
echo -e '--------------------------------------------------\n\n'
echo '[*]Build will start in 5 seconds...'; sleep 5

[ -e "base.tgz" ] && mkdir ${ROOTFS} && tar --strip-components=1 -xpf base.tgz -C ${ROOTFS}

echo '[+]Stage 1: Debootstrap'
[ -e ${ROOTFS}/etc ] && echo -e "[*]Debootstrap already done.\nSkipping Debootstrap..." || debootstrap --foreign --arch $arch kali-rolling ${ROOTFS} ${MIRROR}

echo '[+]Stage 2: Debootstrap second stage and adding Mobian apt repo'
[ -e ${ROOTFS}/etc/passwd ] && echo '[*]Second Stage already done' || nspawn-exec /debootstrap/debootstrap --second-stage
mkdir -p ${ROOTFS}/etc/apt/sources.list.d ${ROOTFS}/etc/apt/keyrings
sed -i 's/main/main contrib non-free non-free-firmware/g' ${ROOTFS}/etc/apt/sources.list
# Download and convert Mobian GPG keybox to a format compatible with apt
curl -L http://repo.mobian.org/mobian.gpg -o /tmp/mobian-keybox.gpg
gpg --no-default-keyring --keyring /tmp/mobian-keybox.gpg --export > ${ROOTFS}/etc/apt/keyrings/mobian.gpg
rm -f /tmp/mobian-keybox.gpg
chmod 644 ${ROOTFS}/etc/apt/keyrings/mobian.gpg
echo "deb [signed-by=/etc/apt/keyrings/mobian.gpg] http://repo.mobian.org/ ${mobian_suite} main non-free-firmware" > ${ROOTFS}/etc/apt/sources.list.d/mobian.list

cat << EOF > ${ROOTFS}/etc/apt/preferences.d/00-mobian-priority
Package: *
Pin: release o=Mobian
Pin-Priority: 700
EOF

ROOT_UUID=`python3 -c 'from uuid import uuid4; print(uuid4())'`
BOOT_UUID=`python3 -c 'from uuid import uuid4; print(uuid4())'`

if [[ "$family" == "sunxi" || "$family" == "rockchip" ]]
then
    BOOTPART="UUID=${BOOT_UUID}	/boot	ext4	defaults,x-systemd.growfs	0	2"
fi

cat << EOF > partuuid
ROOT_UUID=${ROOT_UUID}
BOOT_UUID=${BOOT_UUID}
EOF

cat << EOF > ${ROOTFS}/etc/fstab
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=${ROOT_UUID}	/	ext4	defaults,x-systemd.growfs	0	1
${BOOTPART}
EOF

echo '[+]Stage 3: Installing device specific and environment packages'
nspawn-exec apt update
nspawn-exec apt install -y curl
nspawn-exec sh -c "$(curl -fsSL https://repo.fossfrog.in/setup.sh)"
nspawn-exec apt install -y ${PACKAGES}
nspawn-exec apt install -y ${DPACKAGES}

if [ "$device" = "r8q" ]
then
    echo '[*]Preparing r8q firmware paths expected by the mainline device tree'
    nspawn-exec sh -eu -c '
        dest_dir=/usr/lib/firmware/qcom/sm8250/Samsung/r8q
        mkdir -p "$dest_dir"
        for firmware in adsp.mbn cdsp.mbn slpi.mbn
        do
            preferred_path="/usr/lib/firmware/qcom/sm8250/$firmware"
            if [ -f "$preferred_path" ]
            then
                source_path="$preferred_path"
            else
                candidates="$(find /usr/lib/firmware/qcom/sm8250 \
                    -path "$dest_dir" -prune -o \
                    -type f \
                    -name "$firmware" -print | sort)"
                candidate_count="$(printf "%s\n" "$candidates" | sed "/^$/d" | wc -l)"
                case "$candidate_count" in
                    0)
                        echo "Missing required r8q firmware file: $firmware" >&2
                        exit 1
                        ;;
                    1)
                        source_path="$(printf "%s\n" "$candidates" | sed "/^$/d")"
                        ;;
                    *)
                        echo "Found multiple candidate firmware files for $firmware:" >&2
                        printf "%s\n" "$candidates" | sed "/^$/d" >&2
                        exit 1
                        ;;
                esac
            fi
            source_path="$(readlink -f "$source_path")"
            rm -f "$dest_dir/$firmware"
            ln -srf "$source_path" "$dest_dir/$firmware"
        done
    '

    echo '[*]Validating r8q kernel config and DT patch markers'
    KERNEL_VERSION="$(
        for kernel_path in "${ROOTFS}"/boot/vmlinuz-*; do
            [ -f "$kernel_path" ] || continue
            version="${kernel_path##*/vmlinuz-}"
            printf '%s\n' "$version"
        done | sort -V | tail -1
    )"
    [ -n "$KERNEL_VERSION" ] || {
        echo "Unable to locate an installed r8q kernel image" >&2
        exit 1
    }
    mkdir -p "${ROOTFS}/etc/initramfs-tools/conf.d"
    printf '%s\n' 'MODULES=most' > "${ROOTFS}/etc/initramfs-tools/conf.d/r8q-modules.conf"
    touch "${ROOTFS}/etc/initramfs-tools/modules"
    while IFS= read -r initramfs_module
    do
        [ -n "$initramfs_module" ] || continue
        case "$initramfs_module" in
            \#*) continue ;;
        esac
        grep -qxF "$initramfs_module" "${ROOTFS}/etc/initramfs-tools/modules" || \
            printf '%s\n' "$initramfs_module" >> "${ROOTFS}/etc/initramfs-tools/modules"
    done < r8q.initramfs-modules
    nspawn-exec update-initramfs -u -k "$KERNEL_VERSION"
    if [ ! -f "${ROOTFS}/boot/initrd.img-${KERNEL_VERSION}" ] && \
       [ ! -f "${ROOTFS}/boot/initramfs-${KERNEL_VERSION}.img" ]
    then
        echo "Unable to locate a bootable r8q initramfs after update-initramfs" >&2
        exit 1
    fi
    KERNEL_CONFIG=""
    for config_path in \
        "${ROOTFS}/boot/config-${KERNEL_VERSION}" \
        "${ROOTFS}/usr/lib/linux-image-${KERNEL_VERSION}/config" \
        "${ROOTFS}/usr/lib/modules/${KERNEL_VERSION}/config"
    do
        if [ -f "$config_path" ]
        then
            KERNEL_CONFIG="$config_path"
            break
        fi
    done
    [ -n "$KERNEL_CONFIG" ] || {
        echo "Unable to locate kernel config for r8q kernel ${KERNEL_VERSION}" >&2
        exit 1
    }
    while IFS= read -r expected_config
    do
        [ -n "$expected_config" ] || continue
        if ! echo "$expected_config" | grep -q '^# CONFIG_.* is not set$'
        then
            case "$expected_config" in
                \#*) continue ;;
            esac
        fi
        case "$expected_config" in
            CONFIG_*=y)
                config_name="${expected_config%%=*}"
                if grep -qxF "$config_name" r8q.config-modular-ok
                then
                    grep -Eq "^${config_name}=(y|m)$" "$KERNEL_CONFIG" || {
                        echo "Missing required r8q kernel config: ${config_name}=y|m" >&2
                        exit 1
                    }
                else
                    grep -qxF "$expected_config" "$KERNEL_CONFIG" || {
                        echo "Missing required r8q kernel config: $expected_config" >&2
                        exit 1
                    }
                fi
                ;;
            *)
                grep -qxF "$expected_config" "$KERNEL_CONFIG" || {
                    echo "Missing required r8q kernel config: $expected_config" >&2
                    exit 1
                }
                ;;
        esac
    done < r8q.config

    DTB_PATH=""
    for dtb_candidate in \
        "${ROOTFS}/usr/lib/linux-image-${KERNEL_VERSION}/qcom/sm8250-samsung-r8q.dtb" \
        "${ROOTFS}/usr/lib/linux-image-${KERNEL_VERSION}/sm8250-samsung-r8q.dtb" \
        "${ROOTFS}/usr/lib/modules/${KERNEL_VERSION}/sm8250-samsung-r8q.dtb" \
        "${ROOTFS}/usr/lib/modules/${KERNEL_VERSION}/kernel/arch/arm64/boot/dts/qcom/sm8250-samsung-r8q.dtb"
    do
        if [ -f "$dtb_candidate" ]
        then
            DTB_PATH="$dtb_candidate"
            break
        fi
    done
    [ -n "$DTB_PATH" ] || {
        echo "Missing required r8q DTB artifact for kernel ${KERNEL_VERSION}" >&2
        exit 1
    }
    DTB_DTS="$(mktemp /tmp/r8q-dtb.XXXXXX.dts)"
    if command -v dtc >/dev/null 2>&1
    then
        dtc -I dtb -O dts "$DTB_PATH" > "$DTB_DTS"
    else
        rm -f "$DTB_DTS"
        echo "Missing dtc; install device-tree-compiler to validate the r8q DT patch" >&2
        exit 1
    fi
    if ! python3 - "$DTB_DTS" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()

def extract_named_node(source: str, needle: str) -> str:
    start = source.find(needle)
    if start < 0:
        raise SystemExit(f"Missing {needle} node in decompiled r8q DTB")

    brace_start = source.find("{", start)
    if brace_start < 0:
        raise SystemExit(f"Malformed {needle} node in decompiled r8q DTB")

    depth = 0
    end = None
    for index, char in enumerate(source[brace_start:], start=brace_start):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = index
                break

    if end is None:
        raise SystemExit(f"Unable to parse {needle} node in decompiled r8q DTB")

    return source[start:end]


def extract_node_containing(source: str, needle: str) -> str:
    offset = source.find(needle)
    if offset < 0:
        raise SystemExit(f"Missing {needle} in decompiled r8q DTB")

    brace_start = source.rfind("{", 0, offset)
    if brace_start < 0:
        raise SystemExit(f"Unable to locate node start for {needle} in decompiled r8q DTB")

    depth = 0
    end = None
    for index, char in enumerate(source[brace_start:], start=brace_start):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = index
                break

    if end is None:
        raise SystemExit(f"Unable to parse containing node for {needle} in decompiled r8q DTB")

    return source[brace_start:end]


framebuffer_node = extract_named_node(text, "framebuffer@9c000000")
for token in ("power-domains", "panel-info", "width-mm", "height-mm"):
    if token not in framebuffer_node:
        raise SystemExit(f"Missing r8q DT framebuffer marker: {token}")

dispcc_node = extract_node_containing(text, '"qcom,sm8250-dispcc"')
match = re.search(r"protected-clocks\s*=\s*<([^>]+)>;", dispcc_node, re.S)
if not match:
    raise SystemExit("Missing protected-clocks property in dispcc node")

clock_entries = re.findall(r"0x[0-9a-fA-F]+|\d+", match.group(1))
if not clock_entries:
    raise SystemExit("r8q DT protected-clocks property is empty")
PY
    then
        rm -f "$DTB_DTS"
        exit 1
    fi
    rm -f "$DTB_DTS"
fi

echo '[+]Stage 4: Adding some extra tweaks'
if [ ! -e "${ROOTFS}/etc/repart.d/50-root.conf" ]
then
    mkdir -p ${ROOTFS}/etc/kali-motd
    touch ${ROOTFS}/etc/kali-motd/disable-minimal-warning
    mkdir -p ${ROOTFS}/etc/skel/.local/share/squeekboard/keyboards/terminal
    curl https://raw.githubusercontent.com/Shubhamvis98/PinePhone_Tweaks/main/layouts/us.yaml > ${ROOTFS}/etc/skel/.local/share/squeekboard/keyboards/us.yaml
    ln -srf ${ROOTFS}/etc/skel/.local/share/squeekboard/keyboards/{us.yaml,terminal/}
    sed -i 's/-0.07/0/;s/-0.13/0/' ${ROOTFS}/usr/share/plymouth/themes/kali/kali.script
    mkdir -p ${ROOTFS}/etc/repart.d
    cat << 'EOF' > ${ROOTFS}/etc/repart.d/50-root.conf
[Partition]
Type=root
Weight=1000
EOF
else
    echo '[*]This has been already done'
fi

echo '[+]Stage 5: Adding user and changing default shell to zsh'
if [ ! `grep ${username} ${ROOTFS}/etc/passwd` ]
then
    nspawn-exec adduser --disabled-password --gecos "" ${username}
    sed -i "s#${username}:\!:#${username}:`echo ${password} | openssl passwd -1 -stdin`:#" ${ROOTFS}/etc/shadow
    sed -i 's/bash/zsh/' ${ROOTFS}/etc/passwd
    for i in dialout sudo audio video plugdev input render bluetooth feedbackd netdev; do
        nspawn-exec usermod -aG ${i} ${username} || true
    done
else
    echo '[*]User already present'
fi

echo '[*]Enabling kali plymouth theme'
nspawn-exec plymouth-set-default-theme -R kali
#sed -i "/picture-uri/cpicture-uri='file:\/\/\/usr\/share\/backgrounds\/kali\/kali-red-sticker-16x9.jpg'" ${ROOTFS}/usr/share/glib-2.0/schemas/11_mobile.gschema.override
sed -i "/picture-uri/cpicture-uri='file:\/\/\/usr\/share\/backgrounds\/kali\/kali-metal-dark-16x9.jpg'" ${ROOTFS}/usr/share/glib-2.0/schemas/10_desktop-base.gschema.override
nspawn-exec glib-compile-schemas /usr/share/glib-2.0/schemas

echo '[+]Stage 6: Enable services'
for svc in `echo ${SERVICES} | tr ' ' '\n'`
do
	nspawn-exec systemctl enable $svc
done

echo '[*]Checking for custom script'
if [ -f "${custom_script}" ]
then
    mkdir -p ${ROOTFS}/ztmpz
    cp ${custom_script} ${ROOTFS}/ztmpz
    nspawn-exec bash /ztmpz/${custom_script}
    [ -d "${ROOTFS}/ztmpz" ] && rm -rf ${ROOTFS}/ztmpz
fi

echo '[*]Tweaks and cleanup'
echo ${hostname} > ${ROOTFS}/etc/hostname
grep -q ${hostname} ${ROOTFS}/etc/hosts || \
	sed -i "1s/$/\n127.0.1.1\t${hostname}/" ${ROOTFS}/etc/hosts
nspawn-exec apt clean

if [ ${SPARSE} ]
then
    #nspawn-exec sudo -u ${username} systemctl --user disable pipewire pipewire-pulse
    #nspawn-exec sudo -u ${username} systemctl --user mask pipewire pipewire-pulse
    #nspawn-exec sudo -u ${username} systemctl --user enable pulseaudio
    [ -f "bin/configs/${BOOTLOADER_DEVICE}.toml" ] || BOOTLOADER_DEVICE="${family}"
    cp -r bin/bootloader.sh bin/configs ${ROOTFS}
    chmod +x ${ROOTFS}/bootloader.sh
    nspawn-exec /bootloader.sh ${BOOTLOADER_DEVICE}
    mv -v ${ROOTFS}/boot*img .
    rm -rf ${ROOTFS}/bootloader.sh ${ROOTFS}/configs
fi

echo '[*]Deploy rootfs into EXT4 image'
tar -cpzf ${ROOTFS_TAR} ${ROOTFS} && rm -rf ${ROOTFS}
mkimg ${IMG} ${IMGSIZE} ${PARTITIONS}
tar -xpf ${ROOTFS_TAR}

if [[ "$family" == "sunxi" || "$family" == "rockchip" ]]
then
    echo '[*]Update u-boot config...'
    nspawn-exec -r '/etc/kernel/postinst.d/zz-u-boot-menu $(linux-version list | tail -1)'
fi

echo '[*]Cleanup and unmount'
cleanup

echo "[+]Stage 7: Compressing ${IMG}..."
if [ "$blockmap" ]
then
    bmaptool create ${IMG} > ${IMG}.bmap
else
    echo '[*]Skipped blockmap creation'
fi

if [ "$SPARSE" ]
then
    img2simg ${IMG} ${IMG}_SPARSE
    mv -v ${IMG}_SPARSE ${IMG}
fi

if [ "$compress" ]
then
    [ -f "${IMG}" ] && xz "${IMG}"
else
    echo '[*]Skipped compression'
fi
echo '[+]Image Generated.'
