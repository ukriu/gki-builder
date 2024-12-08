#!/usr/bin/env bash
set -e

mkdir -p android-kernel && cd android-kernel

## Variables
GKI_VERSION="android12-5.10"
USE_LTS_MANIFEST=0
USE_CUSTOM_MANIFEST=1
CUSTOM_MANIFEST_REPO="https://github.com/negroweed/kernel_manifest_android12-5.10" 
CUSTOM_MANIFEST_BRANCH="main"                                                     
WORK_DIR=$(pwd)
BUILDER_DIR="$WORK_DIR/.."
KERNEL_IMAGE="$WORK_DIR/out/${GKI_VERSION}/dist/Image"
ANYKERNEL_REPO="https://github.com/negroweed/Anykernel3"
ANYKERNEL_BRANCH="gki"
RANDOM_HASH=$(head -c 20 /dev/urandom | sha1sum | head -c 7)
ZIP_NAME="gki-KVER-KSU-$RANDOM_HASH.zip"
AOSP_CLANG_VERSION="r536225"
LAST_COMMIT_BUILDER=$(git log --format="%s" -n 1)
# Allow to skip kernel patches
SKIP_KERNEL_PATCHES=0


## Install needed packages
sudo add-apt-repository universe -y
sudo apt update -y
sudo apt upgrade -y
sudo apt install -y bc bison build-essential curl flex glibc-source git gnupg gperf imagemagick \
    lib32tinfo6 liblz4-tool libncurses6 libncurses-dev libsdl1.2-dev libssl-dev \
    libwxgtk3.2-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools \
    xsltproc zip zlib1g-dev python3

## Install Google's repo
curl -o repo https://storage.googleapis.com/git-repo-downloads/repo
sudo mv repo /usr/bin
sudo chmod +x /usr/bin/repo

## Clone AnyKernel
if [ -z "$ANYKERNEL_REPO" ] || [ -z "$ANYKERNEL_BRANCH" ]; then
    echo "[ERROR] ANYKERNEL_REPO or ANYKERNEL_BRANCH var is not defined. Fix your build vars."
    exit 1
fi

git clone --depth=1 "$ANYKERNEL_REPO" -b "$ANYKERNEL_BRANCH" "$WORK_DIR/anykernel"

## Sync kernel manifest
if [ -z "$GKI_VERSION" ]; then
    echo "[ERROR] GKI_VERSION var is not defined. Fix your build vars."
    exit 1
elif echo "$GKI_VERSION" | grep -qi 'lts'; then
    echo "[ERROR] Don't add '-lts' in GKI_VERSION var!. Fix your build vars."
    exit 1
fi

if [ "$USE_CUSTOM_MANIFEST" -eq 1 ] && [ "$USE_LTS_MANIFEST" -eq 1 ]; then
    echo "[ERROR] USE_CUSTOM_MANIFEST can't be used together with USE_LTS_MANIFEST. Fix your build vars."
    exit 1
fi

if [ "$USE_CUSTOM_MANIFEST" -eq 0 ] && [ "$USE_LTS_MANIFEST" -eq 1 ]; then
    repo init --depth 1 -u https://android.googlesource.com/kernel/manifest -b common-${GKI_VERSION}-lts
elif [ "$USE_CUSTOM_MANIFEST" -eq 0 ]; then
    repo init --depth 1 -u https://android.googlesource.com/kernel/manifest -b common-${GKI_VERSION}
elif [ "$USE_CUSTOM_MANIFEST" -eq 1 ]; then
    if [ -z "$CUSTOM_MANIFEST_REPO" ] || [ -z "$CUSTOM_MANIFEST_BRANCH" ]; then
        echo "[ERROR] USE_CUSTOM_MANIFEST is defined, but CUSTOM_MANIFEST_REPO or CUSTOM_MANIFEST_BRANCH is not defined. Fix your build vars."
        exit 1
    fi
    repo init --depth 1 "$CUSTOM_MANIFEST_REPO" -b "$CUSTOM_MANIFEST_BRANCH"
fi

repo sync -j$(nproc --all) --force-sync --current-branch --clone-bundle --optimized-fetch --prune

## Extract kernel version, git commit string
cd "$WORK_DIR/common"
KERNEL_VERSION=$(make kernelversion)
LAST_COMMIT_KERNEL=$(git log --format="%s" -n 1)
cd "$WORK_DIR"

## Set kernel version in ZIP_NAME
ZIP_NAME=$(echo "$ZIP_NAME" | sed "s/KVER/$KERNEL_VERSION/g")

## Clone crdroid's clang
rm -rf "$WORK_DIR/prebuilts-master"
mkdir -p "$WORK_DIR/prebuilts-master/clang/host/linux-x86"
git clone --depth=1 "https://gitlab.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-${AOSP_CLANG_VERSION}" "$WORK_DIR/prebuilts-master/clang/host/linux-x86/clang-${AOSP_CLANG_VERSION}"

