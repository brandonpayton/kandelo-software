import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { MemoryFileSystem } from "../../../host/src/vfs/memory-fs";
import { populateShellEnvironment } from "../../../images/vfs/scripts/shell-vfs-build";
import {
  ensureDirRecursive,
  saveImage,
  symlink,
  writeVfsBinary,
  writeVfsFile,
} from "../../../images/vfs/scripts/vfs-image-helpers";
import { KANDELO_DEMO_CONFIG_PATH } from "../../../web-libs/kandelo-session/src/demo-config";

const SDK_VFS_IN = process.env.KANDELO_SDK_VFS_IN;
const CLANG_BIN_DIR = process.env.KANDELO_CLANG_BIN_DIR;
const OUT_FILE = process.env.KANDELO_CLANG_DEMO_VFS_OUT ??
  "apps/browser-demos/public/clang-demo-vfs.vfs.zst";
const VFS_MB = Number.parseInt(
  process.env.KANDELO_CLANG_DEMO_VFS_MB ??
    process.env.KANDELO_CLANG_DEMO_MAX_VFS_MB ??
    "384",
  10,
);

const S_IFMT = 0xf000;
const S_IFDIR = 0x4000;
const S_IFLNK = 0xa000;

if (!SDK_VFS_IN || !existsSync(SDK_VFS_IN)) {
  throw new Error(`KANDELO_SDK_VFS_IN is not a readable SDK VFS image: ${SDK_VFS_IN ?? ""}`);
}

if (!CLANG_BIN_DIR || !existsSync(CLANG_BIN_DIR)) {
  throw new Error(`KANDELO_CLANG_BIN_DIR is not a readable clang package directory: ${CLANG_BIN_DIR ?? ""}`);
}

function clangToolPath(name: string): string {
  const path = join(CLANG_BIN_DIR!, name);
  if (!existsSync(path)) throw new Error(`clang package output missing: ${path}`);
  return path;
}

function installTool(fs: MemoryFileSystem, artifact: string, path: string): void {
  writeVfsBinary(fs, path, new Uint8Array(readFileSync(clangToolPath(artifact))), 0o755);
}

function dirname(path: string): string {
  const idx = path.lastIndexOf("/");
  if (idx <= 0) return "/";
  return path.slice(0, idx);
}

function joinVfsPath(parent: string, name: string): string {
  return parent === "/" ? `/${name}` : `${parent}/${name}`;
}

function isDir(mode: number): boolean {
  return (mode & S_IFMT) === S_IFDIR;
}

function isSymlink(mode: number): boolean {
  return (mode & S_IFMT) === S_IFLNK;
}

function unlinkNonDirectoryIfPresent(fs: MemoryFileSystem, path: string): void {
  try {
    const st = fs.lstat(path);
    if (!isDir(st.mode)) fs.unlink(path);
  } catch {
    // Missing path is fine.
  }
}

function readVfsBinary(fs: MemoryFileSystem, path: string, size: number): Uint8Array {
  const fd = fs.open(path, 0, 0);
  const data = new Uint8Array(size);
  let off = 0;
  try {
    while (off < size) {
      const n = fs.read(fd, data.subarray(off), null, size - off);
      if (n <= 0) break;
      off += n;
    }
  } finally {
    fs.close(fd);
  }
  return off === size ? data : data.slice(0, off);
}

function copyVfsTree(dst: MemoryFileSystem, src: MemoryFileSystem, path = "/"): number {
  const st = src.lstat(path);

  if (isSymlink(st.mode)) {
    ensureDirRecursive(dst, dirname(path));
    unlinkNonDirectoryIfPresent(dst, path);
    symlink(dst, src.readlink(path), path);
    return 1;
  }

  if (!isDir(st.mode)) {
    ensureDirRecursive(dst, dirname(path));
    unlinkNonDirectoryIfPresent(dst, path);
    writeVfsBinary(dst, path, readVfsBinary(src, path, st.size), st.mode & 0o777);
    return 1;
  }

  if (path !== "/") {
    ensureDirRecursive(dst, path);
    dst.chmod(path, st.mode & 0o777);
  }

  let count = 0;
  const dir = src.opendir(path);
  try {
    for (;;) {
      const entry = src.readdir(dir);
      if (!entry) break;
      if (entry.name === "." || entry.name === "..") continue;
      count += copyVfsTree(dst, src, joinVfsPath(path, entry.name));
    }
  } finally {
    src.closedir(dir);
  }
  return count;
}

