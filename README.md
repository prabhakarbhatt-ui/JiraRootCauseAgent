# JIRA Root Cause Agent

An automated Copilot agent workflow that turns a JIRA issue key into a repository-scoped root cause analysis — with no manual browsing of unrelated code.

## What It Does

1. Fetches JIRA issue data (summary, description, components, labels, comments).
2. Infers the owning module by scoring against a keyword map.
3. Resolves the target GitHub repository (`githubOrg/githubRepo`) from the module map.
4. Searches that repository on GitHub Enterprise (via the Code Search API) for relevant code (functions, error strings, call sites) and fetches matched source files.
5. Produces a structured analysis with root cause, steps to reproduce, and fix suggestion.

## Requirements

| Tool | Purpose | Install / Generate |
|------|---------|--------------------|
| VS Code + GitHub Copilot | Chat interface and agent runner | https://code.visualstudio.com |
| PowerShell 5.1+ | Script execution | Built-in on Windows |
| JIRA PAT | Authenticate to the JIRA REST API | Generated in JIRA profile → Personal Access Tokens (see Step 2) |
| GitHub PAT (**required**) | Authenticate to GitHub Enterprise Code Search API | Generated at `https://github.hpe.com/settings/tokens` (see `SETUP-GUIDE.md` Step 2) |

> The script searches code **on GitHub Enterprise**, not on your local disk. A valid `GITHUB_TOKEN` is mandatory — the run aborts at a pre-flight connectivity check if GitHub is unreachable. No local repository clone or `ripgrep` is needed.

---

## Quick Start (New Developer)

### Step 1 — Clone the repository

This repository (`JiraRootCauseAgent/`) is self-contained. Clone it to any location and open the cloned folder directly in VS Code:

```powershell
git clone https://github.com/prabhakarbhatt-ui/JiraRootCauseAgent.git
cd JiraRootCauseAgent
code .
```

Opening the `JiraRootCauseAgent` folder as your VS Code workspace lets the agent picker discover **JIRA Root Cause Analyst** from the bundled `.github/` automatically — no extra setup.

### Step 2 — Create your credentials file

Run from inside the `JiraRootCauseAgent/` directory:

```powershell
New-Item -ItemType Directory -Force -Path "$HOME/.jira-agent" | Out-Null
Copy-Item "config/jira-creds.json.example" "$HOME/.jira-agent/jira-rootcause-creds.json"
```

Edit `$HOME/.jira-agent/jira-rootcause-creds.json` and fill in your tokens:

```json
{
  "JIRA_AUTH_TOKEN": "<your-jira-pat>",
  "JIRA_USER": "your.name@hpe.com",
  "GITHUB_TOKEN": "<your-github-enterprise-pat>"
}
```

> **JIRA PAT:** sign in at `https://jira-pro.it.hpe.com:8443` → profile settings → Personal Access Tokens → Create. Copy immediately (shown only once).
>
> **GitHub PAT:** sign in at `https://github.hpe.com` → Settings → Developer settings → Personal Access Tokens → Generate new token. Grant at minimum **Contents: Read-only** for the repos in `config/module-repo-map.json`. Copy immediately (shown only once). See `SETUP-GUIDE.md` Step 2 for full instructions.

### Step 3 — Add modules to the map (if needed)

Edit `config/module-repo-map.json`. Each entry maps keywords in JIRA text to a GitHub repository name under `githubOrg`:

```json
{
  "name": "my-module",
  "match": ["keyword1", "keyword2"],
  "githubRepo": "my-module-repo"
}
```

See `CONTRIBUTING.md` for full instructions.

### Step 4 — Run an analysis

Make sure you are in the `JiraRootCauseAgent/` directory before running:

```powershell
cd C:\path\to\JiraRootCauseAgent
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -IssueId CAST-40070
```

Output is written to `output/CAST-40070/`.

---

## Using With VS Code Copilot Chat

### Option A — Agent mode (recommended)

1. Open Copilot Chat (`Ctrl+Shift+I`).
2. Click the agent picker (the `@` or agent icon).
3. Select **JIRA Root Cause Analyst**.
4. Type the issue key: `CAST-40070`

The agent runs the script, reads the output files, and returns a full analysis.

### Option B — Slash prompt

In any Copilot Chat window:

```
/jira-rootcause CAST-40070
```

### Option C — Command line only (no Copilot)

```powershell
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -IssueId CAST-40070
```

Then read `output/CAST-40070/CAST-40070-analysis.md` directly.

---

## Output Files

For issue `CAST-40070`, results are written to `output/CAST-40070/`:

| File | Contents |
|------|---------|
| `CAST-40070.json` | Full JIRA JSON response |
| `context.json` | Resolved module, GitHub repository, crash evidence summary, queries run |
| `repo-search.txt` | GitHub Code Search API hits, grouped by query label |
| `code-analysis.json` | Crash-path analysis of source files fetched from GitHub (when C/H files match) |
| `CAST-40070-analysis.md` | Scaffold analysis (refined by Copilot agent) |

---

## Repository Layout

```
JiraRootCauseAgent/
├── .github/
│   ├── agents/
│   │   └── jira-rootcause.agent.md     ← Copilot agent definition
│   ├── prompts/
│   │   └── jira-rootcause.prompt.md    ← /jira-rootcause slash prompt
│   └── skills/
│       └── jira-repo-bridge/
│           └── SKILL.md                ← Step-by-step skill guide
├── config/
│   ├── jira-creds.json.example         ← Copy to set up credentials
│   ├── jira-creds.json                 ← Local credential fallback (gitignored)
│   └── module-repo-map.json            ← Module-to-repo keyword map
├── output/
│   └── .gitkeep                        ← Output folder (gitignored except .gitkeep)
├── Scripts/
│   ├── fetch-jira.ps1                  ← Fetches JIRA JSON
│   └── invoke-jira-rootcause.ps1       ← Main entrypoint
├── .gitignore
├── CONTRIBUTING.md                     ← How to add modules and extend the map
├── QUICK-START-CHECKLIST.md            ← Step-by-step setup checklist
├── README.md                           ← This file
└── SETUP-GUIDE.md                      ← Detailed credential and config guide
```

---

## Credential Resolution Order

The scripts resolve credentials in this order (first match wins):

1. File path in `JIRA_CREDS_FILE` environment variable
2. `$HOME/.jira-agent/jira-rootcause-creds.json` **(recommended)**
3. `config/jira-creds.json` (local fallback — gitignored, never commit real values)
4. `JIRA_AUTH_TOKEN` environment variable (bearer token)
5. `JIRA_USER` + `JIRA_TOKEN` environment variables (basic auth)

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Unable to infer module` | No module keyword matched JIRA text | Add keywords to `config/module-repo-map.json` (see `CONTRIBUTING.md`) |
| `Cannot reach GitHub API` / pre-flight abort | Network blocked or wrong base URL | Check VPN/network; set `GITHUB_ENTERPRISE_URL` or `githubBaseUrl` in the map |
| `401 Unauthorized` (GitHub) | Missing/invalid `GITHUB_TOKEN` | Generate a token on `github.hpe.com` (not `github.com`) and store it (Step 2) |
| `403 Forbidden` (GitHub) | Token lacks the `repo` scope | Regenerate the classic PAT with the `repo` scope |
| `Missing credentials` | No credential file or env var found | Follow Step 2 above or `SETUP-GUIDE.md` |
| Script runs but no source files analyzed | Crash terms not found in the GitHub repo | Check `repo-search.txt`; add better tokens to the module's `match` list and confirm `githubRepo` |

---

## Running From a Parent Folder (optional)

The default and recommended setup is to open the cloned `JiraRootCauseAgent` folder directly as your VS Code workspace — the bundled `JiraRootCauseAgent/.github/` is then discovered automatically.

If you prefer to keep `JiraRootCauseAgent` nested inside a personal parent folder and open that parent as the workspace instead, VS Code only discovers agent/prompt/skill files at the **workspace root**. In that case, copy the `.github/` folder up to your parent root and adjust the script path to include the `JiraRootCauseAgent/` prefix:

```powershell
# From the parent workspace root:
powershell -ExecutionPolicy Bypass -File JiraRootCauseAgent/Scripts/invoke-jira-rootcause.ps1 -IssueId CAST-40070
```

This parent-folder layout is purely a personal convenience; other users do not need it. The canonical, distributed copy of the agent files always lives inside `JiraRootCauseAgent/.github/`.