COMPILER_STRING=$("$WORK_DIR/prebuilts-master/clang/host/linux-x86/clang-${AOSP_CLANG_VERSION}/bin/clang" -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

## KernelSU setup
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
cd "$WORK_DIR/KernelSU"
KSU_VERSION=$(git describe --abbrev=0 --tags)
cd "$WORK_DIR"

## Apply kernel patches
git config --global user.email "80760888+ukriu@users.noreply.github.com"
git config --global user.name "ukriu"

if [ "$SKIP_KERNEL_PATCHES" -eq 0 ]; then
    cd "$WORK_DIR/common"
    for p in "$BUILDER_DIR/kernel_patches/"*; do
        if ! git am -3 <"$p"; then
            patch -p1 <"$p"
            git add .
            git am --continue || exit 1
        fi
    done
fi

## susfs4ksu
if [ -n "$USE_KSU_SUSFS" ]; then
    git clone --depth=1 "https://gitlab.com/simonpunk/susfs4ksu" -b "gki-${GKI_VERSION}"
    SUSFS_PATCHES="$WORK_DIR/common/susfs4ksu/kernel_patches"
    SUSFS_MODULE="$WORK_DIR/common/susfs4ksu/ksu_module_susfs"
    ZIP_NAME=$(echo "$ZIP_NAME" | sed 's/KSU/KSUxSUSFS/g')
    cd "$WORK_DIR/common/susfs4ksu"
    LAST_COMMIT_SUSFS=$(git log --format="%s" -n 1)
    
    cd "$WORK_DIR/common"
    cp "$SUSFS_PATCHES/50_add_susfs_in_gki-${GKI_VERSION}.patch" .
    cp "$SUSFS_PATCHES/fs/susfs.c" ./fs/
    cp "$SUSFS_PATCHES/include/linux/susfs.h" ./include/linux/
    cp "$SUSFS_PATCHES/fs/sus_su.c" ./fs/
    cp "$SUSFS_PATCHES/include/linux/sus_su.h" ./include/linux/
    cd "$WORK_DIR/KernelSU"
    cp "$SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch" .
    patch -p1 < 10_enable_susfs_for_ksu.patch || exit 1
    cd "$WORK_DIR/common"
    patch -p1 < 50_add_susfs_in_gki-${GKI_VERSION}.patch || exit 1
    
    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
    SUSFS_MODULE_ZIP="ksu_module_susfs_${SUSFS_VERSION}.zip"
fi

cd "$WORK_DIR"

text=$(cat <<EOF
*~~~ GKI KSU CI ~~~*
*GKI Version*: \`${GKI_VERSION}\`
*Kernel Version*: \`${KERNEL_VERSION}\`
*KSU Version*: \`${KSU_VERSION}\`
*Include SUSFS*: \`$([ -n "${USE_KSU_SUSFS}" ] && echo "true" || echo "false")\`
$([ -n "${USE_KSU_SUSFS}" ] && echo "*SUSFS Version*: \`${SUSFS_VERSION}\`")
*LTO Mode*: \`${LTO_TYPE}\`
*Host OS*: \`$(lsb_release -d -s)\`
*CPU Cores*: \`$(nproc --all)\`
*Zip Output*: \`${ZIP_NAME}\`
*Compiler*: \`${COMPILER_STRING}\`
*Last Commit (Builder)*:
\`\`\`
${LAST_COMMIT_BUILDER}
\`\`\`
*Last Commit (Kernel)*:
\`\`\`
${LAST_COMMIT_KERNEL}
\`\`\`
$([ -n "${USE_KSU_SUSFS}" ] && echo "*Last Commit (SUSFS)*:
\`\`\`
${LAST_COMMIT_SUSFS}
\`\`\`")
$([ -n "${NOTE}" ] && echo "*Release Note*:
\`\`\`
${NOTE}
\`\`\`")
EOF
)

set +e

## Build GKI
LTO=$LTO_TYPE BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh -j$(nproc --all) | tee "$WORK_DIR/build_log.txt"

set -e

if ! [ -f "$KERNEL_IMAGE" ]; then
    send_msg "Build failed!"
    echo "Build failed!" >> "$WORK_DIR/build_log.txt"
else
    # Zipping
    cd "$WORK_DIR/anykernel"
    sed -i "s/DUMMY1/$KERNEL_VERSION/g" anykernel.sh
    if [ -z "$USE_KSU_SUSFS" ]; then
        sed -i "s/DUMMY2//g" anykernel.sh
    else
        sed -i "s/DUMMY2/xSUSFS/g" anykernel.sh
    fi
    cp "$KERNEL_IMAGE" .
    zip -r9 "$ZIP_NAME" * -x LICENSE
    mv "$ZIP_NAME" "$WORK_DIR"
    cd "$WORK_DIR"
    
    if [ -n "$USE_KSU_SUSFS" ]; then
        cd "$SUSFS_MODULE"
        zip -r9 "$SUSFS_MODULE_ZIP" * -x README.md
        mv "$SUSFS_MODULE_ZIP" "$WORK_DIR"
        cd "$WORK_DIR"
    fi
fi

export ZIP_NAME
export SUSFS_MODULE_ZIP
