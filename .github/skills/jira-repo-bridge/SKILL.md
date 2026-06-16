# Skill: JIRA To Repository Bridge

## Purpose

Convert a JIRA issue key into GitHub repository-scoped debugging context: fetch, infer module, resolve GitHub repo, search code on GitHub, and scaffold analysis.

## When To Use

When the user asks for root cause analysis from a JIRA issue (e.g. "analyse CAST-40070", "what's wrong with this JIRA ticket", "root cause CAST-xxxxx").

## Step-By-Step Workflow

### Step 0 — Verify GitHub connectivity

**This is a hard requirement.** Before any code search, confirm GitHub is reachable. If it is not, stop and report the exact error. Do not fall back to local file search.

### Step 1 — Run the automation script

```powershell
# Fetches JIRA, resolves GitHub repo, tests GitHub connectivity, searches code on GitHub:
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -IssueId <ISSUE-KEY>
```

The script does the following automatically:
1. Fetches the JIRA JSON via REST API.
2. Extracts text from summary, description, components, labels, and comments.
3. Scores each module in `config/module-repo-map.json` and picks the best match.
4. Resolves `githubOrg` and `githubRepo` from the map.
5. **Tests GitHub connectivity — aborts with a descriptive error if unreachable.**
6. Builds targeted GitHub search queries from crash evidence (thread name, call trace function names, exact log phrases) and searches the repository via the GitHub Code Search API.
7. Writes all results to `output/<KEY>/`.

### Step 2 — Confirm module and GitHub repo inference

Read `output/<KEY>/context.json`:
- `module` — the inferred owning module
- `githubOrg` / `githubRepo` — the resolved GitHub repository
- `githubRepository` — combined `org/repo` string
- `queriesRun` — the labeled GitHub code-search queries that were executed

If the module is wrong, re-run with a corrected `config/module-repo-map.json` or ask the user which module owns the issue.

### Step 3 — Read evidence

- `output/<KEY>/repo-search.txt` — GitHub code search hits (file path + fragment per token)
- `output/<KEY>/<KEY>.json` — full JIRA JSON (stack traces, comments, error text)

### Step 4 — Produce final analysis

Refine `output/<KEY>/<KEY>-analysis.md` using evidence from Steps 2 and 3. Follow the output format in the agent file.

## Prerequisites

- JIRA credentials configured (see `SETUP-GUIDE.md`).
- **`GITHUB_TOKEN`** with at least `repo` scope — set in `config/jira-creds.json` or as the `GITHUB_TOKEN` env var.
- `githubOrg` set to your GitHub organization in `config/module-repo-map.json`.
- Module mapping complete in `config/module-repo-map.json`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Unable to infer module` | Add keywords to the matching module in `module-repo-map.json` or ask the user for the module name |
| `GitHub organization not configured` | Set `githubOrg` in `config/module-repo-map.json` (replace the `REPLACE_WITH_GITHUB_ORG` placeholder) |
| `Cannot reach GitHub API` | Check network connectivity; if on GitHub Enterprise set `GITHUB_ENTERPRISE_URL` or `githubBaseUrl` in `module-repo-map.json` |
| `GitHub API authentication failed (401)` | Set a valid `GITHUB_TOKEN` in `config/jira-creds.json` or the `GITHUB_TOKEN` env var |
| `GitHub API 403 Forbidden` | Your token exists but lacks `repo` scope — regenerate with `repo` scope |
| `Missing JIRA credentials` | Follow `SETUP-GUIDE.md` Step 1 to create `$HOME/.jira-agent/jira-rootcause-creds.json` |
