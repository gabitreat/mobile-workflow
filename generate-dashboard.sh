#!/bin/bash
# Generates dashboard-data.json by scanning ALL git repos under the work directory.
# Recursively finds repos, captures recent feature branches as active work,
# older ones as stale, and accumulates session logs over time.
#
# Usage: ./generate-dashboard.sh [WORK_DIR]
#   WORK_DIR defaults to the parent of this script's directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${1:-$(dirname "$SCRIPT_DIR")}"
OUTPUT="$SCRIPT_DIR/dashboard-data.json"
BRANCHES_TMP="$SCRIPT_DIR/.branches.tmp"

NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TODAY=$(date -u +"%Y-%m-%d")
NOW_EPOCH=$(date -u +%s)

# ── Configurable ──
STALE_DAYS=3          # branches inactive for 3+ days = stale
ACTIVE_WINDOW_DAYS=3  # branches active within 3 days = active work
MAX_STALE_DAYS=30     # ignore branches older than 30 days
ENGINEER="Gabi Pago"
ROLE="iOS Developer"

# ── Helpers ──
json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'
}

# Clean temp files
rm -f "$BRANCHES_TMP"

# ── Find all git repos recursively ──
REPO_DIRS=$(find "$WORK_DIR" -maxdepth 4 -name ".git" -type d 2>/dev/null | sed 's/\/.git$//' | sort)

today_summaries=""
session_repos=""

