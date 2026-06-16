# Prompt: JIRA Root Cause Mining

## Objective

Automate root cause analysis from a JIRA issue key to GitHub repository-scoped code evidence, without browsing the entire workspace.

## How To Invoke This Prompt

In VS Code Copilot Chat, type `/jira-rootcause` followed by the issue key:

```
/jira-rootcause CAST-40070
```

Or select the **JIRA Root Cause Analyst** agent from the agent picker and type the issue key directly.

## Required Input

- JIRA key (example: `CAST-40070`)
- Optional: `GITHUB_ENTERPRISE_URL` if your org uses GitHub Enterprise instead of github.com

## Workflow

1. Run `Scripts/invoke-jira-rootcause.ps1 -IssueId <KEY>`.
   - **The script tests HPE GitHub connectivity as its very first action — before fetching JIRA or doing anything else.**
   - If GitHub is unreachable or authentication fails, the script stops immediately with a descriptive error. **Do not proceed. Do not fetch JIRA. Do not search locally. Halt and report the exact error.**
   - If the pre-flight passes, the script fetches JIRA JSON, infers the owning module, resolves `githubOrg/githubRepo` from `config/module-repo-map.json`, and searches code on GitHub.
   - Output lands in `output/<KEY>/`.
2. Read `output/<KEY>/context.json` to confirm the resolved module and GitHub repository.
4. Read `output/<KEY>/repo-search.txt` for raw GitHub code search hits.
5. Cross-reference hits with the JIRA JSON at `output/<KEY>/<KEY>.json` (stack traces, error messages, comments).
6. Produce root cause, reproducible trigger path, and fix suggestion.
7. Save the final analysis to `output/<KEY>/<KEY>-analysis.md`.

## Module Inference

The script scores each module in `config/module-repo-map.json` against JIRA text (summary, description, components, labels, comments). The highest-scoring module wins. If confidence is low (score = 0), the script throws — update `config/module-repo-map.json` or ask the user for a module name.

## GitHub Configuration

- Set `githubOrg` in `config/module-repo-map.json` to your GitHub organization.
- Each module entry needs a `githubRepo` field.
- For GitHub Enterprise, set `GITHUB_ENTERPRISE_URL` env var or `githubBaseUrl` in `module-repo-map.json`.

## Credential Resolution Order

1. File at path in `JIRA_CREDS_FILE` env var
2. `$HOME/.jira-agent/jira-rootcause-creds.json`
3. `config/jira-creds.json`
4. `JIRA_AUTH_TOKEN` env var (bearer)
5. `JIRA_USER` + `JIRA_TOKEN` env vars (basic auth)
6. `GITHUB_TOKEN` field in credentials file or `GITHUB_TOKEN` env var

See `SETUP-GUIDE.md` for setup steps.

## Rules

- Do not perform workspace-wide source browsing.
- Do not request secrets in chat — credentials are read from files or env vars only.
- If module inference confidence is low, ask the user to provide a module name override.
- **If HPE GitHub is not reachable, stop immediately and report the exact error. Do not fetch JIRA. Do not fall back to local search. The analysis cannot proceed without GitHub access.**

## Deliverables

For issue `<KEY>`, produce:

```
output/<KEY>/<KEY>.json          — raw JIRA data
output/<KEY>/context.json        — resolved module, GitHub repo, search tokens
output/<KEY>/repo-search.txt     — GitHub code search hits
output/<KEY>/<KEY>-analysis.md   — final root cause analysis
```
