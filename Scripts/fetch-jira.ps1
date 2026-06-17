param(
    [Parameter(Mandatory)]
    [string]$IssueId,

    [string]$OutputDir = "output",
    [string]$JiraBaseUrl = "https://jira-pro.it.hpe.com:8443",

    # Skip downloading any single attachment larger than this (bytes). Default 50 MB.
    [long]$MaxAttachmentBytes = 52428800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Returns $true when an attachment looks like a textual log/console/crash dump
# that is worth downloading and parsing for crash evidence.
function Test-IsLogAttachment {
    param(
        [string]$Filename,
        [string]$MimeType
    )

    # Recognised log-ish extensions (optionally gzip-compressed)
    if ($Filename -match '(?i)\.(log|txt|out|dmesg|console|messages|trace|dump|crash|syslog|err|nfo)(\.gz)?$') {
        return $true
    }
    # Common kernel/console log naming conventions even without a clear extension
    if ($Filename -match '(?i)(dmesg|console|syslog|messages|crash|panic|oops|backtrace|callhome|vmcore-dmesg)') {
        return $true
    }
    # Any text/* MIME type
    if ($MimeType -match '^(?i)text/') {
        return $true
    }
    return $false
}

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

# ---------------------------------------------------------------------------
# Download log attachments for crash analysis.
# IMPORTANT: attachments uploaded by the issue's ASSIGNEE are skipped, because
# those are frequently test logs the assignee produced while investigating,
# not the original failure evidence we want to root-cause.
# ---------------------------------------------------------------------------
$assigneeName = if ($data.fields.assignee) { [string]$data.fields.assignee.displayName } else { "" }
$attachmentsDir = Join-Path $issueFolder "attachments"
$manifest = [System.Collections.Generic.List[object]]::new()

if ($data.fields.PSObject.Properties.Name -contains 'attachment' -and $data.fields.attachment) {
    foreach ($a in $data.fields.attachment) {
        $filename = [string]$a.filename
        $author   = if ($a.author) { [string]$a.author.displayName } else { "" }
        $mime     = [string]$a.mimeType
        $size     = [long]$a.size
        $url      = [string]$a.content

        $entry = [ordered]@{
            Filename      = $filename
            Author        = $author
            MimeType      = $mime
            Size          = $size
            IsLog         = (Test-IsLogAttachment -Filename $filename -MimeType $mime)
            Downloaded    = $false
            LocalPath     = ""
            SkippedReason = ""
        }

        if (-not $entry.IsLog) {
            $entry.SkippedReason = "not a log/text file"
            $manifest.Add($entry); continue
        }
        if ($assigneeName -and $author -eq $assigneeName) {
            $entry.SkippedReason = "uploaded by assignee ($author) - skipped (may be a test log)"
            Write-Host "  Skipping assignee-uploaded log: $filename (by $author)"
            $manifest.Add($entry); continue
        }
        if ($size -gt $MaxAttachmentBytes) {
            $entry.SkippedReason = "exceeds size limit ($size bytes > $MaxAttachmentBytes)"
            Write-Warning "  Skipping oversized attachment: $filename ($size bytes)"
            $manifest.Add($entry); continue
        }
        if ([string]::IsNullOrWhiteSpace($url)) {
            $entry.SkippedReason = "no content URL"
            $manifest.Add($entry); continue
        }

        if (-not (Test-Path $attachmentsDir)) {
            New-Item -ItemType Directory -Path $attachmentsDir -Force | Out-Null
        }
        $safeName = $filename -replace '[\\/:*?"<>|]', '_'
        $localPath = Join-Path $attachmentsDir $safeName
        try {
            Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing `
                -OutFile $localPath -TimeoutSec 120
            $entry.Downloaded = $true
            $entry.LocalPath  = $localPath
            Write-Host "  Downloaded log attachment: $filename ($size bytes, by $author)"
        }
        catch {
            $entry.SkippedReason = "download failed: $($_.Exception.Message)"
            Write-Warning "  Failed to download attachment '$filename': $($_.Exception.Message)"
        }
        $manifest.Add($entry)
    }
}

$manifestPath = Join-Path $issueFolder "attachments-manifest.json"
@($manifest) | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $manifestPath
$downloadedCount = @($manifest | Where-Object { $_.Downloaded }).Count
Write-Host "Saved attachment manifest to $manifestPath ($($manifest.Count) attachment(s), $downloadedCount log(s) downloaded for analysis)"
