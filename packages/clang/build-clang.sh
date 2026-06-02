#!/usr/bin/env bash
set -euo pipefail

# Build a small LLVM/Clang tool package for Kandelo.
#
# Output files:
#   clang.wasm
#   wasm-ld.wasm
#   llvm-ar.wasm
#   llvm-ranlib.wasm
#   llvm-nm.wasm
#
# This builds only the WebAssembly backend plus clang/lld tools, disables
# optional host integrations, and uses Makefiles so the host-tool surface stays
# small.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/sdk/activate.sh"

LLVM_MAJOR="${WASM_POSIX_DEP_VERSION:-21}"
ARCH="${WASM_POSIX_DEP_TARGET_ARCH:-wasm32}"
INSTALL_DIR="${WASM_POSIX_DEP_OUT_DIR:-$SCRIPT_DIR/bin}"
SYSROOT="${WASM_POSIX_SYSROOT:-$REPO_ROOT/sysroot}"
LIBCXX_DIR="${WASM_POSIX_DEP_LIBCXX_DIR:-}"

if [[ "$ARCH" != "wasm32" ]]; then
  echo "ERROR: clang package currently supports wasm32 only (got ${ARCH})." >&2
  exit 1
fi

if [[ ! -f "$SYSROOT/lib/libc.a" ]]; then
  echo "ERROR: sysroot not found at $SYSROOT. Run: bash scripts/build-musl.sh" >&2
  exit 1
fi

if [[ -z "$LIBCXX_DIR" && -f "$SYSROOT/lib/libc++.a" && -f "$SYSROOT/lib/libc++abi.a" && -d "$SYSROOT/include/c++/v1" ]]; then
  LIBCXX_DIR="$SYSROOT"
fi

if [[ -z "$LIBCXX_DIR" || ! -f "$LIBCXX_DIR/lib/libc++.a" || ! -f "$LIBCXX_DIR/lib/libc++abi.a" || ! -d "$LIBCXX_DIR/include/c++/v1" ]]; then
  echo "ERROR: libcxx dependency not available. Resolve via: cargo xtask build-deps resolve libcxx" >&2
  exit 1
fi

if [[ "$LIBCXX_DIR" != "$SYSROOT" ]]; then
  mkdir -p "$SYSROOT/lib" "$SYSROOT/include/c++"
  cp -f "$LIBCXX_DIR/lib/libc++.a" "$SYSROOT/lib/libc++.a"
  cp -f "$LIBCXX_DIR/lib/libc++abi.a" "$SYSROOT/lib/libc++abi.a"
  rm -rf "$SYSROOT/include/c++/v1"
  cp -RL "$LIBCXX_DIR/include/c++/v1" "$SYSROOT/include/c++/v1"
fi

if ! command -v wasm32posix-c++ >/dev/null 2>&1; then
  echo "ERROR: wasm32posix-c++ not found. Source sdk/activate.sh or npm link sdk first." >&2
  exit 1
fi

CC_TOOL="$(command -v wasm32posix-cc)"
CXX_TOOL="$(command -v wasm32posix-c++)"
AR_TOOL="$(command -v wasm32posix-ar)"
RANLIB_TOOL="$(command -v wasm32posix-ranlib)"
NM_TOOL="$(command -v wasm32posix-nm)"

LLVM_SRC_DIR="$SCRIPT_DIR/llvm-project-${LLVM_MAJOR}"
HOST_BUILD_DIR="$SCRIPT_DIR/build-host-tablegen-${LLVM_MAJOR}"
BUILD_DIR="$SCRIPT_DIR/build-wasm32"
BIN_DIR="$SCRIPT_DIR/bin"

LLVM_PREFIX="${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || echo /opt/homebrew/opt/llvm)}"

find_host_tool() {
  local name="$1"
  local candidate
  for candidate in \
    "${LLVM_BIN:-}/$name" \
    "$LLVM_PREFIX/bin/$name" \
    "$HOST_BUILD_DIR/bin/$name" \
    "$(command -v "$name" 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_llvm_source() {
  if [[ -f "$LLVM_SRC_DIR/llvm/CMakeLists.txt" && -f "$LLVM_SRC_DIR/clang/CMakeLists.txt" ]]; then
    return
  fi

  echo "==> Cloning LLVM ${LLVM_MAJOR}.x source (sparse: llvm + clang + lld)..."
  rm -rf "$LLVM_SRC_DIR"
  git clone --depth=1 --branch "release/${LLVM_MAJOR}.x" \
    --filter=blob:none --sparse \
    https://github.com/llvm/llvm-project.git "$LLVM_SRC_DIR"
  (
    cd "$LLVM_SRC_DIR"
    git sparse-checkout set llvm clang lld cmake third-party
  )
}

