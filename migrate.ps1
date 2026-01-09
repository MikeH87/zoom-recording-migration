<#
.SYNOPSIS
Migrates Zoom cloud recordings to SharePoint.

.DESCRIPTION
Reads environment variables for credentials and settings. Authenticates to Zoom and Microsoft Graph. Lists and processes recordings older than a configurable date range, uploads them to SharePoint, and deletes them from Zoom. Detailed logic will be implemented in later steps.
#>

function Load-Env {
    $envPath = Join-Path -Path (Get-Location) -ChildPath ".env"
    if (Test-Path $envPath) {
        foreach ($line in Get-Content $envPath) {
            if ($line -match "^\s*$" -or $line -match "^\s*#") { continue }
            $parts = $line.Split("=",2)
            if ($parts.Length -eq 2) { $name = $parts[0]; $value = $parts[1]; [System.Environment]::SetEnvironmentVariable($name, $value) }
        }
    }
}

function Get-ZoomAccessToken {
    $clientId     = [System.Environment]::GetEnvironmentVariable("ZOOM_CLIENT_ID")
    $clientSecret = [System.Environment]::GetEnvironmentVariable("ZOOM_CLIENT_SECRET")
    $accountId    = [System.Environment]::GetEnvironmentVariable("ZOOM_ACCOUNT_ID")
    $authInfo     = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${clientId}:${clientSecret}"))
    $body         = "grant_type=account_credentials&account_id=$accountId"
    $response     = Invoke-RestMethod -Uri "https://zoom.us/oauth/token" -Method Post -Headers @{ Authorization = "Basic $authInfo" } -Body $body -ContentType "application/x-www-form-urlencoded"
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
    $response = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
    return $response.access_token
}

function Invoke-Migration {
    Load-Env
    $zoomToken  = Get-ZoomAccessToken
    $graphToken = Get-GraphAccessToken
    Write-Host ("Zoom token acquired: " + ([string]::IsNullOrEmpty($zoomToken) -eq $false))
    Write-Host ("Graph token acquired: " + ([string]::IsNullOrEmpty($graphToken) -eq $false))
}

Invoke-Migration
