# Git Branch Display Plan

## Goal

Show the current git branch for each detected session in the popover, replacing the current display of the last path component of `workingDirectory`.

The implementation must stay cheap enough to run alongside the existing 2-second refresh loop without spawning a `git` subprocess on every scan for every session.

## Current State

- `DetectedAgent` stores `workingDirectory`, `commandLine`, `tty`, status, app metadata, and activity metadata in `AgentRadar/AgentMonitor.swift`.
- `PopoverView` currently renders `URL(fileURLWithPath: agent.workingDirectory).lastPathComponent` in the row subtitle area.
- `AgentMonitor` rescans every 2 seconds, so any branch detection that shells out repeatedly will add avoidable overhead.

## Design

### 1. Add git display state to `DetectedAgent`

Add published properties for lightweight git metadata that the UI can render directly:

- `gitBranch: String?`
- `gitRepoRoot: String?`

`gitBranch` should be the primary value used by the popover. If it is `nil`, the UI should fall back to the existing folder-name display.

### 2. Cache repo metadata in `AgentMonitor`

Add a small repo-level cache keyed by git directory or repo root. Each cache entry should store:

- `repoRoot: String`
- `gitDir: String`
- `branch: String?`
- `headSignature: String?`
- `lastCheckedAt: Date`
- whether the path is known to be non-git

The key goal is to avoid repeated `git` subprocesses for sessions that belong to the same repository.

### 3. Use `git` only to bootstrap repo identity

On cache miss, resolve repo information from the session `workingDirectory` with one command:

```bash
git -C "$cwd" rev-parse --show-toplevel --absolute-git-dir
```

Implementation notes:

- If the command fails, cache a negative result for that `workingDirectory` or repo lookup key with a short TTL.
- This command handles subdirectories within a repo and worktrees.
- Parse the two output lines into `repoRoot` and `gitDir`.

Do not run `git branch --show-current` on every scan.

### 4. Read branch from `HEAD` directly

Once `gitDir` is known, resolve the branch by reading `\(gitDir)/HEAD` directly.

Expected behaviors:

- If `HEAD` contains `ref: refs/heads/<name>`, show `<name>`.
- If `HEAD` contains some other `ref: ...`, show the tail component after `refs/heads/` only when that prefix exists; otherwise leave it as a detached/non-branch state.
- If `HEAD` is a raw commit SHA, treat the repo as detached.

Detached HEAD handling:

- Prefer showing a short commit SHA if one is already available cheaply from the `HEAD` contents.
- If no friendly detached value is available without another subprocess, leave `gitBranch` nil and let the UI fall back to the folder name.

### 5. Refresh branch cheaply

On each monitor scan:

- For each agent, call a helper such as `updateGitContext(for:)`.
- If the repo lookup is cached, avoid invoking `git`.
- Read `HEAD` only when needed.

Suggested invalidation strategy:

- Always reuse cached repo root and git dir.
- Re-read `HEAD` every scan, or only when file contents / file modification date changed.

Given how small `HEAD` is, reading it directly each scan is acceptable. The important constraint is to avoid frequent subprocesses.

### 6. Share repo data across sessions

If multiple sessions point into the same repo, all of them should resolve to the same cache entry. Updating the cached branch should update all affected sessions on the next scan.

### 7. Update the UI

In `AgentRadar/PopoverView.swift`:

- Replace the current folder-name label with `agent.gitBranch` when available.
- Fall back to `URL(fileURLWithPath: agent.workingDirectory).lastPathComponent` when branch data is unavailable.
- Keep the current typography and truncation behavior unless a small tweak is needed for long branch names.

## Suggested Implementation Steps

1. Extend `DetectedAgent` with git metadata properties.
2. Add repo cache types and storage to `AgentMonitor`.
3. Implement a helper to resolve repo root and git dir from `workingDirectory`.
4. Implement a helper to read and parse `HEAD`.
5. Call the git-context updater during reconciliation/stat refresh.
6. Update `PopoverView` to render branch-or-folder.
7. Build the app to verify it still compiles.

## Constraints

- Do not add a `git` subprocess on every refresh for every session.
- Do not block the main thread with expensive repo probing.
- Preserve current behavior for non-git directories.
- Preserve worktree compatibility.

## Acceptance Criteria

- A session inside a normal git repo shows the current branch name in the popover.
- A session inside a subdirectory of a git repo still shows the correct branch.
- Multiple sessions inside the same repo do not each run their own repeated git subprocesses after bootstrap.
- Non-git directories still render cleanly using the folder fallback.
- Worktree-backed repos resolve correctly.
- The project builds successfully with the existing local build command.
