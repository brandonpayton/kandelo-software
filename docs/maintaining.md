# Maintaining A Kandelo Package Source

This repository is deliberately thin: Kandelo owns the package system,
toolchain, archive format, and resolver. `kandelo-software` owns a set
of package recipes and the release index for the archives it publishes.

## Directory Layout

```text
packages/<name>/package.toml     # portable recipe
packages/<name>/build.toml       # this repo's publish/index settings
packages/<name>/build-<name>.sh  # Kandelo-relative build script
```

The workflow overlays each package into a Kandelo checkout at
`examples/libs/<name>/` before building. That keeps the existing build
scripts working without duplicating Kandelo's SDK, `xtask`, browser VFS
builders, or release archive code in this repository.

## Package Schema

`package.toml` must not contain publish state. Keep these fields out of
it:

- `revision`
- `[binary]`
- `[build].repo_url`
- `[build].commit`

Those belong in `build.toml` or in the release `index.toml` generated
at publish time.

For packages with a `[build]` block, `kernel_abi` must match the
Kandelo `ABI_VERSION` used by the publish workflow. The current package
set targets ABI 10.

`build.toml` should use the indexed binary form:

```toml
script_path = "examples/libs/nethack/build-nethack.sh"
repo_url    = "https://github.com/brandonpayton/kandelo-software.git"
commit      = "UNPUBLISHED"
revision    = 2

[binary]
index_url = "https://github.com/brandonpayton/kandelo-software/releases/download/binaries-abi-v{abi}/index.toml"
```

Keep `{abi}` in the URL. The resolver substitutes the Kandelo ABI at
resolve time.

## Publishing Locally

The same script used by Actions can run locally if `gh`, Nix, Rust, and
the Kandelo build prerequisites are available:

```bash
git clone https://github.com/brandonpayton/wasm-posix-kernel kandelo
cd kandelo
bash scripts/dev-shell.sh true
cd ..
bash kandelo-software/scripts/build-and-publish.sh \
  --software-root kandelo-software \
  --kandelo-root kandelo \
  --packages nethack
```

Set `GITHUB_REPOSITORY=brandonpayton/kandelo-software` and authenticate
`gh` before publishing to GitHub Releases.

## Adding A Package

1. Copy the Kandelo package directory into `packages/<name>/`.
2. Set `package.toml`'s `kernel_abi` to the current Kandelo ABI.
3. Retarget `build.toml` to this repository's release index.
4. Add the package to `packages.txt` in dependency order.
5. Run the publish workflow for that package.

If the package has dependent VFS images, list the base program first.
For example, `cpython` must precede `python-vfs` because the VFS build
reads the CPython source tree and stdlib staged by the CPython build.
