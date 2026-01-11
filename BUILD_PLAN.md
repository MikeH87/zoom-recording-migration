# Build Plan

## Goal
Automatically migrate Zoom cloud recordings older than 18 months into SharePoint, preserving a date folder structure, then delete them from Zoom only after verified upload.

## Phase 1 — Working baseline (complete)
- Zoom Server-to-Server OAuth implemented
- Graph client-credentials auth implemented
- Multi-user recording discovery implemented
- SharePoint large-file upload sessions working
- End-to-end real test successful (including deletion)

## Phase 2 — Backfill (March 2021 → cutoff)
1) Confirm SharePoint base folder is clean enough for backfill (optional cleanup of test artifacts).
2) Run backfill in controlled batches:
   - Start: `FROM_DATE=2021-03-01`
   - End:   `TO_DATE=<cutoff date (today - 18 months)>`
   - Recommended: run month-by-month (or week-by-week) at first to reduce risk.
3) First backfill run should be:
   - `DRY_RUN=false`
   - `DELETE_FROM_ZOOM=false`
   - Validate uploads and logs
4) Second pass (deletion pass):
   - `DRY_RUN=false`
   - `DELETE_FROM_ZOOM=true`
   - Same date window(s), so deletes only happen after we’ve proven data is safely in SharePoint.

## Phase 3 — Ongoing schedule (Render)
- After backfill, run every 3 days to keep SharePoint up to date with the 18-month retention policy.
- Each run should:
  - Compute `FROM_DATE` / `TO_DATE` for the “older-than-18-months” window
  - Upload logs to `TLPI Zoom Calls/_logs/`
- Operational safety:
  - Keep `DELETE_FROM_ZOOM=true` only once stable.
  - If any failures occur, rerun with `DELETE_FROM_ZOOM=false` to revalidate.

## GitHub / CI
- Repo updated and pushed to GitHub.
- Next: add Render deployment files/config (service type + schedule) and document the environment variables in README.

## Required ENV VARS (Render)
Zoom:
- `ZOOM_ACCOUNT_ID`
- `ZOOM_CLIENT_ID`
- `ZOOM_CLIENT_SECRET`

Microsoft Graph:
- `GRAPH_TENANT_ID`
- `GRAPH_CLIENT_ID`
- `GRAPH_CLIENT_SECRET`

Controls:
- `DRY_RUN`
- `DELETE_FROM_ZOOM`
- `FROM_DATE`
- `TO_DATE`
- `INTERNAL_DOMAINS`
- `EXCLUDED_HOST_EMAILS`
