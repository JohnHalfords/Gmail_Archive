# Gmail Archive Delete - v1.03
# Windows PowerShell 5.1
# Author: John Halfords and my friend Chappie (ChatGPT - OpenAI)

# This script moves individually verified Gmail message IDs to Trash.
# It NEVER calls threads.trash, so late-arriving messages cannot be trashed by thread ID.
# A 'candidate' means all current Gmail message IDs match the archived index.
# Merged index entries are verified across every member thread; only the
# selected thread's explicit message IDs are moved after a fresh group check.
# Archive files are deliberately NOT checked: users may remove them intentionally.
# Any discrepancy blocks the entire thread. All Gmail modifications require confirmation.
# Windows PowerShell 5.1 compatible.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$settingsPath = Join-Path $PSScriptRoot 'Gmail_Archive_Settings.psd1'
if (-not (Test-Path -LiteralPath $settingsPath)) { throw "Missing settings: $settingsPath" }
$cfg = Import-PowerShellDataFile -LiteralPath $settingsPath
if (-not $cfg.ScriptFolder -or -not $cfg.ArchiveRoot -or -not $cfg.TriggerLabel) { throw 'Required settings missing.' }
# Keep sensitive OAuth files in the private subfolder.
if (-not $cfg.OAuthFile -or -not $cfg.TokenFile) { throw 'OAuthFile/TokenFile missing in settings.' }
$privatePath = Join-Path $cfg.ScriptFolder 'private'
$oauthPath = Join-Path $privatePath (Split-Path -Path $cfg.OAuthFile -Leaf)
$tokenPath = Join-Path $privatePath (Split-Path -Path $cfg.TokenFile -Leaf)
$indexPath = Join-Path $cfg.ArchiveRoot 'ArchiefIndex.json'
foreach ($path in @($oauthPath,$tokenPath,$indexPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file missing: $path" }
}
$client = (Get-Content -LiteralPath $oauthPath -Raw | ConvertFrom-Json).installed
$saved = Get-Content -LiteralPath $tokenPath -Raw | ConvertFrom-Json
if (-not $client -or -not $saved.refresh_token) { throw 'Missing OAuth client or refresh token.' }
if (@($saved.scope -split '\s+') -notcontains 'https://www.googleapis.com/auth/gmail.modify') {
    throw 'gmail.modify permission is missing. Run the accompanying Gmail_Archive_OAuth_v1.00.ps1 first.'
}
# The access token is short-lived; refresh it during long runs, not only at startup.
$script:headers = @{}
$script:tokenExpiresAt = [datetime]::MinValue
function Refresh-GmailToken {
    $newToken = Invoke-RestMethod -Method Post -Uri $client.token_uri -ContentType 'application/x-www-form-urlencoded' -Body @{
        client_id=$client.client_id; client_secret=$client.client_secret
        refresh_token=$saved.refresh_token; grant_type='refresh_token'
    } -ErrorAction Stop
    if (-not $newToken.access_token) { throw 'OAuth refresh returned no access token.' }
    $script:headers = @{ Authorization = 'Bearer ' + $newToken.access_token }
    $lifetime = if ($newToken.expires_in) { [int]$newToken.expires_in } else { 3599 }
    $script:tokenExpiresAt = (Get-Date).AddSeconds([math]::Max(60,$lifetime-120))
}
Refresh-GmailToken
$script:lastCall = [datetime]::MinValue
$script:apiCalls = 0
$script:activeThreadId = ''
$script:warningCount = 0
$script:runStarted = Get-Date
$script:deleteEvents = New-Object System.Collections.ArrayList
$script:processed = 0
$script:progressLength = 0
$script:sleepActive = $false
$script:phase = 'Preparing archive index'
$script:discovered = 0
# One console line is rewritten in place; per-thread details go only to the HTML log.
function Show-DeleteProgress {
    param([switch]$Final)
    $elapsed = (Get-Date) - $script:runStarted
    $clock = ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($elapsed.TotalHours),$elapsed.Minutes,$elapsed.Seconds)
    if ($script:phase -ne 'Checking') {
        $line = ('Progress: {0} | found {1} threads | elapsed {2} | API {3}' -f $script:phase,$script:discovered,$clock,$script:apiCalls)
    } else {
        $pct = if ($ids.Count -gt 0) { [int][math]::Floor(100*$script:processed/$ids.Count) } else { 100 }
        $line = ('Progress: {0}/{1} ({2}%) | {3} | trash {4} | wait {5} | skip {6} | warn {7} | err {8} | API {9}' -f $script:processed,$ids.Count,$pct,$clock,$counts.Trashed,$counts.NotReady,$counts.Trash,$script:warningCount,$counts.Errors,$script:apiCalls)
    }
    try {
        $width = [Console]::WindowWidth
        if ($width -gt 15 -and $line.Length -ge $width) { $line = $line.Substring(0,$width-1) }
        $pad = [math]::Max(0,$script:progressLength-$line.Length)
        [Console]::Write("`r" + $line + (' '*$pad))
        $script:progressLength = $line.Length
        if ($Final) { [Console]::WriteLine(); $script:progressLength = 0 }
    } catch {
        # Fallback for non-console PowerShell hosts.
        if ($Final) { Write-Host $line }
    }
}
function Write-DeleteWarning([string]$message) {
    if ($script:progressLength -gt 0) {
        try { [Console]::WriteLine() } catch {}
        $script:progressLength = 0
    }
    Write-Warning $message
}
function Enable-RunAwake {
    if (-not ('GmailDeletePower' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GmailDeletePower {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@
    }
    $result = [GmailDeletePower]::SetThreadExecutionState([uint32]2147483649)
    if ($result -eq 0) { Write-Warning 'Could not prevent Windows sleep mode.' }
    else { $script:sleepActive = $true }
}
function Disable-RunAwake {
    if ($script:sleepActive) {
        [void][GmailDeletePower]::SetThreadExecutionState([uint32]2147483648)
        $script:sleepActive = $false
    }
}

# Conservative baseline: minimum 1.5 seconds between calls.
# Tests showed repeated user-quota 403s even at 1 call/second.
# The 403 recovery schedule is progressive; never blindly retry other 403s.
function Invoke-GmailRequest([string]$method, [string]$uri) {
    $baseDelay = [math]::Max(1500, [int]$cfg.ApiRequestIntervalMs)
    $maxRetries = [math]::Max(0,[int]$cfg.ApiRetryCount)
    $authRetried = $false
    $attempt = 0
    while ($true) {
        if ((Get-Date) -ge $script:tokenExpiresAt) { Refresh-GmailToken }
        $elapsed = ((Get-Date) - $script:lastCall).TotalMilliseconds
        if ($elapsed -lt $baseDelay) { Start-Sleep -Milliseconds ([int][math]::Ceiling($baseDelay-$elapsed)) }
        $script:lastCall = Get-Date
        $script:apiCalls++
        try {
            if ($method -eq 'GET') {
                return Invoke-RestMethod -Method Get -Uri $uri -Headers $script:headers -ErrorAction Stop
            }
            $null = Invoke-RestMethod -Method Post -Uri $uri -Headers $script:headers -ErrorAction Stop
            return
        } catch {
            $response = $_.Exception.Response
            $status = if ($response) { [int]$response.StatusCode } else { 0 }
            if ($status -eq 401 -and -not $authRetried) {
                $authRetried = $true
                Refresh-GmailToken
                continue
            }
            # A 403 can also mean a genuine permission failure. Retry only quota errors.
            $quotaExceeded = ($status -eq 429)
            if ($status -eq 403 -and $response) {
                try {
                    $stream = $response.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $errorBody = $reader.ReadToEnd()
                        $quotaExceeded = ($errorBody -match 'rateLimitExceeded|RATE_LIMIT_EXCEEDED|quotaExceeded|Quota exceeded')
                    }
                } catch { $quotaExceeded = $false }
            }
            if ($attempt -ge $maxRetries -or (($status -eq 403 -or $status -eq 429) -and -not $quotaExceeded) -or $status -notin @(403,429,500,502,503,504)) { throw }
            # Short first pause, then progressively longer pauses if quota has not recovered.
            $wait = if ($quotaExceeded) {
                @([int]15,[int]30,[int]65,[int]90,[int]120)[[math]::Min($attempt,4)]
            } else { [int][math]::Min(60,[math]::Pow(2,$attempt+1)) }
            $attempt++
            $msg = "Gmail API HTTP $status; retry $attempt/$maxRetries after $wait seconds."
            Write-DeleteWarning $msg
            $script:warningCount++
            Add-DeleteEvent 'WARNING' $script:activeThreadId $msg
            Start-Sleep -Seconds $wait
        }
    }
}
function Get-Gmail([string]$route) {
    return Invoke-GmailRequest 'GET' ('https://gmail.googleapis.com/gmail/v1/users/me/' + $route)
}
function Invoke-GmailTrash([string]$messageId) {
    $uri = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/' + [uri]::EscapeDataString($messageId) + '/trash'
    $null = Invoke-GmailRequest 'POST' $uri
}
# Log all warnings, blocked threads, and completed Trash moves in the shared HTML log.
function Add-DeleteEvent([string]$level, [string]$tid, [string]$message) {
    [void]$script:deleteEvents.Add([pscustomobject]@{
        Level=$level; ThreadId=$tid; Message=$message; Time=(Get-Date).ToString('HH:mm:ss')
    })
}
function Encode-LogText([string]$value) {
    return [System.Net.WebUtility]::HtmlEncode($value)
}
function Save-DeleteLog {
    $name = [string]$cfg.LogFile
    if (-not $name -or [IO.Path]::GetFileName($name) -cne $name -or -not $name.EndsWith('.html',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'LogFile must be an .html filename without a path.'
    }
    $path = Join-Path $cfg.ArchiveRoot $name
    $marker = '<!-- LOG_ENTRIES -->'
    $enc = New-Object System.Text.UTF8Encoding($false)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<section class="run"><h2>' + (Encode-LogText ($script:runStarted.ToString('dd-MM-yyyy HH:mm:ss') + ' - Gmail Archived Delete - by John Halfords - v1.03 (MOVE TO TRASH)')) + '</h2>')
    [void]$sb.AppendLine(('<p class="stats">Checked: {0} &nbsp;|&nbsp; Trashed: {1} &nbsp;|&nbsp; Not ready: {2} &nbsp;|&nbsp; Trash/ignored: {3} &nbsp;|&nbsp; Warnings: {4} &nbsp;|&nbsp; Errors: {5} &nbsp;|&nbsp; API calls: {6}</p>' -f $ids.Count,$counts.Trashed,$counts.NotReady,$counts.Trash,$script:warningCount,$counts.Errors,$script:apiCalls))
    [void]$sb.AppendLine('<p class="duration">Finished: ' + (Get-Date).ToString('HH:mm:ss') + ' - Verified Gmail messages were moved to Trash.</p>')
    foreach ($ev in $script:deleteEvents) {
        $css = if ($ev.Level -eq 'ERROR') { 'error' } elseif ($ev.Level -eq 'TRASHED') { 'updated' } else { 'warning' }
        [void]$sb.AppendLine('<div class="event ' + $css + '" data-level="' + $ev.Level + '"><b>' + $ev.Level + '</b> &middot; ' + (Encode-LogText $ev.Time) + ' &middot; Gmail threadId: ' + (Encode-LogText $ev.ThreadId) + '<div>' + (Encode-LogText $ev.Message) + '</div></div>')
    }
    [void]$sb.AppendLine('</section>')
    $section = $sb.ToString()
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $old = [IO.File]::ReadAllText($path)
        if (-not $old.Contains($marker)) { throw "Existing HTML log has no insertion marker: $path" }
        $newContent = $old.Replace($marker, $marker + "`r`n" + $section)
        $filterbar = '<div class="logfilters"><label for="levelFilter">Show:</label> <select id="levelFilter" onchange="filterLog()"><option value="ALL">All</option><option value="ERROR">Errors</option><option value="WARNING">Warnings</option><option value="TRASHED">Moved to Trash</option><option value="NOT_READY">Not ready</option><option value="NEW">New</option><option value="UPDATED">Updated</option><option value="SKIPPED_UNCHANGED">Skipped unchanged</option><option value="SKIPPED_REASON">Skipped with reason</option></select> <label><input type="checkbox" id="hideEmpty" onchange="filterLog()"> Hide runs without matching events</label></div>'
        $newContent = [regex]::Replace($newContent,'(?s)<div class="logfilters">.*?</div>',[System.Text.RegularExpressions.MatchEvaluator]{param($m) $filterbar})
    } else {
        $title = Encode-LogText 'Gmail Archived Delete - by John Halfords'
        $newContent = '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>' + $title + '</title><style>body{font:15px/1.5 Arial,sans-serif;max-width:1000px;margin:30px auto;padding:0 18px;color:#222;background:#f7f8fa}.run{background:white;border:1px solid #ddd;border-radius:8px;padding:16px 20px;margin:18px 0}.stats{font-weight:bold}.event{padding:8px 12px;margin:6px 0;border-left:4px solid #999;background:#f4f4f4;overflow-wrap:anywhere}.event.error{color:#a00000;background:#fff0f0;border-color:#d00000}.event.warning{color:#925100;background:#fff5e4;border-color:#e38b00}</style></head><body><h1>' + $title + '</h1><div class="logfilters"><label for="levelFilter">Show:</label> <select id="levelFilter" onchange="filterLog()"><option value="ALL">All</option><option value="ERROR">Errors</option><option value="NOT_READY">Not ready</option><option value="WARNING">Warnings</option><option value="TRASHED">Moved to Trash</option></select> <label><input type="checkbox" id="hideEmpty" onchange="filterLog()"> Hide runs without matching events</label></div>' + $marker + "`r`n" + $section + '<script>function filterLog(){var v=document.getElementById("levelFilter").value;var hide=document.getElementById("hideEmpty").checked;document.querySelectorAll(".run").forEach(function(run){var count=0;run.querySelectorAll(".event").forEach(function(ev){var ok=v==="ALL"||ev.getAttribute("data-level")===v;ev.style.display=ok?"":"none";if(ok)count++;});run.style.display=hide&&count===0?"none":"";});}document.addEventListener("DOMContentLoaded",filterLog);</script></body></html>'
    }
    # Keep newest complete runs; never discard the just-created run.
    $maxMB = [double]$cfg.MaxLogSizeMB
    if ($maxMB -le 0) { throw 'MaxLogSizeMB must be greater than 0.' }
    $limit = [long][math]::Floor($maxMB * 1MB)
    while ($enc.GetByteCount($newContent) -gt $limit) {
        $runs = [regex]::Matches($newContent,'(?s)<section class="run">.*?</section>')
        if ($runs.Count -le 1) { break }
        $oldest = $runs[$runs.Count-1]
        $newContent = $newContent.Remove($oldest.Index,$oldest.Length)
    }
    $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp,$newContent,$enc)
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

Write-Host 'Gmail Archive Delete v1.03 - MOVE TO TRASH' -ForegroundColor Cyan
Write-Host 'Only archived, individually verified Gmail messages can be moved to Trash.'
Write-Host 'Your archive files are NOT deleted.'
$maxThreads = [int]$cfg.MaxThreads
if ($maxThreads -lt 1) { throw 'MaxThreads must be at least 1.' }
Write-Host ("Move verified messages from up to {0} threads to Gmail Trash? [y/N]" -f $maxThreads) -ForegroundColor Yellow
$answer = Read-Host
if ($answer -cne 'y') { Write-Host 'Cancelled. No Gmail messages were modified.'; return }
Enable-RunAwake
Show-DeleteProgress
try {
$index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
# ConvertFrom-Json already returns the top-level JSON array. Do not wrap it in @(...),
# which can nest the whole array as one item on Windows PowerShell 5.1.
$byThread = @{}
foreach ($entry in $index) {
    foreach ($tid in @($entry.gmailThreadIds)) {
        if (-not $tid) { continue }
        if (-not $byThread.ContainsKey([string]$tid)) { $byThread[[string]$tid] = @() }
        $byThread[[string]$tid] += ,$entry
    }
}
$script:phase = 'Finding Gmail label'
Show-DeleteProgress
$labels = @((Get-Gmail 'labels').labels)
$trigger = $labels | Where-Object { $_.name -ceq $cfg.TriggerLabel } | Select-Object -First 1
if (-not $trigger) { throw "Gmail label not found: $($cfg.TriggerLabel)" }
$hits = @{}
$script:phase = 'Finding labeled threads'
Show-DeleteProgress
$pageToken = ''
do {
    $route = 'messages?includeSpamTrash=true&maxResults=100&labelIds=' + [uri]::EscapeDataString([string]$trigger.id)
    if ($pageToken) { $route += '&pageToken=' + [uri]::EscapeDataString($pageToken) }
    $page = Get-Gmail $route
    foreach ($m in @($page.messages)) { if ($m -and $m.threadId) { $hits[[string]$m.threadId] = $true } }
    $pageToken = [string]$page.nextPageToken
    $script:discovered = $hits.Count
    Show-DeleteProgress
} while ($pageToken)
$maxThreads = [int]$cfg.MaxThreads
if ($maxThreads -lt 1) { throw 'MaxThreads must be at least 1.' }
$ids = @($hits.Keys | Sort-Object | Select-Object -First $maxThreads)
Show-DeleteProgress -Final
Write-Host ("Found {0} labeled threads; checking {1} (MaxThreads={2})." -f $hits.Count,$ids.Count,$maxThreads)
$counts = @{ Trashed=0; NotReady=0; Trash=0; Errors=0 }
$cache = @{}
$script:phase = 'Checking'
Show-DeleteProgress
foreach ($tid in $ids) {
    $script:activeThreadId = $tid
    try {
        if (-not $cache.ContainsKey($tid)) {
            $cache[$tid] = Get-Gmail ('threads/' + [uri]::EscapeDataString($tid) + '?format=full&includeSpamTrash=true')
        }
        $thread = $cache[$tid]
        $messages = @($thread.messages | Where-Object { $_ })
        $active = @($messages | Where-Object {
            @($_.labelIds) -contains [string]$trigger.id -and @($_.labelIds) -notcontains 'TRASH'
        })
        if ($active.Count -eq 0) { $counts.Trash++; Add-DeleteEvent 'SKIPPED_REASON' $tid 'Already trashed / no active trigger.'; continue }
        $reasons = New-Object 'System.Collections.Generic.List[string]'
        # Always construct a real array, even when PowerShell returns a single object.
        # Assigning the output of an if-expression can otherwise unwrap that object.
        $matchingEntries = @()
        if ($byThread.ContainsKey($tid)) {
            $matchingEntries = @($byThread[$tid])
        }
        $matchCount = @($matchingEntries).Count
        if ($matchCount -ne 1) { $reasons.Add("Expected exactly one index entry; found $matchCount.") }
        if ($matchCount -eq 1) {
            $entry = $matchingEntries[0]
            $expectedIds = @($entry.gmailMessageIds | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            $groupIds = @($entry.gmailThreadIds | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            $actualIds = @()
            foreach ($groupTid in $groupIds) {
                if (-not $cache.ContainsKey($groupTid)) {
                    try { $cache[$groupTid] = Get-Gmail ('threads/' + [uri]::EscapeDataString($groupTid) + '?format=full&includeSpamTrash=true') }
                    catch { $reasons.Add("Could not verify merged Gmail thread $groupTid."); continue }
                }
                $actualIds += @($cache[$groupTid].messages | Where-Object { $_ } | ForEach-Object { [string]$_.id })
            }
            $actualIds = @($actualIds | Sort-Object -Unique)
            if ($expectedIds.Count -ne $actualIds.Count -or (@(Compare-Object $expectedIds $actualIds).Count -gt 0)) {
                $notArchived = @($actualIds | Where-Object { $expectedIds -cnotcontains $_ })
                $missingFromGmail = @($expectedIds | Where-Object { $actualIds -cnotcontains $_ })
                $reasons.Add(('Gmail message IDs differ from archive index (including merged threads): {0} Gmail message(s) not in index; {1} indexed message(s) not in Gmail.' -f $notArchived.Count,$missingFromGmail.Count))
            }
            if ([int]$entry.messageCount -ne $expectedIds.Count) { $reasons.Add('Index message count mismatch.') }
            if ($groupIds.Count -eq 0 -or $expectedIds.Count -eq 0) {
                $reasons.Add('Empty merged archive index entry; no messages moved.')
            }
            # Each Gmail thread in this merged entry must point to this exact single
            # index entry. Otherwise the index is ambiguous and cannot be trusted.
            foreach ($groupTid in $groupIds) {
                if (-not $byThread.ContainsKey($groupTid) -or @($byThread[$groupTid]).Count -ne 1 -or
                    -not [object]::ReferenceEquals($byThread[$groupTid][0], $entry)) {
                    $reasons.Add("Merged index mapping is ambiguous for Gmail thread $groupTid.")
                }
            }
            # A merged entry may contain multiple Gmail threads. Ensure that their
            # individual live message IDs are unique across the entire group.
            $groupMessageIds = @()
            foreach ($groupTid in $groupIds) {
                if ($cache.ContainsKey($groupTid)) {
                    $groupMessageIds += @($cache[$groupTid].messages | Where-Object { $_ } | ForEach-Object { [string]$_.id })
                }
            }
            if (@($groupMessageIds | Sort-Object -Unique).Count -ne $groupMessageIds.Count) {
                $reasons.Add('Duplicate Gmail message IDs found across merged threads.')
            }
            # This first live version refuses threads already partially in Trash.
            if (@($messages | Where-Object { @($_.labelIds) -contains 'TRASH' }).Count -gt 0) {
                $reasons.Add('Thread contains messages already in Trash; manual review required.')
            }

        }
        if ($reasons.Count -eq 0) {
            # Refresh immediately before modification. Never use threads.trash:
            # explicit message IDs protect new arrivals from accidental removal.
            $fresh = Get-Gmail ('threads/' + [uri]::EscapeDataString($tid) + '?format=full&includeSpamTrash=true')
            $freshMessages = @($fresh.messages | Where-Object { $_ })
            $freshIds = @($freshMessages | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
            $freshActive = @($freshMessages | Where-Object {
                @($_.labelIds) -contains [string]$trigger.id -and @($_.labelIds) -notcontains 'TRASH'
            })
            # For merged entries, expectedIds covers the entire group, not just
            # this Gmail thread. Recheck every member immediately before moving
            # explicit message IDs from the selected thread only.
            $freshGroupIds = @()
            $freshGroupFailed = $false
            foreach ($groupTid in $groupIds) {
                if ($groupTid -ceq $tid) { $groupThread = $fresh }
                else {
                    try { $groupThread = Get-Gmail ('threads/' + [uri]::EscapeDataString($groupTid) + '?format=full&includeSpamTrash=true') }
                    catch { $freshGroupFailed = $true; break }
                }
                $freshGroupIds += @($groupThread.messages | Where-Object { $_ } | ForEach-Object { [string]$_.id })
            }
            $freshGroupUnique = @($freshGroupIds | Sort-Object -Unique)
            if ($freshGroupFailed -or $freshGroupUnique.Count -ne $freshGroupIds.Count -or
                $freshActive.Count -eq 0 -or $freshIds.Count -eq 0 -or
                $freshGroupUnique.Count -ne $expectedIds.Count -or
                @(Compare-Object $freshGroupUnique $expectedIds).Count -gt 0 -or
                @($freshMessages | Where-Object { @($_.labelIds) -contains 'TRASH' }).Count -gt 0) {
                $counts.NotReady++
                $reason = 'Last-second Gmail check changed; nothing moved.'
                
                Add-DeleteEvent 'NOT_READY' $tid $reason
                continue
            }
            # A Gmail thread can receive new messages after this check. By moving
            # only explicit verified IDs, new messages are never moved implicitly.
            $moved = 0
            foreach ($mid in $freshIds) {
                try { Invoke-GmailTrash $mid }
                catch {
                    Add-DeleteEvent 'ERROR' $tid ("PARTIAL MOVE: $moved of $($freshIds.Count) message(s) moved before failure. Manual review required. " + $_.Exception.Message)
                    throw
                }
                $moved++
            }
            $counts.Trashed++
            
            Add-DeleteEvent 'TRASHED' $tid ("Moved $moved verified message(s) to Gmail Trash.")
        } else {
            $counts.NotReady++
            
            Add-DeleteEvent 'NOT_READY' $tid ($reasons -join ' | ')
        }
    } catch {
        $counts.Errors++
        Write-DeleteWarning "CHECK FAILED: $tid - $($_.Exception.Message)"
        Add-DeleteEvent 'ERROR' $tid ([string]$_.Exception.Message)
    } finally {
        $script:processed++
        Show-DeleteProgress
    }
}
Show-DeleteProgress -Final
Write-Host ("SUMMARY | Trashed: {0} | Not ready: {1} | Trash/ignored: {2} | Warnings: {3} | Errors: {4} | API calls: {5}" -f $counts.Trashed,$counts.NotReady,$counts.Trash,$script:warningCount,$counts.Errors,$script:apiCalls)
Write-Host 'Only verified Gmail message IDs were moved to Trash. Archive files and attachments were not checked.'

try {
    Save-DeleteLog
    Write-Host ('HTML log updated: ' + (Join-Path $cfg.ArchiveRoot $cfg.LogFile))
} catch {
    Write-Warning ('Could not save HTML log: ' + $_.Exception.Message)
}

} finally { Disable-RunAwake }
