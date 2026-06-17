# Skill: JIRA To Repository Bridge

## Purpose

Turn a JIRA issue key into grounded root-cause analysis. A helper script gathers
JIRA context and exposes code-access tools; the model selected in VS Code Copilot
Chat does the reasoning. Generic across issue types and languages — not limited
to kernel crashes or NULL-pointer dereferences.

## When To Use

When the user asks for root cause analysis of a JIRA issue (e.g. "analyse
CAST-40143", "what's wrong with this ticket", "root cause CAST-xxxxx").

## Workflow

### Step 1 — Gather context

```powershell
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -Action analyze -IssueId <KEY>
```

This fetches the JIRA JSON, downloads non-assignee log attachments, infers the
owning component / repository, and writes:
- `output/<KEY>/context-bundle.md` — assembled JIRA context to reason over
- `output/<KEY>/context.json` — inferred `defaultRepo`, available repos, metadata
- `output/<KEY>/<KEY>.json` — raw JIRA JSON

### Step 2 — Investigate the code

The script exposes tool actions (run via the execute tool). The chat model drives
the investigation:

```powershell
# search repository code
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -Action search -Query '<terms>' -Repo <repo>
# read a numbered file slice (up to 1500 lines; omit -EndLine for 1500 from -StartLine, or use -EndLine -1 for the whole file)
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -Action readfile -Path <path> -Repo <repo> -StartLine <n> -EndLine <m>
# list a directory
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -Action listdir -Path <dir> -Repo <repo>
# list configured repositories
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -Action listrepos
```

`-Repo` defaults to the inferred repository; pass it to target another.
Each file is downloaded from GitHub only once then cached on disk, so prefer
fewer, larger `readfile` calls over many small slices.

### Step 3 — Produce the analysis

Write `output/<KEY>/<KEY>-analysis.md` following the structure in the agent file.
Ground every claim in JIRA evidence or code actually read. If evidence is
insufficient, state what is needed rather than guessing.

## Prerequisites

- JIRA credentials configured (see `SETUP-GUIDE.md`).
- **`GITHUB_TOKEN`** with at least `repo` scope — in `config/jira-creds.json` or
  the `GITHUB_TOKEN` env var.
- `githubOrg` and each component's `githubRepo` set in `config/module-repo-map.json`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `GitHub organization not configured` | Set `githubOrg` in `config/module-repo-map.json` |
| `Cannot reach GitHub API` (warning) | Check network; for GitHub Enterprise set `GITHUB_ENTERPRISE_URL` or `githubBaseUrl` |
| `GitHub ... auth failed (401)` | Set a valid `GITHUB_TOKEN` |
| `GitHub ... 403 Forbidden` | Token lacks `repo` scope — regenerate with `repo` scope |
| `The 'analyze' action requires -IssueId` | Pass `-IssueId <KEY>` |
| Missing JIRA credentials | Follow `SETUP-GUIDE.md` to create the creds file |
