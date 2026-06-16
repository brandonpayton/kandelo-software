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
| `ruby` | program | Not currently published; upstream Ruby 3.3's wasm runtime still depends on Asyncify for setjmp/fiber support |
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
export WASM_POSIX_DEPS_REGISTRY="/path/to/kandelo-software/packages:/path/to/kandelo/packages/registry"
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
`packages/registry/*`, builds one package at a time with
`xtask archive-stage`, and uploads each archive plus an updated
`index.toml` to `binaries-abi-v<N>`. With an empty `kandelo-ref`, the
workflow uses `kandelo-abi.json`'s `kandelo_ref`; pass an explicit
`kandelo-ref` only when publishing against another source ref is
intended.

The reusable workflow is `.github/workflows/reusable-publish.yml`; the
setup logic is factored into `.github/actions/prepare-kandelo`.

Packages with `packages/<name>/publish.toml` and
`[publish].enabled = false` are skipped by `packages = all` publishes.
Explicitly selecting one of those packages fails with the recorded
reason instead of silently producing an incomplete archive.

The release also carries `gallery.json`. Kandelo's browser gallery reads
that manifest and the same release `index.toml`; entries are shown only
when every package listed for that entry has a successful wasm32 archive
in the index.

## Updating For A New ABI

When Kandelo bumps `ABI_VERSION`:

1. The **Bump Kandelo ABI metadata** workflow can be triggered by
   `repository_dispatch` (`kandelo-abi-release` or `kandelo-abi-bump`)
   from Kandelo, and also runs on a daily schedule. It reads
   `ABI_VERSION` from the configured Kandelo source ref (`main` by
   default) and opens an `abi-bump` PR when this repository still
   targets different ABI/source metadata.
2. That workflow runs `scripts/bump-abi-metadata.sh --abi <N>` to update
   every publishable `package.toml`, `gallery.json`, `kandelo-abi.json`,
   and ABI docs.
3. Merging the `abi-bump` PR triggers **Publish after ABI bump**, which
   rebuilds all packages against the recorded Kandelo source ref and
   publishes them to `binaries-abi-v<N>`.
4. If the metadata already targets the new ABI but the
   `binaries-abi-v<N>` release is missing `index.toml` or `gallery.json`,
   the bump workflow invokes the publish workflow directly to rebuild or
   repair the current ABI release.

The publish workflow also retries the current ABI publish after merged
publish-pipeline fixes, or when a merged PR is labeled `abi-publish`.

For a local or one-off bump, run:

```bash
bash scripts/bump-abi-metadata.sh --abi <N> --kandelo-ref main
```

Do not hardcode the ABI in `build.toml`; its `index_url` must keep the
`{abi}` placeholder.

Kandelo can trigger the bump workflow directly after changing
`ABI_VERSION` with a repository dispatch payload like:

```json
{
  "event_type": "kandelo-abi-bump",
  "client_payload": {
    "abi": 15,
    "kandelo_repository": "brandonpayton/wasm-posix-kernel",
    "kandelo_ref": "main"
  }
}
```

If Kandelo dispatches after cutting a durable `binaries-abi-v<N>` source
tag, use `event_type: "kandelo-abi-release"` and include
`"release_tag": "binaries-abi-v<N>"`; the bump workflow will validate
that tag's `ABI_VERSION` before opening the PR.
