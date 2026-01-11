function Get-GraphAccessToken {
  param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret
  )
  $uri  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
  $body = @{
    client_id     = $ClientId
    scope         = "https://graph.microsoft.com/.default"
    client_secret = $ClientSecret
    grant_type    = "client_credentials"
  }
  (Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType "application/x-www-form-urlencoded").access_token
}

function Encode-GraphPath {
  param([Parameter(Mandatory)][string]$Path)
  $p = ($Path -replace '\\','/').Trim('/')
  if ([string]::IsNullOrWhiteSpace($p)) { return "" }
  ($p -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

function Get-DriveIdForSite {
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$SiteId
  )
  $headers = @{ Authorization = "Bearer $AccessToken" }
  (Invoke-RestMethod -Headers $headers -Uri ("https://graph.microsoft.com/v1.0/sites/$SiteId/drive")).id
}

function Ensure-GraphFolderPath {
  param(
    [Parameter(Mandatory)][string]$DriveId,
    [Parameter(Mandatory)][hashtable]$Headers,
    [Parameter(Mandatory)][string]$FolderPath
  )

  $p = ($FolderPath -replace '\\','/').Trim('/')
  if ([string]::IsNullOrWhiteSpace($p)) { return }

  $parts = $p -split '/'
  $current = ""
  foreach ($part in $parts) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $current = if ($current) { "$current/$part" } else { $part }

    $encoded = Encode-GraphPath -Path $current
    $checkUri = "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$encoded"

    $exists = $true
    try { Invoke-RestMethod -Method Get -Uri $checkUri -Headers $Headers -ErrorAction Stop | Out-Null }
    catch { $exists = $false }

    if (-not $exists) {
      $parent = ($current -split '/')[0..([Math]::Max(0, ($current -split '/').Count - 2))] -join '/'
      $name   = ($current -split '/')[-1]

      $parentEnc = Encode-GraphPath -Path $parent
      $childrenUri = if ($parentEnc) {
        "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/${parentEnc}:/children"
      } else {
        "https://graph.microsoft.com/v1.0/drives/$DriveId/root/children"
      }

      $payload = @{
        name = $name
        folder = @{}
        "@microsoft.graph.conflictBehavior" = "rename"
      } | ConvertTo-Json -Depth 6

      Invoke-RestMethod -Method Post -Uri $childrenUri -Headers $Headers -Body $payload -ContentType "application/json" -ErrorAction Stop | Out-Null
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

  if (-not (Test-Path -LiteralPath $LocalFilePath)) { throw "Local file not found: $LocalFilePath" }

  $headers = @{ Authorization = "Bearer $AccessToken" }
  $driveId = Get-DriveIdForSite -AccessToken $AccessToken -SiteId $SiteId

  Ensure-GraphFolderPath -DriveId $driveId -Headers $headers -FolderPath $FolderPath

  $fileName = [System.IO.Path]::GetFileName($LocalFilePath)
  $itemPath = Encode-GraphPath -Path (("{0}/{1}" -f ($FolderPath.Trim('/')), $fileName).Trim('/'))

  $sessionUri = "https://graph.microsoft.com/v1.0/drives/$driveId/root:/$($itemPath):/createUploadSession"
  $sessionBody = @{
    item = @{
      name = $fileName
      "@microsoft.graph.conflictBehavior" = "rename"
    }
  } | ConvertTo-Json -Depth 6

  $session = Invoke-RestMethod -Method Post -Uri $sessionUri -Headers $headers -Body $sessionBody -ContentType "application/json" -ErrorAction Stop
  if (-not $session.uploadUrl) { throw "createUploadSession failed: uploadUrl missing" }

  $uploadUrl = $session.uploadUrl

  $fileInfo = Get-Item -LiteralPath $LocalFilePath
  $total = [int64]$fileInfo.Length
  $chunkSize = 10MB
  if ($chunkSize -gt $total) { $chunkSize = [int]$total }

  $client = [System.Net.Http.HttpClient]::new()
  $fs = [System.IO.File]::OpenRead($LocalFilePath)

  try {
    $buffer = New-Object byte[] $chunkSize
    $position = [int64]0

    while ($position -lt $total) {
      $toRead = [int][Math]::Min($chunkSize, $total - $position)
      $read = $fs.Read($buffer, 0, $toRead)
      if ($read -le 0) { break }

      $bytes = if ($read -eq $buffer.Length) {
        $buffer
      } else {
        $b = New-Object byte[] $read
        [Array]::Copy($buffer, 0, $b, 0, $read)
        $b
      }

      $start = $position
      $end   = $position + $read - 1

      $content = [System.Net.Http.ByteArrayContent]::new($bytes, 0, $read)
      $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
      $content.Headers.ContentRange = [System.Net.Http.Headers.ContentRangeHeaderValue]::new($start, $end, $total)

      $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, $uploadUrl)
      $req.Content = $content

      $resp = $client.SendAsync($req).GetAwaiter().GetResult()
      $status = [int]$resp.StatusCode

      if (($status -ne 200) -and ($status -ne 201) -and ($status -ne 202)) {
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        throw "Upload session chunk failed: HTTP $status Body=$body"
      }

      $position += $read
    }

    return $true
  }
  finally {
    try { $fs.Dispose() } catch {}
    try { $client.Dispose() } catch {}
  }
}

