param(
    [Parameter(Mandatory)]
    [string]$IssueId,

    [string]$MapFile = "config/module-repo-map.json",
    [string]$OutputDir = "output"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------

function Get-GitHubToken {
    param([string]$ProjectRoot)

    $fileCreds = $null
    $homePath = [Environment]::GetFolderPath("UserProfile")
    $defaultUserCredFile = Join-Path (Join-Path $homePath ".jira-agent") "jira-rootcause-creds.json"

    $candidateFiles = @()
    if (-not [string]::IsNullOrWhiteSpace($env:JIRA_CREDS_FILE)) {
        $candidateFiles += $env:JIRA_CREDS_FILE
    }
    $candidateFiles += $defaultUserCredFile
    $candidateFiles += (Join-Path $ProjectRoot "config/jira-creds.json")

    foreach ($candidate in $candidateFiles) {
        if (-not (Test-Path $candidate)) { continue }
        try {
            $fileCreds = Get-Content $candidate -Raw | ConvertFrom-Json
            break
        }
        catch { }
    }

    $placeholderPattern = '^(REPLACE_ME.*|your[_\.].*|<.*>|TODO.*)$'
    if ($fileCreds -and $fileCreds.PSObject.Properties.Name -contains "GITHUB_TOKEN") {
        $t = [string]$fileCreds.GITHUB_TOKEN
        if ($t -and $t -notmatch $placeholderPattern) { return $t }
    }

    $t = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "Process")
    if (-not [string]::IsNullOrWhiteSpace($t)) { return $t }

    $t = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "User")
    if (-not [string]::IsNullOrWhiteSpace($t)) { return $t }

    return ""
}

