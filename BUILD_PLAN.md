# Build Plan

## Phase 1 — Foundation (complete)
- Environment loading
- Zoom Server-to-Server OAuth
- Microsoft Graph authentication
- SharePoint site and drive resolution
- Zoom user and recording enumeration

## Phase 2 — Archive pass (Pass 1)
- Limit scope initially to a single day for testing
- Download one primary MP4 recording per meeting
- Upload as a single video file to SharePoint
- Create YYYY/MM/DD folder structure
- Verify file exists and size > 0
- No deletion logic

## Phase 3 — Validation
- Manually verify recordings in SharePoint UI
- Confirm folder structure, filenames, and playback

## Phase 4 — Cleanup pass (Pass 2)
- Re-scan Zoom recordings
- Verify SharePoint presence
- Delete from Zoom only after confirmation

## Phase 5 — Automation
- Schedule monthly execution on Render
- Archive pass first, cleanup pass separately
