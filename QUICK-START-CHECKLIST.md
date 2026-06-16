# Quick Start Checklist — JIRA Root Cause Agent

Use this checklist when setting up for the first time. Complete every step before running an analysis.

---

## 1. Install Prerequisites

- [ ] **VS Code** with the **GitHub Copilot** extension installed
- [ ] **PowerShell 5.1+** available (built-in on Windows)

> No `ripgrep` or local repository clone is needed — the script searches code directly on GitHub Enterprise via the Code Search API.

---

## 2. Generate a JIRA Personal Access Token

- [ ] Open `https://jira-pro.it.hpe.com:8443` and sign in
- [ ] Go to profile settings → **Personal Access Tokens**
- [ ] Click **Create** and name it `jira-rootcause-agent`
- [ ] Copy the token immediately — it may only be shown once
- [ ] Store it securely (password manager or secure notes)

---

## 3. Generate a GitHub Personal Access Token

> **Which GitHub?** This project uses **HPE GitHub Enterprise** at `https://github.hpe.com`.  
> Do **not** generate a token on `github.com` — it will not work.

**Classic PAT (recommended for GitHub Enterprise):**

- [ ] Go to `https://github.hpe.com/settings/tokens` → **Generate new token (classic)**
- [ ] Set note (e.g. `jira-rootcause-agent`) and expiration
- [ ] Select the **`repo`** scope (or `public_repo` for public repos only)
- [ ] Click **Generate token** — copy immediately (shown only once)
- [ ] Store securely

**Fine-grained PAT (only if your GitHub Enterprise supports it):**

- [ ] Go to `https://github.hpe.com/settings/tokens?type=beta` → **Generate new token**
- [ ] Set name (e.g. `jira-rootcause-agent`) and expiration
- [ ] Under **Repository access** → select the repos in `config/module-repo-map.json`
- [ ] Under **Permissions → Repository** → set **Contents** to `Read-only`
- [ ] Click **Generate token** — copy immediately (shown only once)

Add to your credentials file or set as env var:

```powershell
$env:GITHUB_TOKEN = "PASTE_YOUR_GITHUB_PAT_HERE"
```

- [ ] `GITHUB_TOKEN` stored

---

## 4. Configure Credentials

**Recommended (keeps creds outside the repo):**

Run from inside the `JiraRootCauseAgent/` directory:

```powershell
cd C:\path\to\JiraRootCauseAgent
New-Item -ItemType Directory -Force -Path "$HOME/.jira-agent" | Out-Null
Copy-Item "config/jira-creds.json.example" "$HOME/.jira-agent/jira-rootcause-creds.json"
```

Edit `$HOME/.jira-agent/jira-rootcause-creds.json`:

```json
{
  "JIRA_AUTH_TOKEN": "PASTE_YOUR_JIRA_PAT_HERE",
  "JIRA_USER": "your.name@hpe.com",
  "GITHUB_TOKEN": "PASTE_YOUR_GITHUB_PAT_HERE"
}
```

- [ ] File created at `$HOME/.jira-agent/jira-rootcause-creds.json`
- [ ] JIRA token value replaced (not `your_jira_personal_access_token`)
- [ ] GitHub token value replaced (not `your_github_personal_access_token`)

**Alternative — environment variable (session only):**

```powershell
$env:JIRA_AUTH_TOKEN = "PASTE_YOUR_PAT_HERE"
```

---

## 5. Verify Module Map

- [ ] Open `config/module-repo-map.json`
- [ ] Confirm `githubOrg` is set and your module has a `githubRepo` that exists on GitHub Enterprise
- [ ] If your module is missing, see `CONTRIBUTING.md` to add it

---

## 6. Run a Test Analysis

Make sure you are in the `JiraRootCauseAgent/` directory first:

```powershell
cd C:\path\to\JiraRootCauseAgent
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -IssueId CAST-40070
```

- [ ] Pre-flight GitHub connectivity check passes
- [ ] Script completes without error
- [ ] `output/CAST-40070/CAST-40070.json` exists (JIRA data fetched)
- [ ] `output/CAST-40070/context.json` shows the correct module and GitHub repository
- [ ] `output/CAST-40070/repo-search.txt` contains GitHub code-search hits

---

## 7. Use in VS Code Copilot Chat

**Agent mode:**
1. Open Copilot Chat (`Ctrl+Shift+I`)
2. Click the agent picker and select **JIRA Root Cause Analyst**
3. Type: `CAST-40070`

**Slash prompt:**
```
/jira-rootcause CAST-40070
```

- [ ] Agent appears in the agent picker
- [ ] Slash prompt `/jira-rootcause` is available in chat

---

## Troubleshooting Quick Reference

| Error | Fix |
|-------|-----|
| `Missing credentials` | Check Step 4 — credentials file not found or token is still a placeholder |
| `Unable to infer module` | Add keywords to `config/module-repo-map.json` (see `CONTRIBUTING.md`) |
| `Cannot reach GitHub API` / pre-flight abort | Check network/VPN; set `GITHUB_ENTERPRISE_URL` or `githubBaseUrl` if not on `github.hpe.com` |
| `401 Unauthorized` (JIRA) | Verify `JIRA_AUTH_TOKEN` is set correctly in your credentials file |
| `401 Unauthorized` (GitHub) | Verify `GITHUB_TOKEN` was generated on `github.hpe.com`, not `github.com` |
| `403 Forbidden` (GitHub) | Your token lacks the `repo` scope — regenerate with correct permissions |

For full detail, see `SETUP-GUIDE.md`.
