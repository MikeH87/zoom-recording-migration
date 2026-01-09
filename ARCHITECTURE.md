# Architecture

## Overview
The system is a PowerShell script that migrates Zoom cloud recordings to SharePoint to reduce Zoom storage costs while keeping recordings searchable. It runs as a scheduled job on Render on a monthly basis.

## Components
- **Zoom API client** – uses server-to-server OAuth credentials to fetch users, list recordings, download recording files, fetch meeting participants and delete recordings.
- **SharePoint/Graph client** – uses Azure AD client credentials to resolve the site and upload files to SharePoint.
- **Migration orchestration** – coordinates listing, downloading, renaming, uploading and deletion, with concurrency control and a dry-run mode.
- **Environment configuration** – sensitive credentials and settings are stored in .env (with placeholders in .env.example) and excluded from Git via .gitignore.

## Data flow
1. At start-up the script reads configuration from environment variables.
2. It obtains an access token from Zoom using S2S OAuth and from Graph using client credentials.
3. It lists Zoom users and iterates through each user to list their recordings within the date range.
4. For each meeting, it retrieves participants, builds a descriptive filename and downloads the selected media recording.
5. The script ensures the year/month/day folder structure exists in the SharePoint document library and uploads the recording.
6. After confirming the upload, it deletes the recording from Zoom (unless dry-run is enabled).
7. Logging and error handling record successes or failures for auditing.

## Key decisions
- Use a single PowerShell script for portability and ease of scheduling on Render.
- Use environment variables for secrets and configuration, with .env for local settings and Render environment variables for production.
- Use Graph API simple uploads for files up to 250 MB and chunked uploads for larger files.
- Build filenames using external participant emails, the meeting date/time in Europe/London, meeting topic, host email and meeting ID.