async function main(): Promise<void> {
  const sab = new SharedArrayBuffer(VFS_MB * 1024 * 1024);
  const fs = MemoryFileSystem.create(sab);

  console.log("Populating full shell environment...");
  populateShellEnvironment(fs, { eagerBinaries: true });

  console.log("Layering Kandelo SDK VFS...");
  const sdkImage = MemoryFileSystem.fromImage(new Uint8Array(readFileSync(SDK_VFS_IN!)));
  const sdkFiles = copyVfsTree(fs, sdkImage);

  for (const dir of [
    "/etc",
    "/etc/kandelo",
    "/home",
    "/usr",
    "/usr/bin",
    "/usr/lib",
    "/usr/lib/llvm",
    "/usr/lib/llvm/bin",
    "/usr/local",
    "/usr/local/bin",
  ]) {
    ensureDirRecursive(fs, dir);
  }
  fs.chmod("/home", 0o777);

  console.log("Installing clang tool binaries...");
  installTool(fs, "clang.wasm", "/usr/lib/llvm/bin/clang");
  installTool(fs, "clang++.wasm", "/usr/lib/llvm/bin/clang++");
  installTool(fs, "wasm-ld.wasm", "/usr/lib/llvm/bin/wasm-ld");
  installTool(fs, "llvm-ar.wasm", "/usr/lib/llvm/bin/llvm-ar");
  installTool(fs, "llvm-ranlib.wasm", "/usr/lib/llvm/bin/llvm-ranlib");
  installTool(fs, "llvm-nm.wasm", "/usr/lib/llvm/bin/llvm-nm");

  symlink(fs, "/usr/lib/llvm/bin/clang", "/usr/bin/clang");
  symlink(fs, "/usr/lib/llvm/bin/clang++", "/usr/bin/clang++");
  symlink(fs, "/usr/lib/llvm/bin/wasm-ld", "/usr/bin/wasm-ld");
  symlink(fs, "/usr/lib/llvm/bin/llvm-ar", "/usr/bin/llvm-ar");
  symlink(fs, "/usr/lib/llvm/bin/llvm-ranlib", "/usr/bin/llvm-ranlib");
  symlink(fs, "/usr/lib/llvm/bin/llvm-nm", "/usr/bin/llvm-nm");
  symlink(fs, "/usr/bin/wasm32posix-cc", "/usr/bin/cc");
  symlink(fs, "/usr/bin/wasm32posix-c++", "/usr/bin/c++");
  symlink(fs, "/usr/bin/wasm32posix-ar", "/usr/bin/ar");
  symlink(fs, "/usr/bin/wasm32posix-ranlib", "/usr/bin/ranlib");
  symlink(fs, "/usr/bin/wasm32posix-nm", "/usr/bin/nm");

  console.log("Writing demo workspace...");
  writeVfsFile(fs, "/etc/profile", shellProfile(), 0o644);
  writeVfsFile(fs, "/home/README.txt", readme(), 0o644);
  writeVfsFile(fs, "/home/hello.c", helloC(), 0o644);
  writeVfsFile(fs, "/home/hello.cpp", helloCpp(), 0o644);
  writeVfsFile(fs, "/home/build.sh", buildScript(), 0o755);
  writeVfsFile(fs, KANDELO_DEMO_CONFIG_PATH, `${JSON.stringify(demoConfig(), null, 2)}\n`, 0o644);

  await saveImage(fs, OUT_FILE);
  console.log(`Layered ${sdkFiles} SDK VFS entries`);
}

function shellProfile(): string {
  return [
    "alias ls='ls --color=auto'",
    "alias grep='grep --color=auto'",
    "export USER=player",
    "export NETHACKOPTIONS='windowtype:curses,color,lit_corridor,hilite_pet'",
    "export HOME=/home",
    "export TMPDIR=/tmp",
    "export TERM=${TERM:-xterm-256color}",
    "export LANG=en_US.UTF-8",
    "export PATH=/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin:/usr/lib/llvm/bin",
    "export CC=wasm32posix-cc",
    "export CXX=wasm32posix-c++",
    "export AR=wasm32posix-ar",
    "export RANLIB=wasm32posix-ranlib",
    "export NM=wasm32posix-nm",
    "export PKG_CONFIG=wasm32posix-pkg-config",
    "export WASM_POSIX_LLVM_DIR=/usr/lib/llvm/bin",
    "export WASM_POSIX_SYSROOT=/usr/wasm32posix/sysroot",
    "export WASM_POSIX_GLUE_DIR=/usr/wasm32posix/glue",
    "export WASM_POSIX_GLUE_OBJ_DIR=/usr/wasm32posix/glue-objects",
    "export WASM_POSIX_CLANG_RESOURCE_DIR=/usr/lib/llvm/lib/clang/21",
    "alias cbuild='cc hello.c -o hello && ./hello'",
    "",
  ].join("\n");
}

function readme(): string {
  return [
    "Kandelo C/C++ demo",
    "",
    "Examples:",
    "  cc hello.c -o hello && ./hello",
    "  c++ hello.cpp -o hello-cpp && ./hello-cpp",
    "  vim hello.c",
    "",
    "Toolchain:",
    "  cc/c++ are Kandelo SDK wrappers targeting wasm32-posix.",
    "  clang, clang++, wasm-ld, llvm-ar, llvm-ranlib, and llvm-nm are in /usr/lib/llvm/bin.",
    "",
  ].join("\n");
}

function helloC(): string {
  return [
    "#include <stdio.h>",
    "",
    "int main(void) {",
    "    puts(\"hello from C compiled inside Kandelo\");",
    "    return 0;",
    "}",
    "",
  ].join("\n");
}

function helloCpp(): string {
  return [
    "#include <iostream>",
    "#include <vector>",
    "",
    "int main() {",
    "    std::vector<int> xs = {1, 2, 3, 4};",
    "    int sum = 0;",
    "    for (int x : xs) sum += x;",
    "    std::cout << \"hello from C++ compiled inside Kandelo: \" << sum << \"\\n\";",
    "    return 0;",
    "}",
    "",
  ].join("\n");
}

function buildScript(): string {
  return [
    "#!/bin/sh",
    "set -e",
    "cc hello.c -o hello",
    "./hello",
    "c++ hello.cpp -o hello-cpp",
    "./hello-cpp",
    "",
  ].join("\n");
}

function demoConfig() {
  return {
    version: 1,
    presentation: {
      bootPrimary: "syslog",
      runningPrimary: ["terminal", "syslog"],
      terminalAccess: "primary",
      internalsAccess: "drawer",
      autoCommand: "printf 'Compiling hello.c inside Kandelo...\\n'; cc hello.c -o hello && ./hello",
    },
  };
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
