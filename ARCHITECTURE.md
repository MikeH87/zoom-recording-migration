# Architecture

## Overview
This application is a Windows PowerShell background worker that migrates Zoom cloud meeting recordings into SharePoint to reduce Zoom storage usage while preserving long-term access and searchability.

## Safety model (critical)
The system uses a **two-pass architecture** to eliminate any risk of data loss.

Deletion from Zoom is **never** performed in the same pass as upload.

---

## Pass 1 — Archive pass (NO DELETION)

**Purpose**
Ensure every Zoom recording exists in SharePoint as a single playable video file before any deletion is considered.

**Behaviour**
- Enumerate Zoom users
- Enumerate meetings older than the retention threshold
- Select one primary MP4 recording per meeting
- Download locally (temporary storage)
- Upload to SharePoint as a single video file
- Store files under:
  Shared Documents/TLPI Zoom Calls/YYYY/MM/DD/
- Verify upload success (exists + size > 0)
- Never overwrite existing files
- Never delete from Zoom

SharePoint becomes the archive of record.

---

## Pass 2 — Cleanup pass (DELETION ONLY AFTER VERIFICATION)

**Purpose**
Delete Zoom recordings only when SharePoint already contains a verified archived copy.

**Behaviour**
- Re-enumerate Zoom meetings
- Reconstruct expected SharePoint path + filename
- Query SharePoint directly
- Delete from Zoom only if the file exists and is valid
- Otherwise skip and log

---

## Guarantees
- Zero-risk deletion
- Fully re-runnable
- SharePoint is always the source of truth
