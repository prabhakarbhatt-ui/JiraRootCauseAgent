# Contributing to JIRA Root Cause Agent

## Adding a New Module

When a new repository or component needs to be analysable, add it to `config/module-repo-map.json`.

### Format

Each module entry in the `modules` array:

```json
{
  "name": "module-name",
  "match": ["keyword1", "keyword2", "keyword3"],
  "githubRepo": "repository-name-on-github-enterprise"
}
```

| Field | Description |
|-------|-------------|
| `name` | Unique logical name for the module (used in analysis output and `context.json`) |
| `match` | Array of lowercase keywords the script scores against JIRA text. Include component names, error prefixes, binary names, subsystem names. More is better. |
| `githubRepo` | **Required.** Repository name on GitHub Enterprise (e.g., `"hpc-dvs-kernel"`). This is the repo the script searches and reads source from. Must match the repo name under the `githubOrg` org. |

### Top-level fields

| Field | Description |
|-------|-------------|
| `githubOrg` | GitHub Enterprise organization that owns all the repositories (e.g., `"hpe"`). |
| `githubBaseUrl` | REST API base URL for GitHub Enterprise (e.g., `"https://github.hpe.com/api/v3"`). Overridden at runtime by the `GITHUB_ENTERPRISE_URL` environment variable. |

### Example

You want to add `hpc-new-module`, hosted at `https://github.hpe.com/hpe/hpc-new-module`.

Add this entry to the `modules` array in `config/module-repo-map.json`:

```json
{
  "name": "hpc-new-module",
  "match": ["new-module", "newmod", "nm_init", "nm_error"],
  "githubRepo": "hpc-new-module"
}
```

### Keyword Selection Tips

- Use lowercase only (the script lowercases all JIRA text before matching).
- Include: binary names, kernel module names, error message prefixes, component JIRA names, abbreviations.
- Avoid: generic words like `error`, `issue`, `fail`, `node` — these are in the stop-word list and won't help.
- Test: run a real JIRA issue and check `output/<KEY>/context.json` to verify the correct module is selected.

### Verifying the New Entry

1. Run the syntax check to catch JSON errors before running a full analysis:
   ```powershell
   powershell -ExecutionPolicy Bypass -File Scripts/_syntax-check.ps1
   ```
2. Add the entry to `config/module-repo-map.json`.
3. Run a known issue for the new module:
   ```powershell
   powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -IssueId <KEY>
   ```
4. Open `output/<KEY>/context.json` and confirm `module` shows the new module name.
5. Check `output/<KEY>/repo-search.txt` has GitHub code-search hits inside the correct repository.

---

## Adding or Updating Scripts

### `Scripts/_syntax-check.ps1`

Runs a PowerShell parse (syntax) check on `invoke-jira-rootcause.ps1`. Run this after any change to that script:

```powershell
powershell -ExecutionPolicy Bypass -File Scripts/_syntax-check.ps1
```

### `Scripts/fetch-jira.ps1`

Fetches JIRA JSON via REST API. Only change this if:
- The JIRA base URL changes.
- A new authentication mode needs to be supported.
- Additional JIRA fields need to be captured.

### `Scripts/invoke-jira-rootcause.ps1`

Main entrypoint. Change this if:
- Module scoring logic needs to change (see `Resolve-Module` function).
- New output files are needed.
- The analysis scaffold format changes.
- The GitHub search query construction changes (see `Get-CrashSearchQueries`).

---

## Updating the Agent/Prompt/Skill Files

| File | When to update |
|------|---------------|
| `.github/agents/jira-rootcause.agent.md` | Agent behaviour changes, new constraints, new output format |
| `.github/prompts/jira-rootcause.prompt.md` | Prompt workflow or credential guidance changes |
| `.github/skills/jira-repo-bridge/SKILL.md` | Step-by-step skill instructions change or new troubleshooting entries |

If you keep this repository nested inside a personal parent folder and open that parent as your VS Code workspace, also update your local copies of these files under the parent root's `.github/` folder. That parent-root copy is a personal convenience only and is **not** part of the distributed repository — the canonical files always live in `JiraRootCauseAgent/.github/`.

---

## Security Rules

- Never commit real credentials to any file in this repository.
- `config/jira-creds.json` is gitignored — it is safe to edit locally but never force-add it.
- The recommended credential location is always **outside** the repository: `$HOME/.jira-agent/jira-rootcause-creds.json`.
- Do not add `JIRA_AUTH_TOKEN` or any secret to agent `.md` files.
