# JIRA Root Cause Agent

An automated Copilot agent workflow that turns a JIRA issue key into a repository-scoped root cause analysis — with no manual browsing of unrelated code.

## What It Does

1. Fetches JIRA issue data (summary, description, components, labels, comments, attachments).
2. Infers a default owning module by scoring against a keyword map, while keeping every configured repository available.
3. Resolves the default GitHub repository (`githubOrg/githubRepo`) and writes a context bundle for the chat model.
4. The chat model investigates the repository on GitHub Enterprise (Code Search, file reads, directory listings) — choosing terms and files based on the specific issue.
5. The model produces a structured, evidence-only analysis with root cause, steps to reproduce, and fix suggestion.

> The agent is **issue-type and language agnostic** — it is not specialized for any single failure class. The script itself performs no LLM reasoning; it gathers context and exposes code-access tools that the chat model drives.

> The script searches code **on GitHub Enterprise**, not on your local disk. A valid `GITHUB_TOKEN` is required for the code-access actions (`search`/`readfile`/`listdir`). A pre-flight connectivity check runs first and prints a warning if GitHub is unreachable or the token is invalid, but the run continues so JIRA context is still gathered. No local repository clone or `ripgrep` is needed.

## Requirements

| Tool | Purpose |
|------|---------|
| VS Code + GitHub Copilot | Chat interface and agent runner |
| PowerShell 5.1+ | Script execution (built-in on Windows) |
| JIRA PAT | Authenticate to the JIRA REST API |
| GitHub PAT (**required**) | Authenticate to the GitHub Enterprise Code Search API |

## Setup

First-time install, credential, and configuration steps are in **[SETUP-GUIDE.md](SETUP-GUIDE.md)**. Complete it before your first run.

## Usage

Once set up, run an analysis in any of these ways. Output is written to `output/<ISSUE-KEY>/`.

**Agent mode (recommended)** — Open Copilot Chat (`Ctrl+Shift+I`), pick **JIRA Root Cause Analyst** from the agent picker, and type the issue key:

```
CAST-40070
```

**Slash prompt** — In any Copilot Chat window:

```
/jira-rootcause CAST-40070
```

## Documentation

| Document | Contents |
|----------|----------|
| [SETUP-GUIDE.md](SETUP-GUIDE.md) | Install, credentials, configuration, first run, and troubleshooting |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Adding modules to the map and extending the scripts |
| [DESIGN-DOCUMENT.md](DESIGN-DOCUMENT.md) | Architecture, execution flow, data contracts, generated artifacts, and extension points |

## Repository Layout

```
JiraRootCauseAgent/
├── .github/
│   ├── agents/jira-rootcause.agent.md     ← Copilot agent definition
│   ├── prompts/jira-rootcause.prompt.md   ← /jira-rootcause slash prompt
│   └── copilot-instructions.md            ← Workspace-level Copilot instructions
├── config/
│   ├── jira-creds.json.example            ← Copy to set up credentials
│   ├── jira-creds.json                    ← Local credential fallback (gitignored)
│   └── module-repo-map.json               ← Module-to-repo keyword map
├── output/                                ← Generated analysis artifacts (gitignored)
├── Scripts/
│   ├── fetch-jira.ps1                     ← Fetches JIRA JSON
│   ├── invoke-jira-rootcause.ps1          ← Main entrypoint
│   └── _syntax-check.ps1                  ← Syntax validation helper
├── CONTRIBUTING.md
├── DESIGN-DOCUMENT.md
├── README.md                              ← This file
└── SETUP-GUIDE.md
```

## Running From a Parent Folder (optional)

The recommended setup is to open the cloned `JiraRootCauseAgent` folder directly as your VS Code workspace — the bundled `.github/` is then discovered automatically.

If you prefer to nest `JiraRootCauseAgent` inside a personal parent folder and open that parent as the workspace, VS Code only discovers agent/prompt/skill files at the **workspace root**. In that case, copy `.github/` up to the parent root and prefix the script path with `JiraRootCauseAgent/`:

```powershell
# From the parent workspace root:
powershell -ExecutionPolicy Bypass -File JiraRootCauseAgent/Scripts/invoke-jira-rootcause.ps1 -IssueId CAST-40070
```

This layout is a personal convenience only; the canonical agent files always live inside `JiraRootCauseAgent/.github/`.