patch_llvm_source() {
  local header="$LLVM_SRC_DIR/llvm/include/llvm/Support/ExponentialBackoff.h"
  local impl="$LLVM_SRC_DIR/llvm/lib/Support/ExponentialBackoff.cpp"
  local path_impl="$LLVM_SRC_DIR/llvm/lib/Support/Unix/Path.inc"
  local file_output_buffer="$LLVM_SRC_DIR/llvm/lib/Support/FileOutputBuffer.cpp"
  local lld_elf_writer="$LLVM_SRC_DIR/lld/ELF/Writer.cpp"
  local lld_wasm_writer="$LLVM_SRC_DIR/lld/wasm/Writer.cpp"
  local lld_cmake="$LLVM_SRC_DIR/lld/CMakeLists.txt"
  local lld_tool_cmake="$LLVM_SRC_DIR/lld/tools/lld/CMakeLists.txt"
  local lld_tool_main="$LLVM_SRC_DIR/lld/tools/lld/lld.cpp"

  if grep -q 'std::random_device RandDev;' "$header"; then
    perl -0pi -e 's/#include <random>/#include <cstdint>/' "$header"
    perl -0pi -e 's/  std::random_device RandDev;\n/  uint64_t RandState = 0x9e3779b97f4a7c15ULL;\n/' "$header"
  fi

  if grep -q 'Dist(RandDev)' "$impl"; then
    perl -0pi -e 's@  std::uniform_int_distribution<uint64_t> Dist\(MinWait\.count\(\),\n                                               CurMaxWait\.count\(\)\);\n  // Use random_device directly instead of a PRNG as uniform_int_distribution\n  // often only takes a few samples anyway\.\n  duration WaitDuration = std::min\(duration\(Dist\(RandDev\)\), EndTime - Now\);@  uint64_t Min = static_cast<uint64_t>(MinWait.count());\n  uint64_t Max = static_cast<uint64_t>(CurMaxWait.count());\n  RandState = RandState * 6364136223846793005ULL + 1;\n  uint64_t Span = Max > Min ? Max - Min + 1 : 1;\n  duration WaitDuration = std::min(duration(Min + (RandState % Span)), EndTime - Now);@s' "$impl"
  fi

  if ! grep -q 'Kandelo exposes a local virtual filesystem' "$path_impl"; then
    perl -0pi -e 's@#elif defined\(__MVS__\)\n  // The file system can have an arbitrary@#elif defined(__wasm__)\n  // Kandelo exposes a local virtual filesystem and does not provide BSD statvfs flags.\n  return true;\n#elif defined(__MVS__)\n  // The file system can have an arbitrary@' "$path_impl"
  fi

  if grep -q 'std::random_device' "$lld_elf_writer"; then
    perl -0pi -e 's@std::mt19937 g\(seed \? seed : std::random_device\(\)\(\)\);@std::mt19937 g(seed ? seed : 0x9e3779b9u);@' "$lld_elf_writer"
  fi

  if ! grep -q "Kandelo's file-backed mmap" "$file_output_buffer"; then
    perl -0pi -e 's@OnDiskBuffer\(StringRef Path, fs::TempFile Temp, fs::mapped_file_region Buf\)\n      : FileOutputBuffer\(Path\), Buffer\(std::move\(Buf\)\), Temp\(std::move\(Temp\)\) \{\}@OnDiskBuffer(StringRef Path, fs::TempFile Temp, fs::mapped_file_region Buf,\n               unsigned Mode)\n      : FileOutputBuffer(Path), Buffer(std::move(Buf)), Temp(std::move(Temp)),\n        Mode(Mode) {}@' "$file_output_buffer"
    perl -0pi -e 's@    // Unmap buffer, letting OS flush dirty pages to file on disk\.\n    Buffer\.unmap\(\);\n\n    // Atomically replace the existing file with the new one\.\n    return Temp\.keep\(FinalPath\);@#if defined(__wasm__) || defined(__wasm32__)\n    // Kandelo\x27s file-backed mmap does not flush dirty pages back into the VFS\n    // file. Copy the mapped bytes to the destination explicitly before\n    // discarding the temporary file.\n    {\n      using namespace sys::fs;\n      int FD;\n      if (auto EC =\n              openFileForWrite(FinalPath, FD, CD_CreateAlways, OF_Delete, Mode))\n        return errorCodeToError(EC);\n      raw_fd_ostream OS(FD, /*shouldClose=*/true, /*unbuffered=*/true);\n      OS << StringRef((const char *)Buffer.data(), Buffer.size());\n      OS.flush();\n      if (std::error_code EC = OS.error())\n        return errorCodeToError(EC);\n    }\n\n    Buffer.unmap();\n    return Temp.discard();\n#else\n    // Unmap buffer, letting OS flush dirty pages to file on disk.\n    Buffer.unmap();\n\n    // Atomically replace the existing file with the new one.\n    return Temp.keep(FinalPath);\n#endif@' "$file_output_buffer"
    perl -0pi -e 's@  fs::TempFile Temp;\n};@  fs::TempFile Temp;\n  unsigned Mode;\n};@' "$file_output_buffer"
    perl -0pi -e 's@return std::make_unique<OnDiskBuffer>\(Path, std::move\(File\),\n                                         std::move\(MappedFile\)\);@return std::make_unique<OnDiskBuffer>(Path, std::move(File),\n                                         std::move(MappedFile), Mode);@' "$file_output_buffer"
  fi

  if grep -q 'FileOutputBuffer::F_executable |' "$lld_wasm_writer"; then
    perl -0pi -e 's@FileOutputBuffer::create\(ctx\.arg\.outputFile, fileSize,\n                               FileOutputBuffer::F_executable \\|\n                                   FileOutputBuffer::F_mmap\);@FileOutputBuffer::create(ctx.arg.outputFile, fileSize,\n                               FileOutputBuffer::F_executable);@' "$lld_wasm_writer"
  fi

  if ! grep -q 'Kandelo wasm-only lld' "$lld_cmake"; then
    perl -0pi -e 's@add_subdirectory\(Common\)\nadd_subdirectory\(tools/lld\)\n\nif \(LLVM_INCLUDE_TESTS\).*?add_subdirectory\(wasm\)\n@add_subdirectory(Common)\nadd_subdirectory(wasm)\nadd_subdirectory(tools/lld)\n# Kandelo wasm-only lld: skip COFF/ELF/MachO/MinGW/docs/tests.\n@s' "$lld_cmake"
  fi

  if grep -q 'lldCOFF' "$lld_tool_cmake"; then
    perl -0pi -e 's@lld_target_link_libraries\(lld\n  PRIVATE\n  lldCommon\n  lldCOFF\n  lldELF\n  lldMachO\n  lldMinGW\n  lldWasm\n  \)@lld_target_link_libraries(lld\n  PRIVATE\n  lldCommon\n  lldWasm\n  )@' "$lld_tool_cmake"
    perl -0pi -e 's@set\(LLD_SYMLINKS_TO_CREATE\n      lld-link ld\.lld ld64\.lld wasm-ld\)@set(LLD_SYMLINKS_TO_CREATE\n      wasm-ld)@' "$lld_tool_cmake"
  fi

  if ! grep -q 'KANDELO_WASM_LLD_DRIVERS' "$lld_tool_main"; then
    perl -0pi -e 's@LLD_HAS_DRIVER\(coff\)\nLLD_HAS_DRIVER\(elf\)\nLLD_HAS_DRIVER\(mingw\)\nLLD_HAS_DRIVER\(macho\)\nLLD_HAS_DRIVER\(wasm\)@LLD_HAS_DRIVER(wasm)\n#define KANDELO_WASM_LLD_DRIVERS                                               \\\n  { { lld::Wasm, &lld::wasm::link } }@' "$lld_tool_main"
    perl -0pi -e 's@LLD_ALL_DRIVERS@KANDELO_WASM_LLD_DRIVERS@g' "$lld_tool_main"
  fi
}

