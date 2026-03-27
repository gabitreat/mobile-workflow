#!/bin/bash
# PaJira — Git repo scanner POC
# Scans all repos under SCAN_ROOT, collects branches, recent commits, tags
# Outputs pajira-data.json

set -euo pipefail

SCAN_ROOT="${1:-/Users/gabipago/Work/Claude}"
OUTPUT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$OUTPUT_DIR/pajira-data.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Collect all .git dirs (max depth 3 to catch Workers/ repos too)
REPOS=()
while IFS= read -r gitdir; do
  REPOS+=("$(dirname "$gitdir")")
done < <(find "$SCAN_ROOT" -maxdepth 4 -name ".git" -type d 2>/dev/null | sort)

echo "PaJira: scanning ${#REPOS[@]} repos..."

# JSON-escape a string: handle backslash, quotes, control chars
json_escape() {
  python3 -c "import json,sys; print(json.dumps(sys.stdin.read().rstrip('\n'))[1:-1])" <<< "$1"
}

# Start JSON
cat > "$OUTPUT" <<HEADER
{
  "generatedAt": "$NOW",
  "scanRoot": "$SCAN_ROOT",
  "repoCount": ${#REPOS[@]},
  "repos": [
HEADER

FIRST=true
for repo in "${REPOS[@]}"; do
  # Skip .claude directories and non-repo dirs
  [[ "$repo" == *"/.claude"* ]] && continue
  [[ "$repo" == *"/node_modules/"* ]] && continue

  cd "$repo" 2>/dev/null || continue

  NAME=$(basename "$repo")
  REL_PATH="${repo#$SCAN_ROOT/}"

  # Current branch
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | head -1 || echo "detached")

  # Default branch (main or master)
  DEFAULT_BRANCH=""
  for candidate in main master; do
    if git show-ref --verify --quiet "refs/heads/$candidate" 2>/dev/null; then
      DEFAULT_BRANCH="$candidate"
      break
    fi
  done
  [ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="$CURRENT_BRANCH"

  # All local branches
  BRANCHES_JSON="["
  BFIRST=true
  while IFS= read -r branch; do
    branch=$(echo "$branch" | sed 's/^[* ]*//' | xargs)
    [ -z "$branch" ] && continue
    # Get last commit date and message for this branch
    LAST_DATE=$(git log -1 --format="%aI" "$branch" 2>/dev/null || echo "")
    LAST_MSG=$(json_escape "$(git log -1 --format="%s" "$branch" 2>/dev/null | head -c 120)")
    LAST_AUTHOR=$(json_escape "$(git log -1 --format="%an" "$branch" 2>/dev/null)")
    AHEAD=$(git rev-list --count "$DEFAULT_BRANCH..$branch" 2>/dev/null || echo "0")
    BEHIND=$(git rev-list --count "$branch..$DEFAULT_BRANCH" 2>/dev/null || echo "0")

    $BFIRST || BRANCHES_JSON+=","
    BFIRST=false
    BRANCHES_JSON+="
        {
          \"name\": \"$branch\",
          \"lastCommitDate\": \"$LAST_DATE\",
          \"lastCommitMsg\": \"$LAST_MSG\",
          \"lastAuthor\": \"$LAST_AUTHOR\",
          \"aheadOfDefault\": $AHEAD,
          \"behindDefault\": $BEHIND
        }"
  done < <(git branch 2>/dev/null)
  BRANCHES_JSON+="
      ]"

  # Recent commits on default branch (last 10)
  COMMITS_JSON="["
  CFIRST=true
  while IFS=$'\t' read -r hash date author msg; do
    msg=$(json_escape "$(echo "$msg" | head -c 120)")
    author=$(json_escape "$author")
    $CFIRST || COMMITS_JSON+=","
    CFIRST=false
    COMMITS_JSON+="
        {
          \"hash\": \"$hash\",
          \"date\": \"$date\",
          \"author\": \"$author\",
          \"message\": \"$msg\"
        }"
  done < <(git log "$DEFAULT_BRANCH" --format="%h%x09%aI%x09%an%x09%s" -10 2>/dev/null || true)
  COMMITS_JSON+="
      ]"

  # Tags (last 10, sorted by date)
  TAGS_JSON="["
  TFIRST=true
  while IFS=$'\t' read -r tag date; do
    [ -z "$tag" ] && continue
    tag=$(json_escape "$tag")
    $TFIRST || TAGS_JSON+=","
    TFIRST=false
    TAGS_JSON+="
        {
          \"name\": \"$tag\",
          \"date\": \"$date\"
        }"
  done < <(git tag --sort=-creatordate --format='%(refname:short)%09%(creatordate:iso-strict)' 2>/dev/null | head -10)
  TAGS_JSON+="
      ]"

  # Stats
  TOTAL_COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo "0")
  BRANCH_COUNT=$(git branch | wc -l | xargs)
  TAG_COUNT=$(git tag | wc -l | xargs)
  LAST_ACTIVITY=$(git log -1 --format="%aI" 2>/dev/null || echo "")

  # Remote URL
  REMOTE_URL=$(json_escape "$(git remote get-url origin 2>/dev/null || echo "")")

  # Escape all string fields
  NAME_ESC=$(json_escape "$NAME")
  REL_PATH_ESC=$(json_escape "$REL_PATH")
  DEFAULT_BRANCH_ESC=$(json_escape "$DEFAULT_BRANCH")
  CURRENT_BRANCH_ESC=$(json_escape "$CURRENT_BRANCH")

  $FIRST || echo "," >> "$OUTPUT"
  FIRST=false

  cat >> "$OUTPUT" <<REPO
    {
      "name": "$NAME_ESC",
      "path": "$REL_PATH_ESC",
      "remoteUrl": "$REMOTE_URL",
      "defaultBranch": "$DEFAULT_BRANCH_ESC",
      "currentBranch": "$CURRENT_BRANCH_ESC",
      "totalCommits": $TOTAL_COMMITS,
      "branchCount": $BRANCH_COUNT,
      "tagCount": $TAG_COUNT,
      "lastActivity": "$LAST_ACTIVITY",
      "branches": $BRANCHES_JSON,
      "recentCommits": $COMMITS_JSON,
      "tags": $TAGS_JSON
    }
REPO

done

# Close JSON
cat >> "$OUTPUT" <<FOOTER
  ]
}
FOOTER

echo "PaJira: wrote $OUTPUT (${#REPOS[@]} repos scanned)"
