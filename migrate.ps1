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

# ---------- MAIN ----------
Write-Log ("=== START RUN (DRY_RUN={0}, FROM={1}, TO={2}) ===" -f $DryRun, $FromDate, $ToDate)

# Validate env
foreach ($v in "ZOOM_ACCOUNT_ID","ZOOM_CLIENT_ID","ZOOM_CLIENT_SECRET","GRAPH_TENANT_ID","GRAPH_CLIENT_ID","GRAPH_CLIENT_SECRET") {
  if (-not [Environment]::GetEnvironmentVariable($v)) { throw "Missing env var: $v" }
}

$zoomToken = Get-ZoomAccessToken -AccountId $env:ZOOM_ACCOUNT_ID -ClientId $env:ZOOM_CLIENT_ID -ClientSecret $env:ZOOM_CLIENT_SECRET
$zoomHeaders = @{ Authorization = "Bearer $zoomToken" }

$graphToken = Get-GraphAccessToken -TenantId $env:GRAPH_TENANT_ID -ClientId $env:GRAPH_CLIENT_ID -ClientSecret $env:GRAPH_CLIENT_SECRET

# Users (no exclusions)
$users = Get-ZoomUsers -Headers $zoomHeaders
if ($env:MAX_USERS) { $users = $users | Select-Object -First ([int]$env:MAX_USERS) }

Write-Log ("Users found: {0}" -f $users.Count)

# Process the recordings (all users)
$start = [DateTime]::ParseExact($FromDate, "yyyy-MM-dd", $null)
$end   = [DateTime]::ParseExact($ToDate,   "yyyy-MM-dd", $null)

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
        $full = Get-ZoomMeetingRecordingsDetail -MeetingId $m.id -Headers $zoomHeaders
      } catch {
        Write-Log "WARN: failed to fetch meeting recordings detail for $($m.id): $($_.Exception.Message)"
        Write-RunCsv -Action "error" -MeetingId "$($m.id)" -RecordingFileId "" -HostEmail $hostEmail -StartTimeIso "" -Topic ($m.topic) -LocalPath "" -SharePointPath "" -Notes "detail_fetch_failed"
        continue
      }

      if (-not $full -or -not $full.start_time) { continue }

      $dt = [DateTime]$full.start_time
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
            Remove-ZoomRecording -MeetingId "$($full.id)" -Headers $zoomHeaders
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

exit