ensure_host_tablegen() {
  local llvm_tblgen clang_tblgen
  llvm_tblgen="$(find_host_tool llvm-tblgen || true)"
  clang_tblgen="$(find_host_tool clang-tblgen || true)"
  if [[ -n "$llvm_tblgen" && -n "$clang_tblgen" ]]; then
    LLVM_TABLEGEN_BIN="$llvm_tblgen"
    CLANG_TABLEGEN_BIN="$clang_tblgen"
    return
  fi

  echo "==> Building host llvm-tblgen and clang-tblgen..."
  cmake -G "Unix Makefiles" \
    -S "$LLVM_SRC_DIR/llvm" \
    -B "$HOST_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="clang" \
    -DLLVM_TARGETS_TO_BUILD="WebAssembly" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    2>&1 | tail -40
  cmake --build "$HOST_BUILD_DIR" --target llvm-tblgen clang-tblgen -j"${HOST_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}" \
    2>&1 | tail -40

  LLVM_TABLEGEN_BIN="$HOST_BUILD_DIR/bin/llvm-tblgen"
  CLANG_TABLEGEN_BIN="$HOST_BUILD_DIR/bin/clang-tblgen"
  [[ -x "$LLVM_TABLEGEN_BIN" && -x "$CLANG_TABLEGEN_BIN" ]] || {
    echo "ERROR: failed to produce host tablegen tools." >&2
    exit 1
  }
}

ensure_llvm_source
patch_llvm_source
ensure_host_tablegen

