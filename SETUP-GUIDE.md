# JIRA Root Cause Agent - Setup Guide

## Overview

This guide sets up an automated JIRA-to-repository root cause workflow. The automation fetches JIRA issue data, infers module ownership, resolves the target repository path, and creates analysis artifacts without workspace-wide code browsing.

## Project Structure

```text
JiraRootCauseAgent/
├── .github/
│   ├── agents/
│   │   └── jira-rootcause.agent.md
│   ├── prompts/
│   │   └── jira-rootcause.prompt.md
│   └── skills/
│       └── jira-repo-bridge/
│           └── SKILL.md
├── Scripts/
│   ├── fetch-jira.ps1
│   └── invoke-jira-rootcause.ps1
├── config/
│   └── module-repo-map.json
└── output/
```

## Step 1: Configure Credentials

Generate a JIRA token first (required):

1. Open `https://jira-pro.it.hpe.com:8443` and sign in.
2. Open profile settings.
3. Open Personal Access Tokens (PAT).
4. Create a new token (example name: `jira-rootcause-agent`).
5. Copy and store the token securely.

Use that value as `JIRA_AUTH_TOKEN` in one of the credential methods below.

Preferred method: user-level credentials file outside the repository.

Create directory and file:

```powershell
New-Item -ItemType Directory -Force -Path "$HOME/.jira-agent" | Out-Null
Copy-Item "config/jira-creds.json.example" "$HOME/.jira-agent/jira-rootcause-creds.json"
```

Recommended file:

- `$HOME/.jira-agent/jira-rootcause-creds.json`

Optional override for custom path:

```powershell
$env:JIRA_CREDS_FILE = "D:/secure/jira-rootcause-creds.json"
```

Local fallback (supported for compatibility):

Create this file:

- `JiraRootCauseAgent/config/jira-creds.json`

Template (copy from `JiraRootCauseAgent/config/jira-creds.json.example`):

```json
{
	"JIRA_AUTH_TOKEN": "your_jira_personal_access_token",
	"JIRA_USER": "your.name@hpe.com",
	"JIRA_TOKEN": "optional_if_using_basic_auth"
}
```

How to update credentials later:

1. Open `$HOME/.jira-agent/jira-rootcause-creds.json` (the recommended location).
2. Replace token/user values.
3. Save and rerun the automation command.

> If you used the local fallback instead, the file is at `JiraRootCauseAgent/config/jira-creds.json`.

Alternative method: environment variables.

```powershell
# Option A (recommended)
[System.Environment]::SetEnvironmentVariable('JIRA_AUTH_TOKEN', 'your_token_here', 'User')

# Option B
[System.Environment]::SetEnvironmentVariable('JIRA_USER', 'your.name@hpe.com', 'User')
[System.Environment]::SetEnvironmentVariable('JIRA_TOKEN', 'your_token_here', 'User')
```

Credential resolution order in scripts:

1. `JIRA_CREDS_FILE` path (if set)
2. `$HOME/.jira-agent/jira-rootcause-creds.json`
3. `JiraRootCauseAgent/config/jira-creds.json`
4. Process environment variables
5. User-scope environment variables

## Step 2: Generate a GitHub Personal Access Token

A GitHub PAT is required if the agent needs to read source repositories hosted on GitHub Enterprise (`github.hpe.com`).

> **Which GitHub instance?**  
> This project targets **HPE GitHub Enterprise** at `https://github.hpe.com`.  
> Do **not** use `github.com` tokens — they will be rejected.  
> If your organization uses a different GitHub Enterprise URL, set `GITHUB_ENTERPRISE_URL` (see below).

### Option A — Classic PAT (recommended for GitHub Enterprise)

Fine-grained PATs are a `github.com`-only feature and are **not available on most GitHub Enterprise Server instances**, including `github.hpe.com`. Use a Classic PAT:

1. Go to `https://github.hpe.com/settings/tokens`.
2. Click **Generate new token (classic)**.
3. Set a descriptive name (e.g., `jira-rootcause-agent`) and an expiration date.
4. Select the **`repo`** scope (gives read access to private repositories).
   - For public repositories only, select `public_repo` instead.
5. Click **Generate token** — copy it immediately (shown only once).

### Option B — Fine-grained PAT (only if your GitHub Enterprise supports it)

If your GitHub Enterprise administrator has enabled fine-grained PATs:

1. Go to `https://github.hpe.com/settings/tokens?type=beta`.
2. Click **Generate new token**.
3. Set a descriptive name (e.g., `jira-rootcause-agent`) and an expiration date.
4. Under **Repository access**, select **Only select repositories** and choose the repos listed in `config/module-repo-map.json`.
5. Under **Permissions → Repository**, set **Contents** to `Read-only`.
6. Click **Generate token** — copy it immediately (shown only once).

