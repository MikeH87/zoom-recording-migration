# Architecture

## What this project does
Migrates **Zoom cloud recordings older than 18 months** into **SharePoint**, using a folder structure:

`TLPI Zoom Calls / YYYY / MM / DD / <recording>.mp4`

Then (optionally) **deletes** the recording from Zoom **only after** a successful SharePoint upload.

## Key scripts
- **migrate.ps1**
  - Orchestrates the run:
    - Gets Zoom access token (Server-to-Server OAuth)
    - Enumerates users (with exclusions)
    - Pulls recordings in a date range
    - Downloads MP4(s) to `.\tmp\`
    - Uploads to SharePoint (large-file safe via upload session)
    - Optionally deletes from Zoom
    - Writes logs locally + uploads run logs to SharePoint

- **sharepoint.ps1**
  - `Get-GraphAccessToken` (client credentials)
  - `Upload-ToSharePoint` (SharePoint/OneDrive drive upload)
    - Ensures folder path exists
    - Uses **Graph upload sessions** with **chunked upload** (HttpClient) so large MP4s work reliably

- **sharepoint-auth.ps1**
  - Helper(s) for SharePoint/Graph auth & lookup (site/drive discovery)

## SharePoint layout
- **Base folder:** `TLPI Zoom Calls`
- **Recordings:** `TLPI Zoom Calls/YYYY/MM/DD/*.mp4`
- **Logs:** `TLPI Zoom Calls/_logs/`
  - Each run produces local logs and then uploads a copy to SharePoint so the migration is auditable even when running on Render.

## Logging & audit trail
Local (repo folder):
- `migration.log` (human-readable run log)
- `last-run.log` (captured stdout/stderr for the last run)

SharePoint:
- Uploaded copies of run logs under: `TLPI Zoom Calls/_logs/`

## Safety rules
- **No delete unless upload succeeded**
- Designed to be **re-runnable**:
  - Uses unique filename elements (meeting id + recording file id) to avoid collisions
  - SharePoint uploader supports conflict behavior (rename) when necessary

## Runtime configuration (ENV VARS)
Zoom:
- `ZOOM_ACCOUNT_ID`
- `ZOOM_CLIENT_ID`
- `ZOOM_CLIENT_SECRET`

Microsoft Graph:
- `GRAPH_TENANT_ID`
- `GRAPH_CLIENT_ID`
- `GRAPH_CLIENT_SECRET`

Operational controls:
- `DRY_RUN` = `true|false`
- `DELETE_FROM_ZOOM` = `true|false` (only meaningful when `DRY_RUN=false`)
- `FROM_DATE` = `YYYY-MM-DD`
- `TO_DATE` = `YYYY-MM-DD`
- `INTERNAL_DOMAINS` = comma list (e.g. `tlpi.co.uk,thelandlordspension.co.uk`) used to filter participants
- `EXCLUDED_HOST_EMAILS` = comma list of host emails to skip (e.g. service/test accounts)

## Render deployment intent
- Run the backfill (March 2021 → cutoff at 18 months ago), then switch to scheduled runs every ~3 days.
- Logs remain available in SharePoint under `_logs`.
