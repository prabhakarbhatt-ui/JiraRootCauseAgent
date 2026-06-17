# Prompt: JIRA Root Cause Analysis

## Objective

Diagnose the **actual** root cause of any JIRA issue and propose a fix, grounded
in the real source code. The reasoning is done by the model selected in the VS
Code Copilot Chat window. A helper PowerShell script only gathers JIRA context
and provides on-demand code-access tools (no LLM is called by the script).

This is generic: it handles crashes, logic bugs, races, performance regressions,
config/build errors, security issues — in any language. It is **not** limited to
kernel crashes or NULL-pointer dereferences.

## How To Invoke

In VS Code Copilot Chat, select the **JIRA Root Cause Analyst** agent and type
the issue key, or use the prompt:

```
/jira-rootcause CAST-40143
```

## Required Input

- JIRA key (example: `CAST-40143`)
- Optional: `GITHUB_ENTERPRISE_URL` (or `githubBaseUrl` in `module-repo-map.json`)
  if your org uses GitHub Enterprise.

## Workflow

1. **Gather context:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -Action analyze -IssueId <KEY>
   ```
   Writes `output/<KEY>/context-bundle.md`, `output/<KEY>/context.json`, and the
   raw `output/<KEY>/<KEY>.json`.
2. Read `context-bundle.md` and `context.json`; form a hypothesis.
3. Investigate the real code using the script's tool actions (run via execute):
   - `-Action search   -Query '<terms>' -Repo <repo>`
   - `-Action readfile -Path <path> -Repo <repo> -StartLine <n> -EndLine <m>`
   - `-Action listdir  -Path <dir> -Repo <repo>`
   - `-Action listrepos`
4. Verify every conclusion against code you actually read.
5. Write the final report to `output/<KEY>/<KEY>-analysis.md`.

## Repository Inference

The script scores each component in `config/module-repo-map.json` against JIRA
text and records the best match as `defaultRepo` in `context.json`. You may
override it (use `-Action listrepos`, then pass `-Repo <name>` to the search /
readfile / listdir actions).

## Configuration

- `githubOrg` in `config/module-repo-map.json` set to your GitHub organization.
- Each component entry needs a `githubRepo` field.
- For GitHub Enterprise: `GITHUB_ENTERPRISE_URL` env var or `githubBaseUrl` in
  `module-repo-map.json`.

## Credential Resolution Order

1. File at path in `JIRA_CREDS_FILE` env var
2. `$HOME/.jira-agent/jira-rootcause-creds.json`
3. `config/jira-creds.json`
4. `JIRA_AUTH_TOKEN` env var (bearer)
5. `JIRA_USER` + `JIRA_TOKEN` env vars (basic auth)
6. `GITHUB_TOKEN` field in credentials file or `GITHUB_TOKEN` env var

See `SETUP-GUIDE.md`.

## Rules

- Do not request secrets in chat — credentials are read from files / env vars.
- Ground every claim in JIRA evidence or code you actually read; cite the source.
- Never invent file contents, line numbers, function names, or APIs.
- If evidence is insufficient, say so and list exactly what is needed. Do not
  fabricate a root cause or a fix.

## Deliverables

```
output/<KEY>/<KEY>.json          — raw JIRA data
output/<KEY>/context-bundle.md   — gathered JIRA context for reasoning
output/<KEY>/context.json        — inferred repo + metadata
output/<KEY>/<KEY>-analysis.md   — final root cause analysis (you write this)
```
