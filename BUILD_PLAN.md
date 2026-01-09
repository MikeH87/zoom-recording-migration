# Build Plan

This document outlines the step-by-step plan to implement the Zoom recording migration script using PowerShell.

1. Research required APIs and tools:
   - Zoom REST API endpoints needed to list users, list recordings, fetch past meeting participants, download recordings, and delete recordings.
   - Microsoft Graph API endpoints for uploading files to SharePoint using PUT or upload sessions.
   - Authentication flows (Zoom S2S OAuth, Graph client credentials).
2. Set up local PowerShell project structure:
   - Create script file (e.g. migrate.ps1) and modules as needed.
   - Create .env and .env.example for environment variables.
3. Write functions for authentication:
   - Function to obtain Zoom access token using environment variables.
   - Function to obtain Graph access token using environment variables.
4. Write functions to list Zoom users and recordings:
   - Paginate through users.
   - Paginate through recordings for each user within the date range.
5. Write function to fetch participants for each meeting and determine external participant emails.
6. Write function to build filenames according to the naming convention (external emails, date/time in Europe/London, topic, host email, meeting ID).
7. Write function to download recordings to a temporary directory.
8. Write functions to resolve the SharePoint site and create year/month/day folders.
9. Write functions to upload files to SharePoint (small files and large files).
10. Write function to delete recordings from Zoom.
11. Write main script logic to orchestrate the above functions with error handling, concurrency control, and dry-run support.
12. Add logging and verification steps.
13. Write unit tests or integration tests where feasible.
14. Document deployment instructions for running the script locally and scheduling it on Render.
