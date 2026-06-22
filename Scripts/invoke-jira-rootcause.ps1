param(
    # What the script should do. The 'analyze' action gathers JIRA context for an
    # issue; the others are on-demand code-access tools the chat model invokes
    # while reasoning (so the *configured VS Code Copilot model* does the
    # analysis - this script never calls an LLM itself).
    [ValidateSet("analyze", "search", "readfile", "listdir", "listrepos")]
    [string]$Action = "analyze",

    [string]$IssueId,       # required for: analyze
    [string]$Query,         # required for: search
    [string]$Path,          # required for: readfile; optional for: listdir
    [string]$Repo,          # optional: target repository (defaults to inferred/first)
    [int]$StartLine = 1,    # readfile: first 1-based line
    [int]$EndLine = 0,      # readfile: last 1-based line (0 = start + 1499; -1 = whole file)

    [string]$MapFile = "config/module-repo-map.json",
    [string]$OutputDir = "output"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===========================================================================
# Jira Root Cause Agent  -  context gatherer + code-access toolbox
#
# This script does NOT call any LLM. The reasoning is done by the model you
# have selected in the VS Code Copilot Chat window. The script's job is to:
#   * analyze  : fetch a JIRA issue and write a context bundle the chat reads.
#   * search   : code-search the (Enterprise) GitHub repo and print results.
#   * readfile : print a numbered slice of a repo source file.
#   * listdir  : list a repo directory.
#   * listrepos: print the configured component -> repository map.
#
# The chat model invokes the search/readfile/listdir actions as its own tools
# (via the `execute` tool) to investigate, then writes the analysis. The agent
# is therefore generic: it can diagnose ANY issue type in ANY language, not just
# kernel crashes or NULL-pointer dereferences.
# ===========================================================================

# ---------------------------------------------------------------------------
# Credentials / configuration
# ---------------------------------------------------------------------------

function Get-AgentCreds {
    param([string]$ProjectRoot)

    $homePath = [Environment]::GetFolderPath("UserProfile")
    $defaultUserCredFile = Join-Path (Join-Path $homePath ".jira-agent") "jira-rootcause-creds.json"

    $candidateFiles = @()
    if (-not [string]::IsNullOrWhiteSpace($env:JIRA_CREDS_FILE)) { $candidateFiles += $env:JIRA_CREDS_FILE }
    $candidateFiles += $defaultUserCredFile
    $candidateFiles += (Join-Path $ProjectRoot "config/jira-creds.json")

    foreach ($candidate in $candidateFiles) {
        if (-not (Test-Path $candidate)) { continue }
        try { return (Get-Content $candidate -Raw | ConvertFrom-Json) }
        catch { }
    }
    return $null
}

function Get-GitHubToken {
    param([object]$Creds)

    $placeholderPattern = '^(REPLACE_ME.*|your[_\.].*|<.*>|TODO.*)$'
    if ($Creds -and ($Creds.PSObject.Properties.Name -contains "GITHUB_TOKEN")) {
        $t = [string]$Creds.GITHUB_TOKEN
        if ($t -and $t -notmatch $placeholderPattern) { return $t }
    }
    $t = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "Process")
    if (-not [string]::IsNullOrWhiteSpace($t)) { return $t }
    $t = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "User")
    if (-not [string]::IsNullOrWhiteSpace($t)) { return $t }
    return ""
}

# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------

function Test-GitHubConnectivity {
    param([string]$Token, [string]$GitHubBaseUrl = "https://api.github.com")

    $headers = @{ Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    try {
        $null = Invoke-WebRequest -Uri "$GitHubBaseUrl/zen" -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 10
        return $true
    }
    catch [System.Net.WebException] {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 401) { Write-Warning "GitHub auth failed (401). Set a valid GITHUB_TOKEN. Code-access actions will fail until fixed." }
        elseif ($statusCode -eq 403) { Write-Warning "GitHub 403 Forbidden. Token may lack 'repo' scope." }
        else { Write-Warning "Cannot reach GitHub API at '$GitHubBaseUrl': $($_.Exception.Message)." }
        return $false
    }
    catch {
        Write-Warning "Cannot reach GitHub API at '$GitHubBaseUrl': $($_.Exception.Message)."
        return $false
    }
}

