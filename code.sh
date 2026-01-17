#!/bin/bash
#
# code.sh - Automated Feature Development Loop
#
# This script orchestrates multiple Claude Code sessions to automate the
# Feature Development Workflow from CLAUDE.md. It fetches GitHub issues,
# plans implementation, codes, tests, reviews, and deploys.
#
# Features:
#   - GitHub-based memory system (labels for phase, comments for session data)
#   - Crash recovery and resume from any phase
#   - Session cost tracking and audit trail
#   - Multi-machine support (all state in GitHub)
#
# Session Architecture:
#   0. User Feedback Triage (clean context - runs first each cycle)
#   1. Issue Selection (clean context)
#   2. Planning (clean context)
#   3. Implementation + Testing + PR (shared context - tight feedback loop)
#   4. Code Review (CLEAN CONTEXT - critical for quality!)
#   5. Fix Review Feedback (if needed)
#   6. Merge + Deploy + Verify (shared context)
#   7. Documentation (optional)
#
# Usage:
#   ./code.sh              # Run continuous loop (triage → select → dev)
#   ./code.sh --once       # Run single cycle including triage
#   ./code.sh -i 42        # Work on specific issue (implies --once)
#   ./code.sh --issue 42   # Same as above
#   ./code.sh --resume     # Resume in-progress work only
#   ./code.sh --status     # Show triage and dev status
#   ./code.sh --triage     # Triage-only mode, then exit
#   ./code.sh --hint "..." # Provide priority hint for issue selection
#   ./code.sh --init       # Run initial setup (GitHub labels, etc.) - once per repo
#
# Examples with --hint:
#   ./code.sh --hint "Work on issue #42 first, then #46, then #58"
#   ./code.sh --hint "Focus on countdown timer bugs before other issues"
#   ./code.sh --hint "Prioritize issues #42, #46, #58, #97 in that order"
#
# Note: Script operates on current working directory, so you can run it
# from any project: cd /path/to/project && /path/to/code.sh
#
set -euo pipefail

# Configuration
# Use current working directory as project root (allows running from any project)
REPO_ROOT="$(pwd)"
STATE_DIR="$REPO_ROOT/.auto-dev"
LOG_FILE="$STATE_DIR/auto-dev.log"
SINGLE_CYCLE=false
RESUME_ONLY=false
SHOW_STATUS=false
RUN_INIT=false
TARGET_ISSUE=""
SELECTION_HINT=""
RUN_TRIAGE_ONLY=false
MAX_REVIEW_ROUNDS=10
MAX_CI_FIX_ATTEMPTS=5
HUMAN_REVIEW_TIMEOUT=60  # Minutes to wait for human reviewers
HUMAN_REVIEW_POLL=60     # Seconds between polling for human reviews

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --once)
            SINGLE_CYCLE=true
            shift
            ;;
        --issue|-i)
            if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                echo "Error: --issue requires an issue number"
                exit 1
            fi
            TARGET_ISSUE="$2"
            SINGLE_CYCLE=true  # Implies --once
            shift 2
            ;;
        --resume)
            RESUME_ONLY=true
            shift
            ;;
        --status)
            SHOW_STATUS=true
            shift
            ;;
        --init)
            RUN_INIT=true
            shift
            ;;
        --hint|-h)
            if [ -z "${2:-}" ]; then
                echo "Error: --hint requires a string argument"
                exit 1
            fi
            SELECTION_HINT="$2"
            shift 2
            ;;
        --triage)
            RUN_TRIAGE_ONLY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--once] [-i|--issue <number>] [--resume] [--status] [--init] [--hint \"...\"] [--triage]"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Logging functions (output to stderr to avoid polluting stdout captures)
log() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE" >&2; }
success() { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓${NC} $*" | tee -a "$LOG_FILE" >&2; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠${NC} $*" | tee -a "$LOG_FILE" >&2; }
error() { echo -e "${RED}[$(date +'%H:%M:%S')] ✗${NC} $*" | tee -a "$LOG_FILE" >&2; }
header() { echo -e "\n${BOLD}${CYAN}$*${NC}" | tee -a "$LOG_FILE" >&2; }

# Detect rate limit errors by parsing JSON output from Claude Code CLI
# Returns 0 if rate limit error detected, 1 otherwise
# Checks for:
#   - API errors: {"type":"error","error":{"type":"rate_limit_error"|"overloaded_error",...}}
#   - SDK result errors: {"type":"result","subtype":"error_during_execution","errors":[...]}
#     where errors array contains rate limit related messages
#   - Hook denials: {"decision":"deny","reason":"Rate limit exceeded"} (exit code 2)
detect_rate_limit_error() {
    local output_file="$1"

    # Parse each JSON line looking for rate limit indicators
    while IFS= read -r line; do
        # Skip non-JSON lines
        [[ "$line" != "{"* ]] && continue

        # Try to parse as JSON, skip if invalid
        local json_valid
        json_valid=$(echo "$line" | jq -e . 2>/dev/null) || continue

        # Check for hook denial (decision: deny with rate limit reason)
        local decision reason
        decision=$(echo "$line" | jq -r '.decision // empty' 2>/dev/null) || true
        if [ "$decision" = "deny" ]; then
            reason=$(echo "$line" | jq -r '.reason // empty' 2>/dev/null) || true
            if echo "$reason" | grep -qiE "(rate.?limit|too many|exceeded|throttl)"; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] RATE LIMIT DETECTED: Hook denial reason='$reason'" >> "$LOG_FILE"
                return 0
            fi
        fi

        # Check for API-level error (type: "error")
        local msg_type error_type
        msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || true

        if [ "$msg_type" = "error" ]; then
            error_type=$(echo "$line" | jq -r '.error.type // empty' 2>/dev/null) || true
            case "$error_type" in
                rate_limit_error|overloaded_error)
                    echo "[$(date +'%Y-%m-%d %H:%M:%S')] RATE LIMIT DETECTED: API error type=$error_type" >> "$LOG_FILE"
                    return 0
                    ;;
            esac
        fi

        # Check for SDK result with error subtype
        if [ "$msg_type" = "result" ]; then
            local subtype
            subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null) || true

            if [ "$subtype" = "error_during_execution" ]; then
                # Check if errors array contains rate limit messages
                local errors
                errors=$(echo "$line" | jq -r '.errors // [] | .[]' 2>/dev/null) || true
                if echo "$errors" | grep -qiE "(rate.?limit|429|overloaded|too many requests)"; then
                    echo "[$(date +'%Y-%m-%d %H:%M:%S')] RATE LIMIT DETECTED: SDK error_during_execution with rate limit message" >> "$LOG_FILE"
                    return 0
                fi
            fi
        fi
    done < "$output_file"

    return 1
}

# Initialize state directory
mkdir -p "$STATE_DIR"

#═══════════════════════════════════════════════════════════════════════════════
# CLEANUP AND EXIT HANDLING
# Ensures background processes (dev servers, etc.) are stopped on exit
#═══════════════════════════════════════════════════════════════════════════════

# Track background PIDs started by this script
BACKGROUND_PIDS=()

