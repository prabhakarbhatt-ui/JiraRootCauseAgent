param(
    [Parameter(Mandatory)]
    [string]$IssueId,

    [string]$OutputDir = "output",
    [string]$JiraBaseUrl = "https://jira-pro.it.hpe.com:8443"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-CredentialValue {
    param(
        [string]$Name,
        [pscustomobject]$FileCreds
    )

    if ($FileCreds -and $FileCreds.PSObject.Properties.Name -contains $Name) {
        $value = [string]$FileCreds.$Name
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    $processValue = [Environment]::GetEnvironmentVariable($Name, "Process")
    if (-not [string]::IsNullOrWhiteSpace($processValue)) {
        return [string]$processValue
    }

    $userValue = [Environment]::GetEnvironmentVariable($Name, "User")
    if (-not [string]::IsNullOrWhiteSpace($userValue)) {
        return [string]$userValue
    }

    return ""
}

function Get-JiraHeaders {
    $projectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $fileCreds = $null

    $homePath = [Environment]::GetFolderPath("UserProfile")
    $defaultUserCredFile = Join-Path (Join-Path $homePath ".jira-agent") "jira-rootcause-creds.json"

    $candidateFiles = @()
    if (-not [string]::IsNullOrWhiteSpace($env:JIRA_CREDS_FILE)) {
        $candidateFiles += $env:JIRA_CREDS_FILE
    }
    $candidateFiles += $defaultUserCredFile
    $candidateFiles += (Join-Path $projectRoot "config/jira-creds.json")

    foreach ($candidate in $candidateFiles) {
        if (-not (Test-Path $candidate)) {
            continue
        }

        try {
            $fileCreds = Get-Content $candidate -Raw | ConvertFrom-Json
            break
        }
        catch {
            throw "Invalid JSON in $candidate"
        }
    }

    $jiraAuthToken = Resolve-CredentialValue -Name "JIRA_AUTH_TOKEN" -FileCreds $fileCreds
    $jiraUser = Resolve-CredentialValue -Name "JIRA_USER" -FileCreds $fileCreds
    $jiraToken = Resolve-CredentialValue -Name "JIRA_TOKEN" -FileCreds $fileCreds

    # Detect unfilled placeholder values
    $placeholderPattern = '^(REPLACE_ME.*|your[_\.].*|<.*>|TODO.*)$'
    $configFilePath = Join-Path $projectRoot "config/jira-creds.json"
    if ($jiraAuthToken -match $placeholderPattern) {
        throw "JIRA credentials not configured: 'JIRA_AUTH_TOKEN' still contains a placeholder value.`nPlease update: $configFilePath"
    }
    if ($jiraUser -match $placeholderPattern) {
        throw "JIRA credentials not configured: 'JIRA_USER' still contains a placeholder value.`nPlease update: $configFilePath"
    }
    if ($jiraToken -match $placeholderPattern) {
        throw "JIRA credentials not configured: 'JIRA_TOKEN' still contains a placeholder value.`nPlease update: $configFilePath"
    }

    if ($jiraAuthToken) {
        return @{
            Authorization = "Bearer $jiraAuthToken"
            Accept        = "application/json"
        }
    }

    if ($jiraUser -and $jiraToken) {
        $credential = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$jiraUser`:$jiraToken"))
        return @{
            Authorization = "Basic $credential"
            Accept        = "application/json"
        }
    }

    throw "JIRA credentials not found. Please populate: $configFilePath`nSee JiraRootCauseAgent/SETUP-GUIDE.md for instructions."
}

$headers = Get-JiraHeaders
$issueUrl = "$JiraBaseUrl/rest/api/2/issue/$IssueId"

$issueFolder = Join-Path $OutputDir $IssueId
if (-not (Test-Path $issueFolder)) {
    New-Item -ItemType Directory -Path $issueFolder -Force | Out-Null
}

try {
    $response = Invoke-WebRequest -Uri $issueUrl -Headers $headers -Method Get -UseBasicParsing
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 401) {
        $configFilePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "config/jira-creds.json"
        throw "JIRA authentication failed (401 Unauthorized). Your credentials are invalid or expired.`nPlease update: $configFilePath`nSee JiraRootCauseAgent/SETUP-GUIDE.md for instructions."
    }
    throw
}
$data = $response.Content | ConvertFrom-Json

$jsonPath = Join-Path $issueFolder "$IssueId.json"
$data | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 $jsonPath

Write-Host "Saved JIRA JSON to $jsonPath"
