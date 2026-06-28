#!/usr/bin/env bash
# Clean up old GitHub Releases
# Keeps the newest N releases, the latest release, and releases marked with a keep marker

set -euo pipefail

# ==========================================
# Configuration
# ==========================================

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

keep_releases="${KEEP_RELEASES:-20}"
keep_marker="${KEEP_RELEASE_MARKER:-[keep-release]}"
dry_run="${DRY_RUN:-false}"

# ==========================================
# Validation
# ==========================================

if ! [[ "$keep_releases" =~ ^[0-9]+$ ]] || (( keep_releases < 1 )); then
  echo "ERROR: KEEP_RELEASES must be a positive integer, got: ${keep_releases}"
  exit 1
fi

# ==========================================
# Fetch Releases
# ==========================================

echo "=== Fetching releases from ${GITHUB_REPOSITORY} ==="

release_json="$(
  gh release list \
    --repo "$GITHUB_REPOSITORY" \
    --exclude-drafts \
    --exclude-pre-releases \
    --limit 1000 \
    --json tagName,name,isLatest,publishedAt
)"

mapfile -t release_tags < <(
  printf '%s\n' "$release_json" | jq -r 'sort_by(.publishedAt) | reverse | .[] | .tagName'
)

mapfile -t preserved_tags < <(
  printf '%s\n' "$release_json" | jq -r \
    --argjson keep "$keep_releases" \
    --arg marker "$keep_marker" \
    '
    sort_by(.publishedAt) | reverse as $releases |
    (
      ($releases[:$keep] | map(.tagName)) +
      ($releases | map(select(.isLatest) | .tagName)) +
      ($releases | map(select(((.name // "") | contains($marker)) or (.tagName | contains($marker))) | .tagName))
    ) | unique[]'
)

# ==========================================
# Build Preserved Map
# ==========================================

declare -A preserved_map=()
for tag in "${preserved_tags[@]}"; do
  preserved_map["$tag"]=1
done

# ==========================================
# Summary
# ==========================================

release_count="${#release_tags[@]}"
preserved_count="${#preserved_tags[@]}"
delete_count=$(( release_count - preserved_count ))

echo ""
echo "=== Summary ==="
echo "Total published releases: ${release_count}"
echo "Releases to keep: ${preserved_count}"
echo "Releases to delete: ${delete_count}"
echo ""
echo "Keep policy:"
echo "  - Newest ${keep_releases} releases"
echo "  - The latest release"
echo "  - Releases marked with '${keep_marker}'"

if [[ "$dry_run" == "true" ]]; then
  echo ""
  echo "=== DRY RUN MODE - No actual deletions ==="
fi

if (( release_count <= keep_releases )); then
  echo ""
  echo "No cleanup needed. Keeping all ${release_count} releases."
  exit 0
fi

# ==========================================
# Cleanup
# ==========================================

echo ""
echo "=== Processing releases ==="

deleted=0
preserved=0

for tag in "${release_tags[@]}"; do
  if [[ -n "${preserved_map[$tag]:-}" ]]; then
    echo "  [KEEP] ${tag}"
    preserved=$(( preserved + 1 ))
    continue
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "  [DELETE (dry-run)] ${tag}"
  else
    echo "  [DELETE] ${tag}"
    gh release delete "$tag" --repo "$GITHUB_REPOSITORY" --cleanup-tag -y
  fi
  deleted=$(( deleted + 1 ))
done

# ==========================================
# Final Summary
# ==========================================

echo ""
echo "=== Cleanup Complete ==="
echo "Preserved: ${preserved} releases"
echo "Deleted: ${deleted} releases"

if [[ "$dry_run" == "true" ]]; then
  echo ""
  echo "Note: This was a dry run. No releases were actually deleted."
  echo "Set DRY_RUN=false to perform actual deletion."
fi
