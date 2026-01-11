# ================================
# Zoom Recording Migration (PROD-READY)
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
#   SITE_ID  (Graph Site ID) default: netorg3849094... (set below)
#   BASE_FOLDER default: TLPI Zoom Calls
#   FROM_DATE, TO_DATE (yyyy-MM-dd) for test runs
#   DRY_RUN (true/false) default true
#   DELETE_FROM_ZOOM (true/false) default false
#   EXCLUDED_HOST_EMAILS (comma list)
#   INTERNAL_DOMAINS (comma list) default tlpi.co.uk,thelandlordspension.co.uk
#   CHUNK_DAYS (int) default 7
#   MAX_USERS (int) limit user iteration (testing)
#   MAX_RECORDINGS (int) limit total processed (testing)
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

function Encode-ZoomMeetingUuid {
  param([Parameter(Mandatory)][string]$Uuid)

  # Zoom UUIDs can contain "/" and must be URL-encoded. Some endpoints require double-encoding.
  $once = [System.Uri]::EscapeDataString($Uuid)
  $twice = [System.Uri]::EscapeDataString($once)
  return $twice
}

  param(
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][hashtable]$Headers
  )
  Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers
}

function Get-ZoomUsers {
  param([Parameter(Mandatory)][hashtable]$Headers)

  $all = @()
  foreach ($status in @("active","inactive","pending")) {
    $nextToken = $null
    do {
      $uri = "https://api.zoom.us/v2/users?page_size=300&status=$status"
      if ($nextToken) { $uri += "&next_page_token=$nextToken" }

      $resp = Invoke-ZoomGet -Uri $uri -Headers $Headers
      if ($resp.users) { $all += $resp.users }
      $nextToken = $resp.next_page_token
    } while ($nextToken)
  }

  # De-duplicate by user id
  $byId = @{}
  foreach ($u in $all) {
    if ($u -and $u.id -and (-not $byId.ContainsKey($u.id))) { $byId[$u.id] = $u }
  }

  return $byId.Values
}

function Get-ZoomRecordingsForUser {
  param(
    [Parameter(Mandatory)][string]$UserId,
    [Parameter(Mandatory)][string]$From,
    [Parameter(Mandatory)][string]$To,
    [Parameter(Mandatory)][hashtable]$Headers
  )

  $meetings = @()
  $nextToken = $null

  do {
    $uri = "https://api.zoom.us/v2/users/$UserId/recordings?from=$From&to=$To&page_size=300"
    if ($nextToken) { $uri += "&next_page_token=$nextToken" }

    $resp = Invoke-ZoomGet -Uri $uri -Headers $Headers
    if ($resp.meetings) { $meetings += $resp.meetings }
    $nextToken = $resp.next_page_token
  } while ($nextToken)

  $meetings
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

  # Zoom reports API: /report/meetings/{meetingId}/participants (requires report scopes + meeting must be in reportable window)
  # Many will return empty -> that's OK.
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

  # Keep names short for file paths
  $joined = ($filtered -join "+")
  if ($joined.Length -gt 60) { $joined = $joined.Substring(0,60) }
  $joined
}

