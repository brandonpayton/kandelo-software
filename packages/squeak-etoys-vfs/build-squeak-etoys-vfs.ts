import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { unzipSync } from "fflate";
import { MemoryFileSystem } from "../../../host/src/vfs/memory-fs";
import { resolveBinary } from "../../../host/src/binary-resolver";
import {
  ensureDirRecursive,
  saveImage,
  symlink,
  writeVfsBinary,
  writeVfsFile,
} from "../../../images/vfs/scripts/vfs-image-helpers";

const SCRIPT_DIR = new URL(".", import.meta.url).pathname;
const REPO_ROOT = join(SCRIPT_DIR, "..", "..", "..");
const OUT_FILE = join(REPO_ROOT, "apps", "browser-demos", "public", "squeak-etoys-vfs.vfs.zst");
const CACHE_DIR = join(SCRIPT_DIR, "cache");

const ETOYS_ZIP = {
  url: "https://etoysillinois.org/downloads/Etoys-To-Go-5.0.zip",
  sha256: "e197b4800e397e101445a246dae871389dc89572f8756df71658e8ccec14ba5e",
};

const ETOYS_PREFIX = "Etoys-To-Go 5.0.app/Contents/Resources/";
const ETOYS_EXAMPLES_PREFIX = `${ETOYS_PREFIX}ExampleEtoys/`;

const ILLINOIS_PROJECTS = [
  {
    id: "breakout",
    title: "Breakout Game",
    fileName: "BreakoutGame.001.pr",
    url: "https://etoysillinois.org/sl/BreakoutGame.001.pr",
    sha256: "cc48310925856d47a8b628b70eb6decfa88dbbebc767d94b8070412c38e25329",
  },
  {
    id: "pinball",
    title: "CS4K5 Grade 5 Pinball Game",
    fileName: "cs4k5g5PinballGame.008.pr",
    url: "https://etoysillinois.org/sl/cs4k5g5PinballGame.008.pr",
    sha256: "a17005fe9b6d9a66509375e7f60e5586096da3c390a2741449654b2ae8bbb9b9",
  },
  {
    id: "pluto",
    title: "CS4U Pluto's Revenge",
    fileName: "CS4U Pluto's Revenge.020.pr",
    url: "https://etoysillinois.org/sl/CS4U%20Pluto%27s%20Revenge.020.pr",
    sha256: "713f0b4d6b384d1c2164b4485f2ca08b629c71d7dac8718a42b84fb1ef22ad6a",
  },
];

const EXAMPLE_PROJECTS = [
  "LunarLanderGame.012.pr",
  "ComputerLogicGame.015.pr",
  "RandomRacing.010.pr",
  "BouncingBallAnimation.012.pr",
  "Welcome.046.pr",
];

const SQUEAK_ENV = [
  "HOME=/home",
  "TMPDIR=/tmp",
  "TERM=xterm-256color",
  "PATH=/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin",
  "SQUEAK_SECUREDIR=/home/.etoys",
  "SQUEAK_USERDIR=/home/Etoys",
  "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
  "SSL_CERT_DIR=/etc/ssl/certs",
];

function initConfig(document?: string) {
  return {
    argv: [
      "/usr/bin/squeak-v3",
      "-encoding",
      "UTF-8",
      "-mmap",
      "768m",
      "-vm-display-fbdev",
      "-vm-sound-OSS",
      "-plugins",
      "/usr/lib/squeak",
      "/home/etoys.image",
      ...(document ? [document] : []),
    ],
    env: SQUEAK_ENV,
    cwd: "/home",
    maxWorkers: 4,
    maxMemoryPages: 65536,
  };
}

async function main() {
  const squeakVm = readFileSync(resolveBinary("programs/squeak-v3.wasm"));
  const zipBytes = await fetchCached(ETOYS_ZIP.url, ETOYS_ZIP.sha256);
  const zip = unzipSync(zipBytes);

  const sab = new SharedArrayBuffer(96 * 1024 * 1024);
  const fs = MemoryFileSystem.create(sab, 256 * 1024 * 1024);

  ensureDirRecursive(fs, "/tmp");
  fs.chmod("/tmp", 0o777);
  ensureDirRecursive(fs, "/home/.etoys");
  ensureDirRecursive(fs, "/home/Etoys/Squeaklets");
  ensureDirRecursive(fs, "/home/ExampleEtoys");
  ensureDirRecursive(fs, "/home/kandelo-projects");
  ensureDirRecursive(fs, "/usr/bin");
  ensureDirRecursive(fs, "/usr/lib/squeak");
  ensureDirRecursive(fs, "/etc/kandelo");
  ensureDirRecursive(fs, "/etc/ssl/certs");

  writeVfsBinary(fs, "/usr/bin/squeak-v3", new Uint8Array(squeakVm), 0o755);
  symlink(fs, "/usr/bin/squeak-v3", "/usr/local/bin/squeak-v3");

  writeVfsBinary(fs, "/home/etoys.image", requiredZip(zip, `${ETOYS_PREFIX}etoys.image`), 0o644);
  writeVfsBinary(fs, "/home/etoys.changes", requiredZip(zip, `${ETOYS_PREFIX}etoys.changes`), 0o644);
  const sources = requiredZip(zip, `${ETOYS_PREFIX}EtoysV5.stc`);
  writeVfsBinary(fs, "/home/EtoysV5.stc", sources, 0o644);
  writeVfsBinary(fs, "/home/Etoys/EtoysV5.stc", sources, 0o644);
  writeVfsBinary(fs, "/home/.etoys/EtoysV5.stc", sources, 0o644);

  for (const fileName of EXAMPLE_PROJECTS) {
    writeVfsBinary(
      fs,
      `/home/ExampleEtoys/${fileName}`,
      requiredZip(zip, `${ETOYS_EXAMPLES_PREFIX}${fileName}`),
      0o644,
    );
  }

  for (const project of ILLINOIS_PROJECTS) {
    const bytes = await fetchCached(project.url, project.sha256);
    writeVfsBinary(fs, `/home/kandelo-projects/${project.fileName}`, bytes, 0o644);
  }

  writeVfsFile(fs, "/home/ETOYS-README.txt", readme(), 0o644);
  writeVfsFile(fs, "/etc/kandelo/demo.json", JSON.stringify(demoConfig(), null, 2) + "\n", 0o644);

  await saveImage(fs, OUT_FILE, { kernelAbi: 12 });
}

function demoConfig() {
  return {
    version: 1,
    presentation: {
      bootPrimary: "syslog",
      runningPrimary: ["framebuffer", "terminal", "syslog"],
      terminalAccess: "drawer",
      internalsAccess: "drawer",
      framebufferInput: "absolute-text",
    },
    init: initConfig(),
    profiles: {
      "squeak-etoys": { init: initConfig() },
      "squeak-lunar-lander": {
        init: initConfig("/home/ExampleEtoys/LunarLanderGame.012.pr"),
      },
      "squeak-logic-game": {
        init: initConfig("/home/ExampleEtoys/ComputerLogicGame.015.pr"),
      },
      "squeak-random-racing": {
        init: initConfig("/home/ExampleEtoys/RandomRacing.010.pr"),
      },
      "squeak-breakout": {
        init: initConfig("/home/kandelo-projects/BreakoutGame.001.pr"),
      },
      "squeak-pinball": {
        init: initConfig("/home/kandelo-projects/cs4k5g5PinballGame.008.pr"),
      },
      "squeak-pluto": {
        init: initConfig("/home/kandelo-projects/CS4U Pluto's Revenge.020.pr"),
      },
    },
    guide: {
      title: "Native Etoys",
      summary: "Etoys 5 runs on the native OpenSmalltalk V3 VM compiled for Kandelo Wasm.",
    },
  };
}

function readme(): string {
  return [
    "Etoys To-Go 5.0 for Kandelo",
    "",
    "Bundled examples:",
    ...EXAMPLE_PROJECTS.map((name) => `  /home/ExampleEtoys/${name}`),
    "",
    "Illinois Etoys projects:",
    ...ILLINOIS_PROJECTS.map((project) => `  /home/kandelo-projects/${project.fileName} - ${project.title}`),
    "",
  ].join("\n");
}

function requiredZip(entries: Record<string, Uint8Array>, path: string): Uint8Array {
  const bytes = entries[path];
  if (!bytes) throw new Error(`Missing ${path} in Etoys zip`);
  return bytes;
}

async function fetchCached(url: string, expectedSha256: string): Promise<Uint8Array> {
  mkdirSync(CACHE_DIR, { recursive: true });
  const cachePath = join(CACHE_DIR, basename(new URL(url).pathname));
  if (existsSync(cachePath)) {
    const bytes = new Uint8Array(readFileSync(cachePath));
    verifySha256(bytes, expectedSha256, cachePath);
    return bytes;
  }

  console.log(`Downloading ${url}`);
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status} ${response.statusText}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  verifySha256(bytes, expectedSha256, url);
  mkdirSync(dirname(cachePath), { recursive: true });
  writeFileSync(cachePath, bytes);
  return bytes;
}

function verifySha256(bytes: Uint8Array, expected: string, label: string): void {
  const actual = createHash("sha256").update(bytes).digest("hex");
  if (actual !== expected) {
    throw new Error(`${label} sha256 mismatch: expected ${expected}, got ${actual}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
