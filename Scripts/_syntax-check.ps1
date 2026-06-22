# _syntax-check.ps1
#
# Purpose : Validate the syntax of invoke-jira-rootcause.ps1 without executing it.
#           Uses the PowerShell AST parser to catch syntax errors early.
#
# When to run : Manually, after editing invoke-jira-rootcause.ps1 and before committing.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File Scripts/_syntax-check.ps1
#
# Exit codes:
#   0 - Syntax OK
#   1 - One or more syntax errors found (details printed to console)

$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path (Join-Path $PSScriptRoot 'invoke-jira-rootcause.ps1')).Path,
    [ref]$null,
    [ref]$errors
)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "SYNTAX ERROR line $($_.Extent.StartLineNumber): $_" }
    exit 1
} else {
    Write-Host "Syntax OK"
    exit 0
}
