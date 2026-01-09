# Company Context

## Business purpose
This project reduces Zoom storage costs by migrating recorded meetings older than 18 months to SharePoint while keeping them searchable.

## Internal domains
- tlpi.co.uk
- thelandlordspension.co.uk

## Target SharePoint location
Site: ZoomCallStorage (
etorg3849094.sharepoint.com/sites/ZoomCallStorage)
Folder: Shared Documents/TLPI Zoom Calls
Recordings will be organised into year/month/day sub-folders.

## Naming convention
Files will be named in the format:
{external_emails concatenated with &} - {YYYY-MM-DD HH-mm} - {meeting topic} - {host email} - {meeting ID}.{extension}External emails exclude the internal domains listed above. All external participant emails are included to improve search indexing.

## Date range
- Initial migration: process recordings up to 18 months old (default FROM_DATE).
- Scheduled run: run monthly, migrating recordings older than 18 months from Zoom to SharePoint and then deleting them from Zoom.

## Credentials and configuration
All credentials are stored in environment variables (local .env during development or Render environment variables in production). Required keys include:
- ZOOM_ACCOUNT_ID
- ZOOM_CLIENT_ID
- ZOOM_CLIENT_SECRET
- GRAPH_CLIENT_ID
- GRAPH_CLIENT_SECRET
- TENANT_ID
- SITE_HOSTNAME (e.g. 
etorg3849094.sharepoint.com)
- SITE_PATH (e.g. /sites/ZoomCallStorage)
- FOLDER_PATH (e.g. Shared Documents/TLPI Zoom Calls)
- INTERNAL_DOMAINS (e.g. 	lpi.co.uk,thelandlordspension.co.uk)
