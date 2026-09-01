---
name: drain-inbox
description: Drain inbox files into canon stubs or delete them.
version: 0.1.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [agency, inbox, canon, wiki]
---

# Drain inbox

Run when the operator asks to drain, triage, or clear `~/agency/inbox`, or on the twice-weekly drain.

Inbox is the dock. Canon is the git wiki. Open Brain is MCP read, not this drain. Tasks are a task tool. Do not write captures into MEMORY.md. Do not ingest into Cognee.

## Steps

1. List files in `~/agency/inbox/` (non-dot). **Done when** you have the full list, including empty.
2. Empty list: report "inbox empty" and stop.
3. For **each** file, read it and choose one:
   - **Kill** — cannot become five sourced sentences. Delete the file. One-line reason.
   - **Bookmark** — a URL plus a one-line why, nothing more. Leave the file in the inbox.
   - **Keep** — can become five honest sourced sentences. Stub a canon page, then delete the inbox file.
4. **Keep** writes `~/agency/canon/<shelf>/<slug>.md` (create the shelf directory). Shelves: `clients`, `offers`, `voice`, `proofs`, `methods`, `decisions`. Frontmatter:

   ```yaml
   ---
   type: method
   status: stub
   sources: []
   role_write: default
   ---
   ```

   Body: at most five sentences, each with a source. `git -C ~/agency/canon add` the page. Do not commit unless the operator asks.
5. Report: killed / bookmarked / promoted, with paths. Inbox should contain only bookmarks.

## Completion

Every inbox file is killed, bookmarked, or promoted. No Cognee, no `ingest-thought`, no MEMORY.md edits.
