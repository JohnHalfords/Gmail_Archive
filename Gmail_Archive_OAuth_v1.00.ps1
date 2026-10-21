# Gmail Archive OAuth - v1.00
# Windows PowerShell 5.1
# Author: John Halfords and my friend Chappie (ChatGPT - OpenAI)

# Authorize both Gmail Archive (readonly) and Gmail Archive Delete (modify).
# Reads the OAuth desktop client from private/ and saves the refresh token there.
# No Gmail messages are read, modified or deleted by this helper.

$ErrorActionPreference = 'Stop'
$settingsPath = Join-Path $PSScriptRoot 'Gmail_Archive_Settings.psd1'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw "Settings file not found: $settingsPath" }
$cfg = Import-PowerShellDataFile -LiteralPath $settingsPath
if (-not $cfg.OAuthFile -or -not $cfg.TokenFile) { throw 'OAuthFile and TokenFile are required in settings.' }
$basePath = if ($cfg.ScriptFolder) { [string]$cfg.ScriptFolder } else { $PSScriptRoot }
$privatePath = Join-Path $basePath 'private'
if (-not (Test-Path -LiteralPath $privatePath)) { $null = New-Item -ItemType Directory -Path $privatePath -Force }
$oauthPath = Join-Path $privatePath (Split-Path -Path ([string]$cfg.OAuthFile) -Leaf)
$tokenPath = Join-Path $privatePath (Split-Path -Path ([string]$cfg.TokenFile) -Leaf)
if (-not (Test-Path -LiteralPath $oauthPath -PathType Leaf)) {
    throw "OAuth desktop-client JSON not found: $oauthPath. Place your Google Cloud client JSON there first."
}
$clientJson = Get-Content -LiteralPath $oauthPath -Raw | ConvertFrom-Json
$client = $clientJson.installed
if (-not $client -or -not $client.client_id -or -not $client.client_secret -or -not $client.token_uri) {
    throw 'The OAuth JSON must contain installed.client_id, installed.client_secret and installed.token_uri (Desktop application).'
}

# Use a free ephemeral local port for the desktop OAuth redirect.
$portPicker = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$portPicker.Start()
$port = ([System.Net.IPEndPoint]$portPicker.LocalEndpoint).Port
$portPicker.Stop()
$redirectUri = "http://127.0.0.1:$port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($redirectUri)

$randomBytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($randomBytes) } finally { $rng.Dispose() }
$state = ([Convert]::ToBase64String($randomBytes)).TrimEnd('=').Replace('+','-').Replace('/','_')
$scopes = @(
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/gmail.modify'
)
function Encode-Query([hashtable]$values) {
    return (($values.GetEnumerator() | ForEach-Object {
        [Uri]::EscapeDataString([string]$_.Key) + '=' + [Uri]::EscapeDataString([string]$_.Value)
    }) -join '&')
}
$authBase = if ($client.auth_uri) { [string]$client.auth_uri } else { 'https://accounts.google.com/o/oauth2/v2/auth' }
$authUrl = $authBase + '?' + (Encode-Query @{
    client_id = $client.client_id
    redirect_uri = $redirectUri
    response_type = 'code'
    scope = ($scopes -join ' ')
    access_type = 'offline'
    prompt = 'consent'
    state = $state
})

try {
    $listener.Start()
    Write-Host 'Opening Google authorization in your browser...'
    Write-Host 'Approve the requested Gmail permissions to use both Archive and Delete.'
    Start-Process $authUrl
    $pending = $listener.GetContextAsync()
    if (-not $pending.Wait([TimeSpan]::FromMinutes(5))) { throw 'Timed out waiting for the OAuth browser redirect (5 minutes).' }
    $context = $pending.GetAwaiter().GetResult()
    $query = $context.Request.QueryString
    $authorized = ($query['state'] -ceq $state -and -not [string]::IsNullOrWhiteSpace($query['code']) -and -not $query['error'])
    $responseText = if ($authorized) { 'Authorization received. You can close this tab and return to PowerShell.' } else { 'Authorization failed or was cancelled. Return to PowerShell for details.' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($responseText)
    $context.Response.ContentType = 'text/plain; charset=utf-8'
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
    $context.Response.Close()
    if ($query['error']) { throw ('Google OAuth returned: ' + $query['error']) }
    if ($query['state'] -cne $state) { throw 'OAuth state mismatch. Authorization rejected.' }
    if (-not $authorized) { throw 'Google did not return an authorization code.' }

    $token = Invoke-RestMethod -Method Post -Uri ([string]$client.token_uri) -ContentType 'application/x-www-form-urlencoded' -Body @{
        code = [string]$query['code']
        client_id = [string]$client.client_id
        client_secret = [string]$client.client_secret
        redirect_uri = $redirectUri
        grant_type = 'authorization_code'
    } -ErrorAction Stop
    if (-not $token.refresh_token) { throw 'Google returned no refresh_token. No token file was written. Revoke the app grant and authorize again.' }
    $grantedScopes = @([string]$token.scope -split '\s+')
    foreach ($required in $scopes) {
        if ($grantedScopes -notcontains $required) { throw "Required Gmail scope not granted: $required. No token file was written." }
    }
    $saved = [ordered]@{
        access_token = [string]$token.access_token
        refresh_token = [string]$token.refresh_token
        token_type = [string]$token.token_type
        scope = [string]$token.scope
        expires_in = [int]$token.expires_in
        created_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    # Write atomically so a failed save does not destroy a previously valid token.
    $tempPath = Join-Path $privatePath ([IO.Path]::GetRandomFileName())
    try {
        $saved | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $tokenPath -Force
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
    Write-Host "OAuth refresh token saved to: $tokenPath"
    Write-Host 'Authorization complete. Both Archive and Delete scopes are present.'
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