function New-SafeFileName {
  param([Parameter(Mandatory)][string]$Name)

  # SharePoint/OneDrive are stricter than Windows. In particular, # and % often cause Graph path errors.
  $safe = ($Name -replace '[\\/:*?"<>|#%]', '_').Trim()

  # Also avoid trailing dots/spaces which SharePoint rejects
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
    Write-Log "No MP4 in meeting $($RecordingDetail.id) ÔÇô skipping"
    return $null
  }

  $dt = [DateTime]$RecordingDetail.start_time
  $topicSafe = New-SafeFileName -Name ($RecordingDetail.topic ? $RecordingDetail.topic : "Untitled")

  # Unique: include meetingId + recordingFileId
  $fileNameCore = "{0:yyyy-MM-dd HH-mm} - {1} - host_{2} - participants_{3} - {4} - {5}.mp4" -f `
    $dt, `
    $topicSafe, `
    (New-SafeFileName -Name $HostEmail), `
    (New-SafeFileName -Name $ParticipantsLabel), `
    $RecordingDetail.id, `
    $mp4.id

  $fileName = Truncate-FileName -FileName $fileNameCore -MaxLength 180
  $localPath = Join-Path $tmpDir $fileName

  if ($DryRun) {
    Write-Log "DRY RUN: creating stub file $fileName"
    New-Item -ItemType File -Path $localPath -Force | Out-Null
    Write-RunCsv -Action "dryrun_downloaded" -MeetingId "$($RecordingDetail.id)" -RecordingFileId "$($mp4.id)" -HostEmail $HostEmail -StartTimeIso $dt.ToString("s") -Topic $RecordingDetail.topic -LocalPath $localPath -SharePointPath "" -Notes "stub"
    return $localPath
  }

  $downloadUrl = "$($mp4.download_url)?access_token=$($Headers.Authorization -replace '^Bearer\s+','')"
  Write-Log ("Downloading MP4 ({0:N1} MB) -> {1}" -f ([double]$mp4.file_size/1MB), $fileName)

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

  # Upload migration.log (append-style locally, overwrite latest + keep dated copy)
  if (Test-Path -LiteralPath $LogFile) {
    $latest = "$logFolder/migration-latest.log"
    $dated  = "$logFolder/migration-$ts.log"
    Upload-ToSharePoint -AccessToken $GraphToken -SiteId $SiteId -FolderPath $logFolder -LocalFilePath $LogFile | Out-Null
    # also save dated copy (same local file, different remote name)
    $tmpCopy = Join-Path $tmpDir ("migration-$ts.log")
    Copy-Item -LiteralPath $LogFile -Destination $tmpCopy -Force
    Upload-ToSharePoint -AccessToken $GraphToken -SiteId $SiteId -FolderPath $logFolder -LocalFilePath $tmpCopy | Out-Null
    Remove-Item -LiteralPath $tmpCopy -Force -ErrorAction SilentlyContinue
  }

  # Upload run CSV (actions)
  if (Test-Path -LiteralPath $RunCsv) {
    Upload-ToSharePoint -AccessToken $GraphToken -SiteId $SiteId -FolderPath $logFolder -LocalFilePath $RunCsv | Out-Null
  }
}

# ---------- MAIN ----------
Write-Log ("=== START RUN (DRY_RUN={0}, FROM={1}, TO={2}) ===" -f $DryRun, $FromDate, $ToDate)

# Validate env
foreach ($v in "ZOOM_ACCOUNT_ID","ZOOM_CLIENT_ID","ZOOM_CLIENT_SECRET","GRAPH_TENANT_ID","GRAPH_CLIENT_ID","GRAPH_CLIENT_SECRET") {
  if (-not [Environment]::GetEnvironmentVariable($v)) { throw "Missing env var: $v" }
}

$zoomToken = Get-ZoomAccessToken -AccountId $env:ZOOM_ACCOUNT_ID -ClientId $env:ZOOM_CLIENT_ID -ClientSecret $env:ZOOM_CLIENT_SECRET
$zoomHeaders = @{ Authorization = "Bearer $zoomToken" }

$graphToken = Get-GraphAccessToken -TenantId $env:GRAPH_TENANT_ID -ClientId $env:GRAPH_CLIENT_ID -ClientSecret $env:GRAPH_CLIENT_SECRET

