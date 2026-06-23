# Prompt: JIRA Root Cause Analysis

## Objective

Diagnose the **actual** root cause of any JIRA issue and propose a fix, grounded
in the real source code. The reasoning is done by the model selected in the VS
Code Copilot Chat window. A helper PowerShell script only gathers JIRA context
and provides on-demand code-access tools (no LLM is called by the script).

## Scope

This is generic: it handles crashes, logic bugs, race conditions, performance
regressions, configuration errors, build failures, security issues, and other
defect classes in any language. Do not assume a defect class up front. Determine
the actual cause from the evidence.

## How To Invoke

In VS Code Copilot Chat, select the **JIRA Root Cause Analyst** agent and type
the issue key, or use the prompt:

```text
/jira-rootcause CAST-40143
```

## Required Input

- JIRA key (example: `CAST-40143`)
- Optional: `GITHUB_ENTERPRISE_URL` (or `githubBaseUrl` in `module-repo-map.json`)

## Workflow

1. Gather context using:

```powershell
powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -Action analyze -IssueId <KEY>
```

2. Read:
   - `output/<KEY>/context-bundle.md`
   - `output/<KEY>/context.json`
   - `output/<KEY>/<KEY>.json` (when needed)

3. Classify the issue and generate up to three ranked hypotheses.

4. Investigate code using:

   - `search`
   - `grep`
   - `readfile`
   - `listdir`
   - `listrepos`

5. Validate hypotheses against code actually read.

6. Produce:

```text
output/<KEY>/<KEY>-analysis.md
```

## Repository Inference

The script scores components in `module-repo-map.json` and records the best
candidate as `defaultRepo` in `context.json`. Override when necessary.

## Grounding Rules (Strict)

- Every claim must be backed by JIRA evidence or code actually read.
- Cite JIRA fields, log lines, and exact file:line references.
- Never invent file contents, APIs, line numbers, symbols, or behavior.
- If evidence is insufficient, explicitly say so.
- Do not fabricate a root cause.
- Do not fabricate a fix.
- Only propose code changes after reading the surrounding implementation.
- Always include a reproduction section.
- Never request or expose secrets.

## Investigation Budget

- Maximum 5 searches before revisiting the current hypothesis.
- Maximum 3 source files per hypothesis before producing an interim conclusion.
- Prefer cached local files (`grep` + `readfile`) over repeated repository searches.
- Stop reading once the call chain, state transition, and root cause are established.
- Avoid duplicate reads.

## Classification First

Classify the issue before deep investigation:

- Crash
- Logic Bug
- Race Condition
- Performance Regression
- Configuration Error
- Build Failure
- Security Issue
- Unknown

Generate up to three candidate hypotheses and rank them.

## Hypothesis Validation

For each hypothesis:

1. Identify supporting evidence.
2. Identify contradicting evidence.
3. Reject unsupported hypotheses.
4. Select the best-supported hypothesis.

Document rejected hypotheses in the final report.

## Efficient Code Reading Strategy

1. Use `search` to locate candidate symbols.
2. Use `grep` to obtain exact line numbers.
3. Read approximately 100–150 lines around the hit initially.
4. Expand to 300+ lines when call-chain reconstruction requires additional context.
5. Avoid file-wide reads unless necessary.
6. Prefer targeted function reads.

## Call Chain Reconstruction

For every root-cause conclusion:

- Identify the triggering function.
- Trace callers.
- Trace state transitions.
- Explain how the failure occurs.
- Explain why existing safeguards failed.

## Concurrency Checklist

For crashes, hangs, corruption, races, deadlocks, and memory issues evaluate:

- Lock acquisition order
- Refcount ownership
- Object ownership
- Concurrent access paths
- List manipulation safety
- Lifetime transitions

## Object Lifecycle Analysis

Reconstruct object lifecycle where applicable:

Creation → Initialization → Reference Acquisition → Usage → Release → Destruction

## Evidence Ranking

Prioritize evidence in this order:

1. Stack traces
2. Error logs
3. Code paths read directly
4. JIRA comments
5. User descriptions

## Large Repository Optimization

- Avoid reading files larger than 2000 lines unless necessary.
- Prefer targeted function reads.
- Avoid duplicate reads.
- Stop when the root cause is sufficiently established.

## Reproduction Guidance

Produce the most actionable reproducer supported by evidence.

### Deterministic Issues

Provide:

- Preconditions
- Inputs
- Commands
- Expected result
- Actual result

### Non-Deterministic Issues

Provide:

1. Conditions required for failure.
2. Stress procedure.
3. Deterministic fault-injection approach when appropriate.

Tie every step to evidence or code that was actually read.

## Required Report Structure

```markdown
# Root Cause Analysis: <KEY>

## Summary

## Issue Classification
- Type:
- Affected component & repository:
- Primary language:

## Root Cause

## Evidence

## Reproduction

## Suggested Fix

## Confidence & Open Questions
```

## Deliverables

```text
output/<KEY>/<KEY>.json
output/<KEY>/context-bundle.md
output/<KEY>/context.json
output/<KEY>/<KEY>-analysis.md
```
