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
