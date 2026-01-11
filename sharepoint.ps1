
function Get-GraphAccessToken {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret
    )

    $uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        client_id     = $ClientId
        scope         = "https://graph.microsoft.com/.default"
        client_secret = $ClientSecret
        grant_type    = "client_credentials"
    }

    $resp = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType "application/x-www-form-urlencoded"
    return $resp.access_token
}

function Encode-GraphPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $parts = $Path -split "/" | Where-Object { $_ -and $_.Trim() -ne "" }
    ($parts | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/"
}

function Get-DriveIdForSite {
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$SiteId
    )
    $uri = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive"
    $response = Invoke-RestMethod -Uri $uri -Headers @{Authorization = "Bearer $AccessToken"}
    return $response.id
}

