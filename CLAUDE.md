# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A custom Talos Linux image builder for Raspberry Pi **CM4, CM5, Pi 4, and Pi 5**, producing a single `rpi_generic` disk image that boots on all four. There is no application code here — the repo is a set of Makefile targets, GitHub Actions workflows, and vendored patches that assemble Talos's official `imager` with a Raspberry Pi vendor kernel and a patched `sbc-raspberrypi` overlay.

This is a fork chain: `wheetazlab/talos-rpi-builder` → `ograff/talos-rpi-builder` → this repo (`conallob/talos-rpi-builder`). All workflow steps use `github.repository_owner` for GHCR paths so forks publish to their own namespace — but see "Fork-portability gotchas" below, some defaults still need to be set by hand.

**Why it exists:** upstream Talos + upstream `sbc-raspberrypi` can't boot CM5 (D0 BCM2712 stepping) or do NVMe boot on Pi 5/CM5 out of the box. This repo layers in fixes that haven't landed upstream yet (see "The core problem" below).

## The core problem (why this repo exists at all)

NVMe/PCIe boot and unified CM4/CM5/Pi4/Pi5 support comes from **[siderolabs/sbc-raspberrypi#88](https://github.com/siderolabs/sbc-raspberrypi/pull/88)** by `@appkins` — 14 patches that unify BCM2711 (CM4/Pi4) and BCM2712 (CM5/Pi5) into one `rpi_generic` U-Boot/overlay. **As of this writing PR #88 is still open/unmerged upstream** (maintainers want the separate `rpi_5` overlay preserved for Image Factory/Omni compatibility, so it's stuck in review). Until it merges, this repo consumes it by forking `sidero-community/sbc-raspberrypi` at the PR's branch commit (`build-overlay.yml` / `scripts/build-overlay.sh`, pinned via `pr88_sha`). **Re-check PR #88's status before cutting each new release** — if it merges, the overlay build can switch to tracking upstream `main` instead of a community fork SHA.

A second recurring issue: `bcm2712-rpi-cm5.dtsi`'s `&sdio1` node ships `broken-cd;`, which makes the kernel poll the (empty, on NVMe-only boots) microSD slot every ~10s forever (`mmc0: Timeout waiting for hardware cmd interrupt`). Fixed locally via `patches/dtb/0011-cm5-sdio1-drop-broken-cd.patch`, injected into the overlay build after PR #88's own patches (numbered `0011-` deliberately, to land after upstream's `0006-`).

A third: `net: macb` TX-stall on the BCM2712 PCIe Ethernet controller ([sbc-raspberrypi#82](https://github.com/siderolabs/sbc-raspberrypi/issues/82)/[#91](https://github.com/siderolabs/sbc-raspberrypi/issues/91)). This one is *already* fixed upstream in `raspberrypi/linux` rpi-6.18.y at the pinned `linux_ref`, so no extra patch is carried for it — just don't downgrade `linux_ref` without checking this is still true.

Track [siderolabs/talos#12748](https://github.com/siderolabs/talos/issues/12748) for the umbrella issue.

## Build commands

```bash
make pull-images      # pre-pull imager/installer-base/overlay/extensions
make build             # → _out/metal-arm64.raw.xz (disk image)
make installer         # → _out/installer-arm64.tar (talosctl upgrade image)
make push-installer    # load+tag+push installer to ghcr.io/$(GHCR_ORG)/talos-rpi-installer
make release            # gh release create with the .raw.xz (needs `gh auth login`)
make publish            # build + installer + push-installer + release
make flash-sd DISK=/dev/rdiskN   # dd the image (5s abort window)
make clean
make help               # prints all versions/vars currently in effect
```

Overrides are `make build VAR=value`, e.g. `TALOS_VERSION`, `CUSTOM_OVERLAY_IMAGE`, `CUSTOM_INSTALLER_BASE`, `EXTRA_KERNEL_ARGS`, `EXTENSIONS` (see Makefile header for the full variable list). Local builds require privileged Docker/Podman — `make build`/`installer` run the Talos `imager` OCI image with `--privileged -v /dev:/dev`.

There is no test suite. "Verification" is: build the image, flash it, boot real hardware. `build-overlay.yml`/`build-overlay.sh` do run a `patch --dry-run` sanity check against a fresh `raspberrypi/linux` checkout before invoking `make sbc-raspberrypi`, to fail fast on patch context drift — that's the closest thing to CI here.

`./scripts/release.sh vX.Y.Z` cuts a release the CI-driven way (see "Release triggers" below) instead of `git tag && git push --tags`.

## Architecture: the three-stage pipeline

**Run order matters — each stage consumes the previous stage's published OCI image.** Never run `publish.yml` before the other two have succeeded and `Makefile`/`CUSTOM_INSTALLER_BASE` point at the right tags.

1. **`build-kernel.yml`** → `ghcr.io/<owner>/rpi-talos:<installer_tag>` (e.g. `v1.13.5-k-rpi`)
   - Delegates the actual kernel compile to the reusable `build-kernel-pkg.yml`, which is **content-hash-tagged** (`kernel-rpi:<linux_ref>-<hash of pkgs-patch + kernel config>`) so unrelated reruns skip a full kernel rebuild and reuse the cached GHCR image. Pass `force_rebuild_kernel: true` to force it.
   - Clones `siderolabs/pkgs` at `pkg_version`, applies `patches/pkgs/0001-Patched-for-Raspberry-Pi-5.patch` (swaps kernel source from upstream stable to `raspberrypi/linux` rpi-6.18.y at `linux_ref`), drops in `patches/pkgs/config-arm64-rpi` as the kernel config.
   - A workflow step **asserts** the vendored Pkgfile patch's `linux_version:` matches the `linux_ref` input — if you bump `linux_ref`, you must regenerate the patch (its `linux_version`/`sha256`/`sha512` hunk) or the workflow hard-fails on purpose.
   - Then clones `siderolabs/talos` at `talos_version`, applies `patches/talos/0001-modules-arm64-rpi.patch` via `git am` (trims `hack/modules-arm64.txt` — this file has been iterated on heavily; see git log for the module-by-module trial-and-error of what can be dropped to shrink the image without breaking boot), and builds `imager`/`installer-base` with `PKG_KERNEL=` pointing at the Pi kernel.
   - **This patch has no dry-run guard** (unlike the pkgs Pkgfile patch's `linux_version:` assert, or the overlay's forward-aware patch loop) — it's a plain `git am`, so it silently breaks with `patch does not apply` if upstream Talos edits `hack/modules-arm64.txt` between releases (confirmed happening between whatever base this was cut against and `v1.13.5`: upstream's file grew from 239 to 241 lines). Because `git am` needs a real 3-way-mergeable patch, you can't just re-diff the old patch against a new base — regenerate it like this:
     ```bash
     # 1. Reconstruct the patch's intended *final* file content (context + added lines, skip removed lines)
     #    from the existing patches/talos/0001-modules-arm64-rpi.patch — this is the actual list of modules
     #    that must survive, independent of whatever Talos version the patch was last cut against.
     # 2. Fetch the new base: curl -O https://raw.githubusercontent.com/siderolabs/talos/<talos_version>/hack/modules-arm64.txt
     # 3. In a scratch git repo: commit the new base, then commit the reconstructed target content over it,
     #    then `git format-patch -1 HEAD --stdout` to produce a fresh, valid patch.
     # 4. Verify: shallow-clone siderolabs/talos at <talos_version>, `git am` the new patch, diff the result
     #    against the reconstructed target to confirm an exact match before committing.
     ```
     This fix only surfaces once `build-installer` runs (a separate job from the kernel compile), so it doesn't waste kernel build time when it breaks — but it does mean `publish.yml`'s image-wait loop will time out if you don't catch it.

2. **`build-overlay.yml`** / `scripts/build-overlay.sh` → `ghcr.io/<owner>/sbc-raspberrypi:<overlay_tag>` (e.g. `pr88-cd5`)
   - Forks `sidero-community/sbc-raspberrypi` at `pr88_sha` (the PR #88 branch — see "core problem" above).
   - Patches the overlay's own Pkgfile to swap in a specific U-Boot source tarball (`uboot_version`/`_sha256`/`_sha512`) and a specific `raspberrypi/linux` DTB source tag (`rpi_dtb_ref`/`_sha256`/`_sha512`) — these are **independent of the Talos kernel version**, they just control what DTBs/U-Boot get baked into the overlay.
   - Deletes PR #88's own `0008-*.patch` (adds an `mdio{}` wrapper that breaks the RPi vendor RP1 driver, which expects a flat `phy@1` — the pinned `RPI_DTB_REF` source already has the flat structure).
   - Injects `patches/dtb/0011-cm5-sdio1-drop-broken-cd.patch`, then rewrites the overlay's patch-apply loop to be **forward-aware**: dry-run each patch, apply if applicable, skip silently if already-applied (upstreamed), hard-fail only on genuine context drift. This is what lets the same patch set survive `raspberrypi/linux` ref bumps without manual patch surgery every time.
   - After running, **update `CUSTOM_OVERLAY_IMAGE` in the Makefile** to the new tag — this isn't automatic.

3. **`publish.yml`** → disk image + `ghcr.io/<owner>/talos-rpi-installer:<tag>` + GitHub Release
   - Triggered by pushing a `v*` tag, or manually.
   - Resolves extension images (`iscsi-tools`, `util-linux-tools`, `nvme-cli`, `tailscale`) to digests via `crane digest` before building, for reproducibility.
   - Builds via the *patched* `imager-rpi:<talos_version>-rpi` image (not the stock `ghcr.io/siderolabs/imager`) — that patched imager is what `build-kernel.yml` step 6 produces, tagged separately from `rpi-talos` in step "Tag imager as imager-rpi".

### Release triggers

All three workflows also fire on `release: types: [published]`, so publishing a GitHub Release kicks off the whole pipeline in one shot — `./scripts/release.sh vX.Y.Z` is the intended way to do this (creates the release with no assets; a draft release does *not* fire the trigger). This was added on top of the pre-existing `workflow_dispatch`/tag-push triggers, which still work unchanged.

**The loop hazard this created and how it's avoided:** `publish.yml`'s release job originally always did `gh release delete && gh release create`. If that ran unconditionally on a `release:published` trigger, it would delete-and-recreate the very release that triggered it, firing `published` again — infinite loop. Fixed by branching on `github.event_name`: a `release`-triggered run does `gh release upload <tag> --clobber` (attaches the asset to the *existing* release, no new release object, no new event) instead. Tag-push/workflow_dispatch runs keep the original delete+recreate behavior. **If you touch the release step again, preserve this branch** — don't collapse it back to a single unconditional `gh release create`.

`build-kernel.yml` and `build-overlay.yml` don't create releases, so they don't have this hazard — a `release`-triggered run of either just needs its inputs resolved with fallback defaults, since `github.event.inputs.*` is only populated for `workflow_dispatch` (see each workflow's "Resolve inputs"/"Resolve versions" step for the pattern: `${{ github.event.inputs.x || 'default' }}` in build-overlay.yml, an explicit `elif github.event_name == 'release'` branch in build-kernel.yml).

**Two more bugs the first cut of this had, found by actually running it (`./scripts/release.sh v1.13.5`):**

1. **`gh release create <tag>` double-fires `publish.yml`.** Creating a release also creates the underlying git tag, which independently satisfies `publish.yml`'s pre-existing `push: tags: v*` trigger — so both `release:published` and `push` land within seconds of each other and `publish.yml` runs twice for the same version. Fixed with a top-level `concurrency: group: publish-${{ github.event.release.tag_name || github.event.inputs.talos_version || github.ref_name }}, cancel-in-progress: true` — the second run to start cancels the first instead of both racing. `build-kernel.yml`/`build-overlay.yml` got the same treatment for consistency (`cancel-in-progress: false` there — a partially-finished kernel/overlay build is expensive to throw away, so a duplicate trigger queues instead of preempting).
2. **`publish.yml` doesn't actually wait for `build-kernel.yml`/`build-overlay.yml`.** All three workflows fire independently off the same `release:published` event — there's no `needs:`-style dependency across separate workflow files, so `publish.yml` would immediately try `crane digest` on the installer-base/overlay images and fail with `MANIFEST_UNKNOWN` if the other two hadn't finished publishing yet (kernel builds especially can take a long time). Fixed with a "Wait for installer-base and overlay images to be published" step in `publish.yml`'s `build` job that polls `crane manifest` every 30s for up to an hour before proceeding, instead of failing on the first check. This is a poll, not real sequencing — if you want true ordering guarantees, the correct fix is restructuring `build-kernel.yml`/`build-overlay.yml`/`publish.yml` into `workflow_call`-based jobs of one umbrella workflow (like `build-kernel.yml` already does internally with `build-kernel-pkg.yml`), not attempted here.

## Versioning quirks — read before bumping `TALOS_VERSION`

- `TALOS_VERSION` in the Makefile is the source of truth for the Talos release. When bumping it, also bump the `talos_version`/`installer_tag` workflow_dispatch defaults in `build-kernel.yml` and `publish.yml`, and the README's version table/examples — **these do not derive from the Makefile automatically**, they're separate hardcoded defaults that silently go stale (this happened going from v1.13.0 → v1.13.5).
- `pkg_version` (the `siderolabs/pkgs` ref used only for the kernel build) is a **different version line** and should generally stay `v1.13.0` — `siderolabs/pkgs` is not tagged per Talos patch release (verified: as of Talos v1.13.5 existing, `siderolabs/pkgs` still only has a `v1.13.0` tag). Don't bump this just because `TALOS_VERSION` moved; only bump it if `pkgs` cuts a new tag your patch needs to be re-anchored against (check the `Anchored on siderolabs/pkgs vX.Y.Z` line in `patches/pkgs/0001-Patched-for-Raspberry-Pi-5.patch`).
- `linux_ref` (the `raspberrypi/linux` short SHA) and the overlay's `rpi_dtb_ref` are independent pins from `TALOS_VERSION` — they track the Pi vendor kernel/DTB source, not Talos.

## Fork-portability gotchas

`workflow_dispatch` input `default:` fields **cannot use GitHub Actions expressions** (`${{ github.repository_owner }}` etc.) — they must be static strings. This repo's `publish.yml` used to hardcode those defaults to `wheetazlab`'s GHCR namespace, meaning a fork's manual/tag-push publish run would silently pull the *upstream* org's installer-base image instead of its own. Fixed by: leaving the `installer_base` input default blank, and computing the real default in the `env:` block (`RPI_INSTALLER_BASE_DEFAULT: 'ghcr.io/${{ github.repository_owner }}/rpi-talos:...'`) — `env:` blocks *do* support expressions, unlike input defaults. If you add new workflow_dispatch inputs that should default to "this fork's own image," follow the same pattern (blank input default + expression-based fallback in `env:` or a resolve step), don't hardcode an org.

The Makefile's `CUSTOM_OVERLAY_IMAGE` default is a plain string too (Makefiles can't read `github.repository_owner`), so it must be hand-updated per fork after running `build-overlay.yml` — currently `ghcr.io/conallob/sbc-raspberrypi:pr88-cd5`.

**`gh pr create` defaults to the fork parent, not `origin`.** This repo is a fork (`conallob/talos-rpi-builder` ← `ograff/talos-rpi-builder` ← `wheetazlab/talos-rpi-builder`), and `gh pr create` without `--repo` targets the parent repo reported by GitHub's fork relationship, not wherever `git remote -v` shows `origin` pointing. This silently opened a PR against `ograff/talos-rpi-builder` instead of `conallob/talos-rpi-builder` even though `origin` was correctly set to the latter. **Always pass `--repo conallob/talos-rpi-builder` explicitly** when running `gh pr create` (and when scripting `gh` calls generally — `gh pr view`, `gh pr checks`, etc. have the same default-to-parent behavior).

## Current state / in-flight work

This fork is actively working through Pi 5/CM5 boot issues (see extensive git log of kernel-module-trimming and DTB-patch trial-and-error) and expects to cut **multiple** Talos releases until factory.talos.dev / upstream `sbc-raspberrypi` resolve PR #88 and the CM5 issues properly. When starting a new release cycle:
1. Check whether [siderolabs/sbc-raspberrypi#88](https://github.com/siderolabs/sbc-raspberrypi/pull/88) has merged — if so, the overlay build can drop the `sidero-community` fork dependency.
2. Check whether a newer Talos patch release fixes anything relevant before re-cutting against an old base.
3. Run the three workflows **in order** (`build-kernel.yml` → `build-overlay.yml` → `publish.yml`), confirm each published image before triggering the next.
4. Update `Makefile` (`CUSTOM_OVERLAY_IMAGE`, `TALOS_VERSION`) and the workflow-default/README version strings together — they don't sync automatically (see "Versioning quirks").

## Hardware notes worth knowing before debugging boot failures

- CM5 requires up-to-date bootloader EEPROM (NVMe/PCIe enumeration needs firmware features added in late 2024) — an outdated EEPROM produces boot failures that look like image problems but aren't. See README "EEPROM Requirement" section.
- Carrier compatibility for the sdio1 broken-cd patch is verified on CM4IO, CM5IO, and DeskPi Super6C. Carriers that don't wire microSD CD to the controller's native CD pin need `cd-gpios` instead and should not use this overlay unmodified.
