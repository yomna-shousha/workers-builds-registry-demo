#!/usr/bin/env bash
# push-sbom.sh
#
# Called during Workers Builds to push build artifacts back to GitHub
# in a SINGLE commit:
#   - sbom.json         (SBOM for security scanning)
#   - package-lock.json (lockfile generated on Cloudflare's infra)
#
# Uses the GitHub Git Data API (trees + commits) to push multiple files
# in one commit. This is critical -- if each file is a separate commit,
# each triggers a push event and can cause an infinite build loop even
# with watch path exclusions.
#
# Requires GITHUB_TOKEN as a build secret in Workers Builds settings.
#
# Usage in Workers Builds "Build command":
#   npm run ci:build && bash scripts/push-sbom.sh

set -euo pipefail

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "WARN: GITHUB_TOKEN not set -- skipping artifact push to GitHub."
  echo "      Set GITHUB_TOKEN in Workers Builds > Settings > Build variables and secrets."
  exit 0
fi

if [ -z "${WORKERS_CI_COMMIT_SHA:-}" ]; then
  echo "WARN: Not running in Workers Builds (WORKERS_CI_COMMIT_SHA not set). Skipping push."
  exit 0
fi

API="https://api.github.com"
REMOTE_URL=$(git remote get-url origin)
REPO_SLUG=$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
BRANCH="${WORKERS_CI_BRANCH:-main}"
BUILD_ID="${WORKERS_CI_BUILD_UUID:-unknown}"

AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
ACCEPT_HEADER="Accept: application/vnd.github+json"

echo "=== Pushing build artifacts to GitHub ==="
echo "Repo:   ${REPO_SLUG}"
echo "Branch: ${BRANCH}"
echo "Build:  ${BUILD_ID}"
echo ""

# --- Step 1: Get the current commit SHA and tree SHA for the branch ---
echo "Getting current branch ref..."
BRANCH_REF=$(curl -sf \
  -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
  "${API}/repos/${REPO_SLUG}/git/ref/heads/${BRANCH}")

CURRENT_COMMIT_SHA=$(echo "$BRANCH_REF" | grep -o '"sha" *: *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
echo "  Current commit: ${CURRENT_COMMIT_SHA:0:7}"

CURRENT_COMMIT=$(curl -sf \
  -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
  "${API}/repos/${REPO_SLUG}/git/commits/${CURRENT_COMMIT_SHA}")

BASE_TREE_SHA=$(echo "$CURRENT_COMMIT" | grep -o '"sha" *: *"[^"]*"' | sed -n '2p' | sed 's/.*: *"//;s/"$//')
echo "  Base tree: ${BASE_TREE_SHA:0:7}"

# --- Step 2: Create blobs for each file ---
# Files to push: add or remove entries here.
# Format: "filepath"
FILES=("sbom.json" "package-lock.json")

TREE_ENTRIES=""

for FILE_PATH in "${FILES[@]}"; do
  if [ ! -f "$FILE_PATH" ]; then
    echo "  WARN: ${FILE_PATH} not found -- skipping."
    continue
  fi

  echo "  Creating blob for ${FILE_PATH}..."

  # Base64-encode to temp file to avoid arg length limits
  CONTENT_FILE=$(mktemp)
  base64 -w 0 "$FILE_PATH" > "$CONTENT_FILE" 2>/dev/null || base64 "$FILE_PATH" | tr -d '\n' > "$CONTENT_FILE"

  BLOB_PAYLOAD=$(mktemp)
  {
    echo -n '{"content":"'
    cat "$CONTENT_FILE"
    echo -n '","encoding":"base64"}'
  } > "$BLOB_PAYLOAD"

  BLOB_RESPONSE=$(curl -sf \
    -X POST \
    -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
    "${API}/repos/${REPO_SLUG}/git/blobs" \
    -d @"$BLOB_PAYLOAD")

  BLOB_SHA=$(echo "$BLOB_RESPONSE" | grep -o '"sha" *: *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
  echo "    Blob SHA: ${BLOB_SHA:0:7}"

  rm -f "$CONTENT_FILE" "$BLOB_PAYLOAD"

  # Build tree entry
  if [ -n "$TREE_ENTRIES" ]; then
    TREE_ENTRIES="${TREE_ENTRIES},"
  fi
  TREE_ENTRIES="${TREE_ENTRIES}{\"path\":\"${FILE_PATH}\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"${BLOB_SHA}\"}"
done

if [ -z "$TREE_ENTRIES" ]; then
  echo "No files to push. Done."
  exit 0
fi

# --- Step 3: Create a new tree with the blobs ---
echo "  Creating tree..."
TREE_RESPONSE=$(curl -sf \
  -X POST \
  -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
  "${API}/repos/${REPO_SLUG}/git/trees" \
  -d "{\"base_tree\":\"${BASE_TREE_SHA}\",\"tree\":[${TREE_ENTRIES}]}")

NEW_TREE_SHA=$(echo "$TREE_RESPONSE" | grep -o '"sha" *: *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
echo "    New tree: ${NEW_TREE_SHA:0:7}"

# --- Step 4: Create a new commit ---
echo "  Creating commit..."
COMMIT_MESSAGE="chore: update build artifacts from Workers Build ${BUILD_ID} [skip ci]"

COMMIT_RESPONSE=$(curl -sf \
  -X POST \
  -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
  "${API}/repos/${REPO_SLUG}/git/commits" \
  -d "{\"message\":\"${COMMIT_MESSAGE}\",\"tree\":\"${NEW_TREE_SHA}\",\"parents\":[\"${CURRENT_COMMIT_SHA}\"]}")

NEW_COMMIT_SHA=$(echo "$COMMIT_RESPONSE" | grep -o '"sha" *: *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
echo "    New commit: ${NEW_COMMIT_SHA:0:7}"

# --- Step 5: Update the branch ref to point to the new commit ---
echo "  Updating branch ref..."
HTTP_STATUS=$(curl -s -o /tmp/gh-response.json -w "%{http_code}" \
  -X PATCH \
  -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
  "${API}/repos/${REPO_SLUG}/git/refs/heads/${BRANCH}" \
  -d "{\"sha\":\"${NEW_COMMIT_SHA}\"}")

if [ "$HTTP_STATUS" = "200" ]; then
  echo ""
  echo "=== Done ==="
  echo "Both sbom.json and package-lock.json pushed in a single commit."
  echo "Commit: ${NEW_COMMIT_SHA:0:7} on ${BRANCH}"
else
  echo "  ERROR: Failed to update branch ref (HTTP ${HTTP_STATUS}):"
  cat /tmp/gh-response.json
  exit 1
fi
