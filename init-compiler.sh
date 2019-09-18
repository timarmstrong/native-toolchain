#!/usr/bin/env bash
# Copyright 2017 Cloudera Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e
set -u
set -o pipefail

# This script sets up the compiler and compilation tools, and exports the following
# environment variables:
#
#  - CC, CXX, CXXFLAGS, CFLAGS, LDFLAGS
#  - ARCH_FLAGS

################################################################################
# Prepare compiler and linker commands. This will set the typical environment
# variables.
################################################################################

if [[ "$OSTYPE" =~ ^linux ]]; then
  # ARCH_FLAGS are used to convey architectur dependent flags that should
  # be obeyed by libraries explicitly needing this information.
  if [[ "$ARCH_NAME" == "ppc64le" ]]; then
     ARCH_FLAGS="-mvsx -maltivec"
  else
     ARCH_FLAGS="-mno-avx2"
  fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
  # Setting the C++ stlib to libstdc++ on Mac instead of the default libc++
  ARCH_FLAGS="-stdlib=libstdc++"
fi

if [[ $SYSTEM_GCC -eq 0 ]]; then
  if [[ $USE_CCACHE -ne 0 ]]; then
    CC=$(setup_ccache $(which gcc))
    CXX=$(setup_ccache $(which g++))
    export PATH="$(dirname $CC):$(dirname $CXX):$PATH"
  fi
  # Build GCC that is used to build LLVM
  $SOURCE_DIR/source/gcc/build.sh

  # Stage one is done, we can upgrade our compiler
  CC="$BUILD_DIR/gcc-$GCC_VERSION/bin/gcc"
  CXX="$BUILD_DIR/gcc-$GCC_VERSION/bin/g++"

  # Add rpath to all binaries we produce that points to the ../lib/ subdirectory relative
  # to the output binaries or libraries. Need to include versions with both $ORIGIN and
  # $$ORIGIN to work around autotools and CMake projects inconsistently escaping LDFLAGS
  # values. We always get the expected "$ORIGIN/" rpaths in produced binaries, but we also
  # get a bad rpath in each binary: either starting with "$$ORIGIN/" or "RIGIN/". The bad
  # rpaths are ignored by the dynamic linker and are harmless.
  if [[ "$OSTYPE" == "darwin"* ]]; then
    FULL_RPATH="-Wl,-rpath,'\$ORIGIN/../lib',-rpath,'\$\$ORIGIN/../lib'"
  else
    FULL_RPATH="-Wl,-rpath,'\$ORIGIN/../lib64',-rpath,'\$\$ORIGIN/../lib64'"
  fi
  FULL_RPATH="${FULL_RPATH},-rpath,'\$ORIGIN/../lib',-rpath,'\$\$ORIGIN/../lib'"

  FULL_LPATH="-L$BUILD_DIR/gcc-$GCC_VERSION/lib64"
  LDFLAGS="$ARCH_FLAGS $FULL_RPATH $FULL_LPATH"
  CXXFLAGS="$ARCH_FLAGS -fPIC -O3 -m64"
  # Some components - cmake, flatbuffers, kudu, etc - invoke binaries they built during
  # their builds. The dynamic linker needs to be able to find the correct versions
  # of libgcc.so, libstdc++.so, etc. We usually rely on setting the rpath in the binary
  # and symlinking those librarier, but in this case the libraries are not symlinked
  # until after the component build completes, so the dynamic linker needs
  # LD_LIBRARY_PATH to locate them.
  if [[ -z "${LD_LIBRARY_PATH:-}" ]]; then
    LD_LIBRARY_PATH=""
  else
    LD_LIBRARY_PATH=":${LD_LIBRARY_PATH}"
  fi
  LD_LIBRARY_PATH="$BUILD_DIR/gcc-$GCC_VERSION/lib64${LD_LIBRARY_PATH}"
else
  if [[ "$OSTYPE" == "darwin"* ]]; then
    CXX="g++ -stdlib=libstdc++"
  fi
  LDFLAGS=""
  CXXFLAGS="-fPIC -O3 -m64"
fi

CFLAGS="-fPIC -O3 -m64"

if [[ $USE_CCACHE -ne 0 ]]; then
  CC=$(setup_ccache $CC)
  CXX=$(setup_ccache $CXX)
  export PATH="$(dirname $CC):$(dirname $CXX):$PATH"
fi

# List of export variables after configuring gcc
export ARCH_FLAGS
export CC
export CXX
export CXXFLAGS
export LDFLAGS
export CFLAGS
export LD_LIBRARY_PATH

# OS X doesn't use binutils.
if [[ "$OSTYPE" != "darwin"* ]]; then
  "$SOURCE_DIR"/source/binutils/build.sh
  # Add ld from binutils to the path so it'll be used.
  PATH="$BUILD_DIR/binutils-$BINUTILS_VERSION/bin:$PATH"
fi

# Build and export toolchain cmake
if [[ $SYSTEM_CMAKE -eq 0 ]]; then
  if [[ "$OSTYPE" == "darwin"* ]]; then
    build_fake_package "cmake"
  else
    $SOURCE_DIR/source/cmake/build.sh
    CMAKE_BIN=$BUILD_DIR/cmake-$CMAKE_VERSION/bin/
    PATH=$CMAKE_BIN:$PATH
  fi
fi

if [[ ${SYSTEM_AUTOTOOLS} -eq 0 ]]; then
  ${SOURCE_DIR}/source/autoconf/build.sh
  ${SOURCE_DIR}/source/automake/build.sh
  ${SOURCE_DIR}/source/libtool/build.sh
fi
