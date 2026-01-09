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

# Read-only: list recordings at account level (paginated). Does NOT download/delete.
function Get-ZoomAccountRecordings {
    param(
        [Parameter(Mandatory=$true)][string]$ZoomToken,
        [Parameter(Mandatory=$true)][string]$FromDate,  # yyyy-mm-dd
        [Parameter(Mandatory=$true)][string]$ToDate     # yyyy-mm-dd
    )

    $accountId = [System.Environment]::GetEnvironmentVariable("ZOOM_ACCOUNT_ID")
    $baseUrl   = "https://api.zoom.us/v2/accounts/$accountId/recordings"
    $headers   = @{ Authorization = "Bearer $ZoomToken" }

    $allMeetings = New-Object System.Collections.Generic.List[object]
    $next = $null

    do {
        $uri = "$baseUrl?from=$FromDate&to=$ToDate&page_size=300"
        if ($next) { $uri = "$uri&next_page_token=$next" }

        $resp = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

        if ($resp -and $resp.meetings) {
            foreach ($m in $resp.meetings) { $allMeetings.Add($m) }
        }

        $next = $resp.next_page_token
    } while ($next)

    return $allMeetings
}

function Invoke-Migration {
    Load-Env

    $zoomToken  = Get-ZoomAccessToken
    $graphToken = Get-GraphAccessToken

    $zoomOk  = ([string]::IsNullOrEmpty($zoomToken)  -eq $false)
    $graphOk = ([string]::IsNullOrEmpty($graphToken) -eq $false)

    if (-not $zoomOk)  { "? Zoom token not acquired"; return }
    if (-not $graphOk) { "? Graph token not acquired"; return }

    # Smoke test: list account recordings for a small window (last 7 days)
    $to   = (Get-Date).ToString("yyyy-MM-dd")
    $from = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd")

    try {
        $meetings = Get-ZoomAccountRecordings -ZoomToken $zoomToken -FromDate $from -ToDate $to
        if ($meetings -and $meetings.Count -ge 0) {
            "? Zoom account recordings reachable (meetings returned: $($meetings.Count))"
        } else {
            "? Zoom account recordings call returned no data"
        }
    } catch {
        "? Zoom account recordings call failed"
    }
}

Invoke-Migration
