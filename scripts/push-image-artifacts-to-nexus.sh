#!/usr/bin/env bash
#
# push-image-artifacts-to-nexus.sh – Fetch the image artifacts produced by the
# "Docker Build" workflow (.github/workflows/docker-build.yml) and push them to
# a Nexus Docker registry, including a multi-arch manifest.
#
# Usage:
#   scripts/push-image-artifacts-to-nexus.sh [--links-only] [RUN_ID]
#
#   RUN_ID        Workflow run to take artifacts from. Defaults to the latest
#                 successful run of docker-build.yml.
#   --links-only  Print the artifact download links and exit (no Nexus creds needed).
#
# Environment:
#   NEXUS_REGISTRY   (required) Registry host[:port], e.g. nexus.example.com:8443
#   NEXUS_USERNAME   (required) Nexus user
#   NEXUS_PASSWORD   (required) Nexus password or token
#   NEXUS_IMAGE      Repository path in Nexus (default: sequin/sequin)
#   TAG_LATEST       Also push the manifest as :latest when "true" (default: false)
#   GH_REPO          owner/repo holding the workflow runs (default: from the origin remote)
#
# Requires: gh (authenticated), docker with buildx, gunzip.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
RESET='\033[0m'

WORKFLOW="docker-build.yml"
ARCHES=(amd64 arm64)

die() {
  echo -e "${RED}Error: $*${RESET}" >&2
  exit 1
}

LINKS_ONLY=false
RUN_ID=""
for arg in "$@"; do
  case "$arg" in
    --links-only) LINKS_ONLY=true ;;
    -h | --help)
      sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) RUN_ID="$arg" ;;
  esac
done

command -v gh >/dev/null || die "gh is not installed"

if [[ -z "${GH_REPO:-}" ]]; then
  origin_url=$(git remote get-url origin 2>/dev/null) || die "GH_REPO is not set and there is no origin remote"
  GH_REPO=$(sed -E 's#^(git@|https://)github\.com[:/]##; s#\.git$##' <<<"$origin_url")
fi
export GH_REPO

if [[ -z "$RUN_ID" ]]; then
  RUN_ID=$(gh run list --workflow "$WORKFLOW" --status success --limit 1 --json databaseId --jq '.[0].databaseId')
  [[ -n "$RUN_ID" ]] || die "no successful $WORKFLOW runs found in $GH_REPO"
fi

echo -e "${BLUE}Using run $RUN_ID of $WORKFLOW in $GH_REPO${RESET}"

# One line per artifact: id<TAB>name<TAB>expired
artifacts=$(gh api "repos/$GH_REPO/actions/runs/$RUN_ID/artifacts" --paginate \
  --jq '.artifacts[] | select(.name | startswith("sequin-image-")) | [.id, .name, .expired] | @tsv')
[[ -n "$artifacts" ]] || die "run $RUN_ID has no sequin-image-* artifacts"

VERSION=""
echo
echo "Artifact download links:"
while IFS=$'\t' read -r id name expired; do
  arch=${name##*-}
  version=${name#sequin-image-}
  version=${version%-"$arch"}
  if [[ -n "$VERSION" && "$VERSION" != "$version" ]]; then
    die "run $RUN_ID has artifacts for more than one version ($VERSION, $version)"
  fi
  VERSION=$version
  status=""
  [[ "$expired" == "true" ]] && status=" ${RED}(expired)${RESET}"
  echo -e "  ${arch}: https://github.com/$GH_REPO/actions/runs/$RUN_ID/artifacts/$id${status}"
done <<<"$artifacts"
echo

$LINKS_ONLY && exit 0

for arch in "${ARCHES[@]}"; do
  grep -q $'\t'"sequin-image-$VERSION-$arch"$'\t' <<<"$artifacts" || die "run $RUN_ID has no $arch image artifact"
done

: "${NEXUS_REGISTRY:?NEXUS_REGISTRY must be set}"
: "${NEXUS_USERNAME:?NEXUS_USERNAME must be set}"
: "${NEXUS_PASSWORD:?NEXUS_PASSWORD must be set}"
NEXUS_IMAGE=${NEXUS_IMAGE:-sequin/sequin}
TAG_LATEST=${TAG_LATEST:-false}
TARGET="$NEXUS_REGISTRY/$NEXUS_IMAGE"

command -v docker >/dev/null || die "docker is not installed"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

echo -e "${BLUE}Logging in to $NEXUS_REGISTRY as $NEXUS_USERNAME${RESET}"
printf '%s' "$NEXUS_PASSWORD" | docker login "$NEXUS_REGISTRY" --username "$NEXUS_USERNAME" --password-stdin

arch_refs=()
for arch in "${ARCHES[@]}"; do
  name="sequin-image-$VERSION-$arch"
  source_ref="sequin/sequin:$VERSION-$arch"
  target_ref="$TARGET:$VERSION-$arch"

  echo -e "${BLUE}Downloading $name${RESET}"
  gh run download "$RUN_ID" --name "$name" --dir "$workdir/$arch"

  echo -e "${BLUE}Loading $source_ref${RESET}"
  gunzip -c "$workdir/$arch/sequin-$VERSION-$arch.tar.gz" | docker load
  rm -rf "${workdir:?}/$arch"

  docker tag "$source_ref" "$target_ref"
  echo -e "${BLUE}Pushing $target_ref${RESET}"
  docker push "$target_ref"
  arch_refs+=("$target_ref")
done

echo -e "${BLUE}Creating manifest $TARGET:$VERSION${RESET}"
docker buildx imagetools create -t "$TARGET:$VERSION" "${arch_refs[@]}"

if [[ "$TAG_LATEST" == "true" ]]; then
  echo -e "${BLUE}Creating manifest $TARGET:latest${RESET}"
  docker buildx imagetools create -t "$TARGET:latest" "${arch_refs[@]}"
else
  echo -e "${YELLOW}Skipping :latest (set TAG_LATEST=true to push it)${RESET}"
fi

echo -e "${GREEN}Pushed $TARGET:$VERSION (${ARCHES[*]})${RESET}"
