<#
.SYNOPSIS
Migrates Zoom cloud recordings to SharePoint.

.DESCRIPTION
PowerShell automation to migrate Zoom cloud recordings older than 18 months into SharePoint, keeping them searchable,
and then deleting from Zoom only after upload confirmation. This file currently contains safe, read-only smoke tests.
#>

function Load-Env {
    $envPath = Join-Path -Path (Get-Location) -ChildPath ".env"
    if (Test-Path $envPath) {
        foreach ($line in Get-Content $envPath) {
            if ($line -match "^\s*$" -or $line -match "^\s*#") { continue }
            $parts = $line.Split("=",2)
            if ($parts.Length -eq 2) {
                $name  = $parts[0]
                $value = $parts[1]
                [System.Environment]::SetEnvironmentVariable($name, $value)
            }
        }
    }
}

function Get-ZoomAccessToken {
    $clientId     = [System.Environment]::GetEnvironmentVariable("ZOOM_CLIENT_ID")
    $clientSecret = [System.Environment]::GetEnvironmentVariable("ZOOM_CLIENT_SECRET")
    $accountId    = [System.Environment]::GetEnvironmentVariable("ZOOM_ACCOUNT_ID")

    $authInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${clientId}:${clientSecret}"))
    $body     = "grant_type=account_credentials&account_id=$accountId"

    $response = Invoke-RestMethod -Uri "https://zoom.us/oauth/token" -Method Post `
        -Headers @{ Authorization = "Basic $authInfo" } `
        -Body $body -ContentType "application/x-www-form-urlencoded"

    return $response.access_token
}


function Test-ZoomRecordingsEndpoint {
    param(
        [Parameter(Mandatory=$true)][string]$ZoomAccessToken
    )

    # Minimal call: last 7 days for the authorised user
    $to   = (Get-Date).ToString("yyyy-MM-dd")
    $from = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd")
    $uri  = "https://api.zoom.us/v2/users/me/recordings?from=$from&to=$to&page_size=30"

    try {
        Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $ZoomAccessToken" } -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}
function Get-GraphAccessToken {
    $clientId     = [System.Environment]::GetEnvironmentVariable("GRAPH_CLIENT_ID")
    $clientSecret = [System.Environment]::GetEnvironmentVariable("GRAPH_CLIENT_SECRET")
    $tenantId     = [System.Environment]::GetEnvironmentVariable("TENANT_ID")

    $body = @{
        client_id     = $clientId
        scope         = "https://graph.microsoft.com/.default"
        client_secret = $clientSecret
        grant_type    = "client_credentials"
    }

    $response = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method Post `
        -Body $body -ContentType "application/x-www-form-urlencoded"

    return $response.access_token
}
function Invoke-Migration {
    Load-Env

    $zoomToken  = Get-ZoomAccessToken
    $graphToken = Get-GraphAccessToken

    if ([string]::IsNullOrEmpty($zoomToken))  { "❌ FAIL Zoom token missing"; return }
    if ([string]::IsNullOrEmpty($graphToken)) { "❌ FAIL Graph token missing"; return }

    $ok = Test-ZoomRecordingsEndpoint -ZoomAccessToken $zoomToken
    if ($ok) { "✅ OK Zoom recordings endpoint works (users/me/recordings)" }
    else     { "❌ FAIL Zoom recordings endpoint call failed" }
}

Invoke-Migration