function Test-GitHubConnectivity {
    param(
        [string]$Token,
        [string]$GitHubBaseUrl = "https://api.github.com"
    )

    $headers = @{
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    try {
        $response = Invoke-WebRequest -Uri "$GitHubBaseUrl/zen" -Headers $headers `
            -Method Get -UseBasicParsing -TimeoutSec 10
    }
    catch [System.Net.WebException] {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 401) {
            throw "GitHub API authentication failed (401 Unauthorized). Set a valid GITHUB_TOKEN in config/jira-creds.json or the GITHUB_TOKEN env var. Aborting."
        }
        if ($statusCode -eq 403) {
            throw "GitHub API returned 403 Forbidden. Your token may lack 'repo' scope. Aborting."
        }
        throw "Cannot reach GitHub API at '$GitHubBaseUrl': $($_.Exception.Message). Check network connectivity. If using GitHub Enterprise, set GITHUB_ENTERPRISE_URL. Aborting."
    }
    catch {
        throw "Cannot reach GitHub API at '$GitHubBaseUrl': $($_.Exception.Message). Aborting."
    }

    Write-Host "GitHub connectivity: OK ($GitHubBaseUrl)"
}

# ---------------------------------------------------------------------------
# Crash-aware evidence extraction
# ---------------------------------------------------------------------------

# Extracts structured crash evidence from raw text (kernel Oops, call traces,
# BUG lines, panic messages, error strings). Returns a hashtable with typed
# fields so downstream search and analysis can operate on structured data
# instead of noise-heavy raw text.
function Get-CrashEvidence {
    param([string]$Text)

    $ev = [ordered]@{
        BugLines        = [System.Collections.Generic.List[string]]::new()   # BUG: / WARNING: / WARN: lines
        OopsAddresses   = [System.Collections.Generic.List[string]]::new()   # address: 0x... lines
        CallTraceFrames = [System.Collections.Generic.List[string]]::new()   # [<addr>] function+0x... or just function names from trace
        FunctionNames   = [System.Collections.Generic.List[string]]::new()   # unique identifiers from call trace
        KernelThreads   = [System.Collections.Generic.List[string]]::new()   # Comm: <name> lines
        ErrorCodes      = [System.Collections.Generic.List[string]]::new()   # error_code(...), ERRNO names
        LogMessages     = [System.Collections.Generic.List[string]]::new()   # driver / kernel log lines
        ModulesLinked   = [System.Collections.Generic.List[string]]::new()   # "Modules linked in:" entries
        PoisonHints     = [System.Collections.Generic.List[string]]::new()   # use-after-free / freed-poison register values
        KernelVersion   = ""
        CrashAddress    = ""
        CrashType       = ""
        CrashPoint      = ""
        CrashingPid     = ""
        RawOops         = [System.Collections.Generic.List[string]]::new()   # full Oops block lines
    }

    $lines = $Text -split "`r?`n"
    $inOops = $false

    foreach ($line in $lines) {
        # BUG / WARNING / WARN / Oops / KASAN / KFENCE / UBSAN / use-after-free / liveness
        if ($line -match '(BUG:|WARNING:|WARN:|Oops:|kernel BUG|general protection fault|Unable to handle|divide error|stack-protector|NULL pointer dereference|null pointer dereference|use-after-free|double free|KASAN:|KFENCE:|UBSAN:|refcount_t: underflow|refcount_t: overflow|list_add corruption|list_del corruption|slab-out-of-bounds|slab-use-after-free|stack-overflow|RCU Stall|hung_task|soft lockup|hard lockup|watchdog: BUG)') {
            $ev.BugLines.Add($line.Trim())
            $inOops = $true
            # Classify crash type from the first matching trigger line
            if (-not $ev.CrashType) {
                if    ($line -match 'KASAN:|use-after-free|slab-use-after-free')                   { $ev.CrashType = 'use-after-free' }
                elseif ($line -match 'double free')                                                { $ev.CrashType = 'double-free' }
                elseif ($line -match 'slab-out-of-bounds|out.of.bounds|KFENCE:')                   { $ev.CrashType = 'out-of-bounds' }
                elseif ($line -match 'NULL pointer dereference|null pointer')                      { $ev.CrashType = 'null-deref' }
                elseif ($line -match 'RCU Stall|hung_task|soft lockup|hard lockup|watchdog')       { $ev.CrashType = 'liveness' }
                elseif ($line -match 'UBSAN:')                                                     { $ev.CrashType = 'undefined-behavior' }
                elseif ($line -match 'general protection fault')                                   { $ev.CrashType = 'gpf' }
                elseif ($line -match 'Oops:')                                                      { $ev.CrashType = 'null-deref' }
                else                                                                               { $ev.CrashType = 'other' }
            }
        }

        # Crash address
        if ($line -match 'address:\s*(0x[0-9a-fA-F]+)') {
            $ev.CrashAddress = $Matches[1]
            $ev.OopsAddresses.Add($line.Trim())
        }

        # RIP / EIP / PC  -  exact faulting instruction (most precise crash location)
        if (-not $ev.CrashPoint) {
            if ($line -match '^\s*RIP:\s*\S+:\s*(.+)$' -or
                $line -match '^\s*PC\s+is\s+at\s+(.+)$' -or
                $line -match '^\s*EIP:\s*\S+:\s*(.+)$' -or
                $line -match '^\s*pc\s*:\s*([a-zA-Z_]\S+\+0x[0-9a-f]+)') {
                $ev.CrashPoint = $line.Trim()
            }
        }

        # Kernel version / tainted flags
        if ($line -match 'CPU:\s*\d+.*Comm:\s*(\S+)') {
            $threadName = $Matches[1]
            if (-not $ev.KernelThreads.Contains($threadName)) {
                $ev.KernelThreads.Add($threadName)
            }
        }
        if ($line -match 'Comm:\s*(\S+)') {
            $threadName = $Matches[1]
            if (-not $ev.KernelThreads.Contains($threadName)) {
                $ev.KernelThreads.Add($threadName)
            }
        }
        # Crashing PID  -  "PID: 1234 Comm:" or "pid: 1234"
        if (-not $ev.CrashingPid -and $line -match 'PID:\s*(\d+)') {
            $ev.CrashingPid = $Matches[1]
        }
        if ($line -match '(Linux version|SMP.*#\d+|\d+\.\d+\.\d+-\S+)') {
            if (-not $ev.KernelVersion) { $ev.KernelVersion = $line.Trim() }
        }

        # "Modules linked in:"  -  identifies the loaded modules (culprit driver is often last/tainting)
        if ($line -match 'Modules linked in:\s*(.+)$') {
            foreach ($m in ($Matches[1] -split '\s+' | Where-Object { $_ -match '^[a-zA-Z0-9_]{2,}$' })) {
                if (-not $ev.ModulesLinked.Contains($m)) { $ev.ModulesLinked.Add($m) }
            }
        }

        # Freed/uninitialized memory poison patterns in registers or fault address.
        # These strongly indicate use-after-free / read of freed slab memory.
        #   6b6b6b6b = SLUB POISON_FREE, 5a5a5a5a = SLUB_RED/uninitialised,
        #   dead0000... = LIST_POISON, ffffffff... = common freed-pointer sentinel
        if ($line -match '(?i)0x?((6b6b6b6b|5a5a5a5a)[0-9a-f]*|dead[0-9a-f]{12}|6b6b6b6b)') {
            $hint = $line.Trim()
            if (-not $ev.PoisonHints.Contains($hint)) { $ev.PoisonHints.Add($hint) }
            # A GPF or generic Oops on a poison value is use-after-free, not a plain NULL deref.
            if ($ev.CrashType -in @('gpf', 'null-deref', 'other', '')) { $ev.CrashType = 'use-after-free' }
        }

        # Call trace frames  -  kernel format: " <addr> function+0xNN/0xNN"
        # or "[<addr>] function+0x..." or just "  function+0xNN"
        if ($line -match '(?:\[\s*<[0-9a-f]+>\s*\]|\s{1,4}[0-9a-f]{16}\s+|\s*\[[\s0-9a-f]+\])\s*([a-zA-Z_][a-zA-Z0-9_.]+)\+0x') {
            $fname = $Matches[1]
            $ev.CallTraceFrames.Add($line.Trim())
            if (-not $ev.FunctionNames.Contains($fname)) { $ev.FunctionNames.Add($fname) }
        }
        # Modern kernel trace frame: optional "? " reliability marker then "symbol+0xNN/0xNN"
        # e.g. "  ? dvs_rq_node_up+0x1a/0x30 [dvsipc]" or "  process_one_work+0x1e0/0x3d0"
        elseif ($line -match '^\s*(?:\?\s+)?([a-zA-Z_][a-zA-Z0-9_.]{2,})\+0x[0-9a-f]+(?:/0x[0-9a-f]+)?') {
            $fname = $Matches[1]
            $ev.CallTraceFrames.Add($line.Trim())
            if (-not $ev.FunctionNames.Contains($fname)) { $ev.FunctionNames.Add($fname) }
        }
        # Simpler fallback: "  function.name+0x" pattern without address prefix
        elseif ($line -match '^\s{1,8}([a-zA-Z_][a-zA-Z0-9_.]{3,})\+0x[0-9a-f]+') {
            $fname = $Matches[1]
            $ev.CallTraceFrames.Add($line.Trim())
            if (-not $ev.FunctionNames.Contains($fname)) { $ev.FunctionNames.Add($fname) }
        }

        # error_code values
        if ($line -match 'error_code\(0x([0-9a-fA-F]+)\)') {
            $ec = "error_code(0x$($Matches[1]))"
            if (-not $ev.ErrorCodes.Contains($ec)) { $ev.ErrorCodes.Add($ec) }
        }

        # Diagnostic log lines (module-agnostic): any kernel/driver line carrying a
        # diagnostic keyword, or a "PREFIX: message" driver log line. De-duplicated so
        # repeated identical lines don't flood the report.
        $isTimestamped = $line -match '\[\s*\d+\.\d+\]' -or $line -match '^\s*\w{3}\s+\d+\s+\d+:\d+:\d+'
        $hasDiagKeyword = $line -match '(?i)(error|fail|timeout|timed.out|invalid|unexpected|corrupt|overflow|underflow|unable|cannot|refused|denied|null.dereference|use.after.free|out.of.bounds|panic|oops|warn|retry|stuck|hang|deadlock|abort|reset)'
        $isDriverPrefix = $line -match '^\s*(?:\[[^\]]*\]\s*)?[a-zA-Z][a-zA-Z0-9_]{1,}:\s+\S'
        if (($isTimestamped -and $hasDiagKeyword) -or ($isDriverPrefix -and $hasDiagKeyword)) {
            $logLine = $line.Trim()
            if (-not $ev.LogMessages.Contains($logLine)) { $ev.LogMessages.Add($logLine) }
        }

        # Collect raw Oops block
        if ($inOops) {
            $ev.RawOops.Add($line)
            # Oops block ends after "---[ end trace" or blank line after kernel version
            if ($line -match '---\[ end (trace|kernel panic)') { $inOops = $false }
        }
    }

    return $ev
}

# Build targeted GitHub search queries from crash evidence.
# Returns an ordered hashtable of label -> query string.
# Each entry becomes one GitHub API search call with a descriptive label.
function Get-CrashSearchQueries {
    param(
        [hashtable]$Evidence,
        [string]$GitHubOrg,
        [string]$GitHubRepo
    )

    $repo = "repo:$GitHubOrg/$GitHubRepo"
    $queries = [ordered]@{}

    # 1. Kernel thread name (e.g. "DVS-async-retry")  -  most specific
    foreach ($thread in $Evidence.KernelThreads) {
        if ($thread.Length -gt 3) {
            $queries["thread:$thread"] = "`"$thread`" $repo"
        }
    }

    # 2. Unique function names from call trace
    foreach ($fn in $Evidence.FunctionNames | Select-Object -First 8) {
        $queries["fn:$fn"] = "$fn $repo"
    }

    # 3. Driver / kernel log message substrings (quoted exact phrases)
    foreach ($msg in $Evidence.LogMessages | Select-Object -First 5) {
        # Strip a leading "[timestamp]" and a leading "prefix:" of any driver, then trim.
        $phrase = $msg -replace '^\[.*?\]\s*', '' -replace '^[a-zA-Z][a-zA-Z0-9_]{1,}:\s*', '' -replace '^\s+', ''
        $phrase = $phrase.Substring(0, [Math]::Min(60, $phrase.Length)).Trim()
        if ($phrase.Length -gt 8) {
            $label = "log:" + ($phrase.Substring(0, [Math]::Min(30, $phrase.Length)) -replace '\s+', '_')
            $queries[$label] = "`"$phrase`" $repo"
        }
    }

    # 4. Crash address offset as a hint (e.g. 0x18 often means struct field)
    if ($Evidence.CrashAddress -and $Evidence.CrashAddress -ne "0x0000000000000000") {
        $offset = $Evidence.CrashAddress
        $queries["crash_offset:$offset"] = "$offset $repo"
    }

    # 5. BUG line keywords (de-noised)
    foreach ($bug in $Evidence.BugLines | Select-Object -First 3) {
        $kw = $bug -replace '\[.*?\]', '' -replace 'BUG:|WARNING:|Oops:', '' `
                   -replace 'CPU:\s*\d+', '' -replace '^\s+|\s+$', ''
        $kw = ($kw -split '\s+' | Where-Object { $_.Length -ge 5 } | Select-Object -First 4) -join ' '
        if ($kw.Length -gt 5) {
            $label = "bug:" + ($kw.Substring(0, [Math]::Min(30, $kw.Length)) -replace '\s+', '_')
            $queries[$label] = "$kw $repo"
        }
    }

    # 6. Error codes
    foreach ($ec in $Evidence.ErrorCodes | Select-Object -First 3) {
        $queries["errcode:$ec"] = "$ec $repo"
    }

    return $queries
}

# ---------------------------------------------------------------------------
# Full JIRA data extraction
# ---------------------------------------------------------------------------

# Extracts every field of value from a JIRA issue object into a flat
# structured report. Returns a hashtable with typed sections.
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

    # All comments  -  body, author, date
    if ($f.comment -and $f.comment.comments) {
        foreach ($c in $f.comment.comments) {
            $data.Comments.Add([ordered]@{
                Author = [string]$c.author.displayName
                Date   = [string]$c.created
                Body   = [string]$c.body
            })
        }
    }

    # Attachments  -  name, size, mime, url
    if ($f.attachment) {
        foreach ($a in $f.attachment) {
            $data.Attachments.Add([ordered]@{
                Filename = [string]$a.filename
                MimeType = [string]$a.mimeType
                Size     = [long]$a.size
                Url      = [string]$a.content
                Created  = [string]$a.created
            })
        }
    }

    # Linked issues
    if ($f.issuelinks) {
        foreach ($lnk in $f.issuelinks) {
            $linked = if ($lnk.outwardIssue) { $lnk.outwardIssue } else { $lnk.inwardIssue }
            if ($linked) {
                $data.LinkedIssues.Add([ordered]@{
                    Key     = [string]$linked.key
                    Summary = [string]$linked.fields.summary
                    Status  = [string]$linked.fields.status.name
                    Type    = if ($lnk.outwardIssue) { [string]$lnk.type.outward } else { [string]$lnk.type.inward }
                })
            }
        }
    }

    # Capture any non-null custom fields (customfield_NNNNN)
    foreach ($prop in $f.PSObject.Properties) {
        if ($prop.Name -match '^customfield_' -and $null -ne $prop.Value -and $prop.Value -ne "") {
            $val = $prop.Value
            # Only keep scalar or simple array values  -  skip huge objects
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

# Concatenate all JIRA text (description + all comment bodies) for analysis.
function Get-FullJiraText {
    param([hashtable]$JiraData)

    $parts = @($JiraData.Summary, $JiraData.Description)
    foreach ($c in $JiraData.Comments) { $parts += $c.Body }
    if ($JiraData.Environment) { $parts += $JiraData.Environment }
    return ($parts -join "`n")
}

# ---------------------------------------------------------------------------
# GitHub repository file reading
# ---------------------------------------------------------------------------

# Fetch a single file's raw text content from GitHub via the Contents API.
# Returns a hashtable: { Path, Content (string), Lines (array), Sha, HtmlUrl }
# Returns $null on 404 (file not found). Throws on auth errors.
function Get-GitHubFileContent {
    param(
        [string]$GitHubOrg,
        [string]$GitHubRepo,
        [string]$FilePath,
        [string]$Token,
        [string]$GitHubBaseUrl = "https://api.github.com",
        [string]$Ref = ""
    )

    # GitHub Enterprise always returns JSON with base64 content regardless of Accept header
    $headers = @{
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    $encoded = $FilePath -replace ' ', '%20'
    $url = "$GitHubBaseUrl/repos/$GitHubOrg/$GitHubRepo/contents/$encoded"
    if ($Ref) { $url += "?ref=$Ref" }

    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 30
    }
    catch [System.Net.WebException] {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 404) { return $null }
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            throw "GitHub API auth failed ($statusCode) reading '$FilePath'. Check GITHUB_TOKEN 'repo' scope."
        }
        throw "GitHub API error reading '$FilePath': $($_.Exception.Message)"
    }

    $rawContent = $resp.Content
    # GitHub Contents API returns JSON with base64-encoded content
    try {
        $obj = $rawContent | ConvertFrom-Json
        if ($obj.encoding -eq 'base64' -and $obj.content) {
            $rawContent = [System.Text.Encoding]::UTF8.GetString(
                [System.Convert]::FromBase64String(($obj.content -replace '[\r\n\s]', ''))
            )
        }
        elseif ($obj.type -eq 'file' -and -not $obj.content) {
            # File too large for Contents API (>1MB)  -  use the blob API with SHA
            if ($obj.sha) {
                $blobUrl = "$GitHubBaseUrl/repos/$GitHubOrg/$GitHubRepo/git/blobs/$($obj.sha)"
                $blobHeaders = $headers.Clone()
                $blobHeaders["Accept"] = "application/vnd.github.raw+json"
                try {
                    $blobResp = Invoke-WebRequest -Uri $blobUrl -Headers $blobHeaders -Method Get -UseBasicParsing -TimeoutSec 60
                    $rawContent = $blobResp.Content
                    # If still JSON/base64
                    try {
                        $blobObj = $rawContent | ConvertFrom-Json
                        if ($blobObj.encoding -eq 'base64') {
                            $rawContent = [System.Text.Encoding]::UTF8.GetString(
                                [System.Convert]::FromBase64String(($blobObj.content -replace '[\r\n\s]', ''))
                            )
                        }
                    } catch { }
                }
                catch { return $null }  # Skip files > 1MB that can't be decoded
            } else {
                return $null
            }
        }
    }
    catch {
        # If JSON parse failed, content was returned as raw text (public GitHub.com)
    }

    # Sanity check: if content looks like base64 (no spaces, very long lines), skip it
    $firstLine = ($rawContent -split "`n", 2)[0]
    if ($firstLine.Length -gt 500 -and $firstLine -notmatch '\s') {
        Write-Warning "Get-GitHubFileContent: '$FilePath' appears to be binary or improperly decoded, skipping."
        return $null
    }

    $fileLines = [string[]]($rawContent -split "`r?`n")
    return @{
        Path    = $FilePath
        Content = $rawContent
        Lines   = $fileLines
        HtmlUrl = "$($GitHubBaseUrl -replace '/api/v3$','')/$GitHubOrg/$GitHubRepo/blob/HEAD/$FilePath"
    }
}

# List files in a GitHub repo directory. Returns array of { Name, Path, Type }.
function Get-GitHubDirectory {
    param(
        [string]$GitHubOrg,
        [string]$GitHubRepo,
        [string]$DirPath,
        [string]$Token,
        [string]$GitHubBaseUrl = "https://api.github.com"
    )

    $headers = @{
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    $url = "$GitHubBaseUrl/repos/$GitHubOrg/$GitHubRepo/contents/$DirPath"
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 20
        $items = $resp.Content | ConvertFrom-Json
        return @($items | ForEach-Object { @{ Name = $_.name; Path = $_.path; Type = $_.type } })
    }
    catch { return @() }
}

# ---------------------------------------------------------------------------
# Source code crash-path analysis
# ---------------------------------------------------------------------------

# Given file content (lines array) and crash evidence, extract:
#   - Functions that create/reference the crashing thread
#   - Functions in the async retry code path
#   - Pointer dereferences that lack a preceding NULL check
#   - Struct member accesses matching the crash offset
#
# Returns a hashtable with:
#   FilePath, RelevantFunctions (list), NullDerefCandidates (list), RawExcerpts (list)
function Invoke-CrashCodeAnalysis {
    param(
        [string]$FilePath,
        [string[]]$FileLines,
        [hashtable]$CrashEvidence,
        [string]$HtmlUrl
    )

    $result = [ordered]@{
        FilePath             = $FilePath
        HtmlUrl              = $HtmlUrl
        RelevantFunctions    = [System.Collections.Generic.List[object]]::new()
        NullDerefCandidates  = [System.Collections.Generic.List[object]]::new()
        RawExcerpts          = [System.Collections.Generic.List[string]]::new()
        StructOffset         = ""
    }

    # Ensure FileLines is always a proper array (protect against single-item coercion)
    $FileLines = [string[]]@($FileLines)
    if ($FileLines.Count -eq 0) { return $result }

    # --- Step 1: Find line numbers containing crash-relevant identifiers ---
    # Build a set of patterns to search for in source
    $searchPatterns = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $CrashEvidence.KernelThreads) {
        # Thread names like "DVS-async-retry" appear as kthread_run(..., "DVS-async-retry")
        $searchPatterns.Add([Regex]::Escape($t))
        # Also look for function names derived from thread: dvs_async_retry, poke_async_retry, etc.
        $snakeName = $t -replace '-', '_' -replace '([A-Z])', '_$1'
        $searchPatterns.Add($snakeName.ToLower().TrimStart('_'))
    }
    foreach ($fn in $CrashEvidence.FunctionNames) {
        $searchPatterns.Add([Regex]::Escape($fn))
    }
    $anchorPattern = ($searchPatterns | Select-Object -Unique) -join '|'

    # --- Step 2: Find function boundaries in the file ---
    # C function: "return_type function_name(...) {" at column 0 or with common patterns
    $funcStarts = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $FileLines.Count; $i++) {
        $line = $FileLines[$i]
        # Match: "type funcname(" at start of line (not inside a block)
        if ($line -match '^[a-zA-Z_][a-zA-Z0-9_\s\*]*\s+(\w+)\s*\(' -and
            $line -notmatch '^\s*(if|for|while|switch|return|#)' -and
            $line -notmatch '/\*' ) {
            $fname = $Matches[1]
            # Confirm it opens a block within next 5 lines
            $hasOpen = $false
            for ($j = $i; $j -lt [Math]::Min($i + 6, $FileLines.Count); $j++) {
                if ($FileLines[$j] -match '\{') { $hasOpen = $true; break }
            }
            if ($hasOpen) {
                $funcStarts.Add(@{ Name = $fname; StartLine = $i })
            }
        }
    }

    # Pair each function start with its end (matching braces)
    $functions = [System.Collections.Generic.List[object]]::new()
    for ($fi = 0; $fi -lt $funcStarts.Count; $fi++) {
        $start = $funcStarts[$fi].StartLine
        $name  = $funcStarts[$fi].Name
        $end   = if ($fi + 1 -lt $funcStarts.Count) { $funcStarts[$fi + 1].StartLine - 1 } else { $FileLines.Count - 1 }
        # Walk forward to find actual closing brace at depth 0
        $depth = 0
        $actualEnd = $end
        for ($li = $start; $li -le $end -and $li -lt $FileLines.Count; $li++) {
            foreach ($ch in $FileLines[$li].ToCharArray()) {
                if ($ch -eq '{') { $depth++ }
                elseif ($ch -eq '}') {
                    $depth--
                    if ($depth -le 0) { $actualEnd = $li; break }
                }
            }
            if ($depth -le 0 -and $li -gt $start) { break }
        }
        $functions.Add(@{ Name = $name; Start = $start; End = $actualEnd })
    }

    # --- Step 3: Score each function for crash relevance ---
    foreach ($func in $functions) {
        $bodyLines = $FileLines[$func.Start..$func.End]
        $bodyText  = $bodyLines -join "`n"

        $score = 0
        $matchedPatterns = [System.Collections.Generic.List[string]]::new()

        foreach ($p in ($searchPatterns | Select-Object -Unique)) {
            if ($bodyText -match $p) {
                $score++
                $matchedPatterns.Add($p)
            }
        }

        if ($score -gt 0) {
            $result.RelevantFunctions.Add([ordered]@{
                Name           = $func.Name
                StartLine      = $func.Start + 1   # 1-based for display
                EndLine        = $func.End + 1
                Score          = $score
                MatchedOn      = ($matchedPatterns | Select-Object -Unique) -join ', '
                LinesOfCode    = $func.End - $func.Start + 1
                HtmlUrl        = "$HtmlUrl#L$($func.Start + 1)-L$($func.End + 1)"
                Excerpt        = ($bodyLines | Select-Object -First 60) -join "`n"
            })
        }
    }

    # Sort by score descending
    $result.RelevantFunctions = [System.Collections.Generic.List[object]](
        $result.RelevantFunctions | Sort-Object { -[int]$_.Score }
    )

    # --- Step 4: Find NULL dereference candidates in relevant functions ---
    # For each relevant function, find pointer dereferences without a preceding NULL check
    foreach ($func in $result.RelevantFunctions) {
        $bodyLines = $FileLines[($func.StartLine - 1)..($func.EndLine - 1)]
        $checkedPointers = [System.Collections.Generic.HashSet[string]]::new()

        for ($li = 0; $li -lt $bodyLines.Count; $li++) {
            $line = $bodyLines[$li]
            $absLine = $func.StartLine + $li

            # NULL checks: multiple kernel/C validation patterns that mark a pointer as safe
            if ($line -match 'if\s*\(\s*!(\w+)\s*[\)&|]' -or
                $line -match 'if\s*\(\s*(\w+)\s*==\s*(NULL|0|false)\s*\)' -or
                $line -match 'if\s*\(\s*(NULL|0)\s*==\s*(\w+)\s*\)' -or
                $line -match 'if\s*\(\s*(\w+)\s*!=\s*(NULL|0)\s*\)' -or
                $line -match 'if\s*\(unlikely\s*\(\s*!(\w+)\s*\)\s*\)' -or
                $line -match 'if\s*\(unlikely\s*\(\s*(\w+)\s*==\s*(NULL|0)\s*\)\s*\)') {
                $ptr = $Matches[1]
                if ($ptr -and $ptr -notmatch '^(NULL|0|false|true|ret|err|rc)$') {
                    $null = $checkedPointers.Add($ptr)
                }
            }
            # IS_ERR / IS_ERR_OR_NULL / PTR_ERR_OR_ZERO
            if ($line -match '(?:IS_ERR(?:_OR_NULL)?|PTR_ERR_OR_ZERO)\s*\(\s*(\w+)\s*\)') {
                $null = $checkedPointers.Add($Matches[1])
            }
            # WARN_ON / BUG_ON assertion checks (pointer was validated if these don't fire)
            if ($line -match '(?:WARN_ON(?:_ONCE)?|BUG_ON)\s*\(\s*!(\w+)\s*\)') {
                $null = $checkedPointers.Add($Matches[1])
            }
            # ptr = ERR_PTR / kzalloc etc. followed by check  -  tracked by IS_ERR above

            # Dereferences: ptr->field or (*ptr).field
            if ($line -match '(\w+)\s*->' -or $line -match '\(\s*\*\s*(\w+)\s*\)') {
                $ptr = $Matches[1]
                if ($ptr -and $ptr -notmatch '^(this|self|NULL|0|true|false)$') {
                    # Check if this pointer was NULL-checked in this function before this line
                    if (-not $checkedPointers.Contains($ptr)) {
                        # Also check a window of 10 lines before for inline checks
                        $windowStart = [Math]::Max(0, $li - 10)
                        $window = ($bodyLines[$windowStart..($li-1)] -join ' ')
                        $checkedInWindow = $window -match "if\s*\(\s*!$ptr\s*\)|if\s*\(\s*$ptr\s*==\s*(NULL|0)\s*\)|IS_ERR(?:_OR_NULL)?\s*\(\s*$ptr\s*\)"
                        if (-not $checkedInWindow) {
                            $result.NullDerefCandidates.Add([ordered]@{
                                Function  = $func.Name
                                Line      = $absLine
                                Pointer   = $ptr
                                Code      = $line.Trim()
                                HtmlUrl   = "$HtmlUrl#L$absLine"
                                Context   = ($bodyLines[[Math]::Max(0,$li-3)..[Math]::Min($bodyLines.Count-1,$li+3)] | ForEach-Object { $_.TrimEnd() }) -join "`n"
                            })
                        }
                    }
                }
            }
        }
    }

    # --- Step 5: Check crash address offset against struct definitions ---
    if ($CrashEvidence.CrashAddress) {
        try {
            $offsetVal = [Convert]::ToInt64($CrashEvidence.CrashAddress.TrimStart('0x'), 16)
            if ($offsetVal -gt 0 -and $offsetVal -lt 0x200) {
                $offsetHex = "0x{0:x}" -f $offsetVal
                # Look for struct definitions with fields at this offset
                # (simple heuristic: look for offsetof or comments mentioning the offset)
                for ($li = 0; $li -lt $FileLines.Count; $li++) {
                    if ($FileLines[$li] -match "offsetof.*$offsetHex|/\*\s*\+?$offsetHex\s*\*/|__attribute__.*aligned.*$offsetVal") {
                        $result.StructOffset = "Line $($li+1): $($FileLines[$li].Trim())"
                    }
                }
                if (-not $result.StructOffset) {
                    $result.StructOffset = "offset $offsetHex ($offsetVal bytes) - look for struct field at this offset in included headers"
                }
            }
        }
        catch { }
    }

    # Build compact raw excerpts for the top 3 relevant functions
    foreach ($func in ($result.RelevantFunctions | Select-Object -First 3)) {
        $result.RawExcerpts.Add("=== $($func.Name) ($($func.HtmlUrl)) ===")
        $result.RawExcerpts.Add($func.Excerpt)
        $result.RawExcerpts.Add("")
    }

    return $result
}