for repo_dir in $REPO_DIRS; do
  # Compute a readable repo name (relative to WORK_DIR)
  repo_name="${repo_dir#$WORK_DIR/}"

  # Skip mobile-workflow itself
  [ "$repo_name" = "mobile-workflow" ] && continue

  # Determine repo type tag
  repo_tag="ios"
  case "$repo_name" in
    android-*) repo_tag="android" ;;
    pago-shared-*) repo_tag="shared" ;;
    pago-spm/*) repo_tag="spm" ;;
    maestro/*) repo_tag="testing" ;;
    temp/*) repo_tag="temp" ;;
  esac

  # Collect today's commits for the summary (across all branches)
  today_commits=$(git -C "$repo_dir" log --all --since="$TODAY" --format="%s" 2>/dev/null || echo "")
  if [ -n "$today_commits" ]; then
    session_repos="$session_repos$repo_name,"
    while IFS= read -r msg; do
      [ -z "$msg" ] && continue
      case "$msg" in Merge*) continue ;; esac
      today_summaries="$today_summaries$msg|$repo_name
"
    done <<< "$today_commits"
  fi

  # Scan ALL local feature branches (not just the current one)
  git -C "$repo_dir" for-each-ref --sort=-committerdate \
    --format='%(refname:short)|%(committerdate:iso)|%(committerdate:unix)' refs/heads/ 2>/dev/null | \
  while IFS='|' read -r branch bdate bepoch; do
    # Skip main/master
    [ "$branch" = "main" ] || [ "$branch" = "master" ] && continue
    # Skip worktree branches
    case "$branch" in worktree-*) continue ;; esac

    days_since=$(( (NOW_EPOCH - bepoch) / 86400 ))

    # Skip branches older than MAX_STALE_DAYS
    [ "$days_since" -gt "$MAX_STALE_DAYS" ] && continue

    # Determine status
    if [ "$days_since" -lt "$STALE_DAYS" ]; then
      status="in-progress"
    else
      status="stale"
    fi

    # Get summary from latest non-merge commit
    summary=$(git -C "$repo_dir" log --format="%s" -5 "$branch" 2>/dev/null | grep -v "^Merge " | head -1)
    [ -z "$summary" ] && summary=$(git -C "$repo_dir" log -1 --format="%s" "$branch" 2>/dev/null || echo "")

    # Extract ticket ID
    ticket_id=""
    if [[ "$branch" =~ (PAGO-[0-9]+) ]]; then
      ticket_id="${BASH_REMATCH[1]}"
    elif [[ "$branch" =~ ^(feature|bugfix|fix|chore)/(.+)$ ]]; then
      ticket_id="${BASH_REMATCH[2]}"
    else
      ticket_id="$branch"
    fi

    # Determine tag type
    tag_type="feature"
    case "$branch" in
      bugfix/*|fix/*) tag_type="bug" ;;
      chore/*) tag_type="chore" ;;
    esac

    # Is this the currently checked-out branch?
    current=$(git -C "$repo_dir" branch --show-current 2>/dev/null || echo "")
    is_current="false"
    [ "$branch" = "$current" ] && is_current="true"

    echo "{\"id\":$(json_escape "$ticket_id"),\"title\":$(json_escape "$branch"),\"repo\":$(json_escape "$repo_name"),\"status\":$(json_escape "$status"),\"branch\":$(json_escape "$branch"),\"summary\":$(json_escape "$summary"),\"lastTouchedAt\":$(json_escape "$bdate"),\"tags\":[$(json_escape "$tag_type"),$(json_escape "$repo_tag")],\"daysSinceActivity\":$days_since,\"isCurrent\":$is_current}" >> "$BRANCHES_TMP"
  done
done

# ── Build today's summary ──
day_summary_json=""
if [ -n "$today_summaries" ]; then
  items=""
  seen=""
  while IFS='|' read -r msg repo; do
    [ -z "$msg" ] && continue
    key=$(echo "$msg" | head -c 60)
    case "$seen" in *"$key"*) continue ;; esac
    seen="$seen|$key"
    items="$items$(json_escape "$msg ($repo)"),"
  done <<< "$today_summaries"
  items="${items%,}"
  day_summary_json="{\"date\":\"$TODAY\",\"items\":[$items]}"
fi

# ── Build session log entry ──
session_repos_clean=$(echo "$session_repos" | tr ',' '\n' | sort -u | grep -v '^$' | paste -sd, - 2>/dev/null || echo "")
session_entry=""
if [ -n "$session_repos_clean" ]; then
  repos_json=""
  IFS=',' read -ra repo_arr <<< "$session_repos_clean"
  for r in "${repo_arr[@]}"; do
    [ -z "$r" ] && continue
    repos_json="$repos_json$(json_escape "$r"),"
  done
  repos_json="${repos_json%,}"
  session_entry="{\"date\":\"$TODAY\",\"sessions\":1,\"repos\":[$repos_json]}"
fi

# ── Read all branches, assemble final JSON with Python ──
all_branches_json=""
if [ -f "$BRANCHES_TMP" ]; then
  all_branches_json=$(paste -sd, - < "$BRANCHES_TMP")
  rm -f "$BRANCHES_TMP"
fi

python3 << 'PYEOF' - "$all_branches_json" "$day_summary_json" "$session_entry" "$NOW_ISO" "$ENGINEER" "$ROLE" "$OUTPUT"
import json, sys
from datetime import datetime

all_branches_raw = sys.argv[1]
day_summary_raw = sys.argv[2]
session_raw = sys.argv[3]
now_iso = sys.argv[4]
engineer = sys.argv[5]
role = sys.argv[6]
output_path = sys.argv[7]

# Parse all branches
all_branches = []
if all_branches_raw.strip():
    try:
        all_branches = json.loads(f"[{all_branches_raw}]")
    except json.JSONDecodeError as e:
        print(f"Warning: failed to parse branches: {e}", file=sys.stderr)

# Separate active vs stale, dedup by branch name
seen = set()
active = []
stale = []

for b in all_branches:
    key = f"{b['repo']}:{b['branch']}"
    if key in seen:
        continue
    seen.add(key)

    if b.get("status") == "in-progress":
        active.append(b)
    else:
        stale.append(b)

# Sort active by: currently checked out first, then by recency
active.sort(key=lambda x: (not x.get("isCurrent", False), x.get("lastTouchedAt", "")), reverse=False)
active.sort(key=lambda x: (x.get("isCurrent", False), x.get("lastTouchedAt", "")), reverse=True)

# Sort stale by days since activity (most stale first)
stale.sort(key=lambda x: x.get("daysSinceActivity", 0), reverse=True)

# Current focus = most recently active item that is currently checked out, or just the most recent
current_focus = ""
for item in active:
    if item.get("isCurrent"):
        current_focus = f"{item['id']} — {item['summary'][:80]}"
        break
if not current_focus and active:
    top = active[0]
    current_focus = f"{top['id']} — {top['summary'][:80]}"

# Parse day summary
past_day = []
if day_summary_raw.strip():
    try:
        past_day = [json.loads(day_summary_raw)]
    except json.JSONDecodeError:
        pass

# Parse session entry
new_session = None
if session_raw.strip():
    try:
        new_session = json.loads(session_raw)
    except json.JSONDecodeError:
        pass

# Load existing data to preserve accumulated session log and blockers
existing_sessions = []
blockers = []
existing_past_days = []
try:
    with open(output_path, 'r') as f:
        existing = json.load(f)
        blockers = existing.get("blockers", [])
        existing_sessions = existing.get("sessionLog", [])
        existing_past_days = existing.get("pastDaySummary", [])
except (FileNotFoundError, json.JSONDecodeError):
    pass

# Merge session log: update today's entry or append
if new_session:
    found = False
    for i, s in enumerate(existing_sessions):
        if s.get("date") == new_session["date"]:
            existing_sessions[i]["sessions"] = s.get("sessions", 0) + 1
            # Merge repos
            existing_repos = set(s.get("repos", []))
            existing_repos.update(new_session.get("repos", []))
            existing_sessions[i]["repos"] = sorted(existing_repos)
            found = True
            break
    if not found:
        existing_sessions.insert(0, new_session)
    # Keep last 14 days
    existing_sessions = existing_sessions[:14]

# Merge past day summaries: update today or append
if past_day:
    found = False
    for i, d in enumerate(existing_past_days):
        if d.get("date") == past_day[0]["date"]:
            # Merge items (dedup)
            existing_items = set(d.get("items", []))
            existing_items.update(past_day[0].get("items", []))
            existing_past_days[i]["items"] = sorted(existing_items)
            found = True
            break
    if not found:
        existing_past_days.insert(0, past_day[0])
    # Keep last 7 days
    existing_past_days = existing_past_days[:7]

# Clean up helper fields
for item in active + stale:
    item.pop("daysSinceActivity", None)
    item.pop("isCurrent", None)

# Build output
dashboard = {
    "lastUpdated": now_iso,
    "engineer": engineer,
    "role": role,
    "currentFocus": current_focus,
    "activeItems": active,
    "pastDaySummary": existing_past_days,
    "blockers": blockers,
    "staleItems": stale,
    "sessionLog": existing_sessions
}

with open(output_path, 'w') as f:
    json.dump(dashboard, f, indent=2, ensure_ascii=False)

print(f"Dashboard updated: {output_path}")
print(f"  Active items: {len(active)}")
print(f"  Stale items:  {len(stale)}")
print(f"  Blockers:     {len(blockers)}")
print(f"  Today commits: {sum(len(d.get('items',[])) for d in past_day)}")
print(f"  Session log entries: {len(existing_sessions)}")
PYEOF