# Fetch a single file's raw text from GitHub. Returns { Path, Lines, HtmlUrl } or $null.
function Get-GitHubFileContent {
    param(
        [string]$GitHubOrg, [string]$GitHubRepo, [string]$FilePath,
        [string]$Token, [string]$GitHubBaseUrl = "https://api.github.com", [string]$Ref = ""
    )

    $headers = @{ Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    $encoded = ($FilePath -replace '^/', '') -replace ' ', '%20'
    $url = "$GitHubBaseUrl/repos/$GitHubOrg/$GitHubRepo/contents/$encoded"
    if ($Ref) { $url += "?ref=$Ref" }

    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 30
    }
    catch [System.Net.WebException] {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 404) { return $null }
        if ($statusCode -eq 401 -or $statusCode -eq 403) { throw "GitHub API auth failed ($statusCode) reading '$FilePath'. Check GITHUB_TOKEN 'repo' scope." }
        throw "GitHub API error reading '$FilePath': $($_.Exception.Message)"
    }

    $rawContent = $resp.Content
    try {
        $obj = $rawContent | ConvertFrom-Json
        if ($obj.encoding -eq 'base64' -and $obj.content) {
            $rawContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($obj.content -replace '[\r\n\s]', '')))
        }
        elseif ($obj.type -eq 'file' -and -not $obj.content) {
            if ($obj.sha) {
                $blobUrl = "$GitHubBaseUrl/repos/$GitHubOrg/$GitHubRepo/git/blobs/$($obj.sha)"
                $blobHeaders = $headers.Clone(); $blobHeaders["Accept"] = "application/vnd.github.raw+json"
                try {
                    $blobResp = Invoke-WebRequest -Uri $blobUrl -Headers $blobHeaders -Method Get -UseBasicParsing -TimeoutSec 60
                    $rawContent = $blobResp.Content
                    try {
                        $blobObj = $rawContent | ConvertFrom-Json
                        if ($blobObj.encoding -eq 'base64') {
                            $rawContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($blobObj.content -replace '[\r\n\s]', '')))
                        }
                    } catch { }
                }
                catch { return $null }
            } else { return $null }
        }
    }
    catch { }

    $firstLine = ($rawContent -split "`n", 2)[0]
    if ($firstLine.Length -gt 500 -and $firstLine -notmatch '\s') { return $null }

    $fileLines = [string[]]($rawContent -split "`r?`n")
    return @{
        Path    = $FilePath
        Lines   = $fileLines
        HtmlUrl = "$($GitHubBaseUrl -replace '/api/v3$','')/$GitHubOrg/$GitHubRepo/blob/HEAD/$FilePath"
    }
}

# Fetch a repo file *once* and reuse it for any later line-range request.
#
# A `readfile` slice only prints up to 1500 lines, but the model often needs to
# inspect several ranges of the same file. Without caching, every slice triggers
# a fresh (and identical) GitHub download of the whole file. This wrapper writes
# the full file content to a small on-disk cache the first time it is read, so
# subsequent reads of ANY range of that file are served locally with no further
# GitHub calls.
function Get-RepoFileCached {
    param([hashtable]$Ctx, [string]$RepoName, [string]$FilePath, [int]$TtlMinutes = 120)

    $cacheDir = if ($Ctx.ContainsKey('CacheDir')) { $Ctx.CacheDir } else { $null }
    if ($cacheDir -and -not (Test-Path $cacheDir)) {
        try { $null = New-Item -ItemType Directory -Path $cacheDir -Force } catch { $cacheDir = $null }
    }

    $key = "$($Ctx.Org)/$RepoName/$($FilePath -replace '^/', '')"
    $cacheFile = $null
    if ($cacheDir) {
        $sha = [System.Security.Cryptography.SHA1]::Create()
        try {
            $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))).Replace('-', '').Substring(0, 20)
        } finally { $sha.Dispose() }
        $cacheFile = Join-Path $cacheDir "$hash.json"
    }

    if ($cacheFile -and (Test-Path $cacheFile)) {
        $ageMin = (New-TimeSpan -Start (Get-Item $cacheFile).LastWriteTime -End (Get-Date)).TotalMinutes
        if ($ageMin -le $TtlMinutes) {
            try {
                $cached = Get-Content $cacheFile -Raw | ConvertFrom-Json
                return @{ Path = [string]$cached.Path; Lines = [string[]]$cached.Lines; HtmlUrl = [string]$cached.HtmlUrl; FromCache = $true }
            }
            catch { }   # corrupt cache entry -> fall through and re-fetch
        }
    }

    $file = Get-GitHubFileContent -GitHubOrg $Ctx.Org -GitHubRepo $RepoName -FilePath $FilePath -Token $Ctx.Token -GitHubBaseUrl $Ctx.BaseUrl
    if (-not $file) { return $null }

    if ($cacheFile) {
        try {
            @{ Path = $file.Path; Lines = $file.Lines; HtmlUrl = $file.HtmlUrl; Key = $key } |
                ConvertTo-Json -Depth 5 -Compress | Set-Content -Encoding UTF8 $cacheFile
        }
        catch { }
    }
    $file.FromCache = $false
    return $file
}

