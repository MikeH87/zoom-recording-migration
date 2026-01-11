# Build Log

## [2026-01-11] — End-to-end working (download → SharePoint → delete)
Key fixes and final working state:
- Zoom auth migrated to **Server-to-Server OAuth** (no manual refresh tokens).
- Zoom recording discovery updated to iterate **all users** (not just `/users/me`).
- Participant handling:
  - Participant emails often return **unknown** (expected: Zoom only returns authenticated/available identities).
  - Internal domains filtered out from participant list.
- Naming convention stabilized:
  - Includes host + participant summary
  - Includes meeting id + recording file id to ensure uniqueness.
- SharePoint uploader made production-ready:
  - Uses **Graph upload sessions** and **chunked upload via HttpClient** (avoids Content-Length mismatch issues).
  - Correct handling of Graph `root:/path:/createUploadSession` URI interpolation and encoding.
- Verified real deletion safety:
  - Successfully migrated and deleted a historical recording:
    - **2020-03-31 15:02** “Laura McCarthy's SSAS Zoom Meeting”
    - Upload succeeded, then deletion confirmed.
- Logs:
  - Run logs uploaded to SharePoint under `TLPI Zoom Calls/_logs/`.

## Notes / lessons learned
- PowerShell string interpolation gotchas:
  - `:$var` patterns inside `"..."` can trigger parser issues; prefer `${var}` or string concatenation.
- Graph upload sessions are sensitive to exact URI formatting:
  - Always use `.../root:/<path>:/createUploadSession`
  - Don’t let PowerShell parse `:$something` accidentally.
- Chunk uploads must send correct `Content-Range` and exact byte counts per chunk.
