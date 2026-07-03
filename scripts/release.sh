#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# release.sh — cut a talos-rpi-builder release and let CI build it
#
# Creates a GitHub Release for <tag> with no build assets attached. Publishing
# the release fires the `release: published` webhook, which triggers
# build-kernel.yml, build-overlay.yml, and publish.yml in this repo.
# publish.yml uploads metal-arm64.raw.xz to this same release once the build
# finishes (gh release upload --clobber — it does not delete/recreate the
# release, so it won't re-trigger itself).
#
# This is an alternative to `git tag vX.Y.Z && git push --tags`: both paths
# reach the same three workflows, but this one lets you write real release
# notes up front instead of getting the generic notes publish.yml generates.
#
# Prerequisites:
#   - gh CLI, authenticated (gh auth login)
#
# Usage:
#   ./scripts/release.sh <tag> [options]
#
# Examples:
#   ./scripts/release.sh v1.13.5
#   ./scripts/release.sh v1.13.6 --notes "Rebuilt against sbc-raspberrypi#88 rev N"
#   ./scripts/release.sh v1.13.5 --draft   # create as draft; publish it manually when ready
# ------------------------------------------------------------------------------

set -euo pipefail

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  cat <<USAGE
Usage: $0 <tag> [options]

Creates a GitHub Release for <tag> with no build assets attached. Publishing
it (immediately, unless --draft) triggers build-kernel.yml -> build-overlay.yml
-> publish.yml, which uploads metal-arm64.raw.xz to this same release.

Options:
  --repo owner/repo    Target repo (default: current repo via gh)
  --target ref         Branch or commit the tag should point at (default: repo default branch)
  --notes "text"       Release notes (default: generic placeholder — CI does not overwrite this)
  --draft               Create as a draft. A draft release does NOT fire the
                         release:published trigger — publish it manually
                         (gh release edit <tag> --draft=false) when ready.

Output image tags derive from <tag> the same way a 'git tag <tag> && git push --tags'
would: build-kernel.yml -> <tag>-k-rpi, publish.yml -> talos-rpi-installer:<tag>.
USAGE
  exit 0
fi

TAG="$1"
shift

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "ERROR: tag '${TAG}' doesn't look like vX.Y.Z (required — build-kernel.yml/publish.yml parse it with grep -oE '^v[0-9]+\\.[0-9]+\\.[0-9]+')" >&2
  exit 1
fi

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
TARGET=""
NOTES="Talos ${TAG} for Raspberry Pi CM4/CM5/Pi 4/Pi 5. Build artifacts are attached automatically by CI (build-kernel.yml -> build-overlay.yml -> publish.yml) once this release is published."
DRAFT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --draft) DRAFT=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "ERROR: could not determine repo from 'gh repo view'; pass --repo owner/repo" >&2
  exit 1
fi

echo "============================================================"
echo " release.sh"
echo "============================================================"
echo " Repo    : ${REPO}"
echo " Tag     : ${TAG}"
echo " Target  : ${TARGET:-<default branch HEAD>}"
echo " Draft   : $([[ "$DRAFT" == true ]] && echo yes || echo no)"
echo "============================================================"
echo ""
echo "==> Creating release ${TAG} (no assets — CI attaches them)"

if [[ "$DRAFT" == true ]]; then
  gh release create "${TAG}" \
    --repo "${REPO}" \
    ${TARGET:+--target "${TARGET}"} \
    --title "${TAG}" \
    --notes "${NOTES}" \
    --draft
else
  gh release create "${TAG}" \
    --repo "${REPO}" \
    ${TARGET:+--target "${TARGET}"} \
    --title "${TAG}" \
    --notes "${NOTES}"
fi

echo ""
if [[ "$DRAFT" == true ]]; then
  echo "==> Draft created. It will NOT trigger CI until you publish it:"
  echo "      gh release edit ${TAG} --repo ${REPO} --draft=false"
else
  echo "==> Published. CI should be starting now:"
  echo "      https://github.com/${REPO}/actions"
fi
