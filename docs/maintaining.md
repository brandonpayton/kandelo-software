# Maintaining A Kandelo Package Source

This repository is deliberately thin: Kandelo owns the package system,
toolchain, archive format, and resolver. `kandelo-software` owns a set
of package recipes and the release index for the archives it publishes.

## Directory Layout

```text
packages/<name>/package.toml     # portable recipe
packages/<name>/build.toml       # this repo's publish/index settings
packages/<name>/publish.toml     # optional this-repo publish policy
packages/<name>/build-<name>.sh  # Kandelo-relative build script
gallery.json                     # browser-gallery entries gated by index.toml
```

The workflow overlays each package into a Kandelo checkout at
`packages/registry/<name>/` before building. That keeps the existing build
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
set targets ABI 43.

Use `scripts/bump-abi-metadata.sh --abi <N> --kandelo-ref main` to
update the package set for a new Kandelo ABI. The scheduled **Bump
Kandelo ABI metadata** workflow reads `ABI_VERSION` from the configured
Kandelo source ref, updates `kandelo-abi.json`, and opens an `abi-bump`
PR when the package metadata changed. Merging that PR triggers the full
package publish workflow for the recorded Kandelo source ref and matching
`binaries-abi-v<N>` release tag. If the metadata is already current but
that release is missing `index.toml` or `gallery.json`, the bump workflow
publishes the current ABI directly.

If an ABI publish fails before the release is complete, merge the fix
through a publish-pipeline path such as `.github/actions/prepare-kandelo/`
or label the fix PR `abi-publish`; either signal retries the current ABI
publish after merge. Re-running the publish workflow also repairs a
missing `gallery.json` when the package archives are already present.

`build.toml` should use the indexed binary form:

```toml
script_path = "packages/registry/nethack/build-nethack.sh"
repo_url    = "https://github.com/brandonpayton/kandelo-software.git"
commit      = "UNPUBLISHED"
revision    = 2

[binary]
index_url = "https://github.com/brandonpayton/kandelo-software/releases/download/binaries-abi-v{abi}/index.toml"
```

Keep `{abi}` in the URL. The resolver substitutes the Kandelo ABI at
resolve time.

If a package is tracked here but must not be published under the current
artifact policy, add `packages/<name>/publish.toml`:

```toml
[publish]
enabled = false
reason = "Why packages=all should skip this package."
```

`packages = all` skips disabled packages and logs the reason. Explicitly
requesting the package fails so maintainers do not accidentally treat a
known-unpublishable package as complete.

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
If a VFS image builder needs an installed wasm binary at runtime, its
wrapper should also resolve that package before invoking the image
builder so subset publishes keep working.

If the package should appear in Kandelo's browser gallery, add an entry
to `gallery.json`. The gallery entry should list every package that must
be available for the demo; Kandelo only shows the entry when the release
`index.toml` marks all of those wasm32 packages as `success`.
