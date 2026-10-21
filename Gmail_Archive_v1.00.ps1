# Gmail Archive - v1.00
# Windows PowerShell 5.1
# Author: John Halfords and my friend Chappie (ChatGPT - OpenAI)

# This script never modifies or deletes Gmail messages.
# Archives complete conversations as HTML with optional attachments.
# Configuration is loaded from Gmail_Archive_Settings.psd1.
# A failure in one conversation does not stop processing other conversations.

# Load configuration from the private PowerShell data file.
$settingsPath = Join-Path $PSScriptRoot 'Gmail_Archive_Settings.psd1'
if (-not (Test-Path -LiteralPath $settingsPath)) {
    throw "Settings file not found: $settingsPath. Copy Gmail_Archive_Settings.example.psd1 and edit it."
}
$Config = Import-PowerShellDataFile -LiteralPath $settingsPath
if (-not ($Config -is [System.Collections.IDictionary])) { throw 'Invalid settings file.' }

# ============================================================
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Build one HTML log section per run; newest runs appear first.
# RunStats.Threads counts all processed threads, including failures.
# Build an HTML log for each run, with the newest run at the top.
$script:RunStarted = Get-Date
$script:LogEvents = New-Object System.Collections.ArrayList
$script:RunStats = @{ Threads=0; Messages=0; New=0; Updated=0; Skipped=0; SkippedUnchanged=0; SkippedReason=0; Errors=0; Warnings=0 }
$script:LogContext = ''
function Add-ArchiveEvent([string]$Level, [string]$Message) {
    $enabled = switch ($Level) {
        'ERROR'   { $Config.LogErrors }
        'WARNING' { $Config.LogWarnings }
        'SKIPPED' { $Config.LogSkipped }
        'SKIPPED_UNCHANGED' { $Config.LogSkipped }
        'SKIPPED_REASON' { $Config.LogSkipped }
        'NEW'     { $Config.LogNewThreads }
        'UPDATED' { $Config.LogUpdatedThreads }
        default   { $false }
    }
    if ($enabled) {
        [void]$script:LogEvents.Add([pscustomobject]@{
            Time=(Get-Date).ToString('HH:mm:ss'); Level=$Level
            Context=$script:LogContext; Message=$Message
        })
    }
}
function Write-ArchiveWarning([string]$Message) {
    $script:RunStats.Warnings++
    Add-ArchiveEvent 'WARNING' $Message
}
function Write-ImageWarning([string]$Message) {
    # Suppress image download warnings only, not API authentication errors.
    if ($Config.LogImageWarnings) { Write-ArchiveWarning $Message }
}
function Write-ArchiveError([string]$Message) {
    $script:RunStats.Errors++
    Add-ArchiveEvent 'ERROR' $Message
}
function Write-ArchiveLog {
    if ($Config.DryRun -and -not $Config.LogDryRuns) { return }
    $root = $Config.ArchiveRoot
    [IO.Directory]::CreateDirectory($root) | Out-Null
    # Prevent path traversal via a malformed configured filename.
    $logName = [IO.Path]::GetFileName([string]$Config.LogFile)
    if ($logName -ne [string]$Config.LogFile -or -not $logName.EndsWith('.html', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LogFile must be an .html filename without a path.'
    }
    $path = Join-Path $root $logName
    $enc = New-Object Text.UTF8Encoding($false)
    $sb = New-Object Text.StringBuilder
    $ended = Get-Date
    $dry = if ($Config.DryRun) { ' (DryRun)' } else { '' }
    [void]$sb.AppendLine('<section class="run"><h2>' + (Html ($script:RunStarted.ToString('dd-MM-yyyy HH:mm:ss') + $dry)) + '</h2>')
    [void]$sb.AppendLine('<p class="stats">Threads: ' + $script:RunStats.Threads + ' &nbsp;|&nbsp; Messages: ' + $script:RunStats.Messages + ' &nbsp;|&nbsp; New: ' + $script:RunStats.New + ' &nbsp;|&nbsp; Updated: ' + $script:RunStats.Updated + ' &nbsp;|&nbsp; Skipped unchanged: ' + $script:RunStats.SkippedUnchanged + ' &nbsp;|&nbsp; Skipped with reason: ' + $script:RunStats.SkippedReason + ' &nbsp;|&nbsp; Warnings: ' + $script:RunStats.Warnings + ' &nbsp;|&nbsp; Errors: ' + $script:RunStats.Errors + '</p>')
    [void]$sb.AppendLine('<p class="duration">Finished: ' + (Html $ended.ToString('HH:mm:ss')) + '</p>')
    foreach ($ev in $script:LogEvents) {
        $levelClass = switch ($ev.Level) { 'ERROR' {'error'} 'WARNING' {'warning'} 'UPDATED' {'updated'} default {'info'} }
        [void]$sb.AppendLine('<div class="event ' + $levelClass + '" data-level="' + (Html $ev.Level) + '"><b>' + (Html $ev.Level) + '</b> &middot; ' + (Html $ev.Time) + ' &middot; ' + (Html $ev.Context) + '<div>' + (Html $ev.Message) + '</div></div>')
    }
    [void]$sb.AppendLine('</section>')
    $filterbar = '<div class="logfilters"><label for="levelFilter">Show:</label> <select id="levelFilter" onchange="filterLog()"><option value="ALL">All</option><option value="ERROR">Errors</option><option value="WARNING">Warnings</option><option value="NEW">New</option><option value="UPDATED">Updated</option><option value="SKIPPED_UNCHANGED">Skipped unchanged</option><option value="SKIPPED_REASON">Skipped with reason</option></select> <label><input type="checkbox" id="hideEmpty" onchange="filterLog()"> Hide runs without matching events</label></div>'
    $filterjs = '<script>function filterLog(){var v=document.getElementById("levelFilter").value;var hide=document.getElementById("hideEmpty").checked;document.querySelectorAll(".run").forEach(function(run){var count=0;run.querySelectorAll(".event").forEach(function(ev){var level=ev.getAttribute("data-level");var ok=v==="ALL"||level===v||(v==="SKIPPED_REASON"&&level==="SKIPPED");ev.style.display=ok?"":"none";if(ok)count++;});run.style.display=hide&&count===0?"none":"";});}document.addEventListener("DOMContentLoaded",filterLog);</script>'
    $marker = '<!-- LOG_ENTRIES -->'
    $title = Html 'Gmail Archive - by John Halfords'
    if (Test-Path -LiteralPath $path) {
        $old = [IO.File]::ReadAllText($path)
        if (-not $old.Contains($marker)) { throw "Existing log file has no insertion marker: $path" }
        # Update the title in existing log files as well.
        $old = [regex]::Replace($old, '(?is)(<title>).*?(</title>)', ('$1' + $title + '$2'))
        $old = (New-Object regex '(?is)(<h1>).*?(</h1>)').Replace($old, ('$1' + $title + '$2'), 1)
        # Upgrade old logs without discarding earlier runs.
        $old = [regex]::Replace($old, '(?i)<div class="event ([^"]+)"><b>(ERROR|WARNING|NEW|UPDATED|SKIPPED|SKIPPED_UNCHANGED|SKIPPED_REASON)</b>', '<div class="event $1" data-level="$2"><b>$2</b>')
        $old = $old.Replace('<option value="SKIPPED">Overgeslagen</option>', '<option value="SKIPPED_UNCHANGED">Skipped unchanged</option><option value="SKIPPED_REASON">Skipped with reason</option>')
        $old = $old.Replace('var ok=v==="ALL"||ev.getAttribute("data-level")===v;', 'var level=ev.getAttribute("data-level");var ok=v==="ALL"||level===v||(v==="SKIPPED_REASON"&&level==="SKIPPED");')
        # Replace an old filter bar with the English version, preserving existing runs.
        $old = [regex]::Replace($old, '(?s)<div class="logfilters">.*?</div>', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $filterbar })
        if (-not $old.Contains('id="levelFilter"')) {
            $old = $old.Replace($marker, $filterbar + "`r`n" + $marker)
        }
        if (-not $old.Contains('function filterLog()')) {
            $old = $old.Replace('</body></html>', $filterjs + '</body></html>')
        }
        $newContent = $old.Replace($marker, $marker + "`r`n" + $sb.ToString())
    } else {
        $newContent = '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>' + $title + '</title><style>body{font:15px/1.5 Arial,sans-serif;max-width:1000px;margin:30px auto;padding:0 18px;color:#222;background:#f7f8fa}h1{margin-bottom:24px}.logfilters{position:sticky;top:0;padding:10px;background:#fff;border:1px solid #ddd;border-radius:6px;z-index:2}.logfilters select{padding:5px}.run{background:white;border:1px solid #ddd;border-radius:8px;padding:16px 20px;margin:18px 0}.run h2{margin:0 0 8px}.stats{font-weight:bold}.duration{color:#666}.event{padding:8px 12px;margin:6px 0;border-left:4px solid #999;background:#f4f4f4;overflow-wrap:anywhere}.event.error{color:#a00000;background:#fff0f0;border-color:#d00000}.event.warning{color:#925100;background:#fff5e4;border-color:#e38b00}.event.updated{border-color:#2971a8}</style></head><body><h1>' + $title + '</h1>' + "`r`n" + $filterbar + "`r`n" + $marker + "`r`n" + $sb.ToString() + $filterjs + '</body></html>'
    }
    # The limit applies to total UTF-8 file size, not the number of lines.
    # Remove the oldest COMPLETE run each time; always retain the current run.
    $maxMB = [double]$Config.MaxLogSizeMB
    if ($maxMB -le 0) { throw 'MaxLogSizeMB must be greater than 0.' }
    $maxBytes = [long][math]::Floor($maxMB * 1MB)
    while ($enc.GetByteCount($newContent) -gt $maxBytes) {
        $runs = [regex]::Matches($newContent, '(?s)<section class="run">.*?</section>')
        if ($runs.Count -le 1) { break }  # Never discard the current run
        $oldest = $runs[$runs.Count - 1]
        $newContent = $newContent.Remove($oldest.Index, $oldest.Length)
    }
    $tempLog = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tempLog, $newContent, $enc)
        Move-Item -LiteralPath $tempLog -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tempLog) { Remove-Item -LiteralPath $tempLog -Force }
    }
}


