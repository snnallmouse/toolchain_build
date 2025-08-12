#!/usr/bin/env bash
set -euo pipefail

# ========= User Configurable Variables =========
LFS=/toolchain
LFS_TGT=x86_64-infra-linux-gnu
BINUTILS_VER=2.38
GCC_VER=11.4.0
GLIBC_VER=2.29
LINUX_VER=5.4.266
CMAKE_VER=3.22.2
JOBS=$(nproc)
ARCH=x86   # Architecture for kernel headers installation
# ===============================================

SRC_DIR="$(pwd)/sources"
BUILD_DIR="$(pwd)/build"

BINUTILS_SRC="${SRC_DIR}/binutils-${BINUTILS_VER}"
GCC_SRC="${SRC_DIR}/gcc-${GCC_VER}"
GLIBC_SRC="${SRC_DIR}/glibc-${GLIBC_VER}"
LINUX_SRC="${SRC_DIR}/linux-${LINUX_VER}"
CMAKE_SRC="${SRC_DIR}/cmake-${CMAKE_VER}"

BINUTILS_BUILD="${BUILD_DIR}/binutils"
GCC_FIRST_BUILD="${BUILD_DIR}/gcc-first"
GLIBC_BUILD="${BUILD_DIR}/glibc"
GCC_SECOND_BUILD="${BUILD_DIR}/gcc-second"

log() { echo -e "\033[1;32m[+] $*\033[0m"; }
unset_tool_env() { unset CC CXX AR RANLIB LD READELF OBJDUMP NM AS || true; }

# Clean build subdirectories and $LFS
clean_environment() {
  log "Cleaning build subdirectories..."
  if [ -d "${BUILD_DIR}" ]; then
    find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
  fi
  log "Cleaning LFS directory: ${LFS}"
  if [ -d "${LFS}" ]; then
    sudo rm -rf "${LFS:?}"/*
  fi
  mkdir -p "${BINUTILS_BUILD}" "${GCC_FIRST_BUILD}" "${GLIBC_BUILD}" "${GCC_SECOND_BUILD}"
}

# Stage 1: Build Binutils
stage_binutils() {
  log "Stage 1: Building Binutils"
  cd "${BINUTILS_BUILD}"
  "${BINUTILS_SRC}/configure" \
    --prefix="${LFS}" \
    --target="${LFS_TGT}" \
    --disable-nls \
    --enable-gold=yes \
    --enable-lto
  make -j"${JOBS}"
  sudo make install
}

# Stage 2: Build first-stage GCC (C only)
stage_gcc_first() {
  log "Stage 2: Building first-stage GCC (C only)"
  cd "${GCC_FIRST_BUILD}"
  "${GCC_SRC}/configure" \
    --prefix="${LFS}" \
    --target="${LFS_TGT}" \
    --with-glibc-version="${GLIBC_VER}" \
    --with-newlib \
    --without-headers \
    --disable-shared \
    --disable-nls \
    --disable-libgomp \
    --disable-libmudflap \
    --disable-libatomic \
    --disable-libssp \
    --disable-libstdcxx \
    --disable-libvtv \
    --enable-languages=c \
    --disable-threads
  make -j"${JOBS}" all-gcc all-target-libgcc
  sudo make install-gcc install-target-libgcc
}

# Stage 3: Install Linux kernel headers
stage_linux_headers() {
  log "Stage 3: Installing Linux kernel headers"
  cd "${LINUX_SRC}"
  make mrproper
  make ARCH="${ARCH}" headers_check || true
  sudo make ARCH="${ARCH}" INSTALL_HDR_PATH="${LFS}/usr" headers_install
}

# Stage 4: Build glibc
stage_glibc() {
  log "Stage 4: Building glibc"
  OLD_PATH="${PATH}"
  
  export CC="${LFS_TGT}-gcc"
  export CXX="${LFS_TGT}-g++"
  export AR="${LFS_TGT}-ar"
  export RANLIB="${LFS_TGT}-ranlib"
  export LD="${LFS_TGT}-ld"
  export READELF="${LFS_TGT}-readelf"
  export OBJDUMP="${LFS_TGT}-objdump"
  export NM="${LFS_TGT}-nm"
  export AS="${LFS_TGT}-as"
  export PATH="${LFS}/bin:${PATH}"

  cd "${GLIBC_BUILD}"
  "${GLIBC_SRC}/configure" \
    --prefix=/usr \
    --host="${LFS_TGT}" \
    --build="$("${GLIBC_SRC}/scripts/config.guess")" \
    --with-binutils="${LFS}/bin" \
    --with-headers="${LFS}/usr/include" \
    --enable-kernel=4.10.0 \
    --disable-profile \
    --disable-werror
  make -j"${JOBS}"
  sudo make install_root="${LFS}" install

  export PATH="${OLD_PATH}"
  unset_tool_env
}

# Ensure /usr/lib -> lib64 symlink
ensure_usr_lib_symlink() {
  log "Ensuring /usr/lib -> lib64 symlink"
  cd "${LFS}/usr"
  if [ ! -L lib ]; then
    sudo ln -s lib64 lib
  fi
}

# Stage 5: Build second-stage GCC (C/C++)
stage_gcc_second() {
  log "Stage 5: Building second-stage GCC (C/C++)"
  unset_tool_env
  cd "${GCC_SECOND_BUILD}"
  "${GCC_SRC}/configure" \
    --prefix="${LFS}" \
    --target="${LFS_TGT}" \
    --with-glibc-version="${GLIBC_VER}" \
    --enable-languages=c,c++ \
    --disable-multilib \
    --disable-nls \
    --enable-shared \
    --enable-threads=posix \
    --with-sysroot="${LFS}" \
    --with-build-sysroot="${LFS}" \
    --enable-lto \
    --enable-gold=yes \
    --with-lib-path=/usr/lib64:/lib64:/usr/lib:/lib
  make -j"${JOBS}"
  sudo make install
}

# Stage 6: Build and install CMake
stage_cmake() {
  log "Stage 6: Building CMake ${CMAKE_VER}"
  if [ ! -d "${CMAKE_SRC}" ]; then
    log "Extracting cmake-${CMAKE_VER}.tar.gz..."
    tar -xf "${SRC_DIR}/cmake-${CMAKE_VER}.tar.gz" -C "${SRC_DIR}"
  fi
  cd "${CMAKE_SRC}"
  ./bootstrap --prefix="${LFS}" --paralled="${JOBS}"
  make -j"${JOBS}"
  sudo make install
}

main() {
  clean_environment
  stage_binutils
  stage_gcc_first
  stage_linux_headers
  stage_glibc
  ensure_usr_lib_symlink
  stage_gcc_second
  stage_cmake
  log "All stages completed. Toolchain + CMake installed in ${LFS}"
}

main "$@"