echo "==> Configuring clang/lld for wasm32-posix..."
if [[ "${KANDELO_CLANG_INCREMENTAL:-0}" != "1" ]]; then
  rm -rf "$BUILD_DIR"
fi

COMMON_FLAGS=(
  -O1
  -g0
  -fno-exceptions
  -fno-rtti
  -DCLANG_BUILD_STATIC
  -DLLVM_BUILD_STATIC
  -DLLVM_ON_UNIX=1
)

LINK_FLAGS=(
  "$LIBCXX_DIR/lib/libc++.a"
  "$LIBCXX_DIR/lib/libc++abi.a"
)

if [[ "${KANDELO_CLANG_SKIP_CONFIGURE:-0}" == "1" ]]; then
  echo "==> Reusing existing clang/lld CMake build directory..."
else
  cmake -G "Unix Makefiles" \
  -S "$LLVM_SRC_DIR/llvm" \
  -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_SYSTEM_NAME=Generic \
  -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
  -DCMAKE_C_COMPILER="$CC_TOOL" \
  -DCMAKE_CXX_COMPILER="$CXX_TOOL" \
  -DCMAKE_AR="$AR_TOOL" \
  -DCMAKE_RANLIB="$RANLIB_TOOL" \
  -DCMAKE_NM="$NM_TOOL" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_C_FLAGS="${COMMON_FLAGS[*]}" \
  -DCMAKE_CXX_FLAGS="${COMMON_FLAGS[*]}" \
  -DCMAKE_EXE_LINKER_FLAGS="${LINK_FLAGS[*]}" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
  -DLLVM_TABLEGEN="$LLVM_TABLEGEN_BIN" \
  -DCLANG_TABLEGEN="$CLANG_TABLEGEN_BIN" \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="WebAssembly" \
  -DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-unknown-unknown \
  -DLLVM_HOST_TRIPLE=wasm32-unknown-unknown \
  -DLLVM_BUILD_TOOLS=ON \
  -DLLVM_INCLUDE_TOOLS=ON \
  -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_BACKTRACES=OFF \
  -DLLVM_ENABLE_DIA_SDK=OFF \
  -DLLVM_ENABLE_EH=OFF \
  -DLLVM_ENABLE_RTTI=OFF \
  -DLLVM_ENABLE_THREADS=OFF \
  -DLLVM_ENABLE_PIC=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_LIBCXX=ON \
  -DLLVM_BUILD_LLVM_DYLIB=OFF \
  -DLLVM_LINK_LLVM_DYLIB=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DCLANG_ENABLE_ARCMT=OFF \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_ENABLE_PLUGIN_SUPPORT=OFF \
  2>&1 | tail -80
fi

echo "==> Building clang tools for Kandelo..."
BUILD_TARGETS=(lld llvm-ar llvm-ranlib llvm-nm)
if [[ "${KANDELO_CLANG_SKIP_CLANG_TARGET:-0}" != "1" ]]; then
  BUILD_TARGETS=(clang "${BUILD_TARGETS[@]}")
fi
cmake --build "$BUILD_DIR" \
  --target "${BUILD_TARGETS[@]}" \
  -j"${KANDELO_CLANG_BUILD_JOBS:-1}" \
  2>&1 | tail -80

mkdir -p "$BIN_DIR" "$INSTALL_DIR"

copy_tool() {
  local built_name="$1"
  local out_name="$2"
  local src="$BUILD_DIR/bin/$built_name"
  local local_dest="$REPO_ROOT/local-binaries/programs/$ARCH/clang/$out_name"
  if [[ ! -e "$src" ]]; then
    echo "ERROR: expected build output not found: $src" >&2
    exit 1
  fi
  cp -L "$src" "$BIN_DIR/$out_name"
  cp -L "$src" "$INSTALL_DIR/$out_name"
  mkdir -p "$(dirname "$local_dest")"
  cp -L "$src" "$local_dest"
  echo "  installed $INSTALL_DIR/$out_name"
  echo "  installed $local_dest"
}

alias_tool() {
  local target_name="$1"
  local out_name="$2"
  local dir
  for dir in "$BIN_DIR" "$INSTALL_DIR" "$REPO_ROOT/local-binaries/programs/$ARCH/clang"; do
    mkdir -p "$dir"
    rm -f "$dir/$out_name"
    ln -s "$target_name" "$dir/$out_name"
    echo "  aliased $dir/$out_name -> $target_name"
  done
}

copy_tool clang clang.wasm
alias_tool clang.wasm clang++.wasm
copy_tool wasm-ld wasm-ld.wasm
copy_tool llvm-ar llvm-ar.wasm
copy_tool llvm-ranlib llvm-ranlib.wasm
copy_tool llvm-nm llvm-nm.wasm

echo "==> clang package build complete."