function Get-GitHubDirectory {
    param(
        [string]$GitHubOrg, [string]$GitHubRepo, [string]$DirPath,
        [string]$Token, [string]$GitHubBaseUrl = "https://api.github.com"
    )

    $headers = @{ Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    $encoded = ($DirPath -replace '^/', '') -replace ' ', '%20'
    $url = "$GitHubBaseUrl/repos/$GitHubOrg/$GitHubRepo/contents/$encoded"
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 20
        $items = $resp.Content | ConvertFrom-Json
        return @($items | ForEach-Object { @{ Name = $_.name; Path = $_.path; Type = $_.type } })
    }
    catch { return @() }
}

function Search-GitHubCode {
    param(
        [string]$GitHubOrg, [string]$GitHubRepo, [string]$Query,
        [string]$Token, [string]$GitHubBaseUrl = "https://api.github.com"
    )

    $headers = @{ Accept = "application/vnd.github.text-match+json"; "X-GitHub-Api-Version" = "2022-11-28" }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    $scoped = "$Query repo:$GitHubOrg/$GitHubRepo"
    $encoded = [Uri]::EscapeDataString($scoped)
    $url = "$GitHubBaseUrl/search/code?q=$encoded&per_page=15"

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Query: $scoped")
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 20
    }
    catch [System.Net.WebException] {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 401 -or $statusCode -eq 403) { return "GitHub search auth/permission error ($statusCode). Token may lack 'repo' scope." }
        if ($statusCode -eq 422 -or $statusCode -eq 429) { return "GitHub search rate-limited or query rejected (status $statusCode). Try a simpler query or wait a moment." }
        return "GitHub search error: $($_.Exception.Message)"
    }
    catch { return "GitHub search error: $($_.Exception.Message)" }

    $json = $resp.Content | ConvertFrom-Json
    $lines.Add("Total hits: $($json.total_count)")
    if ($json.total_count -eq 0) {
        $lines.Add("(no matches)")
    } else {
        foreach ($item in $json.items) {
            $lines.Add("FILE: $($item.path)")
            if ($item.PSObject.Properties.Name -contains "text_matches") {
                foreach ($tm in $item.text_matches) {
                    $fragment = ($tm.fragment -replace '\r?\n', '  ').Trim()
                    if ($fragment) { $lines.Add("  MATCH: $fragment") }
                }
            }
        }
    }
    Start-Sleep -Milliseconds 1100   # GitHub code-search secondary rate limit (~1 req/sec)
    return ($lines -join "`n")
}

# ---------------------------------------------------------------------------
# JIRA data extraction
# ---------------------------------------------------------------------------

