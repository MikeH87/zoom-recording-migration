# ================================
# Zoom Recording Migration (RENDER-SAFE)
# - Moves Zoom cloud recordings into SharePoint (Year/Month/Day)
# - Uses Server-to-Server OAuth for Zoom
# - Uses Microsoft Graph upload sessions for large files
# - Writes local logs + uploads run logs to SharePoint (_logs/)
# - DOES NOT DELETE from Zoom unless DELETE_FROM_ZOOM=true
#
# Required env vars:
#   ZOOM_ACCOUNT_ID, ZOOM_CLIENT_ID, ZOOM_CLIENT_SECRET
#   GRAPH_TENANT_ID, GRAPH_CLIENT_ID, GRAPH_CLIENT_SECRET
#
# Optional env vars:
#   SITE_ID, BASE_FOLDER, FROM_DATE, TO_DATE, DRY_RUN, DELETE_FROM_ZOOM
#   EXCLUDED_HOST_EMAILS, INTERNAL_DOMAINS, CHUNK_DAYS, MAX_USERS, MAX_RECORDINGS
#   KEEP_ALIVE (true/false) -> if true, sleep forever at end to stop Render restart loop
# ================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- Defaults ----------
if (-not $env:INTERNAL_DOMAINS) { [Environment]::SetEnvironmentVariable("INTERNAL_DOMAINS","tlpi.co.uk,thelandlordspension.co.uk","Process") }
if (-not $env:EXCLUDED_HOST_EMAILS) { [Environment]::SetEnvironmentVariable("EXCLUDED_HOST_EMAILS","gareth@tlpi.co.uk,gareth@thelandlordspension.co.uk,mike@tlpi.co.uk,mike@thelandlordspension.co.uk","Process") }

$SiteId     = if ($env:SITE_ID) { $env:SITE_ID } else { "netorg3849094.sharepoint.com,424ec537-9e35-461b-9b00-e588c37b8b35,11ce2bba-a00f-4dec-9a17-95b87b786fda" }
$BaseFolder = if ($env:BASE_FOLDER) { $env:BASE_FOLDER } else { "TLPI Zoom Calls" }

$DryRun = if ($env:DRY_RUN) { [bool]::Parse($env:DRY_RUN) } else { $true }
$DeleteFromZoom = if ($env:DELETE_FROM_ZOOM) { [bool]::Parse($env:DELETE_FROM_ZOOM) } else { $false }

# If FROM_DATE/TO_DATE provided -> use them (testing)
# Else -> process 2021-03-01 through (today - 18 months)
$FromDate = if ($env:FROM_DATE) { $env:FROM_DATE } else { "2021-03-01" }
$ToDate   = if ($env:TO_DATE)   { $env:TO_DATE }   else { (Get-Date).AddMonths(-18).ToString("yyyy-MM-dd") }

$ChunkDays = if ($env:CHUNK_DAYS) { [int]$env:CHUNK_DAYS } else { 7 }
if ($ChunkDays -lt 1) { $ChunkDays = 1 }
if ($ChunkDays -gt 31) { $ChunkDays = 31 }

# ---------- Paths ----------
$Root = $PSScriptRoot
$tmpDir = Join-Path $Root "tmp"
if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }

$LogFile = Join-Path $Root "migration.log"
$RunCsv  = Join-Path $Root ("run-actions-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

# ---------- Logging ----------
function Write-Log {
  param([Parameter(Mandatory)][string]$Message)
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
  Add-Content -Path $LogFile -Value $line
  Write-Host $line
}

function Write-RunCsv {
  param(
    [Parameter(Mandatory)][string]$Action,   # downloaded, uploaded, deleted, skipped, error
    [Parameter(Mandatory)][string]$MeetingId,
    [string]$RecordingFileId,
    [string]$HostEmail,
    [string]$StartTimeIso,
    [string]$Topic,
    [string]$LocalPath,
    [string]$SharePointPath,
    [string]$Notes
  )
  if (-not (Test-Path -LiteralPath $RunCsv)) {
    "timestamp,action,meetingId,recordingFileId,hostEmail,startTime,topic,localPath,sharePointPath,notes" | Set-Content -Path $RunCsv -Encoding UTF8
  }

  $ts = (Get-Date).ToString("s")
  $topicSafe = ($Topic -replace '"','''')
  $notesSafe = ($Notes -replace '"','''')

  $row = '"' + ($ts) + '","' + ($Action) + '","' + ($MeetingId) + '","' + ($RecordingFileId) + '","' + ($HostEmail) + '","' + ($StartTimeIso) + '","' + ($topicSafe) + '","' + ($LocalPath) + '","' + ($SharePointPath) + '","' + ($notesSafe) + '"'
  Add-Content -Path $RunCsv -Value $row
}

# ---------- Load SharePoint uploader ----------
. "$PSScriptRoot\sharepoint.ps1"

# ---------- Zoom Auth ----------
function Get-ZoomAccessToken {
  param(
    [Parameter(Mandatory)][string]$AccountId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret
  )

  $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$ClientId`:$ClientSecret"))
  $headers = @{ Authorization = "Basic $basic" }
  $body = @{ grant_type = "account_credentials"; account_id = $AccountId }

  $resp = Invoke-RestMethod -Method Post -Uri "https://zoom.us/oauth/token" -Headers $headers -Body $body
  $resp.access_token
}

function Invoke-ZoomGet {
  param(
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][hashtable]$Headers
  )

  try {
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers
  } catch {
    $msg = $_.Exception.Message
    try {
      $resp = $_.Exception.Response
      if ($resp -and $resp.GetResponseStream()) {
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd()
        if ($body) { $msg = "$msg | body: $body" }
      }
    } catch { }
    throw $msg
  }
}

function Encode-ZoomMeetingUuid {
  param([Parameter(Mandatory)][string]$Uuid)
  # Zoom UUIDs can contain / and = etc, and some endpoints require double-URL-encoding.
  $once = [System.Uri]::EscapeDataString($Uuid)
  [System.Uri]::EscapeDataString($once)
}

function Get-ZoomMeetingRecordingsDetail {
  param(
    [Parameter(Mandatory)][string]$MeetingUuid,
    [Parameter(Mandatory)][hashtable]$Headers
  )
  $enc = Encode-ZoomMeetingUuid -Uuid $MeetingUuid
  Invoke-ZoomGet -Uri "https://api.zoom.us/v2/meetings/$enc/recordings" -Headers $Headers
}

function Get-MeetingParticipantsEmails {
  param(
    [Parameter(Mandatory)][string]$MeetingId,
    [Parameter(Mandatory)][hashtable]$Headers
  )

  $emails = @()
  try {
    $nextToken = $null
    do {
      $uri = "https://api.zoom.us/v2/report/meetings/$MeetingId/participants?page_size=300"
      if ($nextToken) { $uri += "&next_page_token=$nextToken" }

      $resp = Invoke-ZoomGet -Uri $uri -Headers $Headers
      if ($resp.participants) {
        foreach ($p in $resp.participants) {
          if ($p.user_email) { $emails += [string]$p.user_email }
        }
      }
      $nextToken = $resp.next_page_token
    } while ($nextToken)
  } catch {
    # ignore
  }

  $emails
}

function Get-ExternalParticipantsLabel {
  param(
    [string[]]$ParticipantEmails,
    [string]$HostEmail
  )

  $internalDomains = @()
  if ($env:INTERNAL_DOMAINS) {
    $internalDomains = @($env:INTERNAL_DOMAINS -split "," | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
  }

  $hostLower = if ($HostEmail) { $HostEmail.Trim().ToLower() } else { "" }

  $filtered = @(
    $ParticipantEmails |
      ForEach-Object { $_ -as [string] } |
      ForEach-Object { $_.Trim().ToLower() } |
      Where-Object { $_ } |
      Where-Object { $_ -ne $hostLower } |
      Where-Object {
        $parts = $_ -split "@",2
        if ($parts.Count -ne 2) { return $true }
        $domain = $parts[1]
        return ($internalDomains -notcontains $domain)
      } |
      Sort-Object -Unique
  )

  if (-not $filtered -or $filtered.Count -eq 0) { return "unknown" }

  $joined = ($filtered -join "+")
  if ($joined.Length -gt 60) { $joined = $joined.Substring(0,60) }
  $joined
}

function New-SafeFileName {
  param([Parameter(Mandatory)][string]$Name)

  # SharePoint/OneDrive are stricter than Windows. In particular, # and % often cause Graph path errors.
  $safe = ($Name -replace '[\\/:*?"<>|#%]', '_').Trim()

  # Avoid trailing dots/spaces (SharePoint rejects)
  $safe = $safe.TrimEnd(' ','.')

  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "Untitled" }
  return $safe
}

function Truncate-FileName {
  param(
    [Parameter(Mandatory)][string]$FileName,
    [int]$MaxLength = 180
  )
  if ($FileName.Length -le $MaxLength) { return $FileName }
  $ext = [System.IO.Path]::GetExtension($FileName)
  $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
  $keep = $MaxLength - $ext.Length
  if ($keep -lt 20) { $keep = 20 }
  ($base.Substring(0,$keep) + $ext)
}

function Download-ZoomRecording {
  param(
    [Parameter(Mandatory)]$RecordingDetail,
    [Parameter(Mandatory)][string]$HostEmail,
    [Parameter(Mandatory)][string]$ParticipantsLabel,
    [Parameter(Mandatory)][hashtable]$Headers,
    [switch]$DryRun
  )

  $mp4 = $RecordingDetail.recording_files | Where-Object { $_.file_type -eq "MP4" } | Select-Object -First 1
  if (-not $mp4) {
    Write-Log "No MP4 in meeting $($RecordingDetail.id) - skipping"
    return $null
  }

  $dt = [DateTime]$RecordingDetail.start_time
  $topicSafe = New-SafeFileName -Name ($RecordingDetail.topic ? $RecordingDetail.topic : "Untitled")

  $fileNameCore = "{0:yyyy-MM-dd HH-mm} - {1} - {2} - {3}.mp4" -f `
    $dt, `
    $topicSafe, `
    $RecordingDetail.id, `
    $mp4.id

  # Keep names shorter to stay well within Graph/SharePoint path constraints
  $fileName = Truncate-FileName -FileName $fileNameCore -MaxLength 140
  $localPath = Join-Path $tmpDir $fileName

  if ($DryRun) {
    Write-Log "DRY RUN: creating stub file $fileName"
    New-Item -ItemType File -Path $localPath -Force | Out-Null
    Write-RunCsv -Action "dryrun_downloaded" -MeetingId "$($RecordingDetail.id)" -RecordingFileId "$($mp4.id)" -HostEmail $HostEmail -StartTimeIso $dt.ToString("s") -Topic $RecordingDetail.topic -LocalPath $localPath -SharePointPath "" -Notes "stub"
    return $localPath
  }

  $downloadUrl = "$($mp4.download_url)?access_token=$($Headers.Authorization -replace '^Bearer\s+','')"
  Write-Log ('Downloading MP4 ({0:N1} MB) -> {1}' -f ([double]$mp4.file_size/1MB), $fileName)

  Invoke-WebRequest -Uri $downloadUrl -OutFile $localPath -UseBasicParsing

  Write-RunCsv -Action "downloaded" -MeetingId "$($RecordingDetail.id)" -RecordingFileId "$($mp4.id)" -HostEmail $HostEmail -StartTimeIso $dt.ToString("s") -Topic $RecordingDetail.topic -LocalPath $localPath -SharePointPath "" -Notes ""
  return $localPath
}

function Remove-ZoomRecording {
  param(
    [Parameter(Mandatory)][string]$MeetingUuid,
    [Parameter(Mandatory)][hashtable]$Headers
  )
  $enc = Encode-ZoomMeetingUuid -Uuid $MeetingUuid
  Invoke-RestMethod -Method Delete -Uri "https://api.zoom.us/v2/meetings/$enc/recordings?action=trash" -Headers $Headers | Out-Null
}

function Upload-RunLogsToSharePoint {
  param(
    [Parameter(Mandatory)][string]$GraphToken
  )

  $ts = Get-Date -Format "yyyyMMdd-HHmmss"
  $logFolder = "$BaseFolder/_logs"

  if (Test-Path -LiteralPath $LogFile) {
    Upload-ToSharePoint -AccessToken $GraphToken -SiteId $SiteId -FolderPath $logFolder -LocalFilePath $LogFile | Out-Null
    $tmpCopy = Join-Path $tmpDir ("migration-$ts.log")
    Copy-Item -LiteralPath $LogFile -Destination $tmpCopy -Force
    Upload-ToSharePoint -AccessToken $GraphToken -SiteId $SiteId -FolderPath $logFolder -LocalFilePath $tmpCopy | Out-Null
    Remove-Item -LiteralPath $tmpCopy -Force -ErrorAction SilentlyContinue
  }

  if (Test-Path -LiteralPath $RunCsv) {
    Upload-ToSharePoint -AccessToken $GraphToken -SiteId $SiteId -FolderPath $logFolder -LocalFilePath $RunCsv | Out-Null
  }
}

# ---------- MAIN ----------
Write-Log ("=== START RUN (DRY_RUN={0}, FROM={1}, TO={2}) ===" -f $DryRun, $FromDate, $ToDate)

foreach ($v in "ZOOM_ACCOUNT_ID","ZOOM_CLIENT_ID","ZOOM_CLIENT_SECRET","GRAPH_TENANT_ID","GRAPH_CLIENT_ID","GRAPH_CLIENT_SECRET") {
  if (-not [Environment]::GetEnvironmentVariable($v)) { throw "Missing env var: $v" }
}

$zoomToken = Get-ZoomAccessToken -AccountId $env:ZOOM_ACCOUNT_ID -ClientId $env:ZOOM_CLIENT_ID -ClientSecret $env:ZOOM_CLIENT_SECRET
$zoomHeaders = @{ Authorization = "Bearer $zoomToken" }

# Prefer an explicit env var if provided (lets you override easily)
$ZoomApiAccountId = $env:ZOOM_API_ACCOUNT_ID

# Otherwise, ask Zoom what account id it expects for /accounts/{accountId}/... endpoints
if (-not $ZoomApiAccountId) {
  try {
    $acctMe = Invoke-ZoomGet -Uri "https://api.zoom.us/v2/accounts/me" -Headers $zoomHeaders
    if ($acctMe -and $acctMe.id) { $ZoomApiAccountId = [string]$acctMe.id }
  } catch {
    Write-Log ("WARN: could not resolve ZoomApiAccountId via /accounts/me: {0}" -f $_.Exception.Message)
  }
}

# Fallback (may still work on some accounts, but /accounts/me is preferred)
if (-not $ZoomApiAccountId) { $ZoomApiAccountId = $env:ZOOM_ACCOUNT_ID }

$graphToken = Get-GraphAccessToken -TenantId $env:GRAPH_TENANT_ID -ClientId $env:GRAPH_CLIENT_ID -ClientSecret $env:GRAPH_CLIENT_SECRET

# Users + exclusions
$excluded = @()
if ($env:EXCLUDED_HOST_EMAILS) {
  $excluded = @($env:EXCLUDED_HOST_EMAILS -split "," | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
}

# Users: inline Zoom API call (bypasses Render parsing issues)
$users = @()
$nextToken = $null
do {
  $uri = "https://api.zoom.us/v2/users?page_size=300&status=active,inactive,pending"
  if ($nextToken) { $uri += "&next_page_token=$nextToken" }

  $resp = Invoke-ZoomGet -Uri $uri -Headers $zoomHeaders
  if ($resp.users) { $users += $resp.users }
  $nextToken = $resp.next_page_token
} while ($nextToken)

if ($env:MAX_USERS) { $users = $users | Select-Object -First ([int]$env:MAX_USERS) }

$users = $users | Where-Object {
  $e = ($_.email -as [string])
  if (-not $e) { return $true }
  return ($excluded -notcontains $e.Trim().ToLower())
}

Write-Log ("Users found (after exclusions): {0}" -f $users.Count)

# Walk date range in chunks
$start = [DateTime]::ParseExact($FromDate, "yyyy-MM-dd", $null)
$end   = [DateTime]::ParseExact($ToDate,   "yyyy-MM-dd", $null)
if ($end -lt $start) { throw "TO_DATE ($ToDate) is earlier than FROM_DATE ($FromDate)" }

$totalUploaded = 0
$totalProcessed = 0
$processedUuids = [System.Collections.Generic.HashSet[string]]::new()

$maxRecordings = if ($env:MAX_RECORDINGS) { [int]$env:MAX_RECORDINGS } else { 0 }

$cursor = $start
while ($cursor -le $end) {
  $chunkEnd = $cursor.AddDays($ChunkDays - 1)
  if ($chunkEnd -gt $end) { $chunkEnd = $end }

  $fromStr = $cursor.ToString("yyyy-MM-dd")
  $toStr   = $chunkEnd.ToString("yyyy-MM-dd")

      # --- Account-level recordings sweep (captures recordings for removed users) ---
    # Requires S2S app scopes that allow account recordings listing.
    $acctMeetings = @()
    try {
      $nextAcct = $null
      do {
        $aUri = "https://api.zoom.us/v2/accounts/$ZoomApiAccountId/recordings?from=$fromStr&to=$toStr&page_size=300"
        if ($nextAcct) { $aUri += "&next_page_token=$nextAcct" }
        $aResp = Invoke-ZoomGet -Uri $aUri -Headers $zoomHeaders
        if ($aResp.meetings) { $acctMeetings += $aResp.meetings }
        $nextAcct = $aResp.next_page_token
      } while ($nextAcct)
    } catch {
      Write-Log ("WARN: account recordings sweep failed for {0}..{1}: {2}" -f $fromStr, $toStr, $_.Exception.Message)
      $acctMeetings = @()
    }

    $acctMeetings = @($acctMeetings | Where-Object { $_ -and $_.uuid } | Sort-Object uuid -Unique)

    foreach ($m in $acctMeetings) {
      if ($maxRecordings -gt 0 -and $totalProcessed -ge $maxRecordings) { break }

      if (-not $m.uuid) { continue }
      if (-not $processedUuids.Add([string]$m.uuid)) { continue }

      $totalProcessed++

      $hostEmail = "unknown"
      try {
        if ($m.host_email) { $hostEmail = [string]$m.host_email }
      } catch {}

      $full = $null
      try {
        $full = Get-ZoomMeetingRecordingsDetail -MeetingUuid $m.uuid -Headers $zoomHeaders
      } catch {
        Write-Log "WARN: failed to fetch meeting recordings detail for uuid=$($m.uuid): $($_.Exception.Message)"
        Write-RunCsv -Action "error" -MeetingId "$($m.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso "" -Topic ($m.topic) -LocalPath "" -SharePointPath "" -Notes "detail_fetch_failed_account_sweep"
        continue
      }

      if (-not $full -or -not $full.start_time) { continue }
      $dt = [DateTime]$full.start_time

      if ($dt -lt $start -or $dt -gt $end.AddDays(1).AddSeconds(-1)) { continue }

      Write-Log ("Processing: {0} [{1}] (host: {2})" -f $full.topic, $dt.ToString("yyyy-MM-dd HH:mm"), $hostEmail)

      $participants = @()
      try { $participants = Get-MeetingParticipantsEmails -MeetingId "$($full.id)" -Headers $zoomHeaders } catch { $participants = @() }
      $participantsLabel = Get-ExternalParticipantsLabel -ParticipantEmails $participants -HostEmail $hostEmail

      $localFile = $null
      try {
        $localFile = Download-ZoomRecording -RecordingDetail $full -HostEmail $hostEmail -ParticipantsLabel $participantsLabel -Headers $zoomHeaders -DryRun:$DryRun
      } catch {
        Write-Log "ERROR: download failed for meeting $($full.id): $($_.Exception.Message)"
        Write-RunCsv -Action "error" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath "" -SharePointPath "" -Notes "download_failed_account_sweep"
        continue
      }

      if (-not $localFile) { continue }

      $folderPath = "{0}/{1}/{2}/{3}" -f $BaseFolder, $dt.Year, $dt.Month.ToString("00"), $dt.Day.ToString("00")

      $ok = $false
      try {
        $ok = Upload-ToSharePoint -AccessToken $graphToken -SiteId $SiteId -FolderPath $folderPath -LocalFilePath $localFile
      } catch {
        Write-Log "ERROR: SharePoint upload failed for ${localFile}: $($_.Exception.Message)"
        Write-RunCsv -Action "error" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath $localFile -SharePointPath $folderPath -Notes "upload_failed_account_sweep"
        continue
      }

      if ($ok) {
        $totalUploaded++
        Write-Log "Uploaded OK: $localFile -> $folderPath"
        Write-RunCsv -Action ($DryRun ? "dryrun_uploaded" : "uploaded") -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath $localFile -SharePointPath $folderPath -Notes "account_sweep"
      }
    }
foreach ($u in $users) {
    if ($maxRecordings -gt 0 -and $totalProcessed -ge $maxRecordings) { break }

    $hostEmail = ($u.email -as [string])
    if (-not $hostEmail) { $hostEmail = "unknown" }

    # Recordings list: inline Zoom API call (bypasses Render parsing issues)
    $meetings = @()
    $nextToken2 = $null
    do {
      $uri2 = "https://api.zoom.us/v2/users/$($u.id)/recordings?from=$fromStr&to=$toStr&page_size=300"
      if ($nextToken2) { $uri2 += "&next_page_token=$nextToken2" }

      $resp2 = Invoke-ZoomGet -Uri $uri2 -Headers $zoomHeaders
      if ($resp2.meetings) { $meetings += $resp2.meetings }
      $nextToken2 = $resp2.next_page_token
    } while ($nextToken2)

    # De-dupe: Zoom can return duplicate meeting instances; uuid is the stable unique key
    $meetings = @($meetings | Where-Object { $_ -and $_.uuid } | Sort-Object uuid -Unique)

    foreach ($m in $meetings) {
      if ($maxRecordings -gt 0 -and $totalProcessed -ge $maxRecordings) { break }

      if (-not $m.uuid) { continue }
      if (-not $processedUuids.Add([string]$m.uuid)) {
        Write-Log ("SKIP (duplicate uuid): {0} (host: {1})" -f $m.uuid, $hostEmail)
        Write-RunCsv -Action "skipped" -MeetingId "$($m.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso "" -Topic ($m.topic) -LocalPath "" -SharePointPath "" -Notes "duplicate_uuid"
        continue
      }

      $totalProcessed++

      $full = $null
      try {
        $full = Get-ZoomMeetingRecordingsDetail -MeetingUuid $m.uuid -Headers $zoomHeaders
      } catch {
        Write-Log "WARN: failed to fetch meeting recordings detail for $($m.id) uuid=$($m.uuid): $($_.Exception.Message)"
        Write-RunCsv -Action "error" -MeetingId "$($m.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso "" -Topic ($m.topic) -LocalPath "" -SharePointPath "" -Notes "detail_fetch_failed"
        continue
      }

      if (-not $full -or -not $full.start_time) { continue }

      $dt = [DateTime]$full.start_time

      # Hard guard: skip anything outside the requested global date range
      if ($dt -lt $start -or $dt -gt $end.AddDays(1).AddSeconds(-1)) {
        Write-Log ("SKIP (outside range): {0} [{1}] (host: {2})" -f $full.topic, $dt.ToString("yyyy-MM-dd HH:mm"), $hostEmail)
        Write-RunCsv -Action "skipped" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath "" -SharePointPath "" -Notes "outside_range"
        continue
      }

      Write-Log ("Processing: {0} [{1}] (host: {2})" -f $full.topic, $dt.ToString("yyyy-MM-dd HH:mm"), $hostEmail)

      $participants = @()
      try { $participants = Get-MeetingParticipantsEmails -MeetingId "$($full.id)" -Headers $zoomHeaders } catch { $participants = @() }
      $participantsLabel = Get-ExternalParticipantsLabel -ParticipantEmails $participants -HostEmail $hostEmail

      $localFile = $null
      try {
        $localFile = Download-ZoomRecording -RecordingDetail $full -HostEmail $hostEmail -ParticipantsLabel $participantsLabel -Headers $zoomHeaders -DryRun:$DryRun
      } catch {
        Write-Log "ERROR: download failed for meeting $($full.id): $($_.Exception.Message)"
        Write-RunCsv -Action "error" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath "" -SharePointPath "" -Notes "download_failed"
        continue
      }

      if (-not $localFile) { continue }

      $folderPath = "{0}/{1}/{2}/{3}" -f $BaseFolder, $dt.Year, $dt.Month.ToString("00"), $dt.Day.ToString("00")

      $ok = $false
      try {
        $ok = Upload-ToSharePoint -AccessToken $graphToken -SiteId $SiteId -FolderPath $folderPath -LocalFilePath $localFile
      } catch {
        Write-Log "ERROR: SharePoint upload failed for ${localFile}: $($_.Exception.Message)"
        Write-RunCsv -Action "error" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath $localFile -SharePointPath $folderPath -Notes "upload_failed"
        continue
      }

      if ($ok) {
        $totalUploaded++
        Write-Log "Uploaded OK: $localFile -> $folderPath"
        Write-RunCsv -Action ($DryRun ? "dryrun_uploaded" : "uploaded") -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath $localFile -SharePointPath $folderPath -Notes ""

        if (-not $DryRun -and $DeleteFromZoom) {
          try {
            Remove-ZoomRecording -MeetingUuid $m.uuid -Headers $zoomHeaders
            Write-Log "Deleted from Zoom: meeting uuid=$($m.uuid)"
            Write-RunCsv -Action "deleted" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath $localFile -SharePointPath $folderPath -Notes ""
          } catch {
            Write-Log "ERROR: failed to delete from Zoom meeting uuid=$($m.uuid): $($_.Exception.Message)"
            Write-RunCsv -Action "error" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath $localFile -SharePointPath $folderPath -Notes "delete_failed"
          }
        }
      } else {
        Write-Log "UPLOAD FAILED: $localFile"
        Write-RunCsv -Action "error" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath $localFile -SharePointPath $folderPath -Notes "upload_returned_false"
      }
    }
  }

  if ($maxRecordings -gt 0 -and $totalProcessed -ge $maxRecordings) { break }
  $cursor = $chunkEnd.AddDays(1)
}

try {
  Upload-RunLogsToSharePoint -GraphToken $graphToken
  Write-Log "Uploaded run logs to SharePoint: $BaseFolder/_logs"
} catch {
  Write-Log "WARN: could not upload run logs to SharePoint: $($_.Exception.Message)"
}

Write-Log ("=== END RUN === Uploaded: {0} Processed: {1}" -f $totalUploaded, $totalProcessed)

if ($env:KEEP_ALIVE -and $env:KEEP_ALIVE.ToLower() -eq "true") {
  Write-Log "KEEP_ALIVE=true -> sleeping forever to stop Render restart loop"
  while ($true) { Start-Sleep -Seconds 3600 }
}

exit 0