# Replace the index via a unique temporary file with a recoverable backup.
# Never remove the existing index without a recovery path.
function Save-ArchiveIndex([hashtable]$Index, [string]$IndexPath) {
    $tmp = $IndexPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $IndexPath + '.' + [guid]::NewGuid().ToString('N') + '.bak'
    try {
        @($Index.Values) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
        if (-not (Test-Path -LiteralPath $IndexPath)) {
            Move-Item -LiteralPath $tmp -Destination $IndexPath
            return
        }
        try {
            [IO.File]::Replace($tmp, $IndexPath, $null)
            return
        } catch {
            # Some network shares do not support File.Replace.
                Copy-Item -LiteralPath $IndexPath -Destination $backup -ErrorAction Stop
            $oldIndex = $IndexPath + '.old_' + [guid]::NewGuid().ToString('N')
            Move-Item -LiteralPath $IndexPath -Destination $oldIndex -ErrorAction Stop
            try {
                Move-Item -LiteralPath $tmp -Destination $IndexPath -ErrorAction Stop
            } catch {
                $problem = $_.Exception.Message
                if (-not (Test-Path -LiteralPath $IndexPath)) {
                    Move-Item -LiteralPath $oldIndex -Destination $IndexPath -ErrorAction Stop
                }
                throw "Failed to replace index; previous index restored: $problem"
            }
            # The new index is now valid; cleanup failures must not fail the run.
            Remove-Item -LiteralPath $oldIndex -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# Reuse existing exports after an interrupted index update only when
# both HTML and all saved attachments match exactly.
function Test-SameFile([string]$A, [string]$B) {
    if (-not (Test-Path -LiteralPath $A -PathType Leaf) -or -not (Test-Path -LiteralPath $B -PathType Leaf)) { return $false }
    $aInfo = Get-Item -LiteralPath $A
    $bInfo = Get-Item -LiteralPath $B
    if ($aInfo.Length -ne $bInfo.Length) { return $false }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $aStream = [IO.File]::OpenRead($A)
        try { $aHash = [BitConverter]::ToString($sha.ComputeHash($aStream)) } finally { $aStream.Dispose() }
        $bStream = [IO.File]::OpenRead($B)
        try { $bHash = [BitConverter]::ToString($sha.ComputeHash($bStream)) } finally { $bStream.Dispose() }
        return $aHash -eq $bHash
    } finally { $sha.Dispose() }
}
function Test-SameAssets([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Source)) { return -not (Test-Path -LiteralPath $Target) }
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) { return $false }
    $sourceFiles = @(Get-ChildItem -LiteralPath $Source -File -Recurse)
    $targetFiles = @(Get-ChildItem -LiteralPath $Target -File -Recurse)
    if ($sourceFiles.Count -ne $targetFiles.Count) { return $false }
    $prefix = $Source.TrimEnd('\') + '\'
    foreach ($f in $sourceFiles) {
        $relative = $f.FullName.Substring($prefix.Length)
        if (-not (Test-SameFile $f.FullName (Join-Path $Target $relative))) { return $false }
    }
    return $true
}

function Get-Header($Message, [string]$Name) {
    $h = @($Message.payload.headers | Where-Object { $_.name -ieq $Name } | Select-Object -First 1)
    if ($h.Count) { return [string]$h[0].value }
    return ''
}
function Safe-Name([string]$Value, [int]$Limit = 90) {
    $s = [regex]::Replace($Value, '[\x00-\x1f\\/:*?"<>|]', '_')
    $s = [regex]::Replace($s, '\s+', ' ').Trim().TrimEnd('.', ' ')
    if (-not $s) { $s = 'Onbekend' }
    if ($s.Length -gt $Limit) { $s = $s.Substring(0,$Limit).TrimEnd('.', ' ') }
    return $s
}
function Short-Name([string]$Value, [int]$Limit) {
    $s = Safe-Name $Value 200
    if ($s.Length -gt $Limit) { return $s.Substring(0,$Limit).TrimEnd('.', ' ') + '_' }
    return $s
}
# Read only actual From/To/Cc headers, not quoted message text.
function Get-ConversationNames($Messages) {
    $own = @{}
    foreach ($address in @($Config.OwnAddresses)) {
        if ($address) { $own[([string]$address).Trim().ToLowerInvariant()] = $true }
    }
    $seenAddresses = @{}
    $names = New-Object System.Collections.ArrayList
    foreach ($message in $Messages) {
        foreach ($headerName in @('From','To','Cc')) {
            $header = Get-Header $message $headerName
            if (-not $header) { continue }
            # Addresses may appear in angle brackets or without display names.
            $matches = [regex]::Matches($header, '(?:(?:"([^"]+)"|([^,<"]+?))\s*)?<([^<>\s,;]+@[^<>\s,;]+)>|([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})', 'IgnoreCase')
            foreach ($match in $matches) {
                $address = if ($match.Groups[3].Success) { $match.Groups[3].Value } else { $match.Groups[4].Value }
                $key = $address.ToLowerInvariant()
                if ($own.ContainsKey($key) -or $seenAddresses.ContainsKey($key)) { continue }
                $seenAddresses[$key] = $true
                $name = if ($match.Groups[1].Success) { $match.Groups[1].Value } elseif ($match.Groups[2].Success) { $match.Groups[2].Value.Trim() } else { '' }
                $name = $name.Trim(' ', '"', "'")
                if (-not $name) { $name = $address.Split('@')[0] }
                [void]$names.Add((Safe-Name $name 60))
            }
        }
    }
    if (-not $names.Count) { return 'Onbekend' }
    return ($names.ToArray() -join ', ')
}

function Unique-AttachmentName([string]$Original, [hashtable]$Used) {
    # Preserve extensions while limiting long PDF and attachment filenames.
    $name = Safe-Name $Original 200
    $max = [math]::Max(16, [int]$Config.MaxAttachmentLength)
    if ($name.Length -gt $max) {
        $extension = [IO.Path]::GetExtension($name)
        $stem0 = [IO.Path]::GetFileNameWithoutExtension($name)
        $name = $stem0.Substring(0, [math]::Max(1, $max - $extension.Length)).TrimEnd('.', ' ') + $extension
    }
    $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    $ext = [IO.Path]::GetExtension($name)
    $candidate = $name
    $i = 2
    while ($Used.ContainsKey($candidate.ToLowerInvariant())) {
        $candidate = ('{0} ({1}){2}' -f $stem,$i,$ext)
        $i++
    }
    $Used[$candidate.ToLowerInvariant()] = $true
    return $candidate
}
function Decode-B64Url([string]$Value) {
    if (-not $Value) { return [byte[]]@() }
    $s = $Value.Replace('-','+').Replace('_','/')
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } 1 { throw 'Ongeldige base64url-gegevens.' } }
    return [Convert]::FromBase64String($s)
}
function Html([string]$Value) { return [System.Net.WebUtility]::HtmlEncode($Value) }
# Google often includes the ACTUAL reason for HTTP 403 in the JSON response.
# Otherwise, this information is lost in the localized WebException message.
function Get-GmailErrorDetails($ErrorRecord) {
    $status = 0
    $body = ''
    $reason = ''
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response) {
            $status = [int]$response.StatusCode
            $stream = $response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        }
        if ($body) {
            $json = $body | ConvertFrom-Json
            if ($json.error.errors) { $reason = [string]$json.error.errors[0].reason }
            if (-not $reason -and $json.error.status) { $reason = [string]$json.error.status }
        }
    } catch { } # Reading error details must never mask the original error.
    $message = [string]$ErrorRecord.Exception.Message
    if ($body) { $message += ' | Google: ' + $body }
    return [pscustomobject]@{ Status=$status; Reason=$reason; Message=$message }
}
# Quota units are estimates based on Gmail API method costs.
# These measurements cover this run only, not other clients or Google's internal usage.
$script:LastApiCallAt = $null
$script:ApiCalls = 0
$script:ApiUnits = 0
$script:ApiFailed = 0
# Conservative rolling quota budget, separate from the configurable inter-request delay.
# Gmail per-user limit is 6000 units/min; leave a margin for untracked activity.
$script:QuotaWindow = New-Object System.Collections.ArrayList
$script:QuotaBudgetPerMinute = 4800
function Wait-GmailQuota([int]$Cost) {
    while ($true) {
        $now = Get-Date
        for ($i = $script:QuotaWindow.Count - 1; $i -ge 0; $i--) {
            if (($now - $script:QuotaWindow[$i].At).TotalSeconds -ge 60) {
                $script:QuotaWindow.RemoveAt($i)
            }
        }
        $used = 0
        foreach ($entry in $script:QuotaWindow) { $used += [int]$entry.Cost }
        if (($used + $Cost) -le $script:QuotaBudgetPerMinute) { break }
        $oldest = $script:QuotaWindow[0].At
        $waitMs = [int][math]::Max(250, [math]::Ceiling(60000 - (($now - $oldest).TotalMilliseconds) + 250))
        Start-Sleep -Milliseconds $waitMs
    }
    [void]$script:QuotaWindow.Add([pscustomobject]@{ At=(Get-Date); Cost=$Cost })
}
function Get-ApiCost([string]$Path) {
    # Conservative budgeting for full thread reads; do not treat these as Google-side measurements.
    if ($Path -match '^threads/') { return 120 }
    if ($Path -match '^messages/[^/]+/attachments/') { return 20 }
    if ($Path -match '^messages\?') { return 10 }
    if ($Path -match '^labels(?:\?|$)') { return 1 }
    return 20
}
# Determine the actual count first using existing Gmail list requests.
$script:ProgressTotal = 0
$script:LastProgressBucket = -1
$script:ProgressLineLength = 0
function Show-ArchiveProgress([switch]$Force) {
    if ([int]$Config.ProgressEvery -le 0) { return }
    $n = [int]$script:RunStats.Threads
    $total = [int]$script:ProgressTotal
    $pct = if ($total -gt 0) { [math]::Min(100, [int][math]::Floor(100.0 * $n / $total)) } else { 0 }
    $step = [math]::Max(1, [int]$Config.ProgressEvery)
    $bucket = [int][math]::Floor($pct / $step)
    if (-not $Force -and $bucket -le $script:LastProgressBucket) { return }
    $script:LastProgressBucket = $bucket
    $elapsed = (Get-Date) - $script:RunStarted
    $elapsedText = ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($elapsed.TotalHours),$elapsed.Minutes,$elapsed.Seconds)
    $status = ('{0}/{1} ({2}%) | elapsed {3} | new {4} | updated {5} | unchanged {6} | reason {7} | errors {8} | API {9}' -f $n,$total,$pct,$elapsedText,$script:RunStats.New,$script:RunStats.Updated,$script:RunStats.SkippedUnchanged,$script:RunStats.SkippedReason,$script:RunStats.Errors,$script:ApiCalls)
    Write-Progress -Activity 'Gmail_Archive v1.00' -Status $status -PercentComplete $pct
    $line = 'Progress: ' + $status
    try {
        $width = [Console]::WindowWidth
        if ($width -gt 15 -and $line.Length -ge $width) { $line = $line.Substring(0, $width - 1) }
    } catch { }
    $padding = [math]::Max(0, $script:ProgressLineLength - $line.Length)
    Write-Host ("`r" + $line + (' ' * $padding)) -NoNewline
    $script:ProgressLineLength = $line.Length
}
function Show-ApiSummary {
    Write-Host ''
    Write-Progress -Activity 'Gmail_Archive v1.00' -Completed
    Write-Host ("API total: {0} calls | ~{1} quota units | {2} failed requests" -f $script:ApiCalls,$script:ApiUnits,$script:ApiFailed)
}
function Get-Gmail([string]$Path) {
    $uri = 'https://gmail.googleapis.com/gmail/v1/users/me/' + $Path
    $maxRetries = [math]::Max(0, [int]$Config.ApiRetryCount)
    # Throttle all Gmail GET requests, including skipped conversations.
    $minIntervalMs = [math]::Max(0, [int]$Config.ApiRequestIntervalMs)
    if ($null -eq $script:LastGmailRequestAt) { $script:LastGmailRequestAt = [datetime]::MinValue }
    $authRefreshed = $false
    for ($attempt = 0; $attempt -le ($maxRetries + 1); $attempt++) {
        try {
            $elapsed = ((Get-Date) - $script:LastGmailRequestAt).TotalMilliseconds
            if ($elapsed -lt $minIntervalMs) { Start-Sleep -Milliseconds ([int][math]::Ceiling($minIntervalMs - $elapsed)) }
            $script:LastGmailRequestAt = Get-Date
            # Use the configurable base delay for checks (threads/lists); for downloads
            # of attachments, keep the configured safe delay.
            $slowRequest = ($Path -match '^messages/[^/]+/attachments/')
            if ($slowRequest -and $null -ne $script:LastApiCallAt -and [int]$Config.ApiMinIntervalMs -gt 0) {
                $since = ((Get-Date) - $script:LastApiCallAt).TotalMilliseconds
                $pause = [int][math]::Ceiling([int]$Config.ApiMinIntervalMs - $since)
                if ($pause -gt 0) { Start-Sleep -Milliseconds $pause }
            }
            # Refresh before expiry; avoid losing a long archive run after one hour.
            if ($null -ne $script:TokenRefreshAt -and (Get-Date) -ge $script:TokenRefreshAt) {
                Update-GmailAccessToken
            }
            $cost = Get-ApiCost $Path
            Wait-GmailQuota $cost
            $script:LastApiCallAt = Get-Date
            $script:ApiCalls++
            $script:ApiUnits += $cost
            $started = Get-Date
            try {
                $result = Invoke-RestMethod -Method Get -Headers $script:Headers -Uri $uri -ErrorAction Stop
                return $result
            } catch {
                $script:ApiFailed++
                $d = Get-GmailErrorDetails $_
                # The error response has already been read; propagate the original exception;
                # the outer catch cannot read the response body again.
                $script:LastApiErrorDetails = $d
                throw
            }
        } catch {
            $details = if ($null -ne $script:LastApiErrorDetails) { $d0 = $script:LastApiErrorDetails; $script:LastApiErrorDetails = $null; $d0 } else { Get-GmailErrorDetails $_ }
            if ($details.Status -eq 401) {
                if ($authRefreshed) {
                    throw 'Gmail OAuth authentication still returns 401 after token refresh; stopping.'
                }
                Update-GmailAccessToken
                $authRefreshed = $true
                continue
            }
            # Retry only for recognized temporary API limits.
            $retryable = ($details.Status -eq 429 -or $details.Status -eq 503 -or
                ($details.Status -eq 403 -and $details.Reason -match '^(rateLimitExceeded|userRateLimitExceeded)$'))
            if ($retryable -and $attempt -lt $maxRetries) {
                if ($details.Status -eq 403 -and $details.Reason -match '^(rateLimitExceeded|userRateLimitExceeded)$') {
                    $wait = @(15,30,65,90,120)[[math]::Min($attempt,4)] # Quota backoff.
                } else {
                    $wait = [math]::Min(64, [math]::Max(1, [int]$Config.ApiRetrySeconds) * [math]::Pow(2, $attempt)) + (Get-Random -Minimum 0.0 -Maximum 1.0)
                }
                Write-ArchiveWarning ('Gmail API ' + $details.Status + ' (' + $details.Reason + '); waiting ' + $wait + ' sec. before retrying.')
                Start-Sleep -Seconds $wait
                continue
            }
            # Pass details to the existing error handler.
            throw ('GMAIL_API_ERROR status=' + $details.Status + ' reason=' + $details.Reason + ' | ' + $details.Message)
        }
    }
}
function Get-Parts($Part) {
    $result = @($Part)
    foreach ($child in @($Part.parts)) { if ($null -ne $child) { $result += @(Get-Parts $child) } }
    return $result
}
function Get-PartBytes($Part, [string]$MessageId) {
    $data = $Part.body.data
    if (-not $data -and $Part.body.attachmentId) {
        $id = [uri]::EscapeDataString([string]$Part.body.attachmentId)
        $data = (Get-Gmail ('messages/' + $MessageId + '/attachments/' + $id)).data
    }
    return ,(Decode-B64Url ([string]$data))
}
function Get-PartMime($Part) {
    foreach ($h in @($Part.headers)) {
        if ($h.name -ieq 'Content-Type') { return [string]$h.value }
    }
    return [string]$Part.mimeType
}
function Get-CharsetText([byte[]]$Bytes, [string]$Mime) {
    # Gmail API (format=full) sometimes returns MIME bodies as
    # UTF-8 bytes even when the original MIME header specifies iso-8859-1.
    $charset = 'utf-8'
    if ($Mime -match 'charset\s*=\s*["'']?([^;"''\s]+)') { $charset = $Matches[1] }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $utf8Text = $strictUtf8.GetString($Bytes)
        # ASCII decodeert identiek in UTF-8 en de gebruikelijke MIME-charsets.
        if ($charset -match '^(utf-?8|us-ascii)$' -or
            @($Bytes | Where-Object { $_ -ge 128 }).Count -gt 0) {
            return $utf8Text
        }
    } catch {
        # These bytes are not valid UTF-8: respect the MIME charset.
    }
    try {
        $encoding = [Text.Encoding]::GetEncoding(
            $charset,
            [Text.EncoderFallback]::ExceptionFallback,
            [Text.DecoderFallback]::ExceptionFallback
        )
        return $encoding.GetString($Bytes)
    } catch {
        return [Text.Encoding]::UTF8.GetString($Bytes)
    }
}
function Get-ContentId($Part) {
    foreach ($h in @($Part.headers)) {
        if ($h.name -ieq 'Content-ID') { return ([string]$h.value).Trim().Trim('<','>') }
    }
    return ''
}
function Save-MessageImages([string]$HtmlText, [object[]]$Parts, [string]$MessageId, [string]$AssetsDir, [string]$AssetsName, [hashtable]$UsedNames) {
    # CID images come from Gmail itself; save them before replacing references.
    foreach ($part in $Parts) {
        $cid = Get-ContentId $part
        if (-not $cid) { continue }
        if ([string]$part.mimeType -notmatch '^image/') { continue }
        $ext = switch -Regex ([string]$part.mimeType) {
            'jpeg' { '.jpg'; break } 'png' { '.png'; break } 'gif' { '.gif'; break }
            'webp' { '.webp'; break } 'svg' { '.svg'; break } default { '.img' }
        }
        $original = if ($part.filename) { [string]$part.filename } else { 'inline_' + $cid + $ext }
        $name = Unique-AttachmentName $original $UsedNames
        try {
            [IO.Directory]::CreateDirectory($AssetsDir) | Out-Null
            $path = Join-Path $AssetsDir $name
            [IO.File]::WriteAllBytes($path, [byte[]](Get-PartBytes $part $MessageId))
            $relative = [uri]::EscapeDataString($Config.FilesFolder) + '/' + [uri]::EscapeDataString($AssetsName) + '/' + [uri]::EscapeDataString($name)
            $HtmlText = [regex]::Replace($HtmlText, '(?i)cid:' + [regex]::Escape($cid) + '(?=["''\s>])', $relative.Replace('$','$$'))
            # This MIME part has been saved; do not save it again in the attachment loop.
            $script:SavedCidParts[$MessageId + '|' + $cid] = $name
        } catch {
            if ($_.Exception.Message -match 'GMAIL_API_ERROR status=401') { throw }
            Write-ImageWarning ('CID image could not be saved: ' + $cid + ' (' + $_.Exception.Message + ')')
        }
    }
    # External img src images only; do not fetch arbitrary URLs, fonts or tracking links.
    $matchesImages = [regex]::Matches($HtmlText, '(?is)<img\b[^>]*?\bsrc\s*=\s*(["''])(https?://[^"''<>]+)\1')
    $urls = @{}
    foreach ($match in $matchesImages) {
        $url = [System.Net.WebUtility]::HtmlDecode($match.Groups[2].Value)
        if ($urls.ContainsKey($url)) { continue }
        # Download each external URL only once per conversation.
        if ($script:DownloadedImageUrls.ContainsKey($url)) {
            $urls[$url] = $script:DownloadedImageUrls[$url]
            continue
        }
        $urls[$url] = $null
        $stagingFile = $null
        $target = $null
        try {
            $uri = [uri]$url
            $ext = [IO.Path]::GetExtension($uri.AbsolutePath).ToLowerInvariant()
            if ($ext -notin @('.png','.jpg','.jpeg','.gif','.webp','.bmp','.svg')) { $ext = '.img' }
            $script:ImageNumber++
            $name = Unique-AttachmentName (('{0}{1}' -f $script:ImageNumber,$ext)) $UsedNames
            # Download to a SHORT local temporary path, then copy it
            # to the archive; this avoids Invoke-WebRequest -OutFile problems
            # with long paths or network shares.
            $stagingFile = Join-Path ([IO.Path]::GetTempPath()) ('gmailimg_' + [guid]::NewGuid().ToString('N').Substring(0,8) + $ext)
            Invoke-WebRequest -Uri $url -OutFile $stagingFile -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop | Out-Null
            if (-not [IO.File]::Exists($stagingFile) -or (Get-Item -LiteralPath $stagingFile).Length -eq 0) {
                throw 'Downloaded file is missing or empty.'
            }
            [IO.Directory]::CreateDirectory($AssetsDir) | Out-Null
            $target = Join-Path $AssetsDir $name
            [IO.File]::Copy($stagingFile, $target, $false)
            $urls[$url] = [uri]::EscapeDataString($Config.FilesFolder) + '/' + [uri]::EscapeDataString($AssetsName) + '/' + [uri]::EscapeDataString($name)
            $script:DownloadedImageUrls[$url] = $urls[$url]
        } catch {
            # Do not retry a failed URL within the same conversation.
            $script:DownloadedImageUrls[$url] = $null
            # A failed 1x1 image is a tracking pixel; remove it without a warning.
            # Remove the HTML reference later for this 1x1 tag only.
            $script:FailedImageUrls[$url] = $_.Exception.Message

            if ($target -and [IO.File]::Exists($target)) { Remove-Item -LiteralPath $target -Force }
        } finally {
            if ($stagingFile -and [IO.File]::Exists($stagingFile)) { Remove-Item -LiteralPath $stagingFile -Force }
        }
    }
    # Remove only non-downloadable 1x1 img tags; other failed
    # downloads retain their original URL and generate a warning.
    foreach ($url in @($urls.Keys)) {
        if ($script:FailedImageUrls.ContainsKey($url)) {
            $escapedUrl = [regex]::Escape($url)
            $tagPattern = '(?is)<img\b(?=[^>]*\bsrc\s*=\s*["'']' + $escapedUrl + '["''])(?=[^>]*\bwidth\s*=\s*["'']?1(?:px)?["''\s>])(?=[^>]*\bheight\s*=\s*["'']?1(?:px)?["''\s>])[^>]*>'
            $before = $HtmlText
            $HtmlText = [regex]::Replace($HtmlText, $tagPattern, '')
            if ($HtmlText -eq $before) {
                if (-not $script:WarnedImageUrls.ContainsKey($url)) {
                    Write-ImageWarning ('Image could not be saved: ' + $url + ' (' + $script:FailedImageUrls[$url] + ')')
                    $script:WarnedImageUrls[$url] = $true
                }
            }
        }
    }
    foreach ($url in @($urls.Keys)) {
        if ($urls[$url]) {
            $HtmlText = $HtmlText.Replace($url, $urls[$url]).Replace([System.Net.WebUtility]::HtmlEncode($url), $urls[$url])
        }
    }
    return $HtmlText
}
function Get-ArchivePaths([string[]]$LabelNames) {
    $paths = @()
    foreach ($label in $LabelNames) {
        $segments = @($label -split '/' | ForEach-Object { Safe-Name $_ 80 })
        $paths += ($segments -join '\')
    }
    if (-not $paths.Count) { $paths = @($Config.NoLabelFolder) }
    return @($paths | Sort-Object -Unique)
}

# Prevent Windows from automatically sleeping during the run.
# The screen may turn off; user-initiated sleep is not blocked.
$script:SleepPreventionActive = $false
$script:FinalProgressPrinted = $false
try {
    if (-not ('GmailHJPower' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GmailHJPower {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@ -ErrorAction Stop
    }
    $previousPowerState = [GmailHJPower]::SetThreadExecutionState([uint32]2147483649)
    if ($previousPowerState -eq 0) {
        Write-Warning 'Could not prevent Windows sleep mode.'
    } else {
        $script:SleepPreventionActive = $true
    }
# OAuth secrets live in private/; settings keep their existing filenames.
# Explicit absolute paths or paths already starting with private/ are respected.
function Resolve-PrivateOAuthPath([string]$FileName) {
    if ([IO.Path]::IsPathRooted($FileName)) { return $FileName }
    if ($FileName -match '^(?i:private)[\\/]') { return (Join-Path $Config.ScriptFolder $FileName) }
    return (Join-Path (Join-Path $Config.ScriptFolder 'private') $FileName)
}
$oauthPath = Resolve-PrivateOAuthPath ([string]$Config.OAuthFile)
$tokenPath = Resolve-PrivateOAuthPath ([string]$Config.TokenFile)
if (-not (Test-Path -LiteralPath $oauthPath)) { throw "OAuth file is missing: $oauthPath" }
if (-not (Test-Path -LiteralPath $tokenPath)) { throw "Token file is missing: $tokenPath" }
$client = (Get-Content -LiteralPath $oauthPath -Raw | ConvertFrom-Json).installed
$saved = Get-Content -LiteralPath $tokenPath -Raw | ConvertFrom-Json
if (-not $client -or -not $saved.refresh_token) { throw 'OAuth client or refresh token is missing.' }
if (@($saved.scope -split '\s+') -notcontains 'https://www.googleapis.com/auth/gmail.readonly') { throw 'gmail.readonly scope is missing.' }
$token = Invoke-RestMethod -Method Post -Uri $client.token_uri -ContentType 'application/x-www-form-urlencoded' -Body @{
    client_id = $client.client_id; client_secret = $client.client_secret
    refresh_token = $saved.refresh_token; grant_type = 'refresh_token'
}
if (-not $token.access_token) { throw 'No access_token received.' }
$script:Headers = @{ Authorization = "Bearer $($token.access_token)" }
$script:TokenRefreshAt = (Get-Date).AddSeconds([math]::Max(60, [int]$token.expires_in - 300))
function Update-GmailAccessToken {
    # Use the existing refresh token; leave the token file unchanged.
    try {
        $fresh = Invoke-RestMethod -Method Post -Uri $client.token_uri -ContentType 'application/x-www-form-urlencoded' -Body @{
            client_id=$client.client_id; client_secret=$client.client_secret
            refresh_token=$saved.refresh_token; grant_type='refresh_token'
        } -ErrorAction Stop
        if (-not $fresh.access_token) { throw 'No access_token received.' }
        $script:Headers = @{ Authorization = "Bearer $($fresh.access_token)" }
        $script:TokenRefreshAt = (Get-Date).AddSeconds([math]::Max(60, [int]$fresh.expires_in - 300))
        Write-Host '' # Start a new line after the progress indicator (-NoNewline).
        Write-Host 'Gmail OAuth access token refreshed.'
        $script:ProgressLineLength = 0
    } catch {
        throw ('Failed to refresh Gmail OAuth token; stopping: ' + $_.Exception.Message)
    }
}
$labels = @((Get-Gmail 'labels').labels)
$trigger = $labels | Where-Object { $_.name -ceq $Config.TriggerLabel } | Select-Object -First 1
if (-not $trigger) { throw "Gmail label '$($Config.TriggerLabel)' does not exist." }
$labelMap = @{}
foreach ($label in $labels) {
    if ($label.type -eq 'user' -and $label.id -ne $trigger.id -and $label.name -notmatch '^\[Imap\]/') { $labelMap[[string]$label.id] = [string]$label.name }
}

$indexPath = Join-Path $Config.ArchiveRoot 'ArchiefIndex.json'
$index = @{}
if (Test-Path -LiteralPath $indexPath) {
    $indexData = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
    foreach ($entry in @($indexData)) { if ($entry.threadId) { $index[[string]$entry.threadId] = $entry } }
}


# Older indexes lack message IDs; never silently create duplicate entries.
foreach ($entry in @($index.Values)) {
    if ($null -eq $entry.gmailMessageIds -or $null -eq $entry.rfcMessageIds) {
        throw 'ArchiefIndex.json uses an older format. Back up your data and migrate the index before proceeding.'
    }
}

# Use RFC Message-ID to link new Gmail threads to existing archive entries.
function Normalize-RfcId([string]$Value) {
    if (-not $Value) { return '' }
    return $Value.Trim().Trim('<','>').ToLowerInvariant()
}
function Get-ReferenceIds($Message) {
    $values = @((Get-Header $Message 'In-Reply-To'), (Get-Header $Message 'References'))
    $ids = @()
    foreach ($value in $values) {
        foreach ($match in [regex]::Matches([string]$value, '<([^<>]+)>')) {
            $ids += (Normalize-RfcId $match.Groups[1].Value)
        }
    }
    return @($ids | Where-Object { $_ } | Select-Object -Unique)
}
function Get-CanonicalId($Messages, [string]$CurrentThreadId) {
    if ($index.ContainsKey($CurrentThreadId)) { return $CurrentThreadId }
    foreach ($entry in @($index.Values)) {
        if (@($entry.gmailThreadIds) -contains $CurrentThreadId) { return [string]$entry.threadId }
    }
    foreach ($message in $Messages) {
        foreach ($ref in @(Get-ReferenceIds $message)) {
            if ($script:RfcLookup.ContainsKey($ref)) { return [string]$script:RfcLookup[$ref] }
        }
    }
    return $CurrentThreadId
}
function Get-MessageIds($Messages) {
    return @($Messages | ForEach-Object { [string]$_.id } | Where-Object { $_ } | Select-Object -Unique)
}
function Get-RfcIds($Messages) {
    return @($Messages | ForEach-Object { Normalize-RfcId (Get-Header $_ 'Message-ID') } | Where-Object { $_ } | Select-Object -Unique)
}
# Keep existing exported copies usable when extending an archive.
function Get-ExistingArticles([string]$Path) {
    $content = [IO.File]::ReadAllText($Path)
    $match = [regex]::Match($content, '(?is)(<article\b.*?)(?=</body>\s*</html>)')
    if (-not $match.Success) { throw "Existing HTML cannot be safely extended: $Path" }
    return $match.Groups[1].Value
}

$script:RfcLookup = @{}
foreach ($entry in @($index.Values)) {
    foreach ($rfc in @($entry.rfcMessageIds)) {
        $normalized = Normalize-RfcId ([string]$rfc)
        if ($normalized) { $script:RfcLookup[$normalized] = [string]$entry.threadId }
    }
}

$script:StopGmailBatch = $false
$seen = @{}; $count = 0
# First collect thread IDs only; do not fetch content or attachments yet.
# MaxThreads limits the number of unique Gmail threads processed in one run.
$allHits = @()
Show-ArchiveProgress -Force  # Meteen bij aanvang 0/0; daarna 0/N na het tellen.
$listingComplete = $true
$listed = @{}
$listPageToken = $null
do {
    $listQuery = 'messages?includeSpamTrash=true&maxResults=100&labelIds=' + [uri]::EscapeDataString($trigger.id)
    if ($listPageToken) { $listQuery += '&pageToken=' + [uri]::EscapeDataString($listPageToken) }
    $listPage = Get-Gmail $listQuery
    foreach ($listedHit in @($listPage.messages)) {
        if (-not $listedHit -or -not $listedHit.threadId) { continue }
        $tid = [string]$listedHit.threadId
        if (-not $listed.ContainsKey($tid)) {
            $listed[$tid] = $true
            if ($allHits.Count -lt [int]$Config.MaxThreads) {
                $allHits += [pscustomobject]@{ threadId=$tid }
            } else { $listingComplete = $false; break }
        }
    }
    if (-not $listingComplete) { break }
    $listPageToken = [string]$listPage.nextPageToken
} while ($listPageToken)
$script:ProgressTotal = $allHits.Count
Show-ArchiveProgress -Force  # Show 0/N immediately, even if initial conversations are skipped.
$page = [pscustomobject]@{ messages=$allHits; nextPageToken=$null }
while ($count -lt $Config.MaxThreads) {
    foreach ($hit in @($page.messages)) {
        if (-not $hit -or $seen.ContainsKey([string]$hit.threadId)) { continue }
        $seen[[string]$hit.threadId] = $true
        # Show the previous progress; count a thread BEFORE the API request so rejected threads
        # count toward MaxThreads and appear as errors in the final summary.
        Show-ArchiveProgress
        $count++
        $script:RunStats.Threads++
        $script:LogContext = 'Gmail threadId: ' + [string]$hit.threadId
        try {
            # A single HTTP 403/404 must not abort the entire batch.
            $thread = Get-Gmail ('threads/' + $hit.threadId + '?format=full&includeSpamTrash=true')
        } catch {
            $apiMessage = [string]$_.Exception.Message
            if ($apiMessage -match '(?i)(OAuth|status=401|authenticatie blijft 401)') { throw }
            Write-ArchiveError ('Failed to retrieve Gmail conversation (threadId=' + [string]$hit.threadId + '): ' + $apiMessage)
            # Repeated 403/429/503 responses across threads indicate a general
            # block or rate limit. Stop immediately rather than sending hundreds of requests.
            # This error has already been logged; do NOT throw again (duplicate errors).
            if ($apiMessage -match 'GMAIL_API_ERROR status=(403|429|503)\b') {
                Write-ArchiveWarning 'Batch stopped due to Gmail API access or rate limit. See the Google error details above.'
                $script:StopGmailBatch = $true
                break
            }
            if ($count -ge $Config.MaxThreads) { break }
            continue
        }
        $messages = @($thread.messages | Where-Object { $null -ne $_ } | Sort-Object { [long]$_.internalDate })
        if (-not $messages.Count) {
            Write-ArchiveWarning ('No messages found for threadId=' + [string]$hit.threadId)
            if ($count -ge $Config.MaxThreads) { break }
            continue
        }
        # Select only when at least one trigger-labeled message is OUTSIDE
        # Trash. Once selected, include ALL thread messages,
        # including Trash/Spam, to create a complete archive.
        $activeTrigger = @($messages | Where-Object {
            (@($_.labelIds) -contains [string]$trigger.id) -and
            (@($_.labelIds) -notcontains 'TRASH')
        }).Count -gt 0
        if (-not $activeTrigger) {
            $script:RunStats.Skipped++; $script:RunStats.SkippedReason++
            Add-ArchiveEvent 'SKIPPED_REASON' 'No message with ArchiverenHJ outside Trash; thread not archived.'
            continue
        }
        $last = $messages[-1]
        $script:RunStats.Messages += $messages.Count
        $canonicalId = Get-CanonicalId $messages ([string]$thread.id)
        $isUpdate = $index.ContainsKey($canonicalId)
        $oldEntry = if ($isUpdate) { $index[$canonicalId] } else { $null }
        $hasTrigger = @($messages | Where-Object { @($_.labelIds) -contains [string]$trigger.id }).Count -gt 0
        # Without a trigger, archive only when References point to an existing archive entry.
        if (-not $hasTrigger -and -not $isUpdate) {
            $script:RunStats.Skipped++; $script:RunStats.SkippedReason++
            Add-ArchiveEvent 'SKIPPED_REASON' 'No trigger label and no existing archive entry.'
            continue
        }
        $names = @()
        foreach ($message in $messages) {
            foreach ($labelId in @($message.labelIds)) {
                if ($labelMap.ContainsKey([string]$labelId)) { $names += $labelMap[[string]$labelId] }
            }
        }
        if ($isUpdate -and [string]$thread.id -ne $canonicalId) { $names += @($oldEntry.labelNames | Where-Object { $_ }) }
        $names = @($names | Sort-Object -Unique)
        $destinations = @(Get-ArchivePaths $names)
        $incomingIds = @(Get-MessageIds $messages)
        $priorIds = if ($isUpdate) { @($oldEntry.gmailMessageIds | Where-Object { $_ }) } else { @() }
        $newMessages = @($messages | Where-Object { $priorIds -notcontains [string]$_.id })
        $sameLabels = $isUpdate -and ((@($oldEntry.labelNames | Sort-Object -Unique) -join '|') -eq ($names -join '|'))
        if ($Config.DryRun) { if ($count -ge $Config.MaxThreads) { break }; continue }
        if ($isUpdate -and $newMessages.Count -eq 0 -and $sameLabels) {
            $script:RunStats.Skipped++; $script:RunStats.SkippedUnchanged++
            Add-ArchiveEvent 'SKIPPED_UNCHANGED' 'Unchanged thread.'
            continue
        }
        $subject = Get-Header $last 'Subject'
        if (-not $subject) { $subject = 'No subject' }
        $shortSubject = Short-Name $subject $Config.MaxSubjectLength
        $sender = Short-Name (Get-ConversationNames $messages) $Config.MaxSenderLength
        $date = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$messages[0].internalDate).ToString('yyyy-MM-dd')
        # Keep the exact filename for previously archived conversations.
        # Normalize indexed files explicitly to complete path strings.
        # Avoid indexing a scalar string, which returns only its first character.
        $indexedFiles = @()
        if ($isUpdate) { $indexedFiles = @($oldEntry.files | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
        $fileName = if ($isUpdate -and $indexedFiles.Count -gt 0) {
            [IO.Path]::GetFileName($indexedFiles[0])
        } else { "$date - $sender - $shortSubject [$canonicalId].html" }

        # Build everything in a temporary directory so incomplete exports cannot damage existing archives.
        $temp = Join-Path $Config.ArchiveRoot ('.tmp_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        # Retain the previous index entry for recovery after an error.
        $originalIndexEntry = $oldEntry
        $indexCommitted = $false
        $backupPaths = @()  # Also in case of errors before the export starts.
        try {
            # Do not use the entire HTML filename for attachment folders: it doubles
            # path length and can cause Windows path errors for PDFs.
            $assetsName = $canonicalId + '_files'
            $assetsDir = Join-Path $temp $assetsName
            $previousFiles = $indexedFiles
            $oldHtml = $null
            $oldAssets = $null
            if ($isUpdate -and $previousFiles.Count) {
                $oldHtml = Join-Path $Config.ArchiveRoot ([string]$previousFiles[0])
                $oldAssets = Join-Path (Join-Path (Split-Path -Parent $oldHtml) $Config.FilesFolder) $assetsName
                if (-not (Test-Path -LiteralPath $oldHtml)) {
                    throw ("Existing archive file is missing: {0} | canonicalId={1} | gmailThreadId={2} | indexFiles={3}" -f $oldHtml,$canonicalId,[string]$thread.id,($previousFiles -join '; '))
                }
                if (Test-Path -LiteralPath $oldAssets) { Copy-Item -LiteralPath $oldAssets -Destination $assetsDir -Recurse }
            }
            $body = New-Object System.Text.StringBuilder
            [void]$body.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>' + (Html $subject) + '</title><style>body{font:15px/1.5 Arial,sans-serif;max-width:950px;margin:30px auto;padding:0 20px}article{border-top:2px solid #ddd;padding:18px 0}.meta{color:#555;white-space:pre-wrap}.message{margin-top:18px;overflow-wrap:anywhere}pre{white-space:pre-wrap}.attachments{margin-top:12px}</style></head><body><h1>' + (Html $subject) + '</h1>')
            if ($oldHtml) { [void]$body.AppendLine((Get-ExistingArticles $oldHtml)) }
            $usedAttachmentNames = @{}
            if (Test-Path -LiteralPath $assetsDir) {
                foreach ($existingAsset in @(Get-ChildItem -LiteralPath $assetsDir -File)) {
                    $usedAttachmentNames[$existingAsset.Name] = $true
                }
            }
            $script:SavedCidParts = @{}
            $script:DownloadedImageUrls = @{}
            $script:FailedImageUrls = @{}
            $script:WarnedImageUrls = @{}
            $script:ImageNumber = 0
            foreach ($message in $newMessages) {
                $mFrom = Get-Header $message 'From'; $mTo = Get-Header $message 'To'; $mDate = Get-Header $message 'Date'
                [void]$body.AppendLine('<article><div class="meta"><strong>Van:</strong> ' + (Html $mFrom) + '<br><strong>Aan:</strong> ' + (Html $mTo) + '<br><strong>Datum:</strong> ' + (Html $mDate) + '</div>')
                $parts = @(Get-Parts $message.payload)
                $htmlPart = $parts | Where-Object { $_.mimeType -eq 'text/html' -and -not $_.filename } | Select-Object -First 1
                $textPart = $parts | Where-Object { $_.mimeType -eq 'text/plain' -and -not $_.filename } | Select-Object -First 1
                if ($htmlPart) {
                    $htmlText = Get-CharsetText (Get-PartBytes $htmlPart $message.id) (Get-PartMime $htmlPart)
                    # Never execute active HTML or script code in the offline archive.
                    $htmlText = [regex]::Replace($htmlText, '(?is)<(script|iframe|object|embed|form|base)\b[^>]*>.*?</\1\s*>', '')
                    $htmlText = [regex]::Replace($htmlText, '(?is)<(script|iframe|object|embed|base)\b[^>]*/?>', '')
                    $htmlText = [regex]::Replace($htmlText, '(?i)\s+on[a-z]+\s*=\s*("[^"]*"|''[^'']*''|[^\s>]+)', '')
                    $htmlText = [regex]::Replace($htmlText, '(?i)(href|src)\s*=\s*(["''])\s*(javascript:|data:text/html)[^"'']*\2', '$1="#"')
                    $htmlText = [regex]::Replace($htmlText, '(?is)<style\b[^>]*>.*?</style\s*>', '')
                    $htmlText = [regex]::Replace($htmlText, '(?is)</?(html|head|body|meta|title|link|style)\b[^>]*>', '')
                    if ($Config.DownloadImages) {
                        $htmlText = Save-MessageImages $htmlText $parts $message.id $assetsDir $assetsName $usedAttachmentNames
                    }
                    [void]$body.AppendLine('<div class="message">' + $htmlText + '</div>')
                } elseif ($textPart) {
                    $plain = Get-CharsetText (Get-PartBytes $textPart $message.id) (Get-PartMime $textPart)
                    [void]$body.AppendLine('<div class="message"><pre>' + (Html $plain) + '</pre></div>')
                } else { [void]$body.AppendLine('<p><em>No readable message body.</em></p>') }
                if ($Config.SaveAttachments) {
                    $links = @()
                    foreach ($part in $parts) {
                        if (-not $part.filename) { continue }
                        if (-not (Test-Path -LiteralPath $assetsDir)) { New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null }
                        $cid = Get-ContentId $part
                        if ($cid -and $script:SavedCidParts.ContainsKey($message.id + '|' + $cid)) {
                            $attachmentName = $script:SavedCidParts[$message.id + '|' + $cid]
                        } else {
                            $attachmentName = Unique-AttachmentName ([string]$part.filename) $usedAttachmentNames
                            [IO.File]::WriteAllBytes((Join-Path $assetsDir $attachmentName), [byte[]](Get-PartBytes $part $message.id))
                        }
                        $url = [uri]::EscapeDataString($Config.FilesFolder) + '/' + [uri]::EscapeDataString($assetsName) + '/' + [uri]::EscapeDataString($attachmentName)
                        $links += '<a href="' + $url + '">' + (Html ([string]$part.filename)) + '</a>'
                    }
                    if ($links.Count) { [void]$body.AppendLine('<div class="attachments"><strong>Bijlagen:</strong> ' + ($links -join ' | ') + '</div>') }
                }
                [void]$body.AppendLine('</article>')
            }
            [void]$body.AppendLine('</body></html>')
            $tempHtml = Join-Path $temp $fileName
            [IO.File]::WriteAllText($tempHtml, $body.ToString(), (New-Object Text.UTF8Encoding($false)))
            if ($isUpdate -and -not $Config.UpdateExisting) {
                Write-ArchiveWarning "Already archived, skipping: $canonicalId"
                $script:RunStats.Skipped++; $script:RunStats.SkippedReason++
                Add-ArchiveEvent 'SKIPPED_REASON' 'UpdateExisting is disabled; existing thread was not updated.'
                continue
            }
            $oldMessageCount = if ($isUpdate) { [int]$oldEntry.messageCount } else { 0 }
            $newFiles = @()
            $backupPaths = @()
            # Prepare all destinations; overwrite only files belonging to this index entry.
            foreach ($dest in $destinations) {
                $folder = Join-Path $Config.ArchiveRoot $dest
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                $targetHtml = Join-Path $folder $fileName
                $relativeTarget = $dest + '\' + $fileName
                if ((Test-Path -LiteralPath $targetHtml) -and ($previousFiles -notcontains $relativeTarget)) {
                    throw "Destination file already exists and belongs to another conversation: $targetHtml"
                }
                $targetAssets = Join-Path (Join-Path $folder $Config.FilesFolder) $assetsName
                if ((Test-Path -LiteralPath $targetAssets) -and ($previousFiles -notcontains $relativeTarget)) {
                    throw "Attachment directory already exists and belongs to another conversation: $targetAssets"
                }
                $newFiles += $relativeTarget
            }
            # Create recoverable backups of every export being replaced.
            foreach ($dest in $destinations) {
                $folder = Join-Path $Config.ArchiveRoot $dest
                $targetHtml = Join-Path $folder $fileName
                $targetAssets = Join-Path (Join-Path $folder $Config.FilesFolder) $assetsName
                $backupHtml = $targetHtml + '.v089backup'
                $backupAssets = $targetAssets + '.v089backup'
                if ((Test-Path -LiteralPath $backupHtml) -or (Test-Path -LiteralPath $backupAssets)) {
                    throw "An old recovery backup exists; inspect it first: $targetHtml"
                }
                if (Test-Path -LiteralPath $targetHtml) { Move-Item -LiteralPath $targetHtml -Destination $backupHtml }
                if (Test-Path -LiteralPath $targetAssets) { Move-Item -LiteralPath $targetAssets -Destination $backupAssets }
                $backupPaths += [pscustomobject]@{ Html=$targetHtml; Assets=$targetAssets; BackupHtml=$backupHtml; BackupAssets=$backupAssets }
                if (Test-Path -LiteralPath $assetsDir) {
                    [IO.Directory]::CreateDirectory((Split-Path -Parent $targetAssets)) | Out-Null
                    Copy-Item -LiteralPath $assetsDir -Destination $targetAssets -Recurse
                }
                Copy-Item -LiteralPath $tempHtml -Destination $targetHtml
            }
            $allGmailIds = @($priorIds + $incomingIds | Select-Object -Unique)
            $allRfcIds = @(@($oldEntry.rfcMessageIds | Where-Object { $_ }) + @(Get-RfcIds $messages) | Select-Object -Unique)
            $allThreadIds = @(@($oldEntry.gmailThreadIds | Where-Object { $_ }) + @([string]$thread.id) | Select-Object -Unique)
            $index[$canonicalId] = [pscustomobject]@{
                threadId=$canonicalId; lastMessageId=[string]$last.id
                messageCount=$allGmailIds.Count; files=$newFiles
                gmailMessageIds=$allGmailIds; rfcMessageIds=$allRfcIds
                gmailThreadIds=$allThreadIds; labelNames=$names
            }
            Save-ArchiveIndex $index $indexPath
            $indexCommitted = $true
            foreach ($rfc in $allRfcIds) { $script:RfcLookup[[string]$rfc] = $canonicalId }
            foreach ($backup in $backupPaths) {
                if (Test-Path -LiteralPath $backup.BackupHtml) { Remove-Item -LiteralPath $backup.BackupHtml -Force }
                if (Test-Path -LiteralPath $backup.BackupAssets) { Remove-Item -LiteralPath $backup.BackupAssets -Recurse -Force }
            }

            # Delete old versions only after the new HTML, assets and index are saved.
            # Delete only files from the previous index entry; never delete directories
            # outside the configured archive root.
            if ($isUpdate) {
                $rootFull = [IO.Path]::GetFullPath($Config.ArchiveRoot).TrimEnd('\') + '\'
                foreach ($relativeOld in $previousFiles) {
                    try {
                        $oldHtml = [IO.Path]::GetFullPath((Join-Path $Config.ArchiveRoot ([string]$relativeOld)))
                        if (-not $oldHtml.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                            throw 'Old archive path is outside ArchiveRoot.'
                        }
                        if ([IO.Path]::GetExtension($oldHtml) -ine '.html') { throw 'Old archive path is not an HTML file.' }
                        if (@($newFiles | Where-Object { $_ -ieq [string]$relativeOld }).Count) { continue }
                        # Older versions may still use the long folder name from v0.74.
                        $oldStem = [IO.Path]::GetFileNameWithoutExtension($oldHtml)
                        $oldAssetsNames = @($oldStem + '_files')
                        if ($oldStem -match '\[([a-fA-F0-9]+)\]$') {
                            $oldAssetsNames += ($Matches[1] + '_files')
                        }
                        if (Test-Path -LiteralPath $oldHtml) { Remove-Item -LiteralPath $oldHtml -Force }
                        foreach ($oldAssetsName in ($oldAssetsNames | Select-Object -Unique)) {
                            $oldAssets = Join-Path (Join-Path (Split-Path -Parent $oldHtml) $Config.FilesFolder) $oldAssetsName
                            if (Test-Path -LiteralPath $oldAssets) { Remove-Item -LiteralPath $oldAssets -Recurse -Force }
                        }
                    } catch {
                        Write-ArchiveWarning ('Could not clean up old version: ' + $relativeOld + ' - ' + $_.Exception.Message)
                    }
                }
            }
            if ($isUpdate) {
                $script:RunStats.Updated++
                $detail = if ($null -ne $oldMessageCount) {
                    'Updated: ' + $newMessages.Count + ' new message(s); total ' + $allGmailIds.Count + '.'
                } else {
                    'Updated: total ' + $allGmailIds.Count + ' messages.'
                }
                # When Gmail threads are merged, the archive ID differs from
                # the thread ID in the log context; display both for troubleshooting.
                if ([string]$thread.id -ne [string]$canonicalId) {
                    $detail += ' Added to archive threadId: ' + [string]$canonicalId + '.'
                } else {
                    $detail += ' Archive threadId: ' + [string]$canonicalId + '.'
                }
                Add-ArchiveEvent 'UPDATED' $detail
            } else {
                $script:RunStats.New++
                Add-ArchiveEvent 'NEW' ('New conversation with ' + $messages.Count + ' message(s).')
            }

        } catch {
            # A failure in one conversation must not block hundreds of others.
            # Restore the in-memory index only if saving it failed.
            $originalError = $_
            if (-not $indexCommitted) {
                if ($isUpdate) { $index[$canonicalId] = $originalIndexEntry }
                else { [void]$index.Remove($canonicalId) }
                # Restore old target files if the index could not be saved.
                foreach ($backup in $backupPaths) {
                    if ($null -eq $backup) { continue }
                    try {
                        if ($backup.Html -and (Test-Path -LiteralPath $backup.Html)) { Remove-Item -LiteralPath $backup.Html -Force -ErrorAction Stop }
                        if ($backup.Assets -and (Test-Path -LiteralPath $backup.Assets)) { Remove-Item -LiteralPath $backup.Assets -Recurse -Force -ErrorAction Stop }
                        if ($backup.BackupHtml -and (Test-Path -LiteralPath $backup.BackupHtml)) { Move-Item -LiteralPath $backup.BackupHtml -Destination $backup.Html -ErrorAction Stop }
                        if ($backup.BackupAssets -and (Test-Path -LiteralPath $backup.BackupAssets)) { Move-Item -LiteralPath $backup.BackupAssets -Destination $backup.Assets -ErrorAction Stop }
                    } catch {
                        Write-ArchiveWarning ('Recovery backup was not fully restored: ' + $_.Exception.Message)
                    }
                }
            }
            Write-ArchiveError ($originalError.Exception.Message + ' | ' + $originalError.InvocationInfo.PositionMessage)
        } finally {
            if (Test-Path -LiteralPath $temp) {
                try { Remove-Item -LiteralPath $temp -Recurse -Force }
                catch { Write-ArchiveWarning ('Could not clean up temporary directory: ' + $_.Exception.Message) }
            }
        }
        if ($count -ge $Config.MaxThreads) { break }
    }
    break  # All previously collected unique thread IDs have been processed.
}

# Print final progress.
Show-ArchiveProgress -Force
Write-Host ''
$script:FinalProgressPrinted = $true


} catch {
    Write-ArchiveError ($_.Exception.Message + ' | ' + $_.InvocationInfo.PositionMessage)
    # Error already logged; avoid duplicate console output.
} finally {
    if (-not $script:FinalProgressPrinted) {
        try { Show-ArchiveProgress -Force } catch { }
        Write-Host ''
    }
    if ($script:SleepPreventionActive) {
        try { [void][GmailHJPower]::SetThreadExecutionState([uint32]2147483648) }
        catch { Write-Warning ('Failed to restore sleep settings: ' + $_.Exception.Message) }
    }
    try { Show-ApiSummary } catch { Write-Host ('Could not display API summary: ' + $_.Exception.Message) }
    try { Write-ArchiveLog }
    catch { [Console]::Error.WriteLine('Could not save HTML log: ' + $_.Exception.Message) }
}
