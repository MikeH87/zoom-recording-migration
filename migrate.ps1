# ================================
# Zoom Recording Migration (PROD-READY)
# - Moves Zoom cloud recordings into SharePoint (Year/Month/Day)
# - Uses Server-to-Server OAuth for Zoom
# - Uses Microsoft Graph upload sessions for large files
# - Writes local logs + uploads run logs to SharePoint (_logs/)
# - DOES NOT DELETE from Zoom unless DELETE_FROM_ZOOM=true

# Required env vars:
#   ZOOM_ACCOUNT_ID, ZOOM_CLIENT_ID, ZOOM_CLIENT_SECRET
#   GRAPH_TENANT_ID, GRAPH_CLIENT_ID, GRAPH_CLIENT_SECRET

# Optional env vars:
#   SITE_ID  (Graph Site ID) default: netorg3849094... (set below)
#   BASE_FOLDER default: TLPI Zoom Calls
#   FROM_DATE, TO_DATE (yyyy-MM-dd) for test runs
#   DRY_RUN (true/false) default true
#   DELETE_FROM_ZOOM (true/false) default false
#   EXCLUDED_HOST_EMAILS (comma list) - REMOVED: Including all users now
#   INTERNAL_DOMAINS (comma list) default tlpi.co.uk,thelandlordspension.co.uk
#   CHUNK_DAYS (int) default 7
#   MAX_USERS (int) limit user iteration (testing)
#   MAX_RECORDINGS (int) limit total

# Set EXCLUDED_HOST_EMAILS to empty array to include all users
 = @()