function Get-AllJiraData {
    param([object]$Issue)

    $f = $Issue.fields
    $data = [ordered]@{
        Key         = $Issue.key
        Summary     = [string]$f.summary
        Status      = [string]$f.status.name
        Priority    = [string]$f.priority.name
        Assignee    = if ($f.assignee) { [string]$f.assignee.displayName } else { "Unassigned" }
        Reporter    = if ($f.reporter) { [string]$f.reporter.displayName } else { "" }
        Created     = [string]$f.created
        Updated     = [string]$f.updated
        Components  = @()
        Labels      = @()
        Description = [string]$f.description
        Comments    = [System.Collections.Generic.List[object]]::new()
        Attachments = [System.Collections.Generic.List[object]]::new()
        LinkedIssues = [System.Collections.Generic.List[object]]::new()
        Versions    = @()
        FixVersions = @()
        Environment = [string]$f.environment
        CustomFields = [ordered]@{}
    }

    if ($f.components) { $data.Components = @($f.components | ForEach-Object { [string]$_.name }) }
    if ($f.labels)     { $data.Labels     = @($f.labels     | ForEach-Object { [string]$_ }) }
    if ($f.versions)   { $data.Versions   = @($f.versions   | ForEach-Object { [string]$_.name }) }
    if ($f.fixVersions){ $data.FixVersions= @($f.fixVersions| ForEach-Object { [string]$_.name }) }

    if ($f.comment -and $f.comment.comments) {
        foreach ($c in $f.comment.comments) {
            $data.Comments.Add([ordered]@{ Author = [string]$c.author.displayName; Date = [string]$c.created; Body = [string]$c.body })
        }
    }

    if ($f.attachment) {
        foreach ($a in $f.attachment) {
            $data.Attachments.Add([ordered]@{
                Filename = [string]$a.filename
                Author   = if ($a.author) { [string]$a.author.displayName } else { "" }
                MimeType = [string]$a.mimeType
                Size     = [long]$a.size
                Url      = [string]$a.content
                Created  = [string]$a.created
            })
        }
    }

    if ($f.issuelinks) {
        foreach ($lnk in $f.issuelinks) {
            $hasOutward = $lnk.PSObject.Properties.Name -contains 'outwardIssue' -and $null -ne $lnk.outwardIssue
            $linked = if ($hasOutward) { $lnk.outwardIssue } else { $lnk.inwardIssue }
            if ($linked) {
                $data.LinkedIssues.Add([ordered]@{
                    Key     = [string]$linked.key
                    Summary = [string]$linked.fields.summary
                    Status  = [string]$linked.fields.status.name
                    Type    = if ($hasOutward) { [string]$lnk.type.outward } else { [string]$lnk.type.inward }
                })
            }
        }
    }

    foreach ($prop in $f.PSObject.Properties) {
        if ($prop.Name -match '^customfield_' -and $null -ne $prop.Value -and $prop.Value -ne "") {
            $val = $prop.Value
            if ($val -is [string] -or $val -is [int] -or $val -is [long] -or $val -is [double]) {
                $data.CustomFields[$prop.Name] = $val
            }
            elseif ($val -is [System.Management.Automation.PSCustomObject]) {
                $valStr = try { [string]$val.value } catch { "" }
                if ($valStr) { $data.CustomFields[$prop.Name] = $valStr }
            }
        }
    }

    return $data
}

function Read-LogAttachmentText {
    param([string]$Path, [int]$MaxChars = 2000000)

    if ($Path -match '(?i)\.gz$') {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        $gz = New-Object System.IO.Compression.GzipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
        $sr = New-Object System.IO.StreamReader($gz)
        try { $text = $sr.ReadToEnd() }
        finally { $sr.Dispose(); $gz.Dispose(); $ms.Dispose() }
    }
    else {
        $text = Get-Content -Path $Path -Raw -ErrorAction Stop
    }

    if ($null -eq $text) { return "" }
    if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + "`n[... truncated at $MaxChars characters ...]" }
    return $text
}

# Best-effort component/repo inference. Returns the matching module or $null.
function Resolve-Module {
    param([string]$Text, [object]$Map)

    $best = $null; $bestScore = 0
    foreach ($module in $Map.modules) {
        $score = 0
        foreach ($token in $module.match) {
            if ($Text.Contains($token.ToLowerInvariant())) { $score += 1 }
        }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $module }
    }
    return $best
}

# ---------------------------------------------------------------------------
# Shared initialization (config, token, repo map)
# ---------------------------------------------------------------------------

function Initialize-AgentContext {
    param([string]$ProjectRoot, [string]$MapFile)

    $mapPath = if ([System.IO.Path]::IsPathRooted($MapFile)) { $MapFile } else { Join-Path $ProjectRoot $MapFile }
    $map = Get-Content $mapPath -Raw | ConvertFrom-Json

    $creds = Get-AgentCreds -ProjectRoot $ProjectRoot
    $token = Get-GitHubToken -Creds $creds
    $org   = $map.githubOrg

    $baseUrl = if ($map.PSObject.Properties.Name -contains "githubBaseUrl") {
                   $map.githubBaseUrl
               } else {
                   $envUrl = [Environment]::GetEnvironmentVariable("GITHUB_ENTERPRISE_URL", "Process")
                   if ([string]::IsNullOrWhiteSpace($envUrl)) { $envUrl = [Environment]::GetEnvironmentVariable("GITHUB_ENTERPRISE_URL", "User") }
                   if ([string]::IsNullOrWhiteSpace($envUrl)) { "https://api.github.com" } else { $envUrl }
               }

    if ([string]::IsNullOrWhiteSpace($org) -or $org -match '^REPLACE_') {
        throw "STOP: GitHub organization not configured. Set 'githubOrg' in config/module-repo-map.json."
    }

    $repos = @($map.modules | ForEach-Object { [ordered]@{ name = $_.name; repo = $_.githubRepo; match = @($_.match) } })
    $defaultRepo = if ($repos.Count -gt 0) { $repos[0].repo } else { "" }

    return @{ Map = $map; Token = $token; Org = $org; BaseUrl = $baseUrl; Repos = $repos; DefaultRepo = $defaultRepo }
}

# Resolve which repository an action targets: explicit -Repo wins, else default.
function Resolve-RepoName {
    param([string]$Requested, [hashtable]$Ctx)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { return $Requested }
    return $Ctx.DefaultRepo
}

# ---------------------------------------------------------------------------
# Context bundle (what the chat model reads to start reasoning)
# ---------------------------------------------------------------------------

function Build-ContextBundle {
    param([hashtable]$JiraData, [string]$AttachmentLogText, [object]$Module, [string]$DefaultRepo, [hashtable]$Ctx)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# JIRA Context Bundle: $($JiraData.Key)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("> Generated by invoke-jira-rootcause.ps1 (action: analyze). This file is")
    [void]$sb.AppendLine("> raw context only. The analysis is performed by the model selected in the")
    [void]$sb.AppendLine("> VS Code Copilot Chat window, which investigates further via the script's")
    [void]$sb.AppendLine("> search / readfile / listdir actions and then writes the report.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Fields")
    [void]$sb.AppendLine("- Summary: $($JiraData.Summary)")
    [void]$sb.AppendLine("- Status: $($JiraData.Status)   Priority: $($JiraData.Priority)")
    [void]$sb.AppendLine("- Reporter: $($JiraData.Reporter)   Assignee: $($JiraData.Assignee)")
    if ($JiraData.Components.Count -gt 0) { [void]$sb.AppendLine("- Components: $($JiraData.Components -join ', ')") }
    if ($JiraData.Labels.Count -gt 0)     { [void]$sb.AppendLine("- Labels: $($JiraData.Labels -join ', ')") }
    if ($JiraData.Versions.Count -gt 0)   { [void]$sb.AppendLine("- Affected versions: $($JiraData.Versions -join ', ')") }
    if ($JiraData.Environment)            { [void]$sb.AppendLine("- Environment: $($JiraData.Environment.Trim() -replace '\r?\n',' ')") }
    [void]$sb.AppendLine("")

    $moduleName = if ($Module) { $Module.name } else { "(not confidently inferred)" }
    [void]$sb.AppendLine("## Inferred component (hint only - the model may override)")
    [void]$sb.AppendLine("- Component: $moduleName")
    [void]$sb.AppendLine("- Default repository: $($Ctx.Org)/$DefaultRepo")
    [void]$sb.AppendLine("- Available repositories:")
    foreach ($m in $Ctx.Repos) { [void]$sb.AppendLine("  - $($Ctx.Org)/$($m.repo)  (component: $($m.name); keywords: $($m.match -join ', '))") }
    [void]$sb.AppendLine("")

    [void]$sb.AppendLine("## Description")
    $desc = if ($JiraData.Description) { $JiraData.Description } else { "(empty)" }
    [void]$sb.AppendLine($desc)
    [void]$sb.AppendLine("")

    if ($JiraData.Comments.Count -gt 0) {
        [void]$sb.AppendLine("## Comments ($($JiraData.Comments.Count))")
        $idx = 1
        foreach ($c in $JiraData.Comments) {
            [void]$sb.AppendLine("### Comment $idx  -  $($c.Author) ($($c.Date))")
            [void]$sb.AppendLine([string]$c.Body)
            [void]$sb.AppendLine("")
            $idx++
        }
    }

    if ($JiraData.LinkedIssues.Count -gt 0) {
        [void]$sb.AppendLine("## Linked issues")
        foreach ($li in $JiraData.LinkedIssues) { [void]$sb.AppendLine("- $($li.Type): $($li.Key) [$($li.Status)] $($li.Summary)") }
        [void]$sb.AppendLine("")
    }

    if ($AttachmentLogText -and $AttachmentLogText.Trim()) {
        [void]$sb.AppendLine("## Attached log excerpts (non-assignee uploads)")
        [void]$sb.AppendLine('```')
        $logs = $AttachmentLogText
        if ($logs.Length -gt 400000) { $logs = $logs.Substring(0, 400000) + "`n[... attachment logs truncated; read the file on disk for the rest ...]" }
        [void]$sb.AppendLine($logs)
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("## Next steps for the analyst (you, the chat model)")
    [void]$sb.AppendLine("1. Form a hypothesis about the component and likely cause from the evidence above.")
    [void]$sb.AppendLine("2. Investigate the real code using the script's actions (run via your execute tool):")
    [void]$sb.AppendLine("   - Search:    powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -Action search -Query '<terms>' -Repo <repo>")
    [void]$sb.AppendLine("   - Read file: powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -Action readfile -Path <path> -Repo <repo> -StartLine <n> -EndLine <m>")
    [void]$sb.AppendLine("     Tip: each file is downloaded from GitHub only ONCE then cached on disk, so prefer FEWER, LARGER reads.")
    [void]$sb.AppendLine("     Use -EndLine -1 to read an entire file in a single call; omit -EndLine to read up to 1500 lines from -StartLine.")
    [void]$sb.AppendLine("   - List dir:  powershell -ExecutionPolicy Bypass -File Scripts/invoke-jira-rootcause.ps1 -Action listdir -Path <dir> -Repo <repo>")
    [void]$sb.AppendLine("3. Verify every claim against code you actually read. Do not invent file contents or APIs.")
    [void]$sb.AppendLine("4. Write the final report to output/$($JiraData.Key)/$($JiraData.Key)-analysis.md.")
    [void]$sb.AppendLine("   The report MUST include the following sections (in order):")
    [void]$sb.AppendLine("   - Summary")
    [void]$sb.AppendLine("   - Timeline (if log timestamps are available)")
    [void]$sb.AppendLine("   - Root Cause  ← REQUIRED in every report; cite exact file path + line numbers from code you read")
    [void]$sb.AppendLine("   - Proposed Fix  ← REQUIRED in every report; show as unified diff or before/after snippet with file path + line numbers")
    [void]$sb.AppendLine("       * If evidence is insufficient for a fix, explain what additional data is needed - do NOT omit the section")
    [void]$sb.AppendLine("   - Reproduction Steps  ← REQUIRED in every report, no exceptions")
    [void]$sb.AppendLine("       * Deterministic bug: exact ordered steps (preconditions, inputs, commands, expected vs. actual).")
    [void]$sb.AppendLine("       * Race / timing / memory-pressure bug: (a) conditions that must coincide (grounded in code),")
    [void]$sb.AppendLine("         (b) a stress procedure using standard tooling, and (c) a fault-injection variant for a debug")
    [void]$sb.AppendLine("         build that makes the failure deterministic and doubles as a regression test.")
    [void]$sb.AppendLine("       * Mark any step you did not actually run as derived/unverified strategy.")
    [void]$sb.AppendLine("   - Affected Files")
    [void]$sb.AppendLine("   - Evidence Confidence")
    [void]$sb.AppendLine("   - Information Still Needed (if any)")
    [void]$sb.AppendLine("5. If evidence is insufficient, say so and list exactly what is needed (stack trace, repro, logs).")
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Invoke-AnalyzeAction {
    param([string]$ScriptRoot, [string]$ProjectRoot, [hashtable]$Ctx, [string]$IssueId, [string]$OutputDir)

    if ([string]::IsNullOrWhiteSpace($IssueId)) { throw "The 'analyze' action requires -IssueId." }

    Write-Host "Pre-flight: testing GitHub connectivity ($($Ctx.BaseUrl)) ..."
    $null = Test-GitHubConnectivity -Token $Ctx.Token -GitHubBaseUrl $Ctx.BaseUrl

    Write-Host "Fetching JIRA issue $IssueId ..."
    & (Join-Path $ScriptRoot "fetch-jira.ps1") -IssueId $IssueId -OutputDir $OutputDir

    $issueFolder = Join-Path $OutputDir $IssueId
    $jsonPath    = Join-Path $issueFolder "$IssueId.json"
    if (-not (Test-Path $jsonPath)) { throw "JIRA JSON not found at $jsonPath" }

    Write-Host "Extracting JIRA data ..."
    $issue    = Get-Content $jsonPath -Raw | ConvertFrom-Json
    $jiraData = Get-AllJiraData -Issue $issue
    Write-Host "  Description: $(if($jiraData.Description){'present'}else{'empty'}); Comments: $($jiraData.Comments.Count); Attachments: $($jiraData.Attachments.Count); Linked: $($jiraData.LinkedIssues.Count)"

    Write-Host "Loading downloaded log attachments ..."
    $attachmentLogText  = ""
    $attachmentAnalysis = [System.Collections.Generic.List[object]]::new()
    $manifestPath = Join-Path $issueFolder "attachments-manifest.json"
    if (Test-Path $manifestPath) {
        $attManifest = @(Get-Content $manifestPath -Raw | ConvertFrom-Json)
        foreach ($att in $attManifest) {
            $record = [ordered]@{ Filename = [string]$att.Filename; Author = [string]$att.Author; Analyzed = $false; Reason = [string]$att.SkippedReason; Chars = 0 }
            if (($att.Downloaded -eq $true) -and (-not [string]::IsNullOrWhiteSpace([string]$att.LocalPath)) -and (Test-Path ([string]$att.LocalPath))) {
                try {
                    $text = Read-LogAttachmentText -Path $att.LocalPath
                    if ($text -and $text.Trim().Length -gt 0) {
                        $attachmentLogText += "`n===== ATTACHMENT: $($att.Filename) (uploaded by $($att.Author)) =====`n" + $text + "`n"
                        $record.Analyzed = $true; $record.Reason = ""; $record.Chars = $text.Length
                        Write-Host "  Including log attachment: $($att.Filename) ($($text.Length) chars)"
                    }
                }
                catch { $record.Reason = "read failed: $($_.Exception.Message)"; Write-Warning "  Could not read '$($att.Filename)': $($_.Exception.Message)" }
            }
            $attachmentAnalysis.Add($record)
        }
    }

    $fullText = @($jiraData.Summary, $jiraData.Description, ($jiraData.Comments | ForEach-Object { $_.Body }), $jiraData.Environment) -join "`n"
    $combinedText = if ($attachmentLogText) { $fullText + "`n" + $attachmentLogText } else { $fullText }
    $module = Resolve-Module -Text $combinedText.ToLowerInvariant() -Map $Ctx.Map
    $defaultRepo = if ($module -and $module.PSObject.Properties.Name -contains 'githubRepo' -and $module.githubRepo) { $module.githubRepo } else { $Ctx.DefaultRepo }
    Write-Host "Component inferred: $(if($module){$module.name}else{'(none)'}) -> default repo $($Ctx.Org)/$defaultRepo"

    $bundle = Build-ContextBundle -JiraData $jiraData -AttachmentLogText $attachmentLogText -Module $module -DefaultRepo $defaultRepo -Ctx $Ctx
    $bundlePath = Join-Path $issueFolder "context-bundle.md"
    $bundle | Set-Content -Encoding UTF8 $bundlePath

    $context = [ordered]@{
        issueId           = $IssueId
        summary           = $jiraData.Summary
        status            = $jiraData.Status
        priority          = $jiraData.Priority
        inferredComponent = if ($module) { $module.name } else { "" }
        githubOrg         = $Ctx.Org
        defaultRepo       = $defaultRepo
        availableRepos    = @($Ctx.Repos | ForEach-Object { $_.repo })
        commentCount      = $jiraData.Comments.Count
        attachmentCount   = $jiraData.Attachments.Count
        logAttachmentsIncluded = @($attachmentAnalysis | Where-Object { $_.Analyzed } | ForEach-Object { $_.Filename })
        linkedIssueCount  = $jiraData.LinkedIssues.Count
        jsonPath          = $jsonPath
        contextBundlePath = $bundlePath
        analysisPath      = (Join-Path $issueFolder "$IssueId-analysis.md")
    }
    $contextPath = Join-Path $issueFolder "context.json"
    $context | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $contextPath

    Write-Host ""
    Write-Host "Context gathered. The chat model should now read and reason over:"
    Write-Host "  Context bundle : $bundlePath"
    Write-Host "  Raw JIRA JSON  : $jsonPath"
    Write-Host "  Context (meta) : $contextPath"
    Write-Host ""
    Write-Host "Then investigate code with -Action search/readfile/listdir, and write the report to:"
    Write-Host "  $($context.analysisPath)"
}

function Invoke-SearchAction {
    param([hashtable]$Ctx, [string]$Query, [string]$Repo)
    if ([string]::IsNullOrWhiteSpace($Query)) { throw "The 'search' action requires -Query." }
    $repoName = Resolve-RepoName -Requested $Repo -Ctx $Ctx
    $result = Search-GitHubCode -GitHubOrg $Ctx.Org -GitHubRepo $repoName -Query $Query -Token $Ctx.Token -GitHubBaseUrl $Ctx.BaseUrl
    Write-Output "Repository: $($Ctx.Org)/$repoName"
    Write-Output $result
}

function Invoke-ReadFileAction {
    param([hashtable]$Ctx, [string]$Path, [string]$Repo, [int]$StartLine, [int]$EndLine)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "The 'readfile' action requires -Path." }
    $repoName = Resolve-RepoName -Requested $Repo -Ctx $Ctx
    $file = Get-RepoFileCached -Ctx $Ctx -RepoName $repoName -FilePath $Path
    if (-not $file) { Write-Output "File not found (or too large/binary): $($Ctx.Org)/$repoName/$Path"; return }

    $total = $file.Lines.Count
    $wholeFile = ($EndLine -eq -1)
    $start = if ($StartLine -ge 1) { $StartLine } else { 1 }
    if ($start -gt $total) { $start = $total }
    if ($wholeFile) {
        # -EndLine -1 => return the entire file in one call (no 1500-line cap).
        # Safe because the file is fetched from GitHub once and served from the
        # on-disk cache; a single large read costs the same network as a slice.
        $start = 1
        $end = $total
    }
    else {
        $end = if ($EndLine -ge 1) { $EndLine } else { $start + 1499 }
        if ($end -gt $total) { $end = $total }
        if ($end -lt $start) { $end = $start }
        if (($end - $start) -gt 1499) { $end = $start + 1499 }   # 1500-line cap
    }

    $source = if ($file.FromCache) { "local cache" } else { "GitHub (now cached)" }
    Write-Output "File: $($Ctx.Org)/$repoName/$Path  (lines $start-$end of $total)  [source: $source]"
    Write-Output "URL: $($file.HtmlUrl)"
    Write-Output '```'
    for ($i = $start; $i -le $end; $i++) { Write-Output ("{0,6}: {1}" -f $i, $file.Lines[$i - 1]) }
    Write-Output '```'
}

function Invoke-ListDirAction {
    param([hashtable]$Ctx, [string]$Path, [string]$Repo)
    $repoName = Resolve-RepoName -Requested $Repo -Ctx $Ctx
    $dir = if ($null -eq $Path) { "" } else { $Path }
    $items = Get-GitHubDirectory -GitHubOrg $Ctx.Org -GitHubRepo $repoName -DirPath $dir -Token $Ctx.Token -GitHubBaseUrl $Ctx.BaseUrl
    if (-not $items -or $items.Count -eq 0) { Write-Output "No entries found at '$($Ctx.Org)/$repoName/$dir' (path may not exist)."; return }
    Write-Output "Directory '$($Ctx.Org)/$repoName/$dir':"
    foreach ($it in $items) {
        $suffix = if ($it.Type -eq 'dir') { '/' } else { '' }
        Write-Output "- $($it.Path)$suffix"
    }
}

function Invoke-ListReposAction {
    param([hashtable]$Ctx)
    Write-Output "GitHub org: $($Ctx.Org)   base URL: $($Ctx.BaseUrl)"
    Write-Output "Configured repositories:"
    foreach ($m in $Ctx.Repos) { Write-Output "- $($Ctx.Org)/$($m.repo)  (component: $($m.name); keywords: $($m.match -join ', '))" }
    Write-Output "Default repository: $($Ctx.DefaultRepo)"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

$scriptRoot  = Split-Path -Parent $PSCommandPath
$projectRoot = Split-Path -Parent $scriptRoot

Push-Location $projectRoot
try {
    $ctx = Initialize-AgentContext -ProjectRoot $projectRoot -MapFile $MapFile
    $ctx.CacheDir = Join-Path $projectRoot (Join-Path $OutputDir ".filecache")

    switch ($Action) {
        "analyze"   { Invoke-AnalyzeAction  -ScriptRoot $scriptRoot -ProjectRoot $projectRoot -Ctx $ctx -IssueId $IssueId -OutputDir $OutputDir }
        "search"    { Invoke-SearchAction   -Ctx $ctx -Query $Query -Repo $Repo }
        "readfile"  { Invoke-ReadFileAction -Ctx $ctx -Path $Path -Repo $Repo -StartLine $StartLine -EndLine $EndLine }
        "listdir"   { Invoke-ListDirAction  -Ctx $ctx -Path $Path -Repo $Repo }
        "listrepos" { Invoke-ListReposAction -Ctx $ctx }
    }
}
finally {
    Pop-Location
}
