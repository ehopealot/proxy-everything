#!/usr/bin/env bash
# Guards the narrow, fork-only image-publication workflow. This never builds or
# pushes an image; it makes accidental broadening of the workflow visible.
set -Eeuo pipefail

workflow="${1:-.github/workflows/publish-ghcr.yml}"
readonly source_revision="efdd1f8831a9a888a5b0bb4945ddb629fffc6723"
readonly image="ghcr.io/ehopealot/proxy-everything"

[[ -f "$workflow" ]] || {
  echo "missing $workflow" >&2
  exit 1
}

require() {
  grep -Fqx -- "$1" "$workflow" >/dev/null || {
    echo "missing expected workflow line: $1" >&2
    exit 1
  }
}
reject() {
  if grep -F -- "$1" "$workflow" >/dev/null; then
    echo "unexpected workflow content: $1" >&2
    exit 1
  fi
}

require 'name: Publish fork proxy image'
require '      - ci/publish-proxy-efdd1f8'
require '    if: github.repository == '\''ehopealot/proxy-everything'\'' && github.ref == '\''refs/heads/ci/publish-proxy-efdd1f8'\'''
require '  SOURCE_REVISION: efdd1f8831a9a888a5b0bb4945ddb629fffc6723'
require '  IMAGE: ghcr.io/ehopealot/proxy-everything'
require '  TAG: efdd1f8831a9a888a5b0bb4945ddb629fffc6723'
require '  contents: read'
require '  packages: write'
require '          ref: ${{ env.SOURCE_REVISION }}'
require '          context: source'
require '          platforms: linux/amd64'
require '          tags: ${{ env.IMAGE }}:${{ env.TAG }}'
require '            org.opencontainers.image.source=https://github.com/ehopealot/proxy-everything'
require '            org.opencontainers.image.revision=${{ env.SOURCE_REVISION }}'
require '      - name: Record immutable digest'
require '          echo "${{ env.IMAGE }}@${{ steps.build.outputs.digest }}" >> "$GITHUB_STEP_SUMMARY"'

# Publication authority is restricted to the fork package, one immutable source
# tag, and action commits rather than floating tags.
reject 'cloudflare/proxy-everything'
reject 'DOCKER_USERNAME'
reject 'DOCKER_PASSWORD'
reject ':latest'
for action in actions/checkout docker/login-action docker/setup-buildx-action docker/build-push-action; do
  grep -E "uses: ${action}@[0-9a-f]{40}$" "$workflow" >/dev/null || {
    echo "${action} must be pinned to a full commit SHA" >&2
    exit 1
  }
done

# The trigger branch may contain only this workflow and its static policy test
# beyond the reviewed image source. Building from the pinned checkout below is
# the provenance boundary.
grep -Fqx -- "          git diff --quiet \"\$SOURCE_REVISION\" HEAD -- . ':!.github/workflows/publish-ghcr.yml' ':!test/verify-publish-ghcr-workflow.sh'" "$workflow" >/dev/null || {
  echo "missing publication-artifact-only source guard" >&2
  exit 1
}

echo "publish-ghcr workflow policy passed"