# Cleanup function - kills any background processes we started
cleanup_background_processes() {
    log "Cleaning up background processes..."

    # Kill any tracked background PIDs (handle empty array with ${arr[@]+"${arr[@]}"} pattern)
    if [ ${#BACKGROUND_PIDS[@]} -gt 0 ]; then
        for pid in "${BACKGROUND_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                log "Killing background process $pid"
                kill "$pid" 2>/dev/null || true
            fi
        done
    fi

    # Kill any dev servers on port 3000 (common testing port)
    local port_pids
    port_pids=$(lsof -ti:3000 2>/dev/null || true)
    if [ -n "$port_pids" ]; then
        log "Killing processes on port 3000: $port_pids"
        echo "$port_pids" | xargs kill 2>/dev/null || true
    fi

    # Kill any node processes started by npm run dev in this directory
    local npm_pids
    npm_pids=$(pgrep -f "node.*$REPO_ROOT" 2>/dev/null || true)
    if [ -n "$npm_pids" ]; then
        log "Killing node processes for this project: $npm_pids"
        echo "$npm_pids" | xargs kill 2>/dev/null || true
    fi

    success "Cleanup complete"
}

# Set up trap to run cleanup on exit
trap cleanup_background_processes EXIT

#═══════════════════════════════════════════════════════════════════════════════
# GITHUB MEMORY SYSTEM
# Uses labels for phase tracking, comments for session memory
#═══════════════════════════════════════════════════════════════════════════════

# Label definitions: name|color|description (using | as delimiter since : is in label names)
PHASE_LABELS=(
    "auto-dev:selecting|0E8A16|Being selected for development"
    "auto-dev:planning|1D76DB|Creating implementation plan"
    "auto-dev:implementing|5319E7|Writing code and testing"
    "auto-dev:pr-waiting|FBCA04|PR created, waiting for CI"
    "auto-dev:reviewing|D93F0B|Under code review"
    "auto-dev:fixing|F9D0C4|Addressing review feedback"
    "auto-dev:merging|0052CC|Being merged and deployed"
    "auto-dev:verifying|BFD4F2|Production verification"
    "auto-dev:complete|0E8A16|Successfully completed"
    "auto-dev:blocked|B60205|Needs manual intervention"
    "auto-dev:ci-failed|FBCA04|CI checks failing, attempting fixes"
)

# Signal labels: used by Claude sessions to signal completion status
# These are consumed (removed) after being read by the script
SIGNAL_LABELS=(
    "auto-dev:signal:review-approved|0E8A16|Review approved, ready to merge"
    "auto-dev:signal:review-changes|D93F0B|Review requests changes"
    "auto-dev:signal:needs-update|FBCA04|PR needs updates after verification"
)

# Triage labels: for user-feedback issue triage workflow
TRIAGE_LABELS=(
    "auto-dev:triage:pending|C5DEF5|Feedback awaiting triage"
    "auto-dev:triage:analyzing|1D76DB|Being analyzed for scope"
    "auto-dev:triage:complete|0E8A16|Triage complete, issues created"
    "auto-dev:triage:blocked|B60205|Triage needs manual intervention"
)

# Ensure all required labels exist in the repo with correct colors and descriptions
ensure_labels_exist() {
    log "Ensuring GitHub labels exist..."
    local created=0
    local updated=0

    # Create phase labels
    for label_spec in "${PHASE_LABELS[@]}"; do
        IFS='|' read -r name color desc <<< "$label_spec"
        if gh label create "$name" --color "$color" --description "$desc" 2>/dev/null; then
            created=$((created + 1))
        else
            gh label edit "$name" --color "$color" --description "$desc" 2>/dev/null && updated=$((updated + 1))
        fi
    done

    # Create signal labels
    for label_spec in "${SIGNAL_LABELS[@]}"; do
        IFS='|' read -r name color desc <<< "$label_spec"
        if gh label create "$name" --color "$color" --description "$desc" 2>/dev/null; then
            created=$((created + 1))
        else
            gh label edit "$name" --color "$color" --description "$desc" 2>/dev/null && updated=$((updated + 1))
        fi
    done

    # Create triage labels
    for label_spec in "${TRIAGE_LABELS[@]}"; do
        IFS='|' read -r name color desc <<< "$label_spec"
        if gh label create "$name" --color "$color" --description "$desc" 2>/dev/null; then
            created=$((created + 1))
        else
            gh label edit "$name" --color "$color" --description "$desc" 2>/dev/null && updated=$((updated + 1))
        fi
    done

    if [ $created -gt 0 ] || [ $updated -gt 0 ]; then
        log "Labels: $created created, $updated updated"
    fi
}

# Check if a signal label is set on an issue
has_signal() {
    local issue_num=$1
    local signal=$2
    local labels
    labels=$(gh issue view "$issue_num" --json labels -q '.labels[].name' 2>/dev/null || echo "")
    echo "$labels" | grep -q "^auto-dev:signal:$signal$"
}

# Set a signal label on an issue
set_signal() {
    local issue_num=$1
    local signal=$2
    gh label create "auto-dev:signal:$signal" --color "CCCCCC" 2>/dev/null || true
    gh issue edit "$issue_num" --add-label "auto-dev:signal:$signal" >/dev/null 2>&1 || true
}

# Clear a signal label from an issue (consume the signal)
clear_signal() {
    local issue_num=$1
    local signal=$2
    gh issue edit "$issue_num" --remove-label "auto-dev:signal:$signal" >/dev/null 2>&1 || true
}

# Clear all signal labels from an issue
clear_all_signals() {
    local issue_num=$1
    local labels
    labels=$(gh issue view "$issue_num" --json labels -q '.labels[].name' 2>/dev/null | grep "^auto-dev:signal:" || true)
    for label in $labels; do
        gh issue edit "$issue_num" --remove-label "$label" >/dev/null 2>&1 || true
    done
}

# Set workflow phase for an issue (removes old phase, adds new)
set_phase() {
    local issue_num=$1
    local phase=$2

    # Remove all existing auto-dev phase labels
    local existing_labels
    existing_labels=$(gh issue view "$issue_num" --json labels -q '.labels[].name' 2>/dev/null | grep "^auto-dev:" || true)

    for old_label in $existing_labels; do
        # Keep metadata labels (pr:, branch:, round:, cost:), remove phase labels
        if [[ "$old_label" =~ ^auto-dev:(selecting|planning|implementing|pr-waiting|reviewing|fixing|merging|verifying|complete|blocked|ci-failed)$ ]]; then
            gh issue edit "$issue_num" --remove-label "$old_label" >/dev/null 2>&1 || true
        fi
    done

    # Add new phase label
    gh issue edit "$issue_num" --add-label "auto-dev:$phase" >/dev/null 2>&1 || true
    log "Phase → ${MAGENTA}$phase${NC} for issue #$issue_num"
}

# Get current phase of an issue
get_phase() {
    local issue_num=$1
    local labels
    labels=$(gh issue view "$issue_num" --json labels -q '.labels[].name' 2>/dev/null || echo "")

    for phase in selecting planning implementing pr-waiting reviewing fixing merging verifying complete blocked ci-failed; do
        if echo "$labels" | grep -q "^auto-dev:$phase$"; then
            echo "$phase"
            return 0
        fi
    done
    echo ""
}

# Add/update a metadata label (branch, round, cost)
set_metadata() {
    local issue_num=$1
    local key=$2
    local value=$3

    # Remove existing label with same key prefix
    local existing
    existing=$(gh issue view "$issue_num" --json labels -q ".labels[].name" 2>/dev/null | grep "^auto-dev:$key:" || true)
    if [ -n "$existing" ]; then
        gh issue edit "$issue_num" --remove-label "$existing" >/dev/null 2>&1 || true
    fi

    # Create and add new label
    local label_name="auto-dev:$key:$value"
    gh label create "$label_name" --color "CCCCCC" 2>/dev/null || true
    gh issue edit "$issue_num" --add-label "$label_name" >/dev/null 2>&1 || true
}

# Get metadata value from labels
# Returns empty string if metadata doesn't exist (safe with set -eo pipefail)
get_metadata() {
    local issue_num=$1
    local key=$2
    local labels
    labels=$(gh issue view "$issue_num" --json labels -q ".labels[].name" 2>/dev/null) || true
    echo "$labels" | grep "^auto-dev:$key:" | sed "s/auto-dev:$key://" | head -1 || true
}

# Validate and sanitize a PR number
# Returns clean numeric PR number or empty string if invalid
# Usage: clean_pr=$(validate_pr_number "$pr_num")
validate_pr_number() {
    local input=$1
    # Extract only the numeric part (last number in the string)
    local num
    num=$(echo "$input" | grep -oE '[0-9]+' | tail -1)
    if [ -n "$num" ] && [ "$num" -gt 0 ] 2>/dev/null; then
        echo "$num"
    else
        echo ""
    fi
}

# Post session memory as a structured comment
post_session_memory() {
    local issue_num=$1
    local phase_name=$2
    local session_start=$3
    local session_end=$4
    local cost=$5
    local summary=$6
    local extra_info=${7:-""}

    local duration=$((session_end - session_start))
    local duration_min=$((duration / 60))
    local duration_sec=$((duration % 60))
    local duration_fmt="${duration_min}m ${duration_sec}s"

    # Format timestamps
    local start_fmt end_fmt
    if date --version 2>/dev/null | grep -q GNU; then
        start_fmt=$(date -d "@$session_start" -u +"%Y-%m-%dT%H:%M:%SZ")
        end_fmt=$(date -d "@$session_end" -u +"%Y-%m-%dT%H:%M:%SZ")
    else
        start_fmt=$(date -r "$session_start" -u +"%Y-%m-%dT%H:%M:%SZ")
        end_fmt=$(date -r "$session_end" -u +"%Y-%m-%dT%H:%M:%SZ")
    fi

    local session_id="session-$(date +%s)-$$"

    local comment="## 🤖 Auto-Dev Session: $phase_name

| Field | Value |
|-------|-------|
| **Session ID** | \`$session_id\` |
| **Started** | $start_fmt |
| **Completed** | $end_fmt |
| **Duration** | $duration_fmt |
| **Cost** | \$$cost |

### Summary
$summary"

    if [ -n "$extra_info" ]; then
        comment+="

### Details
$extra_info"
    fi

    comment+="

---
<sub>🤖 Automated by auto-dev</sub>"

    gh issue comment "$issue_num" --body "$comment" >/dev/null 2>&1 || warn "Failed to post session memory"
}

# Get accumulated cost from all session comments
get_accumulated_cost() {
    local issue_num=$1

    # Extract all costs from session comments and sum them
    local total
    total=$(gh issue view "$issue_num" --comments --json comments \
        -q '[.comments[].body | capture("\\*\\*Cost\\*\\* \\| \\$(?<cost>[0-9.]+)") | .cost | tonumber] | add // 0' 2>/dev/null)

    printf "%.2f" "${total:-0}"
}

# Find issues that are in-progress (have auto-dev phase labels)
find_in_progress_issues() {
    local phases=("selecting" "planning" "implementing" "pr-waiting" "reviewing" "fixing" "merging" "verifying")

    for phase in "${phases[@]}"; do
        local issues
        issues=$(gh issue list --label "auto-dev:$phase" --json number,title -q '.[] | "\(.number):\(.title)"' 2>/dev/null || echo "")
        if [ -n "$issues" ]; then
            while IFS= read -r line; do
                local num title
                num=$(echo "$line" | cut -d: -f1)
                title=$(echo "$line" | cut -d: -f2-)
                echo "$num|$phase|$title"
            done <<< "$issues"
        fi
    done
}

# Find the most actionable in-progress issue
find_resumable_issue() {
    # Priority order for resuming
    local phases=("fixing" "reviewing" "pr-waiting" "implementing" "planning" "merging" "verifying" "selecting")

    for phase in "${phases[@]}"; do
        local issue
        issue=$(gh issue list --label "auto-dev:$phase" --json number -q '.[0].number' 2>/dev/null || echo "")
        if [ -n "$issue" ]; then
            echo "$issue"
            return 0
        fi
    done
    echo ""
}

# Show status of all in-progress issues
show_status() {
    header "Auto-Dev Status"

    # Show triage status first
    local untriaged triage_in_progress
    untriaged=$(find_untriaged_feedback_issues)
    triage_in_progress=$(find_triage_in_progress)

    if [ -n "$untriaged" ] || [ -n "$triage_in_progress" ]; then
        echo ""
        echo -e "${BOLD}Triage Queue:${NC}"
        printf "%-6s %-20s %-45s\n" "ISSUE" "STATUS" "TITLE"
        printf "%-6s %-20s %-45s\n" "-----" "------" "-----"

        if [ -n "$untriaged" ]; then
            while IFS='|' read -r num title; do
                [ -z "$num" ] && continue
                printf "%-6s %-20s %-45s\n" "#$num" "awaiting triage" "${title:0:45}"
            done <<< "$untriaged"
        fi

        if [ -n "$triage_in_progress" ]; then
            while IFS='|' read -r num phase title; do
                [ -z "$num" ] && continue
                printf "%-6s %-20s %-45s\n" "#$num" "$phase" "${title:0:45}"
            done <<< "$triage_in_progress"
        fi
        echo ""
    fi

    # Show development status
    local in_progress
    in_progress=$(find_in_progress_issues)

    if [ -z "$in_progress" ] && [ -z "$untriaged" ] && [ -z "$triage_in_progress" ]; then
        log "No in-progress issues found"
        return 0
    fi

    if [ -n "$in_progress" ]; then
        echo -e "${BOLD}Development Queue:${NC}"
        printf "%-6s %-15s %-50s\n" "ISSUE" "PHASE" "TITLE"
        printf "%-6s %-15s %-50s\n" "-----" "-----" "-----"

        while IFS='|' read -r num phase title; do
            local pr_num branch cost
            pr_num=$(get_linked_pr "$num" 2>/dev/null) || true
            cost=$(get_accumulated_cost "$num")

            printf "%-6s %-15s %-50s\n" "#$num" "$phase" "${title:0:50}"
            if [ -n "$pr_num" ]; then
                printf "       └─ PR #%s, Cost: \$%s\n" "$pr_num" "$cost"
            fi
        done <<< "$in_progress"
        echo ""
    fi
}

# Mark issue as blocked
mark_blocked() {
    local issue_num=$1
    local reason=$2

    set_phase "$issue_num" "blocked"

    gh issue comment "$issue_num" --body "## ⚠️ Auto-Dev Blocked

**Reason:** $reason
**Time:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")

### To Resume
1. Fix the underlying issue
2. Remove the \`auto-dev:blocked\` label
3. Add the appropriate phase label to continue from:
   - \`auto-dev:implementing\` - to restart implementation
   - \`auto-dev:reviewing\` - to restart code review
   - etc.

---
<sub>🤖 Automated by auto-dev</sub>" >/dev/null 2>&1 || true

    error "Issue #$issue_num blocked: $reason"
}

#═══════════════════════════════════════════════════════════════════════════════
# USER FEEDBACK TRIAGE SYSTEM
# Processes issues labeled 'user-feedback' into atomic development tasks
#═══════════════════════════════════════════════════════════════════════════════

# Find user-feedback issues that haven't been triaged yet
# Returns: issue_num|title format, one per line
find_untriaged_feedback_issues() {
    # Find issues with 'user-feedback' label but NO triage labels
    local feedback_issues
    feedback_issues=$(gh issue list --label "user-feedback" --state open --json number,title,labels \
        -q '.[] | select(.labels | map(.name) | any(startswith("auto-dev:triage:")) | not) | "\(.number)|\(.title)"' 2>/dev/null || echo "")
    echo "$feedback_issues"
}

# Find user-feedback issues currently being triaged
find_triage_in_progress() {
    local phases=("pending" "analyzing")

    for phase in "${phases[@]}"; do
        local issues
        issues=$(gh issue list --label "auto-dev:triage:$phase" --json number,title -q '.[] | "\(.number)|\(.title)"' 2>/dev/null || echo "")
        if [ -n "$issues" ]; then
            while IFS= read -r line; do
                local num title
                num=$(echo "$line" | cut -d'|' -f1)
                title=$(echo "$line" | cut -d'|' -f2-)
                echo "$num|triage:$phase|$title"
            done <<< "$issues"
        fi
    done
}

# Set triage phase for an issue (removes old triage phase, adds new)
set_triage_phase() {
    local issue_num=$1
    local phase=$2

    # Remove all existing triage phase labels
    local existing_labels
    existing_labels=$(gh issue view "$issue_num" --json labels -q '.labels[].name' 2>/dev/null | grep "^auto-dev:triage:" || true)

    for old_label in $existing_labels; do
        gh issue edit "$issue_num" --remove-label "$old_label" >/dev/null 2>&1 || true
    done

    # Add new triage phase label
    gh issue edit "$issue_num" --add-label "auto-dev:triage:$phase" >/dev/null 2>&1 || true
    log "Triage phase → ${MAGENTA}$phase${NC} for issue #$issue_num"
}

# Get current triage phase of an issue
get_triage_phase() {
    local issue_num=$1
    local labels
    labels=$(gh issue view "$issue_num" --json labels -q '.labels[].name' 2>/dev/null || echo "")

    for phase in pending analyzing complete blocked; do
        if echo "$labels" | grep -q "^auto-dev:triage:$phase$"; then
            echo "$phase"
            return 0
        fi
    done
    echo ""
}

# Triage a single user-feedback issue
# Analyzes scope, creates atomic child issues, returns recommendation
triage_feedback_issue() {
    local issue_num=$1

    log "Triaging user feedback issue #$issue_num..."
    set_triage_phase "$issue_num" "analyzing"

    local session_start
    session_start=$(date +%s)

    # Get issue details
    local issue_json
    issue_json=$(gh issue view "$issue_num" --json title,body,comments 2>/dev/null) || issue_json="{}"
    local issue_title issue_body
    issue_title=$(echo "$issue_json" | jq -r '.title // "Unknown"' 2>/dev/null) || issue_title="Unknown"
    issue_body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null) || issue_body=""

    local raw_output
    raw_output=$(run_claude "
You are triaging a user feedback issue for the habits/fitstreak project.

## Issue #$issue_num: $issue_title

$issue_body

## Your Task

Analyze this feedback and determine:
1. **Scope Assessment**: Is this small (1 atomic issue), medium (2-4 issues), or epic (5+ issues)?
2. **Actionability**: Can we act on this feedback, or does it need clarification?

## Actions Based on Analysis

### If feedback is CLEAR and ACTIONABLE:

**IMPORTANT: Check for duplicates FIRST!**
Before creating any issue, search for existing issues that might already cover the same work:
\`\`\`bash
gh issue list --state open --json number,title --limit 100
\`\`\`

For each issue you would create:
1. Check if a similar issue already exists (same feature/fix, even if worded differently)
2. If duplicate exists: Skip creation, note the existing issue number
3. If no duplicate: Create the new issue

Create atomic child issues using:
\`\`\`bash
gh issue create --title \"Title here\" --body \"Body here\" --label \"priority-label\"
\`\`\`

Each child issue should:
- Be small and well-defined (completable in one development session)
- Have a clear title starting with a verb (Add, Fix, Update, Implement, etc.)
- Reference the parent: 'Part of #$issue_num'
- Have appropriate priority label (P0-foundation, P1-core, P2-enhancement, P3-future)
- NOT duplicate an existing open issue

### If feedback NEEDS CLARIFICATION:
Add a comment asking for specifics:
\`\`\`bash
gh issue comment $issue_num --body \"Thanks for the feedback! To help us prioritize, could you clarify: [specific questions]\"
\`\`\`

## Output Format

After your analysis and actions, output ONLY this JSON (no markdown, no explanation):
{
    \"scope\": \"small|medium|epic|unclear\",
    \"issues_created\": [123, 124, 125],
    \"issues_linked\": [42, 43],
    \"recommendation\": \"close|convert_to_epic|needs_clarification\",
    \"summary\": \"Brief summary of what was done\"
}

Where:
- 'issues_created': New issues you created
- 'issues_linked': Existing issues that already cover part of this feedback (duplicates you found)
- 'close': Feedback fully addressed by child issues or existing issues, can close parent
- 'convert_to_epic': Large scope, rename to 'Epic: ...' and keep open as tracker
- 'needs_clarification': Asked user for more info, pause triage
")

    local session_end
    session_end=$(date +%s)

    # Extract JSON result
    local triage_result
    triage_result=$(echo "$raw_output" | grep -E '^\{.*\}$' | tail -1) || true

    if [ -z "$triage_result" ]; then
        # Try to find JSON anywhere in output
        triage_result=$(echo "$raw_output" | tr '\n' ' ' | grep -oE '\{[^{}]*"recommendation"[^{}]*\}' | head -1) || true
    fi

    if [ -z "$triage_result" ]; then
        warn "Could not extract triage result JSON"
        set_triage_phase "$issue_num" "blocked"
        return 1
    fi

    # Post session memory
    local summary
    summary=$(echo "$triage_result" | jq -r '.summary // "Triage completed"' 2>/dev/null) || summary="Triage completed"
    post_session_memory "$issue_num" "Triage Analysis" "$session_start" "$session_end" "${SESSION_COST:-0}" "$summary"

    # Store result for complete_triage
    echo "$triage_result"
}

# Complete the triage based on recommendation
complete_triage() {
    local issue_num=$1
    local triage_result=$2

    local recommendation scope issues_created issues_linked summary
    recommendation=$(echo "$triage_result" | jq -r '.recommendation // "close"' 2>/dev/null) || recommendation="close"
    scope=$(echo "$triage_result" | jq -r '.scope // "small"' 2>/dev/null) || scope="small"
    issues_created=$(echo "$triage_result" | jq -r '.issues_created // [] | join(", ")' 2>/dev/null) || issues_created=""
    issues_linked=$(echo "$triage_result" | jq -r '.issues_linked // [] | join(", ")' 2>/dev/null) || issues_linked=""
    summary=$(echo "$triage_result" | jq -r '.summary // ""' 2>/dev/null) || summary=""

    case "$recommendation" in
        "close")
            log "Closing feedback issue #$issue_num (fully triaged)"
            set_triage_phase "$issue_num" "complete"

            local close_comment="## ✅ Triage Complete

This feedback has been broken down into actionable issues:
$( [ -n "$issues_created" ] && echo "- Created issues: #${issues_created//,/, #}" || echo "- No new issues created" )
$( [ -n "$issues_linked" ] && echo "- Linked to existing issues: #${issues_linked//,/, #}" || echo "" )

**Scope:** $scope
**Summary:** $summary

Closing this feedback issue as the work is now tracked in the issues above.

---
<sub>🤖 Automated by auto-dev triage</sub>"

            gh issue comment "$issue_num" --body "$close_comment" >/dev/null 2>&1 || true
            gh issue close "$issue_num" >/dev/null 2>&1 || true
            success "Feedback #$issue_num triaged and closed"
            ;;

        "convert_to_epic")
            log "Converting feedback #$issue_num to Epic"
            set_triage_phase "$issue_num" "complete"

            # Get current title and prepend "Epic: " if not already there
            local current_title
            current_title=$(gh issue view "$issue_num" --json title -q '.title' 2>/dev/null) || current_title=""
            if [[ ! "$current_title" =~ ^Epic: ]]; then
                gh issue edit "$issue_num" --title "Epic: $current_title" >/dev/null 2>&1 || true
            fi

            local epic_comment="## 📋 Converted to Epic

This feedback has been analyzed and broken down:
$( [ -n "$issues_created" ] && echo "- Created issues: #${issues_created//,/, #}" || echo "- No new issues created" )
$( [ -n "$issues_linked" ] && echo "- Linked to existing issues: #${issues_linked//,/, #}" || echo "" )

**Scope:** $scope (epic-level)
**Summary:** $summary

This issue will remain open as a tracking epic for the child issues.

---
<sub>🤖 Automated by auto-dev triage</sub>"

            gh issue comment "$issue_num" --body "$epic_comment" >/dev/null 2>&1 || true
            success "Feedback #$issue_num converted to Epic"
            ;;

        "needs_clarification")
            log "Feedback #$issue_num needs clarification from user"
            # Remove triage labels - will be re-triaged when user responds
            set_triage_phase "$issue_num" "pending"

            # Remove user-feedback label temporarily to avoid re-processing
            # User can re-add it after providing clarification
            warn "Issue #$issue_num paused - waiting for user clarification"
            ;;

        *)
            warn "Unknown triage recommendation: $recommendation"
            set_triage_phase "$issue_num" "blocked"
            ;;
    esac
}

# Run the triage session for all untriaged feedback
run_triage_session() {
    header "SESSION 0: User Feedback Triage"

    # Ensure triage labels exist before we try to use them
    # (handles case where --init was never run)
    ensure_labels_exist

    # Collect ALL issues that need triage:
    # 1. New untriaged feedback (no triage labels)
    # 2. Issues stuck in pending/analyzing from previous runs
    local new_issues in_progress_issues all_triage_issues=""

    new_issues=$(find_untriaged_feedback_issues)
    in_progress_issues=$(find_triage_in_progress)

    # Combine lists (new issues first, then in-progress)
    if [ -n "$new_issues" ]; then
        # Format: issue_num|title
        all_triage_issues="$new_issues"
    fi

    if [ -n "$in_progress_issues" ]; then
        # in_progress format is: issue_num|triage:phase|title
        # Convert to: issue_num|title for consistent processing
        local converted_in_progress
        converted_in_progress=$(echo "$in_progress_issues" | while IFS='|' read -r num phase title; do
            [ -z "$num" ] && continue
            echo "$num|$title"
        done)
        if [ -n "$converted_in_progress" ]; then
            if [ -n "$all_triage_issues" ]; then
                all_triage_issues="$all_triage_issues"$'\n'"$converted_in_progress"
            else
                all_triage_issues="$converted_in_progress"
            fi
        fi
    fi

    if [ -z "$all_triage_issues" ]; then
        log "No user-feedback issues to triage"
        return 0
    fi

    local count new_count in_progress_count
    count=$(echo "$all_triage_issues" | wc -l | tr -d ' ')
    new_count=$([ -n "$new_issues" ] && echo "$new_issues" | wc -l | tr -d ' ' || echo "0")
    in_progress_count=$([ -n "$in_progress_issues" ] && echo "$in_progress_issues" | wc -l | tr -d ' ' || echo "0")
    log "Found $count user-feedback issue(s) to triage ($new_count new, $in_progress_count resuming)"

    # Process each feedback issue
    # Note: Using fd 3 to avoid stdin consumption by commands inside the loop
    # (run_claude and other commands may read from stdin, consuming remaining issues)
    while IFS='|' read -r -u 3 issue_num issue_title; do
        [ -z "$issue_num" ] && continue

        log "Processing feedback: #$issue_num - $issue_title"

        local triage_result
        if triage_result=$(triage_feedback_issue "$issue_num"); then
            complete_triage "$issue_num" "$triage_result"
        else
            warn "Triage failed for issue #$issue_num"
        fi

        # Brief pause between issues
        sleep 2
    done 3<<< "$all_triage_issues"

    success "Triage session complete"
}

#═══════════════════════════════════════════════════════════════════════════════
# STREAMING OUTPUT FORMATTER
#═══════════════════════════════════════════════════════════════════════════════

# Track session metrics
SESSION_START_TIME=""
SESSION_COST=""

# Format streaming JSON to show progress to human orchestrator
# Streams: text responses, tool calls, and captures final result
# IMPORTANT: Only outputs clean text to stdout, never raw JSON
# Press ESC to pause, any key to resume (only in interactive sessions)
format_progress() {
    local line type subtype final_result=""
    # Tool name mapping stored in temp files (for subshell access)
    # Use mktemp for safer temp file creation (avoids PID conflicts)
    local tool_names_file tool_inputs_file
    tool_names_file=$(mktemp -t tool_names.XXXXXX) || tool_names_file="/tmp/tool_names_$$_$RANDOM"
    tool_inputs_file=$(mktemp -t tool_inputs.XXXXXX) || tool_inputs_file="/tmp/tool_inputs_$$_$RANDOM"

    # Check if we're in an interactive session (has controlling terminal)
    local interactive=false
    if [[ -t 1 ]] && [[ -e /dev/tty ]]; then
        # Additional check: can we actually read from /dev/tty?
        if timeout 0.01 cat </dev/tty >/dev/null 2>&1 || true; then
            interactive=true
        fi
    fi

    # Set up non-blocking keyboard check (save and restore terminal settings)
    local old_tty_settings=""
    if [[ "$interactive" == "true" ]]; then
        old_tty_settings=$(stty -g 2>/dev/null) || true
    fi

    # Cleanup function to restore terminal and remove temp files
    cleanup_format_progress() {
        [ -n "$old_tty_settings" ] && stty "$old_tty_settings" 2>/dev/null || true
        rm -f "$tool_names_file" "$tool_inputs_file" 2>/dev/null || true
    }
    trap cleanup_format_progress EXIT

    while IFS= read -r line; do
        # Check for ESC key (non-blocking read from terminal) - only in interactive mode
        if [[ "$interactive" == "true" ]]; then
            local key=""
            # Try to read a key without blocking
            if read -t 0.01 -n 1 -s key </dev/tty 2>/dev/null; then
                # ESC key is character 27 (octal 033)
                if [[ "$key" == $'\x1b' ]]; then
                    printf "\n${YELLOW}  ⏸ PAUSED${NC} - Press any key to resume...\n" >&2
                    # Wait for any key to resume
                    read -n 1 -s </dev/tty 2>/dev/null || true
                    printf "${GREEN}  ▶ RESUMED${NC}\n\n" >&2
                fi
            fi
        fi
        # Skip non-JSON lines completely
        [[ "$line" != "{"* ]] && continue

        # Validate it's actually parseable JSON before processing
        if ! echo "$line" | jq -e . >/dev/null 2>&1; then
            continue
        fi

        type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || continue

        case "$type" in
            "assistant")
                # Check for text content (Claude's response)
                local text
                text=$(echo "$line" | jq -r '.message.content[]? | select(.type == "text") | .text // empty' 2>/dev/null) || true
                if [ -n "$text" ] && [ "$text" != "null" ]; then
                    printf "${CYAN}Claude:${NC} %s\n" "$text" >&2
                fi

                # Check for tool use - extract all tools from the message
                local tools_json
                tools_json=$(echo "$line" | jq -c '[.message.content[]? | select(.type == "tool_use") | {id, name, input}]' 2>/dev/null) || true
                if [ -n "$tools_json" ] && [ "$tools_json" != "[]" ]; then
                    # Process each tool
                    echo "$tools_json" | jq -c '.[]' 2>/dev/null | while read -r tool; do
                        local tool_id tool_name tool_input
                        tool_id=$(echo "$tool" | jq -r '.id // empty')
                        tool_name=$(echo "$tool" | jq -r '.name // empty')
                        tool_input=$(echo "$tool" | jq -r '.input | (.description // .command // .pattern // .query // .file_path // .prompt // "working...") | tostring | .[0:100]' 2>/dev/null) || true

                        if [ -n "$tool_name" ] && [ "$tool_name" != "null" ]; then
                            # Store for later lookup (write to temp file for subshell access)
                            echo "$tool_id:$tool_name" >> "$tool_names_file"
                            echo "$tool_id:${tool_input:-working...}" >> "$tool_inputs_file"
                            printf "${YELLOW}  → %s:${NC} %s\n" "$tool_name" "${tool_input:-working...}" >&2
                        fi
                    done
                fi
                ;;
            "user")
                # Tool result - show tool name and brief summary
                local results_json
                results_json=$(echo "$line" | jq -c '[.message.content[]? | select(.type == "tool_result") | {tool_use_id, is_error, content}]' 2>/dev/null) || true
                if [ -n "$results_json" ] && [ "$results_json" != "[]" ]; then
                    echo "$results_json" | jq -c '.[]' 2>/dev/null | while read -r result; do
                        local tool_use_id is_error tool_name result_preview
                        tool_use_id=$(echo "$result" | jq -r '.tool_use_id // empty')
                        is_error=$(echo "$result" | jq -r '.is_error // false')

                        # Look up tool name from stored mapping
                        tool_name=""
                        if [ -f "$tool_names_file" ]; then
                            tool_name=$(grep "^$tool_use_id:" "$tool_names_file" 2>/dev/null | cut -d: -f2- | head -1)
                        fi
                        tool_name="${tool_name:-Tool}"

                        # Get preview of result content (first 3 lines, cleaned up)
                        local result_content
                        result_content=$(echo "$result" | jq -r '
                            .content |
                            if type == "string" then .
                            elif type == "array" then (.[0].text // .[0].content // "")
                            else ""
                            end
                        ' 2>/dev/null) || true

                        if [ "$is_error" = "true" ]; then
                            printf "${RED}  ✗ %s: error${NC}\n" "$tool_name" >&2
                        else
                            printf "${GREEN}  ✓ %s${NC}\n" "$tool_name" >&2
                            # Show first 3 non-empty lines of output
                            if [ -n "$result_content" ] && [ "$result_content" != "null" ]; then
                                echo "$result_content" | grep -v '^$' | head -3 | while IFS= read -r preview_line; do
                                    # Truncate long lines and add indent
                                    printf "      ${GREEN}│${NC} %.76s\n" "$preview_line" >&2
                                done
                            fi
                        fi
                    done
                fi
                ;;
            "result")
                # Temp files cleaned up by trap handler

                subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null) || true
                if [ "$subtype" = "success" ]; then
                    final_result=$(echo "$line" | jq -r '.result // empty' 2>/dev/null) || true
                    SESSION_COST=$(echo "$line" | jq -r '.total_cost_usd // 0' 2>/dev/null) || true
                    printf "${GREEN}Session complete (cost: \$%.4f)${NC}\n" "${SESSION_COST:-0}" >&2
                else
                    # Error result - show error but DON'T output anything to stdout
                    local errors
                    errors=$(echo "$line" | jq -r '.errors // [] | .[:3] | join("; ") | .[0:200]' 2>/dev/null) || true
                    printf "${RED}Session error: %s${NC}\n" "${errors:-unknown error}" >&2
                    SESSION_COST="0"
                fi
                ;;
        esac
    done

    # Temp files cleaned up by trap handler (cleanup_format_progress)

    # Output the final result for capture
    if [ -n "$final_result" ] && [ "$final_result" != "null" ]; then
        printf "%s" "$final_result"
    fi
}

# Wrapper for claude command
# Always runs with --dangerously-skip-permissions and --model opus
# Uses streaming JSON output for progress display
# Logs all raw JSON output to LOG_FILE for debugging
# Handles rate limits and session limits with automatic retry
run_claude() {
    local prompt_preview
    prompt_preview=$(printf '%s' "$1" | head -c 100 | tr '\n' ' ') 2>/dev/null

    local max_retries=50  # Max retries for rate limits (can wait up to ~8 hours)
    local retry_count=0
    local base_wait=300   # Start with 5 minutes wait
    local max_wait=900    # Max 15 minutes between retries

    while true; do
        # Track session start
        SESSION_START_TIME=$(date +%s)
        SESSION_COST="0"

        # Log session start
        echo "" >> "$LOG_FILE"
        echo "═══════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] CLAUDE SESSION START (attempt $((retry_count + 1)))" >> "$LOG_FILE"
        echo "Prompt: ${prompt_preview}..." >> "$LOG_FILE"
        echo "═══════════════════════════════════════════════════════════════════" >> "$LOG_FILE"

        # Show hint about pause functionality
        printf "${BLUE}  [Press ESC to pause]${NC}\n" >&2

        # Capture output to check for rate limits
        local output_file
        output_file=$(mktemp)

        # All sessions use print mode with streaming JSON for progress display
        claude --dangerously-skip-permissions --model opus --verbose -p --output-format stream-json "$@" 2>&1 | tee -a "$LOG_FILE" | tee "$output_file" | format_progress

        local exit_code=${PIPESTATUS[0]}

        # Log session end
        echo "" >> "$LOG_FILE"
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] CLAUDE SESSION END (exit code: $exit_code, cost: \$${SESSION_COST:-0})" >> "$LOG_FILE"
        echo "═══════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"

        # Check for rate limit / session limit errors (only if session failed)
        # Uses JSON parsing to detect actual API errors, not text patterns in Claude's responses
        if [ $exit_code -ne 0 ] && detect_rate_limit_error "$output_file"; then
            retry_count=$((retry_count + 1))
            rm -f "$output_file"

            if [ $retry_count -ge $max_retries ]; then
                error "Max retries ($max_retries) exceeded for rate limits"
                return 1
            fi

            # Calculate wait time with exponential backoff (capped)
            local wait_time=$((base_wait + (retry_count - 1) * 60))
            [ $wait_time -gt $max_wait ] && wait_time=$max_wait

            local wait_mins=$((wait_time / 60))
            warn "Rate/session limit hit. Waiting ${wait_mins} minutes before retry ($retry_count/$max_retries)..."
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] RATE LIMIT: Waiting ${wait_time}s before retry $retry_count" >> "$LOG_FILE"

            # Show countdown
            local remaining=$wait_time
            while [ $remaining -gt 0 ]; do
                printf "\r${YELLOW}  ⏳ Waiting for rate limit: %02d:%02d remaining${NC}  " $((remaining / 60)) $((remaining % 60)) >&2
                sleep 10
                remaining=$((remaining - 10))
            done
            printf "\r${GREEN}  ✓ Resuming after rate limit wait${NC}                    \n" >&2

            continue  # Retry the claude call
        fi

        rm -f "$output_file"
        return $exit_code
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# WORKFLOW SESSIONS
#═══════════════════════════════════════════════════════════════════════════════

# Common instruction block for discovering and creating new issues
# Include this in prompts where Claude is actively working with codebase
NEW_ISSUE_INSTRUCTIONS='
## Discovering and Reporting Issues

While working, if you discover ANY bugs, errors, or problems that are NOT part of your
current task, you MUST search for existing issues and create new ones if none exist.

**IMPORTANT:** "Pre-existing" issues still need to be tracked! If a problem exists in
production (even if not caused by the current PR), it needs a GitHub issue so it can be fixed.

**Process for EVERY issue discovered:**

1. **Search first** - Check if an issue already exists:
   ```bash
   gh issue list --state open --search "keyword from the issue"
   gh issue list --state closed --search "keyword from the issue"  # Also check closed
   ```

2. **Only create if not found** - If no matching issue exists (open or recently closed):
   ```bash
   gh issue create --title "type: brief description" --body "$(cat <<'\''EOF'\''
   ## Description
   Clear description of the issue.

   ## Context
   Where/how this was discovered.

   ## Suggested Fix (optional)
   Any ideas for resolution.

   ---
   *Discovered by auto-dev while working on #CURRENT_ISSUE*
   EOF
   )"
   ```

3. **Use appropriate prefixes**: bug:, feat:, refactor:, perf:, docs:, test:, chore:

**MUST report these (search + create if not found):**
- Console errors (React errors, JavaScript exceptions, network failures)
- Broken functionality (pages not loading, features not working)
- Hydration mismatches or React warnings
- Security vulnerabilities
- Performance issues (slow loading, memory leaks)
- Missing error handling
- Data loading failures
- UI rendering issues
- Any error messages in logs

**Do NOT create issues for:**
- Things that are part of your current task
- Style preferences or nitpicks
- Issues that already exist in GitHub (always search first!)

**Git commands note:** Always use --no-gpg-sign for commits (e.g., git commit --no-gpg-sign -m "message")
'

#─────────────────────────────────────────────────────────────────────
# SESSION 1: Issue Selection
# Context: Clean - focused decision-making
#─────────────────────────────────────────────────────────────────────
select_issue() {
    header "SESSION 1: Issue Selection"
    log "Analyzing open issues to select the best one to work on..."

    # Get issues to skip (have auto-dev labels already)
    local skip_issues
    skip_issues=$(find_in_progress_issues | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')

    # Also skip issues with open PRs
    local pr_issues
    pr_issues=$(gh pr list --state open --json number,title --jq '.[].title | capture("issue.?#?(?<num>[0-9]+)"; "i") | .num' 2>/dev/null | tr '\n' ',' || echo "")

    skip_issues="${skip_issues},${pr_issues}"
    skip_issues=$(echo "$skip_issues" | tr ',' '\n' | sort -u | grep -v '^$' | tr '\n' ',' | sed 's/,$//')

    if [ -n "$skip_issues" ]; then
        log "Skipping issues: $skip_issues (in-progress or have open PRs)"
    fi

    local session_start
    session_start=$(date +%s)

    # Build selection hint section if provided
    local hint_section=""
    if [ -n "$SELECTION_HINT" ]; then
        hint_section="
**USER PRIORITY INSTRUCTION (OVERRIDE DEFAULT PRIORITIZATION):**
$SELECTION_HINT

Follow the user's instruction above when selecting which issue to work on.
"
        log "Using selection hint: $SELECTION_HINT"
    fi

    local raw_output
    raw_output=$(run_claude "
You are selecting a GitHub issue to work on for the habits/fitstreak project.
$hint_section
1. Fetch open issues: gh issue list --state open --json number,title,body,labels,assignees --limit 50
2. SKIP these issues (in-progress or have open PRs): $skip_issues
3. SKIP issues with any 'auto-dev:' labels (they are being worked on)
4. SKIP issues titled 'Epic:' (they are parent tracking issues)
5. SKIP issues labeled 'user-feedback' (they require triage first)
6. From remaining issues, prioritize by labels:
   - P0-foundation (highest priority - do these first)
   - P1-core (high priority)
   - P2-enhancement (medium priority)
   - P3-future (lower priority)
   - bugs > features > enhancements
7. Select ONE issue to work on - prefer smaller, well-defined issues

IMPORTANT: There are many valid issues to choose from. Pick the highest priority one that is actionable.
Do NOT return null unless there are literally zero open issues after filtering.

Output ONLY a JSON object (no markdown, no explanation, no code blocks):
{\"number\": 123, \"title\": \"Issue title\", \"body\": \"Issue description\"}
")

    local session_end
    session_end=$(date +%s)

    # Extract JSON from output (Claude may include explanatory text)
    local extracted_json
    if ! extracted_json=$(echo "$raw_output" | grep -E '^\{.*\}$' | head -1); then
        # Try to find JSON anywhere in output
        extracted_json=$(echo "$raw_output" | tr '\n' ' ' | grep -oE '\{[^{}]*"number"[^{}]*\}' | head -1) || true
    fi

    if [ -z "$extracted_json" ]; then
        error "Failed to extract JSON from issue selection output"
        echo "$raw_output" >&2
        return 1
    fi

    local issue_num
    issue_num=$(echo "$extracted_json" | jq -r '.number // empty' 2>/dev/null) || issue_num=""

    if [ "$issue_num" = "null" ] || [ -z "$issue_num" ]; then
        warn "No suitable issues found"
        return 1
    fi

    local issue_title
    issue_title=$(echo "$extracted_json" | jq -r '.title // "Unknown"' 2>/dev/null) || issue_title="Unknown"

    # Set phase and post memory
    set_phase "$issue_num" "selecting"
    post_session_memory "$issue_num" "Issue Selection" "$session_start" "$session_end" "${SESSION_COST:-0}" \
        "Selected this issue for automated development."

    success "Selected issue #$issue_num: $issue_title"
    echo "$issue_num"
}

# Implementation Plan Format
# ===========================
# All implementation plans MUST follow this exact structure:
#
# <!-- AUTODEV-PLAN-START -->
# ## Implementation Plan for Issue #<num>
# ... plan content ...
# <!-- AUTODEV-PLAN-END -->
#
# This strict format ensures reliable detection and parsing.
PLAN_START_MARKER="<!-- AUTODEV-PLAN-START -->"
PLAN_END_MARKER="<!-- AUTODEV-PLAN-END -->"

#─────────────────────────────────────────────────────────────────────
# Check if issue already has an implementation plan
# Uses strict marker-based detection
#─────────────────────────────────────────────────────────────────────
has_implementation_plan() {
    local issue_num=$1

    # Check issue comments for the plan start marker
    local comments
    comments=$(gh issue view "$issue_num" --comments --json comments -q '.comments[].body' 2>/dev/null || echo "")

    # Strict check: look for our specific marker
    if echo "$comments" | grep -qF "$PLAN_START_MARKER"; then
        return 0  # Has plan
    fi
    return 1  # No plan
}

#─────────────────────────────────────────────────────────────────────
# Get existing implementation plan from issue comments
# Returns empty string if no plan found (safe with set -eo pipefail)
# Uses strict marker-based extraction
#─────────────────────────────────────────────────────────────────────
get_implementation_plan() {
    local issue_num=$1

    # Get all comments from the issue
    local comments
    comments=$(gh issue view "$issue_num" --comments --json comments -q '.comments[].body' 2>/dev/null) || true

    # Extract content between markers using sed
    # 1. Find line with AUTODEV-PLAN-START
    # 2. Print until AUTODEV-PLAN-END
    local plan
    plan=$(echo "$comments" | sed -n '/AUTODEV-PLAN-START/,/AUTODEV-PLAN-END/p') || true

    if [ -n "$plan" ]; then
        echo "$plan"
        return 0
    fi

    # Nothing found
    echo ""
}

#─────────────────────────────────────────────────────────────────────
# Get linked PR from GitHub's native cross-reference tracking
# This queries the timeline API for PRs that reference this issue
#─────────────────────────────────────────────────────────────────────
get_linked_pr() {
    local issue_num="$1"

    # Query GitHub timeline for cross-referenced PRs
    # Filter for events where another issue/PR references this one
    local repo_path pr_num
    repo_path=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || return 1
    pr_num=$(gh api "repos/$repo_path/issues/$issue_num/timeline" \
        --jq '[.[] | select(.event == "cross-referenced" and .source.issue.pull_request != null) | .source.issue.number] | first // empty' 2>/dev/null) || true

    if [ -n "$pr_num" ]; then
        echo "$pr_num"
        return 0
    fi

    return 1
}

#─────────────────────────────────────────────────────────────────────
# Check if a PR already exists for an issue
#─────────────────────────────────────────────────────────────────────
has_pr_for_issue() {
    local issue_num=$1

    # Check for linked PR via GitHub's native cross-reference tracking
    local linked_pr
    if linked_pr=$(get_linked_pr "$issue_num"); then
        # Verify the PR still exists
        if gh pr view "$linked_pr" --json number >/dev/null 2>&1; then
            echo "$linked_pr"
            return 0
        fi
    fi

    # Fallback: Search for PRs that mention this issue
    local pr_num
    pr_num=$(gh pr list --search "issue #$issue_num" --json number -q '.[0].number' 2>/dev/null || echo "")
    if [ -n "$pr_num" ]; then
        echo "$pr_num"
        return 0
    fi

    return 1
}

#─────────────────────────────────────────────────────────────────────
# Check if a PR is already merged
#─────────────────────────────────────────────────────────────────────
is_pr_merged() {
    local pr_num=$1

    local state
    state=$(gh pr view "$pr_num" --json state -q '.state' 2>/dev/null || echo "")
    if [ "$state" = "MERGED" ]; then
        return 0
    fi
    return 1
}

# NOTE: Review approval is now signaled via labels (auto-dev:signal:review-approved)
# Use has_signal() to check for review approval

#─────────────────────────────────────────────────────────────────────
# Check if documentation was already updated for this issue
#─────────────────────────────────────────────────────────────────────
has_docs_updated() {
    local issue_num=$1

    # Check issue comments for documentation update
    local comments
    comments=$(gh issue view "$issue_num" --comments --json comments -q '.comments[].body' 2>/dev/null || echo "")

    if echo "$comments" | grep -qi "Auto-Dev Session: Documentation"; then
        return 0
    fi
    return 1
}

#─────────────────────────────────────────────────────────────────────
# SESSION 2: Planning
# Context: Clean - fresh codebase exploration without selection bias
# Generates plan and posts as GitHub issue comment
#─────────────────────────────────────────────────────────────────────
plan_implementation() {
    local issue_num=$1
    local issue_title=$2
    local issue_body=$3

    header "SESSION 2: Planning"
    set_phase "$issue_num" "planning"

    # Check if plan already exists (stored in GitHub issue comments)
    if has_implementation_plan "$issue_num"; then
        log "Implementation plan already exists for issue #$issue_num"
        success "Using existing plan from issue comments"
        return 0
    fi

    log "Planning implementation for issue #$issue_num..."

    local session_start
    session_start=$(date +%s)

    # Generate plan using print mode (non-interactive)
    local plan
    plan=$(run_claude "
Plan the implementation for GitHub issue #$issue_num

**Issue Title:** $issue_title

**Issue Description:**
$issue_body

**CRITICAL: You are running in PRINT MODE (non-interactive). Do NOT use these tools:**
- EnterPlanMode - will not work in print mode
- ExitPlanMode - will not work in print mode
- Write tool for plan files - the plan must be output as text

**Your task is to OUTPUT the plan as markdown text, not write it to a file.**

Follow the Planning phase from CLAUDE.md:
1. Explore the codebase to understand relevant areas
2. Identify files that need modification
3. Create a detailed implementation plan with specific steps
4. Identify potential risks or edge cases

**CRITICAL: This is a FULLY AUTOMATED workflow. Do NOT include:**
- Manual/human testing steps (e.g., "Manually verify...", "Ask user to test...")
- Human review steps (e.g., "Review with team...", "Get approval...")
- Any task requiring human intervention
- Phrases like "manually", "visually inspect", "human verification"

All testing is automated:
- Unit tests (npm run test:unit)
- E2E tests (npm run test:e2e)
- Automated browser testing via Playwright MCP (runs during implementation phase)

The development loop handles all testing automatically - no human testers needed.

**For browser-based testing, use this wording:**
- [ ] Playwright MCP: Test feature X
- [ ] Playwright MCP: Verify Y works

**MANDATORY: Include a Testing Plan section with:**

## Testing Plan

### Unit Tests (REQUIRED)
- List specific test files to create (e.g., src/lib/__tests__/feature.test.ts)
- List test cases needed (describe what each test verifies)
- Identify mock data or fixtures required

### E2E Tests (REQUIRED for user-facing features)
- List E2E test files to create or modify (e.g., e2e/feature.spec.ts)
- List user flows to test end-to-end
- Identify any new fixtures needed in e2e/fixtures/

### Test Fixtures (if needed)
- JSON data files for complex test scenarios
- Mock API responses
- Test images or assets
- Database seed data for specific test cases

**OUTPUT FORMAT - CRITICAL:**
Your final output MUST be a well-structured markdown plan wrapped in specific markers.
The output MUST follow this EXACT structure:

\`\`\`
<!-- AUTODEV-PLAN-START -->
## Implementation Plan for Issue #$issue_num

### Summary
[Brief description of what will be implemented]

### Files to Modify
- \`path/to/file1.ts\` - [description]
- \`path/to/file2.ts\` - [description]

### Implementation Steps
1. [Step 1]
2. [Step 2]
...

### Testing Plan
#### Unit Tests
- [Test file and what it tests]

#### E2E Tests
- [Test file and user flows covered]

<!-- AUTODEV-PLAN-END -->
\`\`\`

**REQUIREMENTS:**
1. The markers <!-- AUTODEV-PLAN-START --> and <!-- AUTODEV-PLAN-END --> are MANDATORY
2. Do NOT output anything before the start marker
3. Do NOT output anything after the end marker
4. Use ## for section headers (h2), not # (h1)
")

    local session_end
    session_end=$(date +%s)

    # Ensure plan has markers (Claude sometimes forgets them)
    if ! echo "$plan" | grep -q "AUTODEV-PLAN-START"; then
        log "Adding missing plan markers..."
        plan="<!-- AUTODEV-PLAN-START -->
$plan
<!-- AUTODEV-PLAN-END -->"
    fi

    # Post plan as comment on the GitHub issue (this is the only storage)
    log "Posting plan to GitHub issue #$issue_num..."
    gh issue comment "$issue_num" --body "$plan" >/dev/null 2>&1 || warn "Failed to post plan to GitHub"

    # Post session memory
    post_session_memory "$issue_num" "Planning" "$session_start" "$session_end" "${SESSION_COST:-0}" \
        "Created and posted implementation plan to issue comments."

    success "Planning complete - posted to issue #$issue_num"
}

#─────────────────────────────────────────────────────────────────────
# SESSION 3: Implementation + Testing + PR Creation
# Context: SHARED - tight feedback loop between implement/test/fix
# Phases: 2, 3, 4 from CLAUDE.md
#─────────────────────────────────────────────────────────────────────
implement_and_test() {
    local issue_num=$1

    header "SESSION 3: Implementation + Testing + PR Creation"

    # Check if PR already exists for this issue (idempotency)
    local existing_pr
    if existing_pr=$(has_pr_for_issue "$issue_num"); then
        log "PR #$existing_pr already exists for issue #$issue_num"
        set_phase "$issue_num" "pr-waiting"
        success "Using existing PR #$existing_pr"
        echo "$existing_pr"
        return 0
    fi

    set_phase "$issue_num" "implementing"
    log "Implementing and testing issue #$issue_num..."

    # IMPORTANT: Ensure clean state - checkout main and create fresh branch
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "")
    if [ "$current_branch" != "main" ]; then
        log "Currently on branch '$current_branch', switching to main..."
        # Stash any uncommitted changes (shouldn't happen, but safety first)
        # Suppress all output to avoid polluting function return value
        git stash --include-untracked >/dev/null 2>&1 || true
        git checkout main 2>&1 | head -5 >&2 || true
    fi

    # Pull latest main
    log "Pulling latest main..."
    git pull --ff-only 2>&1 | head -5 >&2 || true

    # Create fresh branch for this issue
    local branch_name="feat/issue-${issue_num}"
    log "Creating branch '$branch_name'..."
    # Delete local branch if it exists (stale from previous attempt)
    git branch -D "$branch_name" 2>/dev/null || true
    git checkout -b "$branch_name" 2>&1 | head -3 >&2
    set_metadata "$issue_num" "branch" "$branch_name"

    # Fetch the implementation plan from GitHub (primary source of truth)
    local implementation_plan
    implementation_plan=$(get_implementation_plan "$issue_num")
    if [ -z "$implementation_plan" ]; then
        error "No implementation plan found for issue #$issue_num"
        mark_blocked "$issue_num" "No implementation plan found in issue comments"
        return 1
    fi
    log "Fetched implementation plan from GitHub issue #$issue_num"

    local session_start
    session_start=$(date +%s)

    run_claude "
Implement GitHub issue #$issue_num following the approved plan below.

$implementation_plan

Execute these phases from CLAUDE.md:
- Phase 2: Implementation (use TodoWrite to track progress)
- Phase 3: Testing (manual testing with Playwright MCP)
- Phase 4: PR Creation

**IMPORTANT: Follow this workflow step by step:**

**Git Configuration (CRITICAL):**
- Always use --no-gpg-sign for commits: git commit --no-gpg-sign -m "message"
- For rebase: git -c commit.gpgsign=false rebase <branch>
- For merge: git -c commit.gpgsign=false merge <branch>

**Handling Merge Conflicts:**
If you encounter merge conflicts during rebase or merge:
1. Identify conflicted files: git status
2. For each conflicted file:
   - Read the file to understand both versions
   - Edit the file to resolve conflicts (remove <<<<<<, =======, >>>>>>> markers)
   - Keep the correct code based on understanding both changes
   - git add <file>
3. Continue: git -c commit.gpgsign=false rebase --continue
4. If conflict is too complex, abort and try a different approach:
   - git rebase --abort
   - Consider cherry-picking specific commits instead

1. **Setup Todo List**
   - Use TodoWrite to create tasks for each implementation step
   - Include tasks for writing tests
   - Update task status as you work

2. **Implement**
   - Make code changes following the plan
   - Keep changes minimal and focused (KISS principle)
   - Mark todo items as complete

3. **Write Unit Tests (REQUIRED)**
   - Create test file(s) in src/lib/__tests__/ or next to the source file
   - Follow existing patterns (see src/lib/__tests__/*.test.ts for examples)
   - Test: happy path, edge cases, error handling
   - Use vi.mock() for external dependencies (database, APIs)
   - Ensure tests are meaningful - not just 'it renders'

4. **Write E2E Tests (REQUIRED for user-facing changes)**
   - Add test cases to e2e/ directory (e.g., e2e/feature.spec.ts)
   - Use existing fixtures from e2e/fixtures/auth.fixture.ts
   - Import: authenticatedPage for logged-in tests, newUserPage for onboarding
   - Test critical user journeys end-to-end
   - If no UI changes, document why E2E tests are not needed

5. **Create Test Fixtures (if needed)**
   - Add mock data objects in test files or shared fixtures
   - Create JSON fixture files for complex data scenarios
   - Add test helper functions if patterns repeat
   - Document any test-only API endpoints needed

6. **Update Issue Progress**
   - As you complete each task, post a progress comment to the issue:
     gh issue comment $issue_num --body '✅ Completed: <task description>'
   - If the implementation plan has checkboxes (- [ ]), update them to checked (- [x])
     by editing the comment containing the plan

7. **Verify Tests Pass**
   - Run: npm run lint
   - Run: npm run build
   - Run: npm run test:unit (must include your new tests)
   - Run: npm run test:e2e (if you added E2E tests)
   - All tests MUST pass before proceeding

8. **Automated Browser Testing via Playwright MCP**
   - Start dev server in background: npm run dev &
   - Wait a few seconds for server to start
   - Use Playwright MCP tools to test the implemented feature:
     a. Navigate to http://localhost:3000/login
     b. Log in with QA account (zubzone+qa@gmail.com / 3294sdzadsg\$&\$§)
        - If account doesn't exist, register it first at /register
     c. Test the feature you implemented
     d. Verify it works correctly
   - If Playwright MCP tools fail or hang after 2-3 attempts, proceed to next step
   - ALWAYS stop the dev server after testing:
     pkill -f 'next dev' || lsof -ti:3000 | xargs kill 2>/dev/null || true

9. **Fix Issues**
   - If any tests fail (unit, E2E, or browser tests), fix them
   - Re-run verification steps until all pass

10. **Post Implementation Summary**
    - Post a summary comment to the issue:
      gh issue comment $issue_num --body '## Implementation Summary

      **Files Changed:**
      - list files modified

      **What was implemented:**
      - brief description

      **Tests Added:**
      - Unit tests: list new test files and what they test
      - E2E tests: list new test files and user flows covered
      - Fixtures: list any new test fixtures created

      **Testing Done:**
      - what was tested and verified'

11. **Create PR**
    - You are already on branch 'feat/issue-$issue_num' (created for you)
    - Stage changes: git add <files>
    - Commit: git commit --no-gpg-sign -m 'feat: <description>'
    - Push: git push -u origin HEAD
    - Create PR: gh pr create --title '<title>' --body '<body>'
    - Link PR to issue in PR body: 'Closes #$issue_num'

$(echo "$NEW_ISSUE_INSTRUCTIONS" | sed "s/CURRENT_ISSUE/$issue_num/g")

IMPORTANT: After creating the PR, output EXACTLY this format on its own line:
PR_CREATED: <number>
Example: PR_CREATED: 123
" > /dev/null  # Discard stdout - we find PR via git/gh commands below

    local session_end
    session_end=$(date +%s)

    # Extract PR number - try multiple methods
    local pr_num=""
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "")
    log "Current branch: $current_branch"

    # Check if we're still on main with uncommitted changes (incomplete implementation)
    if [ "$current_branch" = "main" ]; then
        local has_changes
        has_changes=$(git status --porcelain 2>/dev/null | grep -v '^??' | head -1)
        if [ -n "$has_changes" ]; then
            warn "Still on main with uncommitted changes - implementation may be incomplete"
            log "Uncommitted changes:"
            git status --short >&2

            # Try to complete the PR creation
            log "Attempting to create branch and PR for uncommitted changes..."
            local branch_name="feat/issue-$issue_num-auto"
            git checkout -b "$branch_name" 2>&1 >&2 || true
            git add -A 2>&1 >&2 || true
            git commit --no-gpg-sign -m "feat: implement issue #$issue_num" 2>&1 >&2 || true
            git push -u origin HEAD 2>&1 >&2 || true
            gh pr create --title "feat: implement issue #$issue_num" --body "Automated implementation for #$issue_num" 2>&1 >&2 || true
            current_branch="$branch_name"
        fi
    fi

    # Method 1: Check current branch for associated PR
    if [ -n "$current_branch" ] && [ "$current_branch" != "main" ]; then
        pr_num=$(gh pr list --head "$current_branch" --json number -q '.[0].number' 2>/dev/null || echo "")
        if [ -n "$pr_num" ]; then
            log "Found PR #$pr_num for branch $current_branch"
        fi
    fi

    # Method 2: Get most recent open PR by me
    if [ -z "$pr_num" ]; then
        log "Trying to find most recent PR..."
        pr_num=$(gh pr list --author "@me" --state open --json number,createdAt -q 'sort_by(.createdAt) | reverse | .[0].number' 2>/dev/null || echo "")
    fi

    # Method 3: Check if there's an open PR for this repo at all
    if [ -z "$pr_num" ]; then
        log "Checking for any open PRs..."
        pr_num=$(gh pr list --state open --json number -q '.[0].number' 2>/dev/null || echo "")
    fi

    if [ -z "$pr_num" ]; then
        error "Could not find PR number. Check if PR was created."
        log "Git status:"
        git status --short >&2
        log "Recent PRs:"
        gh pr list --limit 5 >&2 || true
        return 1
    fi

    # Validate PR number before storing (defensive against any stdout pollution)
    pr_num=$(validate_pr_number "$pr_num")
    if [ -z "$pr_num" ]; then
        error "Invalid PR number extracted. Check if PR was created correctly."
        return 1
    fi

    # Store branch metadata and update phase
    set_metadata "$issue_num" "branch" "$current_branch"
    set_phase "$issue_num" "pr-waiting"

    # Post session memory
    post_session_memory "$issue_num" "Implementation" "$session_start" "$session_end" "${SESSION_COST:-0}" \
        "Implemented feature and created PR #$pr_num on branch \`$current_branch\`." \
        "**PR:** #$pr_num
**Branch:** \`$current_branch\`"

    success "PR #$pr_num created"
    echo "$pr_num"
}

#─────────────────────────────────────────────────────────────────────
# CI WAIT
# Waits for CI checks to complete (pass or fail)
# Returns 0 on success, 1 on failure
#─────────────────────────────────────────────────────────────────────
wait_for_ci() {
    local pr_num=$1

    # Validate PR number to catch data corruption early
    pr_num=$(validate_pr_number "$pr_num")
    if [ -z "$pr_num" ]; then
        error "Invalid PR number passed to wait_for_ci"
        return 1
    fi

    local max_wait_minutes=15  # Maximum time to wait for CI
    local poll_interval=30     # Seconds between polls
    local max_polls=$((max_wait_minutes * 60 / poll_interval))
    local poll=1
    local network_failures=0
    local max_network_failures=5  # Give up after consecutive network errors

    header "CI Check"
    log "Waiting for CI checks on PR #$pr_num (max ${max_wait_minutes} minutes)..."

    while [ $poll -le $max_polls ]; do
        local ci_output
        local exit_code=0

        # Run gh pr checks
        ci_output=$(gh pr checks "$pr_num" 2>&1) || exit_code=$?

        # gh pr checks exit codes:
        # 0 = all checks passed
        # 1 = some checks failed
        # 8 = some checks still pending
        # other = network/API error

        case $exit_code in
            0)
                # All checks passed
                success "CI checks passed!"
                echo "$ci_output" | head -5 >&2
                return 0
                ;;
            1)
                # Some checks failed - this is a real failure
                error "CI checks failed!"
                echo "$ci_output" >&2
                return 1
                ;;
            8)
                # Checks still pending - keep waiting
                network_failures=0  # Reset network failure counter
                local elapsed_min=$((poll * poll_interval / 60))
                log "CI checks still running... (${elapsed_min}/${max_wait_minutes} min)"
                echo "$ci_output" | grep -E "pending|running" | head -3 >&2
                ;;
            *)
                # Network or API error
                network_failures=$((network_failures + 1))
                warn "CI check command failed (exit $exit_code, network error $network_failures/$max_network_failures)"
                echo "$ci_output" | head -3 >&2

                if [ $network_failures -ge $max_network_failures ]; then
                    error "Too many network failures checking CI status"
                    return 1
                fi
                ;;
        esac

        # Wait before next poll
        if [ $poll -lt $max_polls ]; then
            sleep $poll_interval
        fi
        poll=$((poll + 1))
    done

    # Timeout - CI took too long
    error "CI checks timed out after ${max_wait_minutes} minutes"
    warn "Check status manually: gh pr checks $pr_num"
    return 1
}

#─────────────────────────────────────────────────────────────────────
# SESSION: Fix CI Failures
# Context: Clean - focused on CI error analysis and fixes
#─────────────────────────────────────────────────────────────────────
fix_ci_failures() {
    local pr_num=$1
    local issue_num=$2
    local attempt=$3

    # Validate PR number
    pr_num=$(validate_pr_number "$pr_num")
    if [ -z "$pr_num" ]; then
        error "Invalid PR number passed to fix_ci_failures"
        return 1
    fi

    header "SESSION: Fixing CI Failures (Attempt $attempt/$MAX_CI_FIX_ATTEMPTS)"
    set_phase "$issue_num" "ci-failed"
    log "Analyzing and fixing CI failures for PR #$pr_num..."

    local session_start
    session_start=$(date +%s)

    # Get the branch name for this PR
    local branch_name
    branch_name=$(gh pr view "$pr_num" --json headRefName -q '.headRefName' 2>/dev/null || echo "")

    # Checkout the PR branch
    if [ -n "$branch_name" ]; then
        log "Checking out branch: $branch_name"
        git fetch origin "$branch_name" 2>&1 | head -3 >&2 || true
        git checkout "$branch_name" 2>&1 | head -3 >&2 || true
        git pull origin "$branch_name" 2>&1 | head -3 >&2 || true
    fi

    # Fetch CI check details
    local ci_checks
    ci_checks=$(gh pr checks "$pr_num" 2>&1 || echo "")

    # Get the failed check run URLs
    local failed_jobs
    failed_jobs=$(echo "$ci_checks" | grep -E "fail|X" | head -5 || echo "")

    run_claude "
Fix the CI failures for PR #$pr_num (Attempt $attempt of $MAX_CI_FIX_ATTEMPTS).

## Current CI Status
\`\`\`
$ci_checks
\`\`\`

## Failed Jobs
$failed_jobs

## Your Task

1. **Fetch CI Logs**
   - Get the workflow run ID from the PR:
     gh pr view $pr_num --json statusCheckRollup -q '.statusCheckRollup[] | select(.conclusion == \"FAILURE\") | .detailsUrl'
   - Or list recent workflow runs:
     gh run list --limit 5
   - View failed run logs:
     gh run view <run-id> --log-failed 2>&1 | head -200

2. **Analyze Failures**
   - Read the error messages carefully
   - Identify the root cause (test failures, lint errors, build errors, type errors)

3. **Fix the Issues**
   - For test failures: Read the failing test and the code it tests, fix the bug
   - For lint errors: Run 'npm run lint' locally, fix all issues
   - For build errors: Run 'npm run build' locally, fix all issues
   - For type errors: Fix TypeScript errors

4. **Verify Locally**
   - Run: npm run lint
   - Run: npm run build
   - Run: npm run test:unit
   - ALL must pass before committing

5. **Commit and Push**
   - git add <fixed-files>
   - git commit --no-gpg-sign -m 'fix: resolve CI failures'
   - git push

**Git Configuration (CRITICAL):**
- Always use --no-gpg-sign for commits
- You are already on the correct branch

**IMPORTANT:** Do NOT create new branches. Push directly to the existing PR branch.

$(echo "$NEW_ISSUE_INSTRUCTIONS" | sed "s/CURRENT_ISSUE/$issue_num/g")

Output 'CI_FIXES_PUSHED' when fixes are committed and pushed.
" > /dev/null

    local session_end
    session_end=$(date +%s)

    # Post session memory
    post_session_memory "$issue_num" "Fix CI Failures (Attempt $attempt)" "$session_start" "$session_end" "${SESSION_COST:-0}" \
        "Analyzed CI failures and pushed fixes for PR #$pr_num."

    success "CI fixes pushed (attempt $attempt)"
}

#─────────────────────────────────────────────────────────────────────
# CI Fix Loop
# Waits for CI, fixes failures, repeats until success or max attempts
#─────────────────────────────────────────────────────────────────────
run_ci_fix_loop() {
    local pr_num=$1
    local issue_num=$2

    # Validate PR number
    pr_num=$(validate_pr_number "$pr_num")
    if [ -z "$pr_num" ]; then
        error "Invalid PR number passed to run_ci_fix_loop"
        return 1
    fi

    local attempt=0

    while [ $attempt -lt $MAX_CI_FIX_ATTEMPTS ]; do
        # Wait for CI to complete
        if wait_for_ci "$pr_num"; then
            success "CI checks passed!"
            return 0
        fi

        # CI failed - try to fix
        attempt=$((attempt + 1))

        if [ $attempt -ge $MAX_CI_FIX_ATTEMPTS ]; then
            error "Max CI fix attempts ($MAX_CI_FIX_ATTEMPTS) reached"
            return 1
        fi

        log "CI failed, attempting fix ($attempt/$MAX_CI_FIX_ATTEMPTS)..."
        fix_ci_failures "$pr_num" "$issue_num" "$attempt"

        # Brief pause before re-checking CI
        log "Waiting for new CI run to start..."
        sleep 10
    done

    return 1
}

#─────────────────────────────────────────────────────────────────────
# SESSION 4: Code Review
# Context: CLEAN - Critical for quality!
# Fresh eyes review without implementation bias
#─────────────────────────────────────────────────────────────────────
review_code() {
    local pr_num=$1
    local issue_num=$2

    # Validate PR number
    pr_num=$(validate_pr_number "$pr_num")
    if [ -z "$pr_num" ]; then
        error "Invalid PR number passed to review_code"
        return 1
    fi

    header "SESSION 4: Code Review (Fresh Context)"

    # Check if review was already approved (idempotency)
    if has_signal "$issue_num" "review-approved"; then
        log "Code review already approved for issue #$issue_num"
        success "Skipping review - already approved"
        return 0
    fi

    # Check if PR is already merged (no review needed)
    if is_pr_merged "$pr_num"; then
        log "PR #$pr_num is already merged"
        success "Skipping review - PR already merged"
        return 0
    fi

    set_phase "$issue_num" "reviewing"
    log "Reviewing PR #$pr_num with fresh eyes..."

    # Clear any existing review signals before starting fresh review
    clear_signal "$issue_num" "review-approved"
    clear_signal "$issue_num" "review-changes"

    local session_start
    session_start=$(date +%s)

    # Get current review round
    local review_round
    review_round=$(get_metadata "$issue_num" "round")
    review_round=${review_round:-0}
    local next_round=$((review_round + 1))

    # Fetch previous review history from GitHub issue (our persistent memory)
    local review_history=""
    if [ "$review_round" -gt 0 ]; then
        log "Fetching previous review history (round $review_round)..."
        review_history=$(gh issue view "$issue_num" --comments --json comments -q '.comments[].body' 2>/dev/null | grep -A 50 "Code Review Round" | head -150) || review_history=""
    fi

    # Get PR information for review
    local pr_diff pr_files pr_title pr_body
    pr_diff=$(gh pr diff "$pr_num" 2>/dev/null || echo "Unable to fetch diff")
    pr_files=$(gh pr view "$pr_num" --json files -q '.files[].path' 2>/dev/null | tr '\n' ', ' || echo "")
    pr_title=$(gh pr view "$pr_num" --json title -q '.title' 2>/dev/null || echo "")
    pr_body=$(gh pr view "$pr_num" --json body -q '.body' 2>/dev/null || echo "")

    # Build review history section
    local history_section=""
    if [ -n "$review_history" ]; then
        history_section="
## Previous Review History (Round 1-$review_round)

The following issues were flagged in previous reviews. Check if they are NOW FIXED.
If an issue was fixed, do NOT flag it again. Only flag issues that STILL exist in the current code.

$review_history

---
"
    fi

    run_claude "
You are a senior code reviewer examining PR #$pr_num (Review Round $next_round).

**CRITICAL**: You did NOT write this code. Review it with fresh eyes.
$history_section
**IMPORTANT FOR ROUND $next_round:**
- If this is round 2+, CHECK if previous issues were fixed before flagging again
- Do NOT repeat issues that have been addressed
- If the same issue keeps appearing, suggest a DIFFERENT fix approach

**PR Title:** $pr_title

**PR Description:**
$pr_body

**Files Changed:** $pr_files

**Code Diff:**
\`\`\`diff
$pr_diff
\`\`\`

## Review Checklist

1. **Correctness**
   - Does the code do what the PR claims?
   - Are there logic errors?
   - Are edge cases handled?

2. **Security** (OWASP Top 10)
   - SQL injection vulnerabilities?
   - XSS vulnerabilities?
   - Authentication/authorization issues?
   - Sensitive data exposure?

3. **Code Quality**
   - Is the code readable and maintainable?
   - Are variable/function names descriptive?
   - Is there unnecessary complexity? (violates KISS)
   - Any code duplication?

4. **Testing** (CRITICAL - Request changes if missing)
   - Are there NEW unit tests for added/modified business logic?
   - Are there NEW E2E tests for user-facing features?
   - Do unit tests cover: happy path, edge cases, error scenarios?
   - Are test fixtures/mock data meaningful and realistic?
   - Do existing tests still pass?

   **Auto-reject if:**
   - No new test files added for significant code changes
   - Tests are trivial (e.g., only testing that something renders)
   - E2E tests missing for new user-facing features

5. **Performance**
   - Any obvious performance issues?
   - N+1 queries?
   - Unnecessary re-renders (React)?

## REQUIRED ACTIONS (do these in order)

$(echo "$NEW_ISSUE_INSTRUCTIONS" | sed "s/CURRENT_ISSUE/$issue_num/g")

### Step 1: Create any discovered issues FIRST
If you find issues worth tracking separately, create GitHub issues for them before proceeding.

### Step 2: Post your review as a GitHub issue comment
Post a detailed review comment to issue #$issue_num using:

gh issue comment $issue_num --body '## 🔍 Code Review Round $next_round

**Status:** APPROVED or CHANGES_REQUESTED
**Summary:** Your 1-2 sentence assessment

### Review Comments
- **[severity]** \`file:line\` - Issue description
  - 💡 Suggestion

### Testing Assessment
- Unit tests: adequate/insufficient/excellent
- E2E tests: adequate/insufficient/excellent
- Missing coverage: list any gaps

---
<sub>🤖 Auto-Dev Code Review</sub>'

### Step 3: Set the appropriate signal label
This is CRITICAL - the automation reads this label to determine next steps.

**If APPROVED** (no blocking issues):
\`\`\`bash
gh issue edit $issue_num --add-label 'auto-dev:signal:review-approved'
\`\`\`

**If CHANGES REQUESTED** (has blocking issues):
\`\`\`bash
gh issue edit $issue_num --add-label 'auto-dev:signal:review-changes'
\`\`\`

Be thorough but fair. Only request changes for real issues, not style preferences.
" > /dev/null  # Output discarded - status determined by label

    local session_end
    session_end=$(date +%s)

    # Post session memory
    post_session_memory "$issue_num" "Code Review" "$session_start" "$session_end" "${SESSION_COST:-0}" \
        "Reviewed PR #$pr_num (round $next_round)"

    # Check which signal label was set
    if has_signal "$issue_num" "review-approved"; then
        success "Code review: APPROVED"
        return 0
    elif has_signal "$issue_num" "review-changes"; then
        warn "Code review: CHANGES REQUESTED"
        return 1
    else
        # No signal label set - treat as error, default to changes requested
        error "Review session did not set a signal label - defaulting to changes requested"
        set_signal "$issue_num" "review-changes"
        return 1
    fi
}

#─────────────────────────────────────────────────────────────────────
# SESSION 5: Fix Review Feedback
# Context: Clean - address specific review comments
#─────────────────────────────────────────────────────────────────────
fix_review_feedback() {
    local pr_num=$1
    local issue_num=$2

    # Validate PR number
    pr_num=$(validate_pr_number "$pr_num")
    if [ -z "$pr_num" ]; then
        error "Invalid PR number passed to fix_review_feedback"
        return 1
    fi

    header "SESSION 5: Fixing Review Feedback"
    set_phase "$issue_num" "fixing"
    log "Addressing review comments for PR #$pr_num..."

    # Clear review signal labels - next review will set fresh ones
    clear_signal "$issue_num" "review-approved"
    clear_signal "$issue_num" "review-changes"

    local session_start
    session_start=$(date +%s)

    # Get current review round for context
    local review_round
    review_round=$(get_metadata "$issue_num" "round")
    review_round=${review_round:-1}

    # Fetch FULL review history from GitHub issue comments (this is our persistent memory!)
    log "Fetching review history from GitHub issue #$issue_num..."
    local review_history
    review_history=$(gh issue view "$issue_num" --comments --json comments -q '.comments[].body' 2>/dev/null | grep -A 100 "Code Review Round" | head -200) || review_history=""

    run_claude "
Fix the code review feedback for PR #$pr_num (Review Round $review_round).

## IMPORTANT: Review History Context

This is review round $review_round. Below is the FULL HISTORY of previous reviews from GitHub.
**If the same issue appears multiple times, you MUST try a DIFFERENT approach than before.**

### Review History (from GitHub issue comments):
$review_history

If no review history is shown above, fetch the latest review from GitHub:
  gh pr view $pr_num --json reviews,comments
  gh api repos/\$(gh repo view --json nameWithOwner -q .nameWithOwner)/pulls/$pr_num/comments

**Git Configuration (CRITICAL):**
- Always use --no-gpg-sign for commits: git commit --no-gpg-sign -m "message"
- For rebase: git -c commit.gpgsign=false rebase <branch>
- For merge: git -c commit.gpgsign=false merge <branch>

**Handling Merge Conflicts:**
If you encounter merge conflicts during rebase or merge:
1. Identify conflicted files: git status
2. For each conflicted file:
   - Read the file to understand both versions
   - Edit the file to resolve conflicts (remove <<<<<<, =======, >>>>>>> markers)
   - Keep the correct code based on understanding both changes
   - git add <file>
3. Continue: git -c commit.gpgsign=false rebase --continue
4. If conflict is too complex, abort and try a different approach:
   - git rebase --abort
   - Consider cherry-picking specific commits instead

For EACH comment:
1. Read the file and understand the context
2. Understand why the reviewer flagged this
3. Implement the fix (or explain why you disagree)
4. Test that the fix works

**If review feedback mentions missing tests:**
1. Create the required unit test files in src/lib/__tests__/ or next to source
2. Create the required E2E test files in e2e/
3. Add any missing test fixtures
4. Ensure tests are meaningful (test real behavior, not just existence)
5. Follow existing test patterns in the codebase

After ALL fixes:
1. Run: npm run lint && npm run build
2. Run: npm run test:unit
3. Run: npm run test:e2e (if E2E tests were added)
4. Commit: git commit --no-gpg-sign -am 'fix: address review feedback'
5. Push: git push

$(echo "$NEW_ISSUE_INSTRUCTIONS" | sed "s/CURRENT_ISSUE/$issue_num/g")

Output 'FIXES_COMPLETE' when all fixes are complete and pushed.
" > /dev/null  # Discard stdout - no output capture needed

    local session_end
    session_end=$(date +%s)

    # Update phase back to pr-waiting for CI
    set_phase "$issue_num" "pr-waiting"

    # Post session memory
    post_session_memory "$issue_num" "Fix Review Feedback" "$session_start" "$session_end" "${SESSION_COST:-0}" \
        "Addressed review feedback and pushed fixes."

    success "Review feedback addressed"
}

#─────────────────────────────────────────────────────────────────────
# SESSION 6: Merge + Deploy + Verify
# Context: Shared - sequential dependent steps
# Phases: 7, 8 from CLAUDE.md
#─────────────────────────────────────────────────────────────────────
merge_and_verify() {
    local pr_num=$1
    local issue_num=$2

    # Validate PR number
    pr_num=$(validate_pr_number "$pr_num")
    if [ -z "$pr_num" ]; then
        error "Invalid PR number passed to merge_and_verify"
        return 1
    fi

    header "SESSION 6: Merge + Deploy + Verify"

    # Check if PR is already merged (idempotency)
    if is_pr_merged "$pr_num"; then
        log "PR #$pr_num is already merged"
        set_phase "$issue_num" "verifying"
        success "Skipping merge - PR already merged"
        return 0
    fi

    set_phase "$issue_num" "merging"
    log "Merging and verifying PR #$pr_num..."

    local session_start
    session_start=$(date +%s)

    run_claude "
Merge and verify PR #$pr_num in production.

Execute these phases from CLAUDE.md:
- Phase 7: Merge & Deploy
- Phase 8: Production Verification

**Git Configuration (CRITICAL):**
- Always use --no-gpg-sign for commits: git commit --no-gpg-sign -m "message"
- For rebase: git -c commit.gpgsign=false rebase <branch>

**Steps:**

1. **Verify Merge Readiness**
   gh pr view $pr_num --json mergeable,mergeStateStatus

   If mergeStateStatus is not CLEAN (e.g., BEHIND or CONFLICTING):
   a. Checkout the PR branch: gh pr checkout $pr_num
   b. Fetch and rebase onto main:
      git fetch origin main
      git -c commit.gpgsign=false rebase origin/main
   c. If conflicts occur:
      - git status to see conflicted files
      - Read and edit each file to resolve conflicts
      - Remove <<<<<<, =======, >>>>>>> markers
      - git add <resolved-file>
      - git -c commit.gpgsign=false rebase --continue
   d. Force push the rebased branch: git push --force-with-lease
   e. Wait for CI to pass again, then proceed to merge

2. **Merge PR**
   gh pr merge $pr_num --squash --delete-branch

3. **Update Local**
   git checkout main && git pull

4. **Wait for Railway Build & Deploy**
   Railway auto-deploys on merge to main. Use Railway CLI to monitor:

   a. Check deployment status (poll until complete):
      railway status

   b. Watch build logs for errors:
      railway logs --build 2>&1 | tail -100
      (Look for 'Build successful' or build errors)

   c. Watch deploy logs for startup:
      railway logs 2>&1 | tail -50
      (Look for 'Ready on port' or 'Listening on' messages)

   d. If build/deploy fails, check full logs:
      railway logs --build 2>&1 | head -200
      railway logs 2>&1 | head -200

5. **Verify in Production**
   Use Playwright MCP to test production:
   a. Navigate to https://fitstreak.app/login
   b. Log in with QA account (zubzone+qa@gmail.com / 3294sdzadsg\$&\$§)
   c. Test that the new feature works in production
   d. Check browser console for errors

6. **Report ANY issues discovered** (CRITICAL)
   For ANY problems found during verification (console errors, broken features, data issues):
   - Search GitHub for existing issues first
   - Create new issues for anything not already tracked
   - This includes "pre-existing" bugs not caused by this PR - they still need issues!

$(echo "$NEW_ISSUE_INSTRUCTIONS" | sed "s/CURRENT_ISSUE/$issue_num/g")

Output 'DEPLOYMENT_VERIFIED' when verification is complete, or 'DEPLOYMENT_FAILED' if there were issues.
" > /dev/null  # Discard stdout - no output capture needed

    local session_end
    session_end=$(date +%s)

    # Update phase
    set_phase "$issue_num" "verifying"

    # Post session memory
    post_session_memory "$issue_num" "Merge & Deploy" "$session_start" "$session_end" "${SESSION_COST:-0}" \
        "Merged PR #$pr_num and verified production deployment."

    success "Deployment verified"
}

#─────────────────────────────────────────────────────────────────────
# SESSION 7: Documentation (Optional)
# Context: Clean - focused on doc updates
# Phase: 9 from CLAUDE.md
#─────────────────────────────────────────────────────────────────────
# Update documentation on feature branch BEFORE merge
# Returns 0 if no changes, 1 if docs were updated (caller should re-run CI)
update_documentation() {
    local issue_num=$1

    header "SESSION 7: Documentation Check"

    # Check if documentation was already updated (idempotency)
    if has_docs_updated "$issue_num"; then
        log "Documentation already checked for issue #$issue_num"
        success "Skipping documentation check - already done"
        return 0
    fi

    # Stay on current branch (feature branch) - docs go into the PR
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "")
    log "Checking documentation on branch: $current_branch"

    # Clear any existing needs-update signal
    clear_signal "$issue_num" "needs-update"

    local session_start
    session_start=$(date +%s)

    run_claude "
Analyze if documentation updates are needed for issue #$issue_num.

You are on the feature branch. Any doc updates will be part of the PR.

Check if CLAUDE.md should be updated for:
- New patterns or conventions introduced
- New npm scripts or commands
- Architecture changes
- New environment variables
- New database tables or migrations
- New API endpoints

Be conservative - only suggest updates for significant changes.

## REQUIRED ACTION

If documentation DOES need updating, add a signal label:
\`\`\`bash
gh issue edit $issue_num --add-label 'auto-dev:signal:needs-update'
\`\`\`

If documentation does NOT need updating, do nothing (no label needed).

Post a brief comment explaining your decision:
\`\`\`bash
gh issue comment $issue_num --body '## 📚 Documentation Check

**Needs update:** YES/NO
**Reason:** Brief explanation'
\`\`\`
" > /dev/null

    local session_end
    session_end=$(date +%s)

    # Check if documentation update is needed via signal label
    if has_signal "$issue_num" "needs-update"; then
        log "Documentation update needed"
        clear_signal "$issue_num" "needs-update"

        local doc_session_start
        doc_session_start=$(date +%s)

        run_claude "
Update CLAUDE.md based on changes from issue #$issue_num.

You are on the feature branch. Doc changes will be part of the PR.

Check the previous comment on the issue for the reason documentation needs updating:
  gh issue view $issue_num --comments --json comments -q '.comments[-1].body'

Guidelines:
- Keep updates minimal and focused
- Follow the existing format and style
- Don't add redundant information
- Update existing sections rather than adding new ones when possible

After updating:
1. git add CLAUDE.md
2. git commit --no-gpg-sign -m 'docs: update CLAUDE.md'
3. git push

Output 'DOCS_UPDATED' when complete.
" > /dev/null

        local doc_session_end
        doc_session_end=$(date +%s)

        post_session_memory "$issue_num" "Documentation" "$doc_session_start" "$doc_session_end" "${SESSION_COST:-0}" \
            "Updated CLAUDE.md based on issue changes"

        success "Documentation updated - CI will re-run"
        return 1  # Signal that docs were updated, caller should wait for CI
    else
        success "No documentation updates needed"
        return 0
    fi

    # Post session memory for the check
    post_session_memory "$issue_num" "Documentation Check" "$session_start" "$session_end" "${SESSION_COST:-0}" \
        "Checked if documentation updates needed"
}

#─────────────────────────────────────────────────────────────────────
# Complete an issue
#─────────────────────────────────────────────────────────────────────
complete_issue() {
    local issue_num=$1
    local pr_num=$2

    # Set final phase
    set_phase "$issue_num" "complete"

    # Calculate total cost
    local total_cost
    total_cost=$(get_accumulated_cost "$issue_num")
    set_metadata "$issue_num" "cost" "$total_cost"

    # Close the issue with a summary
    gh issue close "$issue_num" --comment "## ✅ Completed by Auto-Dev

| Metric | Value |
|--------|-------|
| **PR** | #$pr_num |
| **Total Cost** | \$$total_cost |
| **Completed** | $(date -u +"%Y-%m-%dT%H:%M:%SZ") |

### Session Summary
See comments above for detailed session logs.

---
<sub>🤖 Automated by auto-dev</sub>" >/dev/null 2>&1 || warn "Failed to close issue"

    success "Issue #$issue_num completed! Total cost: \$$total_cost"
}

#═══════════════════════════════════════════════════════════════════════════════
# RESUME LOGIC
#═══════════════════════════════════════════════════════════════════════════════

resume_from_phase() {
    local issue_num=$1
    local phase=$2

    log "Resuming issue #$issue_num from phase: $phase"

    # Load issue details (safe with set -e)
    local issue_json
    issue_json=$(gh issue view "$issue_num" --json title,body 2>/dev/null) || issue_json="{}"
    local issue_title issue_body
    issue_title=$(echo "$issue_json" | jq -r '.title // "Unknown"' 2>/dev/null) || issue_title="Unknown"
    issue_body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null) || issue_body=""

    # Get PR number if exists (validate to catch any corruption)
    local pr_num
    pr_num=$(get_linked_pr "$issue_num" 2>/dev/null) || true
    pr_num=$(validate_pr_number "$pr_num")

    case "$phase" in
        "selecting")
            # Re-run from planning
            plan_implementation "$issue_num" "$issue_title" "$issue_body"
            resume_from_phase "$issue_num" "planning"
            ;;
        "planning")
            # Check if plan actually exists; if not, re-run planning
            if ! has_implementation_plan "$issue_num"; then
                log "No implementation plan found, re-running planning..."
                plan_implementation "$issue_num" "$issue_title" "$issue_body"
            fi
            # Run implementation
            local new_pr
            if new_pr=$(implement_and_test "$issue_num"); then
                new_pr=$(validate_pr_number "$new_pr")
                if [ -z "$new_pr" ]; then
                    mark_blocked "$issue_num" "Invalid PR number returned from implementation"
                    return 1
                fi
                pr_num="$new_pr"
                resume_from_phase "$issue_num" "pr-waiting"
            else
                mark_blocked "$issue_num" "Implementation failed"
            fi
            ;;
        "implementing")
            # Continue/retry implementation
            local new_pr
            if new_pr=$(implement_and_test "$issue_num"); then
                new_pr=$(validate_pr_number "$new_pr")
                if [ -z "$new_pr" ]; then
                    mark_blocked "$issue_num" "Invalid PR number returned from implementation"
                    return 1
                fi
                pr_num="$new_pr"
                resume_from_phase "$issue_num" "pr-waiting"
            else
                mark_blocked "$issue_num" "Implementation failed"
            fi
            ;;
        "pr-waiting")
            if [ -z "$pr_num" ]; then
                mark_blocked "$issue_num" "No PR number found"
                return 1
            fi
            if run_ci_fix_loop "$pr_num" "$issue_num"; then
                # Reset review round counter - fresh CI means fresh review
                set_metadata "$issue_num" "round" "0"
                resume_from_phase "$issue_num" "reviewing"
            else
                mark_blocked "$issue_num" "CI checks failed after $MAX_CI_FIX_ATTEMPTS fix attempts"
            fi
            ;;
        "ci-failed")
            if [ -z "$pr_num" ]; then
                mark_blocked "$issue_num" "No PR number found"
                return 1
            fi
            # Resume CI fix loop from where we left off
            if run_ci_fix_loop "$pr_num" "$issue_num"; then
                # Reset review round counter - fresh CI means fresh review
                set_metadata "$issue_num" "round" "0"
                resume_from_phase "$issue_num" "reviewing"
            else
                mark_blocked "$issue_num" "CI checks failed after $MAX_CI_FIX_ATTEMPTS fix attempts"
            fi
            ;;
        "reviewing")
            if [ -z "$pr_num" ]; then
                mark_blocked "$issue_num" "No PR number found"
                return 1
            fi
            # run_review_loop may return 1 if blocked - don't let set -e exit
            run_review_loop "$issue_num" "$pr_num" || true
            ;;
        "fixing")
            if [ -z "$pr_num" ]; then
                mark_blocked "$issue_num" "No PR number found"
                return 1
            fi
            fix_review_feedback "$pr_num" "$issue_num"
            if run_ci_fix_loop "$pr_num" "$issue_num"; then
                # Don't reset round here - we're continuing the same review cycle
                resume_from_phase "$issue_num" "reviewing"
            else
                mark_blocked "$issue_num" "CI failed after $MAX_CI_FIX_ATTEMPTS fix attempts"
            fi
            ;;
        "merging")
            if [ -z "$pr_num" ]; then
                mark_blocked "$issue_num" "No PR number found"
                return 1
            fi
            # Docs should already be done before merging phase
            merge_and_verify "$pr_num" "$issue_num"
            complete_issue "$issue_num" "$pr_num"
            ;;
        "verifying")
            # PR already merged, just complete
            complete_issue "$issue_num" "$pr_num"
            ;;
        "complete")
            success "Issue #$issue_num is already complete"
            ;;
        "blocked")
            warn "Issue #$issue_num is blocked - remove 'auto-dev:blocked' label and set appropriate phase to resume"
            ;;
        *)
            warn "Unknown phase: $phase"
            return 1
            ;;
    esac
}

run_review_loop() {
    local issue_num=$1
    local pr_num=$2

    # Validate PR number
    pr_num=$(validate_pr_number "$pr_num")
    if [ -z "$pr_num" ]; then
        error "Invalid PR number passed to run_review_loop"
        return 1
    fi

    # Get current review round
    local review_round
    review_round=$(get_metadata "$issue_num" "round")
    review_round=${review_round:-0}

    # Safety check: if round counter is already at or past max, reset it
    # This can happen if resuming after a failed run or stale metadata
    if [ "$review_round" -ge "$MAX_REVIEW_ROUNDS" ]; then
        warn "Review round counter ($review_round) >= max ($MAX_REVIEW_ROUNDS), resetting to 0"
        review_round=0
        set_metadata "$issue_num" "round" "0"
    fi

    while [ "$review_round" -lt "$MAX_REVIEW_ROUNDS" ]; do
        review_round=$((review_round + 1))
        set_metadata "$issue_num" "round" "$review_round"
        log "Review round $review_round/$MAX_REVIEW_ROUNDS"

        if review_code "$pr_num" "$issue_num"; then
            # Approved - check docs before merge
            if ! update_documentation "$issue_num"; then
                # Docs were updated, wait for CI before merging
                log "Documentation updated, waiting for CI..."
                if ! run_ci_fix_loop "$pr_num" "$issue_num"; then
                    mark_blocked "$issue_num" "CI failed after doc update"
                    return 1
                fi
            fi
            merge_and_verify "$pr_num" "$issue_num"
            complete_issue "$issue_num" "$pr_num"
            return 0
        fi

        if [ "$review_round" -lt "$MAX_REVIEW_ROUNDS" ]; then
            # Fix feedback
            fix_review_feedback "$pr_num" "$issue_num"

            # Re-run CI after fixes (with fix loop)
            if ! run_ci_fix_loop "$pr_num" "$issue_num"; then
                mark_blocked "$issue_num" "CI failed after $MAX_CI_FIX_ATTEMPTS fix attempts"
                return 1
            fi
        else
            mark_blocked "$issue_num" "Max review rounds ($MAX_REVIEW_ROUNDS) reached"
            return 1
        fi
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# MAIN LOOP
#═══════════════════════════════════════════════════════════════════════════════
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║          AUTO-DEV: Automated Development Loop              ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Handle --status flag
    if [ "$SHOW_STATUS" = true ]; then
        show_status
        exit 0
    fi

    # Handle --init flag
    if [ "$RUN_INIT" = true ]; then
        header "Initializing Auto-Dev"
        ensure_labels_exist
        success "Setup complete - GitHub labels are ready"
        exit 0
    fi

    # Handle --triage flag (triage-only mode)
    if [ "$RUN_TRIAGE_ONLY" = true ]; then
        log "Triage-only mode - will triage feedback and exit"
        run_triage_session
        success "Triage-only mode complete"
        exit 0
    fi

    if [ -n "$TARGET_ISSUE" ]; then
        log "Target issue mode - working on issue #$TARGET_ISSUE"
    elif [ "$SINGLE_CYCLE" = true ]; then
        log "Single cycle mode - will exit after one issue"
    elif [ "$RESUME_ONLY" = true ]; then
        log "Resume mode - will only resume in-progress work"
    else
        log "Continuous mode - Press Ctrl+C to stop"
    fi

    if [ -n "$SELECTION_HINT" ]; then
        log "Selection hint: ${YELLOW}$SELECTION_HINT${NC}"
    fi

    while true; do
        echo ""
        log "═══════════════════════════════════════════════════════════"
        log "Starting development cycle at $(date)"
        log "═══════════════════════════════════════════════════════════"

        # Session 0: Triage ALL user-feedback issues first
        # Always runs before any dev work (unless targeting a specific issue or resume-only)
        if [ -z "$TARGET_ISSUE" ] && [ "$RESUME_ONLY" != true ]; then
            run_triage_session
        fi

        local issue_num="" issue_title="" issue_body=""

        # If target issue specified, use it directly
        if [ -n "$TARGET_ISSUE" ]; then
            issue_num="$TARGET_ISSUE"

            # Check if this issue is already in-progress
            local existing_phase
            existing_phase=$(get_phase "$issue_num")
            if [ -n "$existing_phase" ] && [ "$existing_phase" != "complete" ] && [ "$existing_phase" != "blocked" ]; then
                log "Issue #$issue_num is already in-progress (phase: $existing_phase)"
                resume_from_phase "$issue_num" "$existing_phase"

                local new_phase
                new_phase=$(get_phase "$issue_num")
                if [ "$new_phase" = "complete" ] || [ "$new_phase" = "blocked" ]; then
                    log "Issue #$issue_num finished. Exiting."
                    exit 0
                fi
                sleep 5
                continue
            fi

            # Fetch issue details from GitHub
            log "Fetching issue #$issue_num from GitHub..."
            local issue_json
            if ! issue_json=$(gh issue view "$issue_num" --json title,body 2>/dev/null); then
                error "Failed to fetch issue #$issue_num"
                exit 1
            fi
            issue_title=$(echo "$issue_json" | jq -r '.title // "Unknown"' 2>/dev/null) || issue_title="Unknown"
            issue_body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null) || issue_body=""

            success "Working on: $issue_title"
        else
            # Check for in-progress work first (RESUME)
            local resume_issue_num
            resume_issue_num=$(find_resumable_issue)

            if [ -n "$resume_issue_num" ]; then
                local resume_phase
                resume_phase=$(get_phase "$resume_issue_num")
                log "Found in-progress issue #$resume_issue_num in phase: $resume_phase"

                resume_from_phase "$resume_issue_num" "$resume_phase"

                # Check if we completed or blocked
                local new_phase
                new_phase=$(get_phase "$resume_issue_num")
                if [ "$new_phase" = "complete" ] || [ "$new_phase" = "blocked" ]; then
                    if [ "$SINGLE_CYCLE" = true ]; then
                        log "Single cycle complete. Exiting."
                        exit 0
                    fi
                fi

                # Continue to next iteration
                sleep 5
                continue
            fi

            # No in-progress work
            if [ "$RESUME_ONLY" = true ]; then
                log "No in-progress issues found. Exiting resume mode."
                exit 0
            fi

            # Select new issue
            if ! issue_num=$(select_issue); then
                if [ "$SINGLE_CYCLE" = true ]; then
                    warn "No issues to work on. Exiting."
                    exit 0
                fi
                warn "No suitable issues found. Waiting 30 minutes..."
                sleep 1800
                continue
            fi

            # Fetch issue details from GitHub
            local issue_json
            issue_json=$(gh issue view "$issue_num" --json title,body 2>/dev/null) || issue_json="{}"
            issue_title=$(echo "$issue_json" | jq -r '.title // "Unknown"' 2>/dev/null) || issue_title="Unknown"
            issue_body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null) || issue_body=""
        fi

        # Run the full workflow
        plan_implementation "$issue_num" "$issue_title" "$issue_body"

        local pr_num=""
        if ! pr_num=$(implement_and_test "$issue_num"); then
            mark_blocked "$issue_num" "Implementation failed"
            continue
        fi

        # Validate PR number to catch any stdout pollution
        pr_num=$(validate_pr_number "$pr_num")
        if [ -z "$pr_num" ]; then
            mark_blocked "$issue_num" "Invalid PR number returned from implementation"
            continue
        fi

        if ! run_ci_fix_loop "$pr_num" "$issue_num"; then
            mark_blocked "$issue_num" "CI checks failed after $MAX_CI_FIX_ATTEMPTS fix attempts"
            continue
        fi

        if ! run_review_loop "$issue_num" "$pr_num"; then
            # Already marked as blocked in run_review_loop
            continue
        fi

        # Success path handled in run_review_loop -> complete_issue

        if [ "$SINGLE_CYCLE" = true ]; then
            log "Single cycle complete. Exiting."
            exit 0
        fi

        # Brief pause before next cycle
        log "Pausing 30 seconds before next cycle..."
        sleep 30
    done
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
