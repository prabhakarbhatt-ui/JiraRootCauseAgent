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
   - `-Action readfile -Path <path> -Repo <repo> -StartLine <n> -EndLine <m>` (up to 1500 lines; omit `-EndLine` for 1500 from `-StartLine`, or `-EndLine -1` for the whole file; files are cached after first read — prefer fewer, larger reads)
   - `-Action listdir  -Path <dir> -Repo <repo>`
   - `-Action listrepos`
   `-Repo` defaults to the inferred repository; pass it explicitly to target a different one.
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
- Always include a reproduction section. For deterministic bugs give exact
  ordered steps (preconditions, inputs, commands, expected vs. actual). For
  races / timing bugs, list the conditions that must coincide, a stress
  procedure to make them overlap, and — when a debug build is acceptable — a
  deterministic fault-injection variant that doubles as a regression test. Mark
  any step you did not actually run as a derived/unverified strategy.
- If evidence is insufficient, say so and list exactly what is needed. Do not
  fabricate a root cause or a fix.

## Reproduction guidance

Produce the most actionable reproducer the evidence supports, and be explicit
about how deterministic it is:

- **Deterministic bug** (logic error, config/build failure, wrong result): give
  exact, ordered steps — environment/preconditions, inputs, commands, and the
  expected vs. actual result. Prefer a minimal failing case.
- **Non-deterministic bug** (race, use-after-free, memory pressure, timing): you
  usually cannot give a one-shot repro. Instead:
  1. List the **conditions that must coincide** for the failure (grounded in the
     code paths you read), e.g. which two threads/contexts must overlap.
  2. Give a **stress procedure** that makes the overlap likely (load generation
     plus the triggering event), using only standard tooling — no source changes.
  3. Where a debug build is acceptable, give a **deterministic fault-injection**
     variant (e.g. a targeted delay or `fail_*` hook that widens the race
     window) that makes the failure fire on demand, and note that after the fix
     the same injection no longer triggers it — i.e. it doubles as a regression
     test.
- Tie each repro step back to specific evidence or `file:line` you read. Do not
  invent flags, sysctls, or APIs; only use ones you can cite.
- If you genuinely cannot construct any repro, say so and list exactly what is
  needed (e.g. vmcore, full stack trace, the input that triggered it).

## Required report structure

```markdown
# Root Cause Analysis: <KEY>

## Summary
One or two sentences: what is broken and why.

## Issue Classification
- Type: (crash / logic bug / race / performance / config / build / security / other)
- Affected component & repository:
- Primary language:

## Root Cause
The specific cause, grounded in evidence. Cite JIRA fields and exact file:line
references (with URLs) for any code you rely on.

## Evidence
Bullet list mapping each conclusion to its source (JIRA comment, log line, or
file:line you read).

## Reproduction
The most actionable reproducer the evidence supports — follow the Reproduction
guidance rules above.

## Suggested Fix
A concrete, minimal fix. Include a code diff or before/after snippet when a code
change applies and you have read the surrounding code. For non-code fixes
(config/process), give exact steps. If you cannot determine a fix, explain why
and list what is needed.

## Confidence & Open Questions
State your confidence (high/medium/low) and list assumptions and unresolved
questions.
```

It is acceptable — and expected — to report "insufficient evidence" rather than
to guess.

## Deliverables

```
output/<KEY>/<KEY>.json          — raw JIRA data
output/<KEY>/context-bundle.md   — gathered JIRA context for reasoning
output/<KEY>/context.json        — inferred repo + metadata
output/<KEY>/<KEY>-analysis.md   — final root cause analysis (you write this)
```
