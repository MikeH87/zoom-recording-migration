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

  $resp = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body -ContentType "application/x-www-form-urlencoded"
  return $resp.access_token
}

function Get-GraphErrorBody {
  param([Parameter(Mandatory)]$ErrorRecord)

  try {
    # PowerShell 7: HttpResponseException has .Response (HttpResponseMessage)
    $ex = $ErrorRecord.Exception
    if ($ex.Response -and $ex.Response.Content) {
      return $ex.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  } catch {}

  try {
    # Windows PowerShell legacy WebException
    $ex = $ErrorRecord.Exception
    if ($ex.Response -and $ex.Response.GetResponseStream) {
      $stream = $ex.Response.GetResponseStream()
      if ($stream) {
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $reader.Close()
        return $text
      }
    }
  } catch {}

  return ""
}

function Encode-GraphPath {
  param([Parameter(Mandatory)][string]$Path)

  # Graph expects path segments URL-encoded but with "/" preserved.
  $p = $Path -replace '\\','/'
  $p = $p.Trim('/')
  if (-not $p) { return "" }

  $segments = $p -split '/'
  $encoded = $segments | ForEach-Object { [System.Uri]::EscapeDataString($_) }
  return ($encoded -join '/')
}

function Upload-ToSharePoint {
  param(
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$SiteId,
    [Parameter(Mandatory)][string]$FolderPath,
    [Parameter(Mandatory)][string]$LocalFilePath
  )

  if (-not (Test-Path -LiteralPath $LocalFilePath)) {
    throw "Local file not found: $LocalFilePath"
  }

  $headers = @{
    Authorization = "Bearer $AccessToken"
  }

  $fileName = [System.IO.Path]::GetFileName($LocalFilePath)

  # Build a Graph path "FolderPath/fileName" with safe encoding
  $graphPath = ""
  if ($FolderPath) {
    $graphPath = ($FolderPath.TrimEnd('/','\') + "/" + $fileName)
  } else {
    $graphPath = $fileName
  }

  $encodedPath = Encode-GraphPath -Path $graphPath

  $fileInfo = Get-Item -LiteralPath $LocalFilePath
  $size = [int64]$fileInfo.Length

  # Simple upload works up to 4MB; use upload session for larger
  if ($size -le 4MB) {
    $putUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/$encodedPath:/content"
    try {
      Invoke-RestMethod -Method Put -Uri $putUrl -Headers $headers -InFile $LocalFilePath -ContentType "application/octet-stream" | Out-Null
      return $true
    } catch {
      $body = Get-GraphErrorBody -ErrorRecord $_
      throw "Graph simple upload failed ($putUrl): $($_.Exception.Message)`n$body"
    }
  }

  # Upload session for large files
  $sessionUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/$encodedPath:/createUploadSession"
  $sessionBody = @{
    item = @{
      "@microsoft.graph.conflictBehavior" = "replace"
      name = $fileName
    }
  } | ConvertTo-Json -Depth 5

  $uploadUrl = $null
  try {
    $sess = Invoke-RestMethod -Method Post -Uri $sessionUrl -Headers ($headers + @{ "Content-Type" = "application/json" }) -Body $sessionBody
    $uploadUrl = $sess.uploadUrl
    if (-not $uploadUrl) { throw "No uploadUrl returned from createUploadSession" }
  } catch {
    $body = Get-GraphErrorBody -ErrorRecord $_
    throw "Graph createUploadSession failed ($sessionUrl): $($_.Exception.Message)`n$body"
  }

  $chunkSize = 10MB
  $fs = [System.IO.File]::OpenRead($LocalFilePath)

  try {
    $buffer = New-Object byte[] $chunkSize
    $pos = 0L

    while ($pos -lt $size) {
      $read = $fs.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }

      $start = $pos
      $end = $pos + $read - 1
      $pos = $pos + $read

      $chunkHeaders = @{
        Authorization   = "Bearer $AccessToken"
        "Content-Length"= "$read"
        "Content-Range" = "bytes $start-$end/$size"
      }

      $ms = New-Object System.IO.MemoryStream
      $ms.Write($buffer, 0, $read) | Out-Null
      $ms.Position = 0

      try {
        Invoke-RestMethod -Method Put -Uri $uploadUrl -Headers $chunkHeaders -Body $ms.ToArray() -ContentType "application/octet-stream" | Out-Null
      } catch {
        $body = Get-GraphErrorBody -ErrorRecord $_
        throw "Graph chunk upload failed (bytes $start-$end/$size): $($_.Exception.Message)`n$body"
      } finally {
        $ms.Dispose()
      }
    }

    return $true
  }
  finally {
    $fs.Dispose()
  }
}