# Search GitHub using labeled queries (label -> full query string).
# Each query is issued independently so results are grouped by what they
# were searching for, not by raw tokens.
function Search-GitHubCode {
    param(
        [string]$GitHubOrg,
        [string]$GitHubRepo,
        [System.Collections.IDictionary]$LabeledQueries,
        [string]$Token,
        [string]$GitHubBaseUrl = "https://api.github.com"
    )

    $headersWithMatch = @{
        Accept                 = "application/vnd.github.text-match+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if ($Token) { $headersWithMatch["Authorization"] = "Bearer $Token" }

    $results   = [System.Collections.Generic.List[string]]::new()
    $seenFiles  = [System.Collections.Generic.HashSet[string]]::new()
    # MatchedFilePaths: only repo-relative paths (strip org/repo prefix), C/H source files first
    $MatchedFilePaths = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $LabeledQueries.GetEnumerator()) {
        $label = $entry.Key
        $query = $entry.Value

        $encoded = [Uri]::EscapeDataString($query)
        $url = "$GitHubBaseUrl/search/code?q=$encoded&per_page=10"
        try {
            $resp = Invoke-WebRequest -Uri $url -Headers $headersWithMatch `
                -Method Get -UseBasicParsing -TimeoutSec 20
        }
        catch [System.Net.WebException] {
            $statusCode = $null
            if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
            if ($statusCode -eq 401 -or $statusCode -eq 403) {
                throw "GitHub API authentication/authorization failed ($statusCode) for query '$label'. Check GITHUB_TOKEN permissions (needs 'repo' scope). Aborting."
            }
            # Rate limit
            if ($statusCode -eq 422 -or $statusCode -eq 429) {
                $results.Add("## $label")
                $results.Add("(rate-limited or query rejected by GitHub - skipped)")
                Start-Sleep -Seconds 5
                continue
            }
            throw "GitHub API error for query '$label': $($_.Exception.Message). Aborting."
        }
        catch {
            throw "GitHub API error for query '$label': $($_.Exception.Message). Aborting."
        }

        $json = $resp.Content | ConvertFrom-Json
        $results.Add("## $label")
        $results.Add("Query: $query")
        $results.Add("Total hits: $($json.total_count)")

        if ($json.total_count -eq 0) {
            $results.Add("(no matches)")
        }
        else {
            foreach ($item in $json.items) {
                $filePath = "$($item.repository.full_name)/$($item.path)"
                $isNew = $seenFiles.Add($filePath)
                $marker = if ($isNew) { "" } else { " [also matched above]" }
                $results.Add("  FILE: $filePath$marker")
                # Collect repo-relative path for file fetching (strip org/repo/ prefix)
                $relPath = $item.path
                if ($isNew -and ($relPath -match '\.(c|h|cc|cpp)$')) {
                    $null = $MatchedFilePaths.Add($relPath)
                }
                if ($item.PSObject.Properties.Name -contains "text_matches") {
                    foreach ($tm in $item.text_matches) {
                        $fragment = ($tm.fragment -replace '\r?\n', '  ').Trim()
                        $results.Add("    MATCH: $fragment")
                    }
                }
            }
        }

        # Respect GitHub Search API secondary rate limit (1 req/sec for code search)
        Start-Sleep -Milliseconds 1100
    }

    # Return both the text report lines AND the list of matched source file paths
    return @{
        Lines             = $results
        MatchedFilePaths  = $MatchedFilePaths
    }
}

# ---------------------------------------------------------------------------
# Module inference helper (kept for backward compat)
# ---------------------------------------------------------------------------

function Resolve-Module {
    param(
        [string]$Text,
        [object]$Map
    )

    $best = $null
    $bestScore = -1

    foreach ($module in $Map.modules) {
        $score = 0
        foreach ($token in $module.match) {
            if ($Text.Contains($token.ToLowerInvariant())) {
                $score += 1
            }
        }

        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $module
        }
    }

    if ($bestScore -le 0) {
        throw "Unable to infer module from JIRA content. Update module-repo-map.json with better keywords."
    }

    return $best
}

# ---------------------------------------------------------------------------
# Evidence-only analysis scaffold builder
# Writes ONLY what was actually observed in JIRA and GitHub search results.
# Every section that has no evidence is marked [EVIDENCE NEEDED]  -  nothing
# is invented or assumed.
# ---------------------------------------------------------------------------

function Build-AnalysisReport {
    param(
        [string]$IssueId,
        [hashtable]$JiraData,
        [hashtable]$CrashEvidence,
        [string]$ModuleName,
        [string]$GitHubRepository,
        [string]$RepoSearchText,
        [System.Collections.Generic.List[object]]$CodeAnalysis = $null
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $NA = "[EVIDENCE NEEDED - not found in JIRA or GitHub search]"

    $lines.Add("## JIRA: $IssueId - $($JiraData.Summary)")
    $lines.Add("")
    $lines.Add("**Priority:** $($JiraData.Priority) | **Status:** $($JiraData.Status) | **Module (inferred):** $ModuleName")
    $lines.Add("**Assignee:** $($JiraData.Assignee) | **Reporter:** $($JiraData.Reporter)")
    $lines.Add("**Created:** $($JiraData.Created) | **Updated:** $($JiraData.Updated)")
    $lines.Add("**GitHub Repository:** $GitHubRepository")
    if ($JiraData.Components.Count -gt 0) { $lines.Add("**Components:** $($JiraData.Components -join ', ')") }
    if ($JiraData.Labels.Count -gt 0)     { $lines.Add("**Labels:** $($JiraData.Labels -join ', ')") }
    if ($JiraData.LinkedIssues.Count -gt 0) {
        $links = $JiraData.LinkedIssues | ForEach-Object { "$($_.Type) $($_.Key) ($($_.Summary)) [$($_.Status)]" }
        $lines.Add("**Linked Issues:** $($links -join ' | ')")
    }
    $lines.Add("")

    # --- Problem Statement (verbatim from JIRA) ---
    $lines.Add("### Problem")
    if ($JiraData.Description) {
        $lines.Add($JiraData.Description.Trim())
    } else {
        $lines.Add($NA)
    }
    $lines.Add("")

    # --- Crash / Kernel Evidence ---
    $lines.Add("### Crash Evidence (from JIRA)")
    $hasCrash = $false

    if ($CrashEvidence.BugLines.Count -gt 0) {
        $lines.Add("#### BUG / Oops Lines")
        $lines.Add('```')
        foreach ($l in $CrashEvidence.BugLines) { $lines.Add($l) }
        $lines.Add('```')
        if ($CrashEvidence.CrashType) {
            $lines.Add("**Classified crash type: ``$($CrashEvidence.CrashType)``**")
        }
        $hasCrash = $true
    }

    if ($CrashEvidence.CrashPoint) {
        $lines.Add("#### Crash Instruction (RIP/PC/EIP)")
        $lines.Add('```')
        $lines.Add($CrashEvidence.CrashPoint)
        $lines.Add('```')
        $hasCrash = $true
    }

    if ($CrashEvidence.OopsAddresses.Count -gt 0) {
        $lines.Add("#### Fault Address")
        $lines.Add('```')
        foreach ($l in $CrashEvidence.OopsAddresses) { $lines.Add($l) }
        $lines.Add('```')
        if ($CrashEvidence.CrashAddress) {
            $lines.Add("**Decoded offset:** $($CrashEvidence.CrashAddress) - likely a struct field dereference (NULL + offset = member access on freed/NULL pointer)")
        }
        $hasCrash = $true
    }

    if ($CrashEvidence.KernelThreads.Count -gt 0) {
        $lines.Add("#### Crashing Thread(s)")
        foreach ($t in $CrashEvidence.KernelThreads) { $lines.Add("- ``$t``") }
        if ($CrashEvidence.CrashingPid) { $lines.Add("- PID: ``$($CrashEvidence.CrashingPid)``") }
        $hasCrash = $true
    }

    if ($CrashEvidence.ModulesLinked.Count -gt 0) {
        $lines.Add("#### Modules Linked In")
        $lines.Add("``$(($CrashEvidence.ModulesLinked | Select-Object -First 20) -join ' ')``")
        $hasCrash = $true
    }

    if ($CrashEvidence.PoisonHints.Count -gt 0) {
        $lines.Add("#### Freed-Memory Poison Indicators")
        $lines.Add("> Register/address values below match known kernel poison patterns (6b6b…=SLUB free poison, 5a5a…=uninitialised, dead…=list poison). Their presence strongly indicates a **use-after-free**, not a plain NULL dereference.")
        $lines.Add('```')
        foreach ($p in ($CrashEvidence.PoisonHints | Select-Object -First 6)) { $lines.Add($p) }
        $lines.Add('```')
        $hasCrash = $true
    }

    if ($CrashEvidence.KernelVersion) {
        $lines.Add("#### Kernel Version")
        $lines.Add("``$($CrashEvidence.KernelVersion)``")
        $hasCrash = $true
    }

    if ($CrashEvidence.CallTraceFrames.Count -gt 0) {
        $lines.Add("#### Call Trace")
        $lines.Add('```')
        foreach ($f in $CrashEvidence.CallTraceFrames) { $lines.Add($f) }
        $lines.Add('```')
        $hasCrash = $true
    }

    if ($CrashEvidence.LogMessages.Count -gt 0) {
        $lines.Add("#### Driver / Kernel Log Messages")
        $lines.Add('```')
        foreach ($m in $CrashEvidence.LogMessages) { $lines.Add($m) }
        $lines.Add('```')
        $hasCrash = $true
    }

    if (-not $hasCrash) { $lines.Add($NA) }
    $lines.Add("")

    # --- Comments (all, verbatim, attributed) ---
    $lines.Add("### JIRA Comments ($($JiraData.Comments.Count) total)")
    if ($JiraData.Comments.Count -gt 0) {
        foreach ($c in $JiraData.Comments) {
            $lines.Add("#### $($c.Author) - $($c.Date)")
            $lines.Add($c.Body.Trim())
            $lines.Add("")
        }
    } else {
        $lines.Add($NA)
    }

    # --- Attachments ---
    if ($JiraData.Attachments.Count -gt 0) {
        $lines.Add("### Attachments")
        foreach ($a in $JiraData.Attachments) {
            $lines.Add("- ``$($a.Filename)`` ($($a.MimeType), $($a.Size) bytes, uploaded $($a.Created))")
            $lines.Add("  URL: $($a.Url)")
        }
        $lines.Add("")
    }

    # --- GitHub Code Search Results ---
    $lines.Add("### GitHub Code Search Results")
    $lines.Add("Repository: ``$GitHubRepository``")
    $lines.Add("")
    $lines.Add('```')
    $lines.Add($RepoSearchText)
    $lines.Add('```')
    $lines.Add("")

    # --- Source Code Analysis (from reading actual repository files) ---
    $lines.Add("### Source Code Analysis")
    if ($CodeAnalysis -and $CodeAnalysis.Count -gt 0) {
        $lines.Add("> Files fetched directly from the GitHub repository and analyzed for the crash code path.")
        $lines.Add("")
        foreach ($ca in $CodeAnalysis) {
            $lines.Add("#### File: [$($ca.FilePath)]($($ca.HtmlUrl))")
            $lines.Add("")

            if ($ca.RelevantFunctions.Count -gt 0) {
                $lines.Add("**Crash-relevant functions found:**")
                foreach ($fn in $ca.RelevantFunctions) {
                    $lines.Add("- [``$($fn.Name)``]($($fn.HtmlUrl)) (lines $($fn.StartLine)-$($fn.EndLine), matched: $($fn.MatchedOn))")
                }
                $lines.Add("")
            } else {
                $lines.Add("No crash-relevant functions identified in this file.")
                $lines.Add("")
            }

            if ($ca.NullDerefCandidates.Count -gt 0) {
                $lines.Add("**NULL dereference candidates (pointer used without preceding NULL check):**")
                $lines.Add("")
                $prev = ""
                foreach ($nd in $ca.NullDerefCandidates) {
                    # Deduplicate: skip if same function+pointer was already listed
                    $key = "$($nd.Function):$($nd.Pointer)"
                    if ($key -eq $prev) { continue }
                    $prev = $key
                    $lines.Add("| Function | Line | Pointer | Code |")
                    $lines.Add("|---|---|---|---|")
                    $lines.Add("| ``$($nd.Function)`` | [L$($nd.Line)]($($nd.HtmlUrl)) | ``$($nd.Pointer)`` | ``$($nd.Code -replace '\|','&#124;')`` |")
                    $lines.Add("")
                    $lines.Add("Context:")
                    $lines.Add('```c')
                    $lines.Add($nd.Context)
                    $lines.Add('```')
                    $lines.Add("")
                }
            } else {
                $lines.Add("No unchecked pointer dereferences detected in relevant functions (manual review recommended).")
                $lines.Add("")
            }

            if ($ca.StructOffset) {
                $lines.Add("**Struct offset note:** $($ca.StructOffset)")
                $lines.Add("")
            }
        }
    } else {
        $lines.Add("[EVIDENCE NEEDED - no source files were fetched from the repository. GitHub search returned no C/H file matches.]")
        $lines.Add("")
    }

    # --- Root Cause (derived only from evidence above) ---
    $lines.Add("### Root Cause")
    $lines.Add("> **NOTE: The following is derived strictly from JIRA data and GitHub search hits above.**")
    $lines.Add("> Every claim cites the exact evidence. Anything not supported is marked $NA.")
    $lines.Add("")

    # Derive root cause from evidence
    $rcLines = [System.Collections.Generic.List[string]]::new()

    if ($CrashEvidence.KernelThreads.Count -gt 0 -and $CrashEvidence.BugLines.Count -gt 0) {
        $thread = $CrashEvidence.KernelThreads[0]
        $bugLine = $CrashEvidence.BugLines[0]
        $rcLines.Add("- The kernel thread ``$thread`` triggered: ``$bugLine``")
    } elseif ($CrashEvidence.BugLines.Count -gt 0) {
        $rcLines.Add("- Crash trigger: ``$($CrashEvidence.BugLines[0])``")
    }

    if ($CrashEvidence.CrashType) {
        $rcLines.Add("- **Crash type: $($CrashEvidence.CrashType)**")
    }
    if ($CrashEvidence.CrashPoint) {
        $rcLines.Add("- Faulting instruction (RIP/PC): ``$($CrashEvidence.CrashPoint)``")
    }

    if ($CrashEvidence.CrashAddress) {
        $addr = $CrashEvidence.CrashAddress
        # Near-NULL addresses (< 0x1000) are struct-field offsets on NULL/freed pointer
        $addrVal = [Convert]::ToInt64($addr.TrimStart("0x"), 16)
        if ($addrVal -lt 0x1000) {
            $rcLines.Add("- Fault address ``$addr`` is a near-NULL offset. This indicates a struct field (at offset $addr from NULL) was accessed through a NULL or freed pointer.")
        } else {
            $rcLines.Add("- Fault address: ``$addr``")
        }
    }

    if ($CrashEvidence.LogMessages.Count -gt 0) {
        $rcLines.Add("- Sequence of events from logs (exact from JIRA):")
        foreach ($m in $CrashEvidence.LogMessages) { $rcLines.Add("  - ``$m``") }
    }

    if ($CrashEvidence.FunctionNames.Count -gt 0) {
        $rcLines.Add("- Functions in call trace: $($CrashEvidence.FunctionNames -join ', ')")
    }

    # Check GitHub hits for the crashing thread
    $threadHits = @()
    foreach ($thread in $CrashEvidence.KernelThreads) {
        if ($RepoSearchText -match [Regex]::Escape($thread)) {
            $threadHits += $thread
        }
    }
    if ($threadHits.Count -gt 0) {
        $rcLines.Add("- GitHub search found references to thread(s): $($threadHits -join ', ') - see 'GitHub Code Search Results' above for exact files.")
    } else {
        $rcLines.Add("- GitHub search did NOT find the crashing thread name(s) in the repository. $NA for exact source file.")
    }

    if ($rcLines.Count -gt 0) {
        foreach ($l in $rcLines) { $lines.Add($l) }
    } else {
        $lines.Add($NA)
    }
    $lines.Add("")

    # --- Steps to Reproduce ---
    $lines.Add("### Steps to Reproduce")
    $lines.Add("> Derived only from JIRA description and comments. Steps not described in JIRA are marked $NA.")
    $lines.Add("")

    $reproLines = [System.Collections.Generic.List[string]]::new()
    $reproStepNum = 1
    $reproSectionFound = $false

    # 1. Look for an explicit "Steps to Reproduce" / "How to Reproduce" section in any JIRA text
    $allJiraTextBlocks = @($JiraData.Description) + @($JiraData.Comments | ForEach-Object { $_.Body } | Where-Object { $_ })
    foreach ($textBlock in $allJiraTextBlocks) {
        if (-not $textBlock) { continue }
        $sectionMatch = [Regex]::Match($textBlock,
            '(?im)(?:steps?\s+to\s+repro(?:duce)?|how\s+to\s+repro(?:duce)?|repro\s+steps?|reproduction\s+steps?|to\s+reproduce:)\s*[\r\n]+([\s\S]+?)(?=\r?\n{2,}[A-Z#*]|\z)')
        if ($sectionMatch.Success) {
            $reproLines.Add("*(Extracted verbatim from JIRA — an explicit reproduce section was found.)*")
            $reproLines.Add("")
            foreach ($rl in ($sectionMatch.Groups[1].Value.Trim() -split '\r?\n')) { $reproLines.Add($rl) }
            $reproSectionFound = $true
            break
        }
    }

    if (-not $reproSectionFound) {
        # No explicit section in JIRA. Build a STRUCTURED reproducer scaffold:
        #   Preconditions (environment)  ->  Trigger (action/condition)  ->  Observed signal (the crash).
        # This avoids dumping raw description prose as fake "steps".

        # --- Preconditions / environment ---
        $preconds = [System.Collections.Generic.List[string]]::new()
        if ($JiraData.Versions.Count -gt 0) {
            $preconds.Add("Affected software version(s): $($JiraData.Versions -join ', ')")
        }
        if ($CrashEvidence.KernelVersion) {
            $preconds.Add("Kernel: $($CrashEvidence.KernelVersion)")
        }
        if ($CrashEvidence.ModulesLinked.Count -gt 0) {
            $preconds.Add("Module loaded: $(($CrashEvidence.ModulesLinked | Select-Object -First 8) -join ', ')")
        }
        if ($JiraData.Environment -and $JiraData.Environment.Trim()) {
            $preconds.Add("Environment (JIRA field): $($JiraData.Environment.Trim() -replace '\r?\n',' ')")
        }
        $impactMatch = [Regex]::Match($JiraData.Description, '(?:(\d+)|([Ff]our|[Ff]ive|[Ss]ix|[Ss]even|[Ee]ight))\s+nodes?\s+crash(?:ed|ing)?')
        if ($impactMatch.Success) {
            $preconds.Add("Observed scale of impact: $($impactMatch.Value) (from JIRA description)")
        }

        $reproLines.Add("**Preconditions / environment**")
        if ($preconds.Count -gt 0) {
            foreach ($p in $preconds) { $reproLines.Add("- $p") }
        } else {
            $reproLines.Add("- $NA")
        }
        $reproLines.Add("")

        # --- Trigger: ordered event sequence from logs (the closest thing to a repro path) ---
        $reproLines.Add("**Trigger (observed event sequence from logs in JIRA, in order)**")
        if ($CrashEvidence.LogMessages.Count -gt 0) {
            $seqNum = 1
            foreach ($lm in ($CrashEvidence.LogMessages | Select-Object -First 8)) {
                $reproLines.Add("$seqNum. ``$lm``")
                $seqNum++
            }
        } else {
            $reproLines.Add("- $NA — no diagnostic log lines were present in JIRA. Attach the full dmesg/console log to reconstruct the trigger path.")
        }
        $reproLines.Add("")

        # --- Observed crash signal: what confirms the bug reproduced ---
        $reproLines.Add("**Expected observable signal (the crash that confirms reproduction)**")
        $signalAdded = $false
        if ($CrashEvidence.BugLines.Count -gt 0) {
            $crashTypeNote = if ($CrashEvidence.CrashType) { " [$($CrashEvidence.CrashType)]" } else { "" }
            $reproLines.Add("- Kernel crash${crashTypeNote}: ``$($CrashEvidence.BugLines[0])``")
            $signalAdded = $true
        }
        if ($CrashEvidence.KernelThreads.Count -gt 0) {
            $threadStr = ($CrashEvidence.KernelThreads | ForEach-Object { "``$_``" }) -join ', '
            $pidNote = if ($CrashEvidence.CrashingPid) { " (PID $($CrashEvidence.CrashingPid))" } else { "" }
            $reproLines.Add("- Crashing context: thread(s) $threadStr$pidNote")
            $signalAdded = $true
        }
        if ($CrashEvidence.CrashPoint) {
            $reproLines.Add("- Faulting instruction: ``$($CrashEvidence.CrashPoint)``")
            $signalAdded = $true
        }
        if (-not $signalAdded) {
            $reproLines.Add("- $NA")
        }
    }

    if ($reproLines.Count -gt 0) {
        foreach ($rl in $reproLines) { $lines.Add($rl) }
        $lines.Add("")
        if (-not $reproSectionFound) {
            $lines.Add("> **Note:** JIRA contained no explicit 'Steps to Reproduce' section. The above is a structured scaffold (preconditions → trigger → crash signal) built strictly from JIRA fields, log lines, and crash evidence. It is NOT a verified, executed reproducer — the exact triggering workload must be confirmed by the owning team.")
        }
    } else {
        $lines.Add($NA)
    }
    $lines.Add("")

    # --- Suggested Fix ---
    $lines.Add("### Suggested Fix")
    $lines.Add("> Based only on crash evidence and source code read from the repository above. No code was invented.")
    $lines.Add("")

    # Crash-type-aware fix guidance (prepended when crash type is known)
    if ($CrashEvidence.CrashType -eq 'use-after-free' -or $CrashEvidence.CrashType -eq 'double-free') {
        $lines.Add("**Crash type detected: $($CrashEvidence.CrashType)**  -  use-after-free bugs require fixing *object lifetime*, not just adding NULL guards.")
        $lines.Add("")
        $lines.Add("Common causes and targeted fixes:")
        $lines.Add("- **Object freed while still referenced:** Add a reference count (``kref`` / ``refcount_t``) and only free on the last drop.")
        $lines.Add("- **kthread accessing freed struct on shutdown:** Set a ``stopping`` flag before freeing; check it at the top of the kthread loop, or use ``kthread_stop()`` before the free.")
        $lines.Add("- **RCU-managed object used outside read-side lock:** Ensure the kthread holds ``rcu_read_lock()`` or takes a reference before the RCU grace period ends.")
        $lines.Add("")
    } elseif ($CrashEvidence.CrashType -eq 'out-of-bounds') {
        $lines.Add("**Crash type detected: out-of-bounds memory access**  -  validate all array indices and buffer sizes before use.")
        $lines.Add("")
    } elseif ($CrashEvidence.CrashType -eq 'gpf') {
        $lines.Add("**Crash type detected: general protection fault**  -  the CPU faulted on a non-canonical/wild pointer. This is usually a corrupted, freed, or uninitialised pointer rather than a plain NULL.")
        $lines.Add("")
        $lines.Add("Common causes and targeted fixes:")
        $lines.Add("- **Wild/poisoned pointer (use-after-free):** if any register shows a poison value (``6b6b…``/``5a5a…``/``dead…``), fix object lifetime — add a reference count or stop the accessor before freeing.")
        $lines.Add("- **Struct corruption:** validate the object's magic/sentinel field before dereferencing.")
        $lines.Add("- Enable ``CONFIG_KASAN`` to pinpoint the exact allocation/free sites.")
        $lines.Add("")
    } elseif ($CrashEvidence.CrashType -eq 'liveness') {
        $lines.Add("**Crash type detected: kernel liveness issue** (RCU stall / soft lockup / hung task).")
        $lines.Add("")
        $lines.Add("Common causes and targeted fixes:")
        $lines.Add("- Spinlock held while sleeping or across a schedule point  -  release before any blocking call.")
        $lines.Add("- Long loop without a preemption point  -  add ``cond_resched()`` inside the loop body.")
        $lines.Add("- RCU callback that re-registers itself  -  ensure each callback terminates the grace period.")
        $lines.Add("")
    } elseif ($CrashEvidence.CrashType -eq 'undefined-behavior') {
        $lines.Add("**Crash type detected: undefined behavior (UBSAN)**  -  fix the specific UBSAN violation reported in the BUG line above.")
        $lines.Add("")
    }

    # If we have real code analysis, use it for precise fix suggestion
    $bestNd = $null
    $bestFn = $null
    $bestFile = $null
    if ($CodeAnalysis -and $CodeAnalysis.Count -gt 0) {
        foreach ($ca in $CodeAnalysis) {
            if ($ca.NullDerefCandidates.Count -gt 0 -and -not $bestNd) {
                $bestNd   = $ca.NullDerefCandidates[0]
                $bestFile = $ca.FilePath
            }
            if ($ca.RelevantFunctions.Count -gt 0 -and -not $bestFn) {
                $bestFn = $ca.RelevantFunctions[0]
            }
        }
    }

    if ($bestNd) {
        $lines.Add("**Identified from source code analysis of ``$bestFile``:**")
        $lines.Add("")
        $lines.Add("Function ``$($bestNd.Function)`` at [line $($bestNd.Line)]($($bestNd.HtmlUrl)) dereferences pointer ``$($bestNd.Pointer)`` without a preceding NULL check.")
        $lines.Add("")
        $lines.Add("Faulting code:")
        $lines.Add('```c')
        $lines.Add($bestNd.Context)
        $lines.Add('```')
        $lines.Add("")
        $lines.Add("**Proposed fix (add NULL guard before the dereference):**")
        $lines.Add('```c')
        $lines.Add("if (!$($bestNd.Pointer)) {")
        $lines.Add("    /* $($bestNd.Pointer) was freed or never set - bail out safely */")
        $lines.Add("    pr_warn(`"%s: $($bestNd.Pointer) is NULL, aborting operation\n`", __func__);")
        $lines.Add("    return;   /* or appropriate error code */" )
        $lines.Add("}")
        $lines.Add("/* existing dereference: $($bestNd.Code) */")
        $lines.Add('```')
        $lines.Add("")
        $lines.Add("**Validation:**")
        $lines.Add("- Reproduce the trigger condition (described in JIRA) in a test environment.")
        if ($CrashEvidence.KernelThreads.Count -gt 0) {
            $lines.Add("- Confirm ``$($CrashEvidence.KernelThreads[0])`` no longer panics with the fix applied.")
        }
        $lines.Add("- Run the module's regression test suite to verify no regressions.")
        $lines.Add("- Consider enabling CONFIG_KASAN / CONFIG_KFENCE in the test kernel to surface any remaining memory-safety issues.")
    }
    elseif ($bestFn) {
        # We found the function but no specific deref candidate  -  give directions to the right place
        $lines.Add("**Function ``$($bestFn.Name)`` in ``$bestFile`` is the crash-relevant code path** (matched: $($bestFn.MatchedOn)).")
        $lines.Add("")
        $lines.Add("[View on GitHub]($($bestFn.HtmlUrl))")
        $lines.Add("")
        $lines.Add("The NULL dereference detection heuristic did not flag a specific line, likely because:")
        $lines.Add("- The NULL check exists in a calling function (not this one)")
        $lines.Add("- The pointer is passed as a parameter without local validation")
        $lines.Add("")
        $lines.Add("**Manual inspection needed:** review all pointer parameters passed into ``$($bestFn.Name)`` and verify that each is validated (NULL-checked or reference-counted) by its callers before this function is entered.")
        $lines.Add("")
        if ($CrashEvidence.CrashAddress) {
            $addrVal = try { [Convert]::ToInt64($CrashEvidence.CrashAddress.TrimStart("0x"), 16) } catch { 9999 }
            if ($addrVal -lt 0x1000) {
                $lines.Add("The fault address ``$($CrashEvidence.CrashAddress)`` (offset $addrVal from NULL) identifies a struct field access. Identify which struct pointer is NULL and check which member sits at byte offset $addrVal from its base.")
            }
        }
    }
    elseif ($CrashEvidence.CrashAddress -and $CrashEvidence.KernelThreads.Count -gt 0) {
        $addrVal = try { [Convert]::ToInt64($CrashEvidence.CrashAddress.TrimStart("0x"), 16) } catch { 9999 }
        if ($addrVal -lt 0x1000) {
            $lines.Add("The crash is a NULL/freed-pointer struct-field dereference (offset ``$($CrashEvidence.CrashAddress)`` from NULL) in thread ``$($CrashEvidence.KernelThreads[0])``.")
            $lines.Add("Source file fetch from GitHub failed - add a NULL guard in the retry function once the file is accessible.")
        } else {
            $lines.Add($NA)
        }
    } else {
        $lines.Add($NA)
    }
    $lines.Add("")

    # --- Data Sources & Gaps ---
    $lines.Add("### Data Sources and Known Gaps")
    $lines.Add("| Source | Status |")
    $lines.Add("|--------|--------|")
    $lines.Add("| JIRA description | Included verbatim above |")
    $lines.Add("| JIRA comments ($($JiraData.Comments.Count)) | Included verbatim above |")
    $lines.Add("| JIRA attachments ($($JiraData.Attachments.Count)) | Listed above (not downloaded - binary/log files require manual access) |")
    if ($CodeAnalysis -and $CodeAnalysis.Count -gt 0) {
        $fileList = ($CodeAnalysis | ForEach-Object { $_.FilePath }) -join ', '
        $lines.Add("| Source code read from GitHub | $($CodeAnalysis.Count) file(s) fetched and analyzed: $fileList |")
    } else {
        $lines.Add("| Source code read from GitHub | Not fetched - no C/H files matched in search results |")
    }

    $metisUrl = $JiraData.Comments | ForEach-Object { $_.Body } | Where-Object { $_ -match 'metis\.hpc' } | Select-Object -First 1
    if ($metisUrl) {
        $urlMatch = [Regex]::Match($metisUrl, 'https://metis[^\s]+')
        if ($urlMatch.Success) {
            $lines.Add("| Metis call-home collection | URL found in comments: $($urlMatch.Value) - **not accessed** (requires internal HPE network + Metis portal auth) |")
        }
    }

    $buginfo = $JiraData.Comments | ForEach-Object { $_.Body } | Where-Object { $_ -match '/hpcdc/project/buginfo' } | Select-Object -First 1
    if ($buginfo) {
        $pathMatch = [Regex]::Match($buginfo, '/hpcdc/project/buginfo/\S+')
        if ($pathMatch.Success) {
            $lines.Add("| vmcore / crash dump | Copied to ``$($pathMatch.Value)`` per comments - **not accessed** (requires SSH to north/south/east/west.hpc.amslabs.hpecorp.net) |")
        }
    }

    $lines.Add("| GitHub code search | Completed - see results above |")
    if ($CrashEvidence.CallTraceFrames.Count -eq 0) {
        $lines.Add("| Full kernel call trace | **NOT PRESENT in JIRA** - only log lines available. Attach dmesg/vmcore output to JIRA for precise function-level analysis. |")
    } else {
        $lines.Add("| Full kernel call trace | Extracted - see Crash Evidence above |")
    }
    $lines.Add("")
    $lines.Add("---")
    $lines.Add("*Analysis generated $(Get-Date -Format 'yyyy-MM-dd HH:mm UTC'). All claims are evidence-bound. Use ``[EVIDENCE NEEDED]`` markers to identify gaps requiring manual investigation.*")

    return $lines -join "`n"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$scriptRoot = Split-Path -Parent $PSCommandPath
$projectRoot = Split-Path -Parent $scriptRoot

Push-Location $projectRoot
try {
    # STEP 0: Read config and resolve GitHub settings
    $mapPath = if ([System.IO.Path]::IsPathRooted($MapFile)) { $MapFile } else { Join-Path $projectRoot $MapFile }
    $map = Get-Content $mapPath -Raw | ConvertFrom-Json

    $githubToken   = Get-GitHubToken -ProjectRoot $projectRoot
    $githubOrg     = $map.githubOrg
    $githubBaseUrl = if ($map.PSObject.Properties.Name -contains "githubBaseUrl") {
                         $map.githubBaseUrl
                     } else {
                         $envUrl = [Environment]::GetEnvironmentVariable("GITHUB_ENTERPRISE_URL", "Process")
                         if ([string]::IsNullOrWhiteSpace($envUrl)) {
                             $envUrl = [Environment]::GetEnvironmentVariable("GITHUB_ENTERPRISE_URL", "User")
                         }
                         if ([string]::IsNullOrWhiteSpace($envUrl)) { "https://api.github.com" } else { $envUrl }
                     }

    if ([string]::IsNullOrWhiteSpace($githubOrg) -or $githubOrg -match '^REPLACE_') {
        throw "STOP: GitHub organization not configured. Set 'githubOrg' in config/module-repo-map.json. Aborting before JIRA fetch."
    }

    # STEP 1: Pre-flight GitHub connectivity check (mandatory  -  abort if fails)
    Write-Host "Pre-flight: Testing HPE GitHub connectivity ($githubBaseUrl) ..."
    Test-GitHubConnectivity -Token $githubToken -GitHubBaseUrl $githubBaseUrl

    # STEP 2: Fetch JIRA issue (all fields, all comments, attachments, linked issues)
    Write-Host "Fetching JIRA issue $IssueId ..."
    & (Join-Path $scriptRoot "fetch-jira.ps1") -IssueId $IssueId -OutputDir $OutputDir

    $issueFolder = Join-Path $OutputDir $IssueId
    $jsonPath    = Join-Path $issueFolder "$IssueId.json"
    if (-not (Test-Path $jsonPath)) {
        throw "JIRA JSON not found at $jsonPath"
    }

    # STEP 3: Extract ALL JIRA data into structured form
    Write-Host "Extracting all JIRA data (description, comments, attachments, linked issues) ..."
    $issue    = Get-Content $jsonPath -Raw | ConvertFrom-Json
    $jiraData = Get-AllJiraData -Issue $issue
    $fullText = Get-FullJiraText -JiraData $jiraData

    Write-Host "  Description: $(if($jiraData.Description){'present'}else{'empty'})"
    Write-Host "  Comments: $($jiraData.Comments.Count)"
    Write-Host "  Attachments: $($jiraData.Attachments.Count)"
    Write-Host "  Linked issues: $($jiraData.LinkedIssues.Count)"

    # STEP 4: Infer module from all JIRA text
    $module     = Resolve-Module -Text $fullText.ToLowerInvariant() -Map $map
    $githubRepo = if ($module.PSObject.Properties.Name -contains "githubRepo") { $module.githubRepo } else { "" }
    if ([string]::IsNullOrWhiteSpace($githubRepo)) {
        throw "No 'githubRepo' defined for module '$($module.name)'. Update config/module-repo-map.json. Aborting."
    }
    Write-Host "Module inferred: $($module.name) -> $githubOrg/$githubRepo"

    # STEP 5: Parse crash evidence from ALL JIRA text (description + every comment)
    Write-Host "Parsing crash evidence (Oops, call trace, BUG lines, log messages) ..."
    $crashEvidence = Get-CrashEvidence -Text $fullText

    Write-Host "  BUG lines found: $($crashEvidence.BugLines.Count)"
    Write-Host "  Call trace frames: $($crashEvidence.CallTraceFrames.Count)"
    Write-Host "  Kernel threads: $($crashEvidence.KernelThreads -join ', ')"
    Write-Host "  Log messages: $($crashEvidence.LogMessages.Count)"
    Write-Host "  Crash address: $(if($crashEvidence.CrashAddress){$crashEvidence.CrashAddress}else{'none'})"
    Write-Host "  Crash type: $(if($crashEvidence.CrashType){$crashEvidence.CrashType}else{'unclassified'})"
    Write-Host "  Modules linked: $($crashEvidence.ModulesLinked.Count); poison hints: $($crashEvidence.PoisonHints.Count)"

    # STEP 6: Build targeted GitHub search queries from crash evidence
    Write-Host "Building targeted GitHub search queries from crash evidence ..."
    $queries = Get-CrashSearchQueries -Evidence $crashEvidence `
                                      -GitHubOrg $githubOrg -GitHubRepo $githubRepo

    if ($queries.Count -eq 0) {
        Write-Warning "No crash-specific queries could be derived. No call trace or BUG lines found in JIRA. Falling back to summary keywords."
        # Minimal fallback: top words from summary only (not full text)
        $summaryWords = $jiraData.Summary -split '\s+' |
            Where-Object { $_.Length -ge 5 -and $_ -notmatch '^(with|from|during|after|kernel|linux)$' } |
            Select-Object -First 5
        foreach ($w in $summaryWords) {
            $queries["summary:$w"] = "$w repo:$githubOrg/$githubRepo"
        }
    }

    Write-Host "  Queries to run: $($queries.Count)"
    foreach ($q in $queries.Keys) { Write-Host "    $q" }

    # STEP 7: Execute GitHub code search
    Write-Host "Searching GitHub repository $githubOrg/$githubRepo ..."
    $searchOut   = Join-Path $issueFolder "repo-search.txt"
    $searchLines = [System.Collections.Generic.List[string]]::new()
    $searchLines.Add("Issue: $IssueId")
    $searchLines.Add("Module: $($module.name)")
    $searchLines.Add("GitHub Repository: $githubOrg/$githubRepo")
    $searchLines.Add("Queries ($($queries.Count)):")
    foreach ($q in $queries.Keys) { $searchLines.Add("  $q : $($queries[$q])") }
    $searchLines.Add("---")

    $searchResult = Search-GitHubCode -GitHubOrg $githubOrg -GitHubRepo $githubRepo `
                                      -LabeledQueries $queries -Token $githubToken `
                                      -GitHubBaseUrl $githubBaseUrl
    foreach ($line in $searchResult.Lines) { $searchLines.Add($line) }
    $searchLines | Set-Content -Encoding UTF8 $searchOut
    Write-Host "  Search results saved to $searchOut"
    Write-Host "  C/H source files matched: $($searchResult.MatchedFilePaths.Count)"

    # STEP 7.5: Fetch matched source files from GitHub and analyze the crash code path
    $codeAnalysis = [System.Collections.Generic.List[object]]::new()
    if ($searchResult.MatchedFilePaths.Count -gt 0) {
        Write-Host "Fetching and analyzing source files from GitHub ..."
        # Prioritize files most likely to contain the crash path:
        # 1. Files matched by the thread-name query come first (they contain the kthread_run call)
        # 2. Limit to 5 files to avoid excessive API calls
        $filesToFetch = $searchResult.MatchedFilePaths | Select-Object -Unique | Select-Object -First 5
        foreach ($relPath in $filesToFetch) {
            Write-Host "  Fetching: $relPath ..."
            try {
                $fileData = Get-GitHubFileContent -GitHubOrg $githubOrg -GitHubRepo $githubRepo `
                                                  -FilePath $relPath -Token $githubToken `
                                                  -GitHubBaseUrl $githubBaseUrl
                if ($fileData) {
                    Write-Host "    -> $($fileData.Lines.Count) lines fetched"
                    $analysis = Invoke-CrashCodeAnalysis -FilePath $relPath `
                                                         -FileLines $fileData.Lines `
                                                         -CrashEvidence $crashEvidence `
                                                         -HtmlUrl $fileData.HtmlUrl
                    Write-Host "    -> Relevant functions: $($analysis.RelevantFunctions.Count), NULL-deref candidates: $($analysis.NullDerefCandidates.Count)"
                    $codeAnalysis.Add($analysis)
                } else {
                    Write-Warning "    File not found at path '$relPath' (404)"
                }
            }
            catch {
                Write-Warning "    Could not fetch '$relPath': $_"
            }
        }

        # Save raw file analysis to disk for reference
        $analysisJsonPath = Join-Path $issueFolder "code-analysis.json"
        $codeAnalysis | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $analysisJsonPath
        Write-Host "  Code analysis saved to $analysisJsonPath"
    } else {
        Write-Warning "No C/H source files matched in GitHub search. Code analysis skipped."
        Write-Warning "This means the crash-specific terms (thread name, function names, log phrases) were not found in the repository source. Verify the module mapping and repository name."
    }

    # STEP 8: Build evidence-only analysis (no hallucination)
    Write-Host "Building analysis report (evidence-only, no hallucination) ..."
    $analysisPath = Join-Path $issueFolder "$IssueId-analysis.md"
    $repoSearchText = $searchLines -join "`n"

    $analysisText = Build-AnalysisReport `
        -IssueId          $IssueId `
        -JiraData         $jiraData `
        -CrashEvidence    $crashEvidence `
        -ModuleName       $module.name `
        -GitHubRepository "$githubOrg/$githubRepo" `
        -RepoSearchText   $repoSearchText `
        -CodeAnalysis     $codeAnalysis

    $analysisText | Set-Content -Encoding UTF8 $analysisPath

    # STEP 9: Write context.json
    $context = [ordered]@{
        issueId          = $IssueId
        summary          = $jiraData.Summary
        status           = $jiraData.Status
        priority         = $jiraData.Priority
        module           = $module.name
        githubOrg        = $githubOrg
        githubRepo       = $githubRepo
        githubRepository = "$githubOrg/$githubRepo"
        commentCount     = $jiraData.Comments.Count
        attachmentCount  = $jiraData.Attachments.Count
        linkedIssueCount = $jiraData.LinkedIssues.Count
        crashEvidence    = [ordered]@{
            bugLinesFound      = $crashEvidence.BugLines.Count
            callFramesFound    = $crashEvidence.CallTraceFrames.Count
            kernelThreads      = @($crashEvidence.KernelThreads)
            functionNames      = @($crashEvidence.FunctionNames)
            crashAddress       = $crashEvidence.CrashAddress
            crashPoint         = $crashEvidence.CrashPoint
            crashType          = $crashEvidence.CrashType
            crashingPid        = $crashEvidence.CrashingPid
            modulesLinked      = @($crashEvidence.ModulesLinked)
            poisonHintsFound   = $crashEvidence.PoisonHints.Count
            logMessagesFound   = $crashEvidence.LogMessages.Count
            kernelVersion      = $crashEvidence.KernelVersion
        }
        queriesRun       = @($queries.Keys)
        sourceFilesFetched = @($codeAnalysis | ForEach-Object { $_.FilePath })
        nullDerefCandidates = @($codeAnalysis | ForEach-Object { $_.NullDerefCandidates } | ForEach-Object { "$($_.Function) line $($_.Line): $($_.Pointer)" })
        jsonPath         = $jsonPath
        searchPath       = $searchOut
        analysisPath     = $analysisPath
    }

    $contextPath = Join-Path $issueFolder "context.json"
    $context | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $contextPath

    Write-Host ""
    Write-Host "Done. Output files:"
    Write-Host "  JIRA JSON     : $jsonPath"
    Write-Host "  Search hits   : $searchOut"
    if ($codeAnalysis.Count -gt 0) {
        Write-Host "  Code analysis : $(Join-Path $issueFolder 'code-analysis.json') ($($codeAnalysis.Count) file(s) analyzed)"
    }
    Write-Host "  Analysis      : $analysisPath"
    Write-Host "  Context       : $contextPath"
}
finally {
    Pop-Location
}