# Users + exclusions
$excluded = @()
if ($env:EXCLUDED_HOST_EMAILS) {
  $excluded = @($env:EXCLUDED_HOST_EMAILS -split "," | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
}

$users = Get-ZoomUsers -Headers $zoomHeaders
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
$maxRecordings = if ($env:MAX_RECORDINGS) { [int]$env:MAX_RECORDINGS } else { 0 }

$cursor = $start
while ($cursor -le $end) {
  $chunkEnd = $cursor.AddDays($ChunkDays - 1)
  if ($chunkEnd -gt $end) { $chunkEnd = $end }

  $fromStr = $cursor.ToString("yyyy-MM-dd")
  $toStr   = $chunkEnd.ToString("yyyy-MM-dd")

  foreach ($u in $users) {
    if ($maxRecordings -gt 0 -and $totalProcessed -ge $maxRecordings) { break }

    $hostEmail = ($u.email -as [string])
    if (-not $hostEmail) { $hostEmail = "unknown" }

    $meetings = @()
    try {
      $meetings = Get-ZoomRecordingsForUser -UserId $u.id -From $fromStr -To $toStr -Headers $zoomHeaders
    } catch {
      Write-Log "WARN: failed recordings list for user $($u.id) ($hostEmail): $($_.Exception.Message)"
      continue
    }

    foreach ($m in $meetings) {
      if ($maxRecordings -gt 0 -and $totalProcessed -ge $maxRecordings) { break }

      $totalProcessed++

      # Get full recording detail (includes recording_files)
      $full = $null
      try {
        $full = Get-ZoomMeetingRecordingsDetail -MeetingUuid $m.uuid -Headers $zoomHeaders
      } catch {
        Write-Log "WARN: failed to fetch meeting recordings detail for $($m.id): $($_.Exception.Message)"
        Write-RunCsv -Action "error" -MeetingId "$($m.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso "" -Topic ($m.topic) -LocalPath "" -SharePointPath "" -Notes "detail_fetch_failed"
        continue
      }

      if (-not $full -or -not $full.start_time) { continue }

      $dt = [DateTime]$full.start_time

# Guard: enforce date window (protects against Zoom returning other instances for the same meeting)
if ($dt -lt $start -or $dt -gt $end) {
  Write-Log ("SKIP (outside range): {0} [{1}] (host: {2})" -f $full.topic, $dt.ToString("yyyy-MM-dd HH:mm"), $hostEmail)
  Write-RunCsv -Action "skipped" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath "" -SharePointPath "" -Notes "outside_date_window"
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
            Write-Log "Deleted from Zoom: meeting $($full.id)"
            Write-RunCsv -Action "deleted" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath $localFile -SharePointPath $folderPath -Notes ""
          } catch {
            Write-Log "ERROR: failed to delete from Zoom meeting $($full.id): $($_.Exception.Message)"
            Write-RunCsv -Action "error" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath $localFile -SharePointPath $folderPath -Notes "delete_failed"
          }
        }
      } else {
        Write-Log "UPLOAD FAILED: $localFile"
        Write-RunCsv -Action "error" -MeetingId "$($full.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso $dt.ToString("s") -Topic $full.topic -LocalPath $localFile -SharePointPath $folderPath -Notes "upload_returned_false"
      }

      # keep tmp files for now; you can clean later if needed
    }
  }

  if ($maxRecordings -gt 0 -and $totalProcessed -ge $maxRecordings) { break }
  $cursor = $chunkEnd.AddDays(1)
}

# Upload logs to SharePoint (always; helps Render runs)
try {
  Upload-RunLogsToSharePoint -GraphToken $graphToken
  Write-Log "Uploaded run logs to SharePoint: $BaseFolder/_logs"
} catch {
  Write-Log "WARN: could not upload run logs to SharePoint: $($_.Exception.Message)"
}

Write-Log ("=== END RUN === Uploaded: {0} Processed: {1}" -f $totalUploaded, $totalProcessed)




Exit

Exit

exit
exit


# --- Render keep-alive to prevent rapid restart loops on Web Services ---
try {
  $keep = 0
  if ($env:KEEP_ALIVE_SECONDS) { $keep = [int]$env:KEEP_ALIVE_SECONDS }
  elseif ($env:RENDER -or $env:RENDER_SERVICE_ID) { $keep = 600 }
  if ($keep -gt 0) {
    Write-Log "Run complete. Sleeping for $keep seconds to prevent Render restart loop (set KEEP_ALIVE_SECONDS=0 to disable)."
    Start-Sleep -Seconds $keep
  }
} catch { }



