FROM alpine:3 AS kernel-config
RUN apk add \
    argp-standalone \
    automake \
    bash \
    bc \
    binutils-dev \
    bison \
    build-base \
    coreutils \
    curl \
    diffutils \
    findutils \
    flex \
    git \
    gmp-dev \
    gnupg \
    installkernel \
    kmod \
    elfutils-dev \
    linux-headers \
    mpc1-dev \
    mpfr-dev \
    ncurses-dev \
    openssl-dev \
    patch \
    rsync \
    sed \
    squashfs-tools \
    tar \
    xz \
    xz-dev \
    zlib-dev \
    libunwind-dev


ARG KERNEL_VERSION
ARG KERNEL_SERIES

COPY /keys.asc /keys.asc

# Download and verify kernel
# PGP keys: 589DA6B1 (greg@kroah.com) & 6092693E (autosigner@kernel.org) & 00411886 (torvalds@linux-foundation.org)
RUN KERNEL_MAJOR=$(echo ${KERNEL_VERSION} | cut -d . -f 1) && \
    KERNEL_MAJOR=v${KERNEL_MAJOR}.x && \
    KERNEL_SOURCE=https://www.kernel.org/pub/linux/kernel/${KERNEL_MAJOR}/linux-${KERNEL_VERSION}.tar.xz && \
    KERNEL_SHA256_SUMS=https://www.kernel.org/pub/linux/kernel/${KERNEL_MAJOR}/sha256sums.asc && \
    KERNEL_PGP2_SIGN=https://www.kernel.org/pub/linux/kernel/${KERNEL_MAJOR}/linux-${KERNEL_VERSION}.tar.sign && \
    curl -fsSLO ${KERNEL_SHA256_SUMS} && \
    gpg2 -q --import keys.asc && \
    gpg2 --verify sha256sums.asc && \
    KERNEL_SHA256=$(grep linux-${KERNEL_VERSION}.tar.xz sha256sums.asc | cut -d ' ' -f 1) && \
    [ -f linux-${KERNEL_VERSION}.tar.xz ] || curl -fsSLO ${KERNEL_SOURCE} && \
    echo "${KERNEL_SHA256}  linux-${KERNEL_VERSION}.tar.xz" | sha256sum -c - && \
    xz -T 0 -d linux-${KERNEL_VERSION}.tar.xz && \
    curl -fsSLO ${KERNEL_PGP2_SIGN} && \
    gpg2 --verify linux-${KERNEL_VERSION}.tar.sign linux-${KERNEL_VERSION}.tar && \
    cat linux-${KERNEL_VERSION}.tar | tar --absolute-names -x && mv /linux-${KERNEL_VERSION} /linux

# Copy all the possible defconfigs NOTE(rpardini): not ideal, changes to one arch cause cache misses for the others
COPY /defconfig-* /

RUN mkdir -p /out/src

# Kernel config; copy the correct defconfig as .config, and run olddefconfig
RUN set -x && \
    cp /config-${KERNEL_SERIES}-$(uname -m) .config; \
    make olddefconfig

# Use this stage to run kernel configuration tasks like menuconfig / savedefconfig etc with:
#   docker buildx build --load --progress=plain --build-arg KERNEL_VERSION=5.10.212 --build-arg KERNEL_SERIES=5.10.y -t hook-kernel:builder --target kernel-configurator .
#   docker run -it -v "$(pwd)":/out-config hook-kernel:builder
# Otherwise, since this stage is not referenced anywhere during normal build, it is completely skipped
FROM kernel-config as kernel-configurator
WORKDIR /linux
VOLUME /out-config
ENTRYPOINT ["/bin/sh"]


FROM kernel-config AS kernel-build

# Kernel
RUN set -x && \
    make -j "$(getconf _NPROCESSORS_ONLN)" KCFLAGS="-fno-pie" && \
    case $(uname -m) in \
    x86_64) \
        cp arch/x86_64/boot/bzImage /out/kernel; \
        ;; \
    aarch64) \
        cp arch/arm64/boot/Image /out/kernel; \
        ;; \
    esac && \
    cp System.map /out


# Modules and Device Tree binaries
RUN set -x && \
    make INSTALL_MOD_PATH=/tmp/kernel-modules modules_install && \
    ( DVER=$(basename $(find /tmp/kernel-modules/lib/modules/ -mindepth 1 -maxdepth 1)) && \
      cd /tmp/kernel-modules/lib/modules/$DVER && \
      rm build source && \
      ln -s /usr/src/linux-headers-$DVER build ) && \
    case $(uname -m) in \
    aarch64) \
        make INSTALL_DTBS_PATH=/tmp/kernel-modules/boot/dtb dtbs_install; \
        ;; \
    esac && \
    ( cd /tmp/kernel-modules && tar cf /out/kernel.tar . )


RUN ls -lahtR /tmp/kernel-modules
RUN ls -lahtR /out/ 
 
FROM scratch
ENTRYPOINT []
CMD []
WORKDIR /
COPY --from=kernel-build /out/* /
