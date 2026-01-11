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
    $headers = @{ Authorization = "Bearer $AccessToken" }
    $drive = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive" -Method Get -ErrorAction Stop
    return $drive.id
}

function Ensure-GraphFolderPath {
    param(
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$FolderPath
    )

    $clean = ($FolderPath -split "/" | Where-Object { $_ -and $_.Trim() -ne "" })
    if (-not $clean -or $clean.Count -eq 0) { return }

    $parentParts = @()
    foreach ($seg in $clean) {
        $parentPath = ($parentParts -join "/")
        $parentEnc  = Encode-GraphPath -Path $parentPath
        $segName    = $seg

        # Create child under parent: /root:/{parent}:/children
        $childrenUri = if ($parentEnc) {
            "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/${parentEnc}:/children"
        } else {
            "https://graph.microsoft.com/v1.0/drives/$DriveId/root/children"
        }

        # Check if folder already exists
        $existing = $null
        try {
            $list = Invoke-RestMethod -Method Get -Uri $childrenUri -Headers $Headers -ErrorAction Stop
            $existing = $list.value | Where-Object { $_.name -eq $segName -and $_.folder }
        } catch {
            # If listing fails, we still attempt create; Graph will error if truly impossible
        }

        if (-not $existing) {
            $body = @{
                name = $segName
                folder = @{}
                "@microsoft.graph.conflictBehavior" = "fail"
            } | ConvertTo-Json -Depth 6

            try {
                Invoke-RestMethod -Method Post -Uri $childrenUri -Headers $Headers -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
            } catch {
                # If someone else created it between list+create, ignore "nameAlreadyExists"/409
                if ($_.Exception.Message -notmatch "409|nameAlreadyExists") { throw }
            }
        }

        $parentParts += $segName
    }
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

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $driveId = Get-DriveIdForSite -AccessToken $AccessToken -SiteId $SiteId

    Ensure-GraphFolderPath -DriveId $driveId -Headers $headers -FolderPath $FolderPath

    $fileName = [System.IO.Path]::GetFileName($LocalFilePath)

    # Build itemPath (folder segments + filename) and encode each segment safely
    $folderEnc = Encode-GraphPath -Path $FolderPath
    $fileEnc   = [uri]::EscapeDataString($fileName)
    $itemPathEnc = if ($folderEnc) { "$folderEnc/$fileEnc" } else { $fileEnc }

    # Upload session endpoint MUST be: root:/{itemPath}:/createUploadSession
    $sessionUri = "https://graph.microsoft.com/v1.0/drives/$driveId/root:/${itemPathEnc}:/createUploadSession"
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

            # exact sized bytes for this chunk
            $bytes = if ($read -eq $buffer.Length) {
                $buffer
            } else {
                $tmp = New-Object byte[] $read
                [Array]::Copy($buffer, 0, $tmp, 0, $read)
                $tmp
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
        try { $fs.Close() } catch {}
        try { $client.Dispose() } catch {}
    }
}
