# kandelo-software

Prebuilt third-party software and VFS images for the current Kandelo ABI.

This repository is a package source for software that is expensive to
rebuild in the main Kandelo CI. It starts with the packages that were
temporarily removed from browser-demo rebuilds, plus NetHack:

| Package | Kind | Notes |
|---|---|---|
| `cpython` | program | CPython `python.wasm` |
| `python-vfs` | VFS image | CPython standard library image |
| `perl` | program | Perl `perl.wasm` |
| `perl-vfs` | VFS image | Perl standard library image |
| `ruby` | program | Ruby `ruby.wasm` |
| `redis` | program | `redis-server.wasm` and `redis-cli.wasm` |
| `redis-vfs` | VFS image | Redis server boot image |
| `erlang` | program/runtime | BEAM plus trimmed OTP runtime bundle |
| `erlang-vfs` | VFS image | Erlang/OTP runtime image |
| `texlive` | program/runtime | `pdftex.wasm` plus TeX Live bundle |
| `nethack` | program | NetHack `nethack.wasm` |

The package recipes live under `packages/<name>/`. They use Kandelo's
current two-file package shape:

- `package.toml` is the portable recipe: name, version, ABI, source,
  license, dependencies, build script path, and declared outputs.
- `build.toml` is this repository's publish view: repository URL,
  revision, and the release `index.toml` used for binary resolution.

## Consuming the packages

After this repository has a `binaries-abi-v<N>` release, a Kandelo
checkout can resolve these packages from this package source by putting
the package directory first in the resolver registry path:

```bash
export WASM_POSIX_DEPS_REGISTRY="/path/to/kandelo-software/packages:/path/to/kandelo/examples/libs"
cd /path/to/kandelo
cargo xtask build-deps resolve nethack --arch wasm32
```

The resolver reads `packages/nethack/package.toml`, follows
`packages/nethack/build.toml` to this repository's
`binaries-abi-v{abi}/index.toml`, verifies the archive sha and
compatibility metadata, then unpacks the matching archive into the
local Kandelo cache.

If no matching archive exists yet, source build fallback expects the
package to be overlaid into a full Kandelo checkout because these build
scripts are intentionally Kandelo-relative. Use:

```bash
bash scripts/sync-packages.sh /path/to/kandelo
```

## Publishing

The maintained path is GitHub Actions:

1. Push this repository to `brandonpayton/kandelo-software`.
2. Run **Publish Kandelo software** from the Actions tab.
3. Keep `packages = all` for a full ABI refresh, or pass a
   comma-separated subset such as `nethack,redis`.

The workflow checks out Kandelo, overlays `packages/*` into
`examples/libs/*`, builds one package at a time with
`xtask archive-stage`, and uploads each archive plus an updated
`index.toml` to `binaries-abi-v<N>`, where `N` is read from Kandelo's
`crates/shared/src/lib.rs`.

The reusable workflow is `.github/workflows/reusable-publish.yml`; the
setup logic is factored into `.github/actions/prepare-kandelo`.

The release also carries `gallery.json`. Kandelo's browser gallery reads
that manifest and the same release `index.toml`; entries are shown only
when every package listed for that entry has a successful wasm32 archive
in the index.

## Updating For A New ABI

When Kandelo bumps `ABI_VERSION`:

1. Update each publishable `package.toml` to `kernel_abi = <new ABI>`.
2. Run the publish workflow against the Kandelo ref that contains the
   ABI bump.
3. Verify the release has a new `binaries-abi-v<N>/index.toml`.

Do not hardcode the ABI in `build.toml`; its `index_url` must keep the
`{abi}` placeholder.
