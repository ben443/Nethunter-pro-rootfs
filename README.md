# Kali Phosh for PinePhone and Qcom Phones

```
-----------------------------------------
 _____     _   _____         _
|   | |___| |_|  |  |_ _ ___| |_ ___ ___
| | | | -_|  _|     | | |   |  _| -_|  _|
|_|___|___|_| |__|__|___|_|_|_| |___|_|
 _____
|  _  |___ ___
|   __|  _| . | Image Generator
|__|  |_| |___| by Shubham Vishwakarma

twitter/git: shubhamvis98
-----------------------------------------
```

A huge thanks to Mobian Project and Megi's Kernel Patches.

## Build Instruction:
```
#PinePhone
./build.sh -t pinephone

#PinePhone Pro
./build.sh -t pinephonepro

#SDM845
./build.sh -t sdm845

#Samsung Galaxy S20 FE 5G (r8q)
./build.sh -t r8q
```

## Required packages:
    - android-sdk-libsparse-utils
    - bmap-tools
    - debootstrap
    - device-tree-compiler (required for `r8q` DT validation)
    - qemu-user-static or qemu-user
    - rsync
    - systemd-container

Download official Kali Nethunter for PinePhone and PinePhone Pro from Kali download page: https://www.kali.org/get-kali/#kali-mobile

![](https://img.shields.io/github/downloads/Shubhamvis98/kali-pinephone/total?label=Downloads&style=plastic)

## r8q kernel notes

- `r8q.config` is a merge-config fragment for the external mainline kernel package used with this repository's `r8q` build flow.
- `r8q.config-modular-ok` lists the `r8q.config` entries that may be shipped as modules because the build injects them into the generated initramfs.
- `r8q.initramfs-modules` lists the boot-critical modules that are forced into the generated initramfs when the kernel package ships them as modules instead of built-ins.
- `patches/0001-arm64-dts-qcom-sm8250-samsung-common-r8q-display-fix.patch` is the currently required mainline DT patch to keep the firmware framebuffer alive on `r8q`.
- This repository does not build the kernel itself; apply the patch to your kernel source and merge the config fragment before building the kernel package that installs the `r8q` DTB, kernel image, modules, and initramfs consumed by `build.sh`.
- The `r8q` build now writes an initramfs-tools override (`MODULES=most` plus `r8q.initramfs-modules`), regenerates the installed kernel initramfs, validates the installed kernel config against `r8q.config`, and checks the installed `sm8250-samsung-r8q.dtb` for the DT patch markers before it will finish the image build.