### Store the token

Add `GITHUB_TOKEN` to your credentials file:

```json
{
  "JIRA_AUTH_TOKEN": "your_jira_personal_access_token",
  "JIRA_USER": "your.name@hpe.com",
  "GITHUB_TOKEN": "your_github_enterprise_pat"
}
```

Or set it as an environment variable:

```powershell
# Session only
$env:GITHUB_TOKEN = "your_github_pat_here"

# Permanent (User scope)
[System.Environment]::SetEnvironmentVariable('GITHUB_TOKEN', 'your_github_pat_here', 'User')
```

### Custom GitHub Enterprise URL

If your organization's GitHub Enterprise is **not** at `github.hpe.com`, override the base URL:

```powershell
# Session only
$env:GITHUB_ENTERPRISE_URL = "https://github.your-company.com"

# Permanent
[System.Environment]::SetEnvironmentVariable('GITHUB_ENTERPRISE_URL', 'https://github.your-company.com', 'User')
```

The script reads `githubBaseUrl` from `config/module-repo-map.json` as the default; `GITHUB_ENTERPRISE_URL` overrides it at runtime.

> **Note:** `JIRA_AUTH_TOKEN` authenticates to the Jira REST API (`jira-pro.it.hpe.com`). `GITHUB_TOKEN` authenticates to the GitHub Enterprise API (`github.hpe.com`). Do not use one in place of the other.

## Step 3: Tune Module Mapping

Edit `config/module-repo-map.json`. This file has top-level settings and a `modules` array:

### Top-level fields

| Field | Description |
|-------|-------------|
| `githubOrg` | The GitHub organization that owns the repositories (e.g., `"hpe"`). Used when constructing GitHub API URLs. |
| `githubBaseUrl` | Base URL of the GitHub Enterprise REST API (e.g., `"https://github.hpe.com/api/v3"`). Overridden at runtime by `GITHUB_ENTERPRISE_URL` env var. |

### Per-module fields

| Field | Description |
|-------|-------------|
| `name` | Logical module name (used in analysis output and `context.json`) |
| `match` | Keywords scored against JIRA text to identify which module owns an issue |
| `githubRepo` | **Required.** Repository name on GitHub Enterprise under `githubOrg`. This is the repo the script searches and reads source from (e.g., `"hpc-dvs-kernel"`). |

Always update this map when new modules are added.

## Step 4: Run End-To-End Automation

Make sure you are in the `JiraRootCauseAgent/` directory:

```powershell
cd C:\path\to\JiraRootCauseAgent
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -IssueId CAST-40070
```

Execution sequence:

1. Pre-flight: test GitHub Enterprise connectivity (the run aborts immediately if it fails).
2. Fetch JIRA issue JSON (all fields, comments, attachments, linked issues).
3. Infer the owning module using keyword scoring and resolve `githubOrg/githubRepo`.
4. Extract crash evidence (BUG/Oops lines, call trace frames, kernel thread, fault address, log messages).
5. Build targeted GitHub code-search queries and search the repository via the GitHub Code Search API.
6. Fetch matched C/H source files from GitHub and run crash-path analysis.
7. Generate the analysis scaffold and context metadata.

## Generated Artifacts

For issue `<KEY>`:

- `output/<KEY>/<KEY>.json`: raw JIRA payload
- `output/<KEY>/repo-search.txt`: GitHub Code Search API evidence (grouped by query label)
- `output/<KEY>/code-analysis.json`: crash-path analysis of source files fetched from GitHub (when C/H files match)
- `output/<KEY>/context.json`: execution metadata, resolved repository, crash evidence summary
- `output/<KEY>/<KEY>-analysis.md`: editable analysis draft

## Copilot Agent Integration

- Agent definition: `.github/agents/jira-rootcause.agent.md`
- Prompt: `.github/prompts/jira-rootcause.prompt.md`
- Skill: `.github/skills/jira-repo-bridge/SKILL.md`

Recommended request style:

```text
Analyze CAST-40070 using JIRA Root Cause Analyst
```

> If your GitHub Enterprise is not at `github.hpe.com`, set `GITHUB_ENTERPRISE_URL` or `githubBaseUrl` before invoking the agent.

## Validation Checklist

Run after any script change:

1. Verify fetch works for a known issue.
2. Verify module inference chooses expected module.
3. Verify the resolved GitHub repository is reachable (pre-flight passes).
4. Verify `repo-search.txt` has matches for at least one query.
5. Verify `context.json` and analysis markdown are generated.

## Known Constraints

- Module inference is keyword-based and may need tuning.
- A reachable GitHub Enterprise instance and a valid `GITHUB_TOKEN` are required; the run aborts at the pre-flight check otherwise.
- Script does not apply code fixes automatically; it generates fix recommendations.
