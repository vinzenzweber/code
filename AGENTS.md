# AGENTS.md

## Purpose
This document defines the high‑level automated workflow previously orchestrated by `code.sh`. AI agents should follow this process to triage user feedback, select work, plan, implement, test, review, merge, and optionally update documentation. GitHub issues/labels/comments are the source of truth for state.

## State and Source of Truth
- Use GitHub issue labels to track phase and signals (e.g., `auto-dev:phase:*`, `auto-dev:triage:*`, `auto-dev:signal:*`).
- Store session summaries and key artifacts (plans, decisions) as GitHub issue comments.
- The workflow must be resumable from any phase by inspecting labels and issue comments.

## CLI Hints (GitHub)
Use the GitHub CLI (`gh`) for all issue/PR operations.

- List open issues (basic):
  - `gh issue list --state open --json number,title,labels --limit 50`
- Fetch issue details:
  - `gh issue view <num> --json title,body,comments,labels`
- Add or remove labels:
  - `gh issue edit <num> --add-label 'auto-dev:phase:planning'`
  - `gh issue edit <num> --remove-label 'auto-dev:phase:planning'`
- Comment on an issue:
  - `gh issue comment <num> --body "text"`
- Create an issue:
  - `gh issue create --title "Title" --body "Body" --label "P1-core"`
- Find duplicates (search title/body):
  - `gh issue list --state open --search "keyword"`
  - `gh issue list --state closed --search "keyword"`
- List PRs and detect issue linkage:
  - `gh pr list --state open --json number,title`
  - `gh pr view <pr> --json title,body,labels,comments`

## Workflow Overview (Phases)
The workflow runs in cycles. A single cycle processes at most one development issue (unless resuming). Each phase should post a short session summary to the issue.

### Session 0: User Feedback Triage
1. Find issues labeled `user-feedback` that have no triage label or are stuck in `auto-dev:triage:pending/analyzing`.
   - Example: `gh issue list --state open --label user-feedback --json number,title,labels`
2. For each feedback issue:
   - Analyze scope and actionability.
   - Check for duplicates before creating any issue.
     - Example: `gh issue list --state open --search "similar keyword"`
   - If actionable, create small child issues and link duplicates.
     - Example: `gh issue create --title "Fix X" --body "Part of #<num>" --label "P1-core"`
   - If large, convert the parent to an epic (prefix title `Epic:`) and keep it open.
     - Example: `gh issue edit <num> --title "Epic: <old title>"`
   - If unclear, ask for clarification and mark triage pending.
     - Example: `gh issue comment <num> --body "Please clarify ..."`
3. Update triage labels and leave a comment summarizing results.
   - Example: `gh issue edit <num> --add-label 'auto-dev:triage:complete'`

### Session 1: Issue Selection
1. List open issues (limit ~50) and exclude:
   - Issues with `auto-dev:` labels (already in progress)
   - Issues with open PRs
   - Epic issues (`Epic:` in title)
   - `user-feedback` issues (require triage first)
2. Prioritize by labels and type:
   - P0 > P1 > P2 > P3
   - Bugs > features > enhancements
3. Select a single issue to work on. Record the decision in comments or labels.
   - Example: `gh issue edit <num> --add-label 'auto-dev:phase:selecting'`

### Session 2: Planning
1. Read the issue title/body and relevant code.
   - Example: `gh issue view <num> --json title,body,comments`
2. Produce a markdown implementation plan with explicit steps and a testing plan.
3. Post the plan as a comment with required markers so it is machine‑readable.
   - Example: `gh issue comment <num> --body "$(cat plan.md)"`
4. Set phase label to planning complete.
   - Example: `gh issue edit <num> --add-label 'auto-dev:phase:planning'`

### Session 3: Implementation + Testing + PR
1. Implement strictly according to the approved plan.
2. Run required tests (unit/E2E/Playwright MCP as applicable).
3. Create a PR, link it to the issue, and update phase labels.
   - Example: `gh pr create --fill` then `gh issue edit <num> --add-label 'auto-dev:phase:implementing'`
4. Post a brief session summary (changes, tests run, PR number).
   - Example: `gh issue comment <num> --body "Summary: ... PR #123 ... Tests: ..."`

### Session 4: Code Review
1. Perform an automated review of the PR (or request review if appropriate).
2. If review passes, proceed. If changes are required, move to Session 5.
3. Post review results to the issue or PR.

### Session 5: Fix Review Feedback
1. Apply requested fixes.
2. Re‑run relevant tests.
3. Update the PR and re‑enter review as needed (bounded retries).
4. Post a summary of fixes and test results.

### Session 6: Merge + Deploy + Verify
1. Merge the PR.
   - Example: `gh pr merge <pr> --merge`
2. Verify deployment or post‑merge checks.
3. Update phase label and post a final session summary.

### Session 7: Documentation (Optional)
1. Determine whether documentation updates are needed.
2. If yes, update docs on the feature branch, commit, and push.
3. Signal that CI must re‑run if docs changed.
   - Example: `gh issue edit <num> --add-label 'auto-dev:signal:needs-update'`
4. Post a brief comment explaining the decision.

## Resume Logic
- At start, check for any issues with in‑progress phase labels.
- Resume from the recorded phase using issue labels/comments.
- If a required artifact (e.g., plan) is missing, regenerate it and continue.

## Output Expectations
- Keep comments concise and structured.
- Always record the summary of each session (what happened, key artifacts, costs if tracked).
- Prefer deterministic, atomic steps over large uncontrolled changes.

## Constraints
- Avoid human‑dependent steps. All tests and checks should be automated.
- Do not proceed without an approved plan.
- Do not create duplicate issues; always search first.
