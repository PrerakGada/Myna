# Integration Plan

How the orchestrator merges the three lane branches back into `native-app-rebuild` once each lane reports done.

## Merge order

**Lane C first** (daemon refactor) → **Lane A second** (depends on Lane C's `/v2/*` endpoints semantically, though Lane A's tests mock them) → **Lane B third** (Sparkle wiring touches `apps/macos/project.yml` which Lane A may have also modified; merge B last lets us resolve the SUPublicEDKey if both modified it).

## Per-merge protocol

For each lane:

```bash
# 1. Fast-forward check
cd ~/Developer/myna
git fetch  # no-op (no remote yet) but harmless
git checkout native-app-rebuild

# 2. Examine the lane's commits before merging
WORKTREE=.claude/worktrees/agent-<id>
git --git-dir="$WORKTREE/.git" log --oneline native-app-rebuild..HEAD

# Or, since worktrees share .git:
git log --oneline native-app-rebuild..worktree-agent-<id>

# 3. Merge with --no-ff so the lane's commits stay grouped
git merge --no-ff worktree-agent-<id> -m "Merge Lane <X>: <summary>"

# 4. Conflict resolution if any. The contract says no file overlap, but
#    project.yml or .gitignore might collide.
#    Resolve favoring the lane's changes for files in their scope.

# 5. Post-merge sanity build
cd apps/macos && xcodegen generate
xcodebuild -scheme Myna -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/integration CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild test -scheme Myna -destination 'platform=macOS' \
  -derivedDataPath /tmp/integration CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
cd ../..
"$HOME/.venvs/myna/bin/pytest" daemon/tests -q
```

If build OR tests break: revert the merge with `git reset --hard HEAD~1`, file an issue in `AUDIT_REPORT.md`, attempt cherry-pick of clean commits only.

## After all three lanes merged

1. Run the L0 code-review auditor agents (3, in parallel)
2. Wait for all 3 reports
3. Address any 🔴 blockers (likely cherry-pick a fix or send a SendMessage to the original lane agent)
4. Run the L0 security auditor (1)
5. Address any 🔴/🟠 security findings
6. Orchestrator runs the final-verification real-device checklist
7. Write `STATUS.md` morning briefing
8. (No push — wait for Rashid's morning go-ahead per CLAUDE.md commit/push rule)

## Worktree cleanup

After a lane is merged and its findings addressed:

```bash
# The agent's worktree stays under .claude/worktrees/ — that's normal.
# We don't `git worktree remove` because we want the JSONL transcripts
# preserved for the morning audit log.
```

Worktrees are gitignored at root (`.claude/` is in `.gitignore`), so they don't pollute the repo.
