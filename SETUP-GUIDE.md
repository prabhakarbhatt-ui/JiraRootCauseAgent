# Setup Guide — JIRA Root Cause Agent

Complete every step below before running an analysis. Check off each box as you go. This is the single setup, configuration, and first-run reference; the [README](README.md) covers day-to-day usage and [DESIGN-DOCUMENT.md](DESIGN-DOCUMENT.md) covers architecture.

---

## Step 1 — Install prerequisites and clone

- [ ] **VS Code** with the **GitHub Copilot** extension installed ([code.visualstudio.com](https://code.visualstudio.com))
- [ ] **PowerShell 5.1+** available (built-in on Windows)

> No `ripgrep` or local repository clone of the target product is needed — the script searches code directly on GitHub Enterprise via the Code Search API.

Clone this repository and open it directly as your VS Code workspace so the agent picker discovers **JIRA Root Cause Analyst** from the bundled `.github/` automatically:

```powershell
git clone https://github.com/prabhakarbhatt-ui/JiraRootCauseAgent.git
cd JiraRootCauseAgent
code .
```

- [ ] Repository cloned and opened as the workspace

---

## Step 2 — Generate a JIRA Personal Access Token

- [ ] Open `https://jira-pro.it.hpe.com:8443` and sign in
- [ ] Go to profile settings → **Personal Access Tokens**
- [ ] Click **Create** and name it `jira-rootcause-agent`
- [ ] Copy the token immediately — it is shown only once — and store it securely

This value becomes `JIRA_AUTH_TOKEN` in Step 4.

---

## Step 3 — Generate a GitHub Personal Access Token

A GitHub PAT is **required** for code investigation: the script searches source repositories on GitHub Enterprise. A pre-flight connectivity check runs first and prints a warning if GitHub is unreachable or the token is invalid; the run still continues and gathers JIRA context, but the code-access actions (`search`/`readfile`/`listdir`) will fail until the token/network is fixed.

> **Which GitHub instance?** This project targets **HPE GitHub Enterprise** at `https://github.hpe.com`.
> Do **not** use a `github.com` token — it will be rejected.
> If your organization uses a different GitHub Enterprise URL, set `GITHUB_ENTERPRISE_URL` (see [Custom GitHub Enterprise URL](#custom-github-enterprise-url)).

**Option A — Classic PAT (recommended for GitHub Enterprise):**

Fine-grained PATs are a `github.com`-only feature and are not available on most GitHub Enterprise Server instances, including `github.hpe.com`.

- [ ] Go to `https://github.hpe.com/settings/tokens` → **Generate new token (classic)**
- [ ] Set a name (e.g. `jira-rootcause-agent`) and an expiration date
- [ ] Select the **`repo`** scope (read access to private repos), or `public_repo` for public repos only
- [ ] Click **Generate token** and copy it immediately (shown only once)

**Option B — Fine-grained PAT (only if your GitHub Enterprise supports it):**

- [ ] Go to `https://github.hpe.com/settings/tokens?type=beta` → **Generate new token**
- [ ] Set a name and expiration date
- [ ] Under **Repository access**, select the repos in `config/module-repo-map.json`
- [ ] Under **Permissions → Repository**, set **Contents** to `Read-only`
- [ ] Click **Generate token** and copy it immediately (shown only once)

This value becomes `GITHUB_TOKEN` in Step 4.

---

## Step 4 — Configure credentials

**Recommended — credentials file outside the repository.** Run from inside the `JiraRootCauseAgent/` directory:

```powershell
cd C:\path\to\JiraRootCauseAgent
New-Item -ItemType Directory -Force -Path "$HOME/.jira-agent" | Out-Null
Copy-Item "config/jira-creds.json.example" "$HOME/.jira-agent/jira-rootcause-creds.json"
```

Edit `$HOME/.jira-agent/jira-rootcause-creds.json` and replace the placeholders with the tokens from Steps 2 and 3:

```json
{
  "JIRA_AUTH_TOKEN": "PASTE_YOUR_JIRA_PAT_HERE",
  "JIRA_USER": "your.name@hpe.com",
  "GITHUB_TOKEN": "PASTE_YOUR_GITHUB_PAT_HERE"
}
```

- [ ] File created at `$HOME/.jira-agent/jira-rootcause-creds.json`
- [ ] JIRA token replaced (not a placeholder)
- [ ] GitHub token replaced (not a placeholder)

To update credentials later, edit the same file and rerun the command in Step 6.

**Alternative — environment variables:**

```powershell
# Session only
$env:JIRA_AUTH_TOKEN = "your_token_here"
$env:GITHUB_TOKEN     = "your_github_pat_here"

# Permanent (User scope)
[System.Environment]::SetEnvironmentVariable('JIRA_AUTH_TOKEN', 'your_token_here', 'User')
[System.Environment]::SetEnvironmentVariable('GITHUB_TOKEN', 'your_github_pat_here', 'User')
```

A local fallback file at `config/jira-creds.json` (gitignored) is also supported for compatibility — never commit real values to it.

> `JIRA_AUTH_TOKEN` authenticates to the JIRA REST API (`jira-pro.it.hpe.com`); `GITHUB_TOKEN` authenticates to the GitHub Enterprise API (`github.hpe.com`). They are not interchangeable.

### Credential resolution order

The scripts resolve credentials in this order (first match wins):

1. File path in `JIRA_CREDS_FILE` (if set)
2. `$HOME/.jira-agent/jira-rootcause-creds.json` **(recommended)**
3. `config/jira-creds.json` (local fallback — gitignored)
4. `JIRA_AUTH_TOKEN` process/user environment variable (bearer token)
5. `JIRA_USER` + `JIRA_TOKEN` environment variables (basic auth)

### Custom GitHub Enterprise URL

If your GitHub Enterprise is not at `github.hpe.com`, override the base URL:

```powershell
# Session only
$env:GITHUB_ENTERPRISE_URL = "https://github.your-company.com"

# Permanent
[System.Environment]::SetEnvironmentVariable('GITHUB_ENTERPRISE_URL', 'https://github.your-company.com', 'User')
```

The script reads `githubBaseUrl` from `config/module-repo-map.json` as the default; `GITHUB_ENTERPRISE_URL` overrides it at runtime.

---

## Step 5 — Verify the module map

- [ ] Open `config/module-repo-map.json`
- [ ] Confirm `githubOrg` is set and your module has a `githubRepo` that exists on GitHub Enterprise
- [ ] If your module is missing, add it — see [CONTRIBUTING.md](CONTRIBUTING.md) for the field reference and keyword tips

---

## Step 6 — Run a test analysis

Make sure you are in the `JiraRootCauseAgent/` directory:

```powershell
cd C:\path\to\JiraRootCauseAgent
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -IssueId CAST-40070
```

- [ ] Pre-flight GitHub connectivity check runs (a warning here does not stop the run)
- [ ] Script completes without error
- [ ] An `output/CAST-40070/` folder is produced with the JIRA data, resolved default module/repository, and a context bundle (`context-bundle.md`, `context.json`)

For the full execution sequence and a description of each generated artifact, see [DESIGN-DOCUMENT.md](DESIGN-DOCUMENT.md).

---

## Step 7 — Use in VS Code Copilot Chat

**Agent mode:**

1. Open Copilot Chat (`Ctrl+Shift+I`)
2. Click the agent picker and select **JIRA Root Cause Analyst**
3. Type the issue key: `CAST-40070`

**Slash prompt:**

```
/jira-rootcause CAST-40070
```

- [ ] Agent appears in the agent picker
- [ ] Slash prompt `/jira-rootcause` is available in chat

> If your GitHub Enterprise is not at `github.hpe.com`, set `GITHUB_ENTERPRISE_URL` or `githubBaseUrl` before invoking the agent.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Missing credentials` | No credential file/env var found, or token is still a placeholder | Re-check Step 4 |
| `Unable to infer module` | No module keyword matched the JIRA text | Add keywords to `config/module-repo-map.json` (see [CONTRIBUTING.md](CONTRIBUTING.md)) |
| `Cannot reach GitHub API` (pre-flight warning) | Network/VPN blocked or wrong base URL | Check VPN/network; set `GITHUB_ENTERPRISE_URL` or `githubBaseUrl`. The run continues, but code-access actions will fail until fixed |
| `401 Unauthorized` (JIRA) | `JIRA_AUTH_TOKEN` missing or wrong | Verify the token in your credentials file |
| `401 Unauthorized` (GitHub) | Token generated on `github.com`, not `github.hpe.com` | Regenerate on `github.hpe.com` |
| `403 Forbidden` (GitHub) | Token lacks the `repo` scope | Regenerate the classic PAT with the `repo` scope |
| Wrong repository inferred / model can't find relevant code | Module keywords didn't match the JIRA text | Check `output/<KEY>/context.json` (`inferredComponent`, `defaultRepo`); add better tokens to the module's `match` list and confirm `githubRepo` |

---

## Known constraints

- Module inference is keyword-based and may need tuning.
- A reachable GitHub Enterprise instance and a valid `GITHUB_TOKEN` are required for code investigation; the pre-flight check only warns if they are unavailable, and the code-access actions fail until fixed.
- The script does not apply code fixes automatically; it generates fix recommendations.
