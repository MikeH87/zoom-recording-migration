Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-GraphAccessToken {
  param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret
  )

  $body = @{
    grant_type    = "client_credentials"
    client_id     = $ClientId
    client_secret = $ClientSecret
    scope         = "https://graph.microsoft.com/.default"
  }

  $token = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body -ContentType "application/x-www-form-urlencoded"
  return $token.access_token
}

function Encode-GraphPath {
  param([Parameter(Mandatory)][string]$Path)

  $p = ($Path -replace '\\','/').Trim('/')
  if (-not $p) { return "" }

  $segments = $p -split '/'
  $encoded = foreach ($s in $segments) { [System.Uri]::EscapeDataString($s) }
  return ($encoded -join '/')
}

function Ensure-SpFolderPath {
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$SiteId,
    [Parameter(Mandatory)][string]$FolderPath
  )

  $headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }

  $p = ($FolderPath -replace '\\','/').Trim('/')
  if (-not $p) { return }

  $parts = @($p -split '/' | Where-Object { $_ })
  $current = ""

  foreach ($part in $parts) {
    $parent = $current
    $current = if ($current) { "$current/$part" } else { $part }

    $childrenUrl = if ($parent) {
      $encodedParent = Encode-GraphPath -Path $parent
      # IMPORTANT: ${encodedParent} prevents PowerShell parsing errors around ":/"
      "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/${encodedParent}:/children"
    } else {
      "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root/children"
    }

    $body = @{
      name = $part
      folder = @{}
      "@microsoft.graph.conflictBehavior" = "replace"
    } | ConvertTo-Json -Depth 5

    try {
      Invoke-RestMethod -Method Post -Uri $childrenUrl -Headers $headers -Body $body | Out-Null
    } catch {
      # If it already exists, Graph throws; that is fine.
    }
  }
}

function Upload-ToSharePoint {
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$SiteId,
    [Parameter(Mandatory)][string]$FolderPath,
    [Parameter(Mandatory)][string]$LocalFilePath
  )

  $headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }

  if (-not (Test-Path -LiteralPath $LocalFilePath)) {
    throw "Local file not found: $LocalFilePath"
  }

  Ensure-SpFolderPath -AccessToken $AccessToken -SiteId $SiteId -FolderPath $FolderPath

  $fileName = [System.IO.Path]::GetFileName($LocalFilePath)
  $size = (Get-Item -LiteralPath $LocalFilePath).Length

  $combined = ((($FolderPath -replace '\\','/').Trim('/')) + "/" + $fileName).Trim('/')
  $encodedPath = Encode-GraphPath -Path $combined

  # Rerun-safe behaviour:
  # - If item exists with same size => success
  # - If item exists different size => delete then reupload
  $metaUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/${encodedPath}"
  try {
    $existing = Invoke-RestMethod -Method Get -Uri $metaUrl -Headers $headers
    if ($existing -and $existing.size -eq $size) { return $true }
    if ($existing) { Invoke-RestMethod -Method Delete -Uri $metaUrl -Headers $headers | Out-Null }
  } catch {
    # Not found is fine
  }

  # Small files: simple upload (<= 4MB)
  if ($size -le 4000000) {
    $putUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/${encodedPath}:/content"
    $bytes = [System.IO.File]::ReadAllBytes($LocalFilePath)
    $h = @{ Authorization = "Bearer $AccessToken" }
    Invoke-RestMethod -Method Put -Uri $putUrl -Headers $h -Body $bytes -ContentType "application/octet-stream" | Out-Null
    return $true
  }

  # Large files: upload session (chunked)
  $sessionUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/${encodedPath}:/createUploadSession"
  $sessionBody = @{
    item = @{
      "@microsoft.graph.conflictBehavior" = "replace"
      name = $fileName
    }
  } | ConvertTo-Json -Depth 5

  $session = Invoke-RestMethod -Method Post -Uri $sessionUrl -Headers $headers -Body $sessionBody
  if (-not $session.uploadUrl) { throw "createUploadSession did not return uploadUrl" }

  $uploadUrl = $session.uploadUrl

  # Upload in 10MB chunks
  $chunkSize = 10MB
  $fs = [System.IO.File]::OpenRead($LocalFilePath)
  try {
    $buffer = New-Object byte[] $chunkSize
    $pos = 0L

    while ($true) {
      $read = $fs.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }

      $start = $pos
      $end = $pos + $read - 1
      $pos += $read

      $chunk = if ($read -eq $buffer.Length) { $buffer } else { $buffer[0..($read-1)] }

      $h = @{
        "Content-Length" = "$read"
        "Content-Range"  = "bytes $start-$end/$size"
      }

      Invoke-RestMethod -Method Put -Uri $uploadUrl -Headers $h -Body $chunk -ContentType "application/octet-stream" | Out-Null
    }

    return $true
  } finally {
    $fs.Dispose()
  }
}