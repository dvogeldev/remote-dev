# Agency OS / Hermes Memory Architecture — Handoff Brief

**Purpose:** Give another model (or engineer) enough context to continue design and implementation without re-litigating this thread.  
**Date of source conversation:** 2026-08-31  
**Authoring stance:** Senior systems architecture discussion with the operator of a self-hosted Hermes Agent on a VPS, building an “Agency OS” (research, copy, marketing, content).

---

## 1. What the operator is building

A personal/small-agency operating system:

- **Runtime:** Nous Research **Hermes Agent** (self-hosted, profiles, skills, session FTS, messaging later).
- **Work:** Copywriting, research, marketing, content creation — multiple *roles*, one human.
- **Knowledge problem:** During the day they capture articles, YouTube, thoughts, and (until recently) todos into **Open Brain** (Nate B. Jones pattern: Postgres + pgvector + MCP). That dump is not serving roles.
- **Desired outcome:** A knowledge system Hermes can orchestrate *by role*, with connections across clients/offers/proofs — not a second chatbot notebook.

Constraints called out early: VPS RAM, avoid stacking Hermes + TencentDB Agent Memory + Cognee as three always-on extractors.

---

## 2. Conversation arc (inception → now)

1. **RAM question:** Combined footprint of Hermes + TencentDB + Cognee on a VPS.  
   Finding: Hermes is cheap (~200–400 MB idle, ~1 GB busy). TencentDB Node gateway and Cognee dominate. 8 GB realistic minimum if both extra engines run; 4 GB only if Cognee is embedded and ingest is light.

2. **Bang-for-buck memory:** Session/personal (Hermes native) vs Tencent-style “agent memory.”  
   Finding: Native files + session search win for prefs and “what did we say.” Tencent-style L0–L3 wins for long/repeating *work*. Do not replace one with the other.

3. **Agency OS layers:** Wiki vs graph vs agent memory, orchestrated by Hermes.  
   Finding: Three *jobs*, not three products. Wiki = canon. Graph = connections. Agent memory = scar tissue of doing work. Hermes = router, not warehouse.

4. **Provider tour:** Hermes native limits; Cognee (graph+semantic); Open Brain (“just RAG+MCP”); Honcho; official eight providers.  
   Finding: Native cannot do multi-hop “broader connections.” Honcho models *people*. Cognee models *the book of business*. Open Brain is a capture bus.

5. **Optimal enhancement:** Operator felt the thread “honed in on Honcho.” Correction: Honcho is the wrong *foundation* for an agency. Evergreen spine = git wiki + Cognee. Hindsight only as optional Hermes-native conversation→facts adapter.

6. **Cognee vs Hindsight:** Operator’s read confirmed: Cognee is the destination graph/semantic layer; Hindsight’s edge is *native Hermes wiring*, not a better world model. “Native = plumbing. Cognee = the tank.”

7. **KM workflow correction:** Open Brain was used as CMS + task list. Correct model: inbox vs canon vs graph vs tasks. Promote on a schedule; don’t embed raw captures; todos leave the brain.

8. **“Beautiful setup”:** Empty Hermes provider slot; profiles per role; six skills; Cognee over `canon/` only; Open Brain as dock.

9. **Initial Hermes setup steps:** Install → `hermes setup` → built-in memory ON, **external provider OFF** → short SOUL/USER/MEMORY → clone profiles → one `drain-inbox` skill. Cognee later as tools, not MemoryProvider.

---

## 3. Decisions that should stick (do not reopen lightly)

| Decision | Choice |
|---|---|
| Hermes provider slot (day one) | **Empty.** `hermes memory off`. Built-in MEMORY.md + USER.md + session FTS only. |
| Source of truth | **Git wiki** at `~/agency/canon` (or equivalent). Human-revertible pages. |
| Connection / multi-hop layer | **Cognee**, ingesting *promoted* canon + finished artifacts only. |
| Capture | **Open Brain** (or `inbox/`) as dock. Fields: url, why, role. |
| Tasks | Real todo/calendar tool. **Never** the vector store. |
| Honcho | Accessory later for operator/client-as-person. **Not** the agency spine. |
| Hindsight | Optional later if talk must become structured facts via official Hermes hooks. |
| TencentDB Agent Memory | Later, if long-horizon jobs need scenes/skills-as-assets / team governance. |
| One extractor per stream | Do not run Honcho + Cognee + Tencent all capturing the same turns. |
| Hermes role | Orchestrator: profiles, skills, routing. Not the warehouse. |

---

## 4. Target architecture

```text
Operator (CLI / Telegram later)
        │
        ▼
Hermes Agent
  profiles: operator | research | copy | marketing | editor
  native: SOUL.md, USER.md, MEMORY.md (tiny, frozen per session)
  session_search (SQLite FTS5)
  skills: drain-inbox, promote, brief, draft-copy, critique, after-action
  memory.provider: NONE
        │
        ├── inbox / Open Brain     raw captures
        ├── ~/agency/canon (git)   Client, Offer, Voice, Proof, Method, Decision
        ├── Cognee                 graph + semantic over canon (+ artifacts)
        └── task system            next actions
```

**Write policy (core invariant):**

- Free-flow → inbox only.  
- Promoted, sourced statements → wiki.  
- Graph built from wiki + finished work, never from the raw hose.  
- Task outcomes / “next time do X” → skill patch or decision page.  
- Operator prefs → USER.md (Honcho only if needed later).

---

## 5. Layer roles (precise)

| Layer | Answers | Shape | Writer |
|---|---|---|---|
| Hermes native | Who is the OS / operator; env paths | ≤ ~3.5k chars, always in prompt | Agent + human, curated |
| Session FTS | What was said in a past chat | Transcripts | Automatic |
| Skills | How we do this role’s job | SKILL.md playbooks | Hermes after jobs + human |
| Wiki | What is true for the agency | Dated pages + INDEX.md | Editor / promote skill |
| Cognee | How entities connect | Graph + vectors | Ingest after promotion |
| Open Brain | What I noticed today | Thoughts + embeddings | Capture gesture |
| Hindsight (optional) | Structured facts from conversation | Facts/entities/reflect | Hermes provider slot |
| Honcho (optional) | How this *person* decides | Dialectic user model | Separate from canon |
| Tencent (optional) | Long-task episodes, team assets | L0–L3 / Chat/Skill/Wiki/CodeGraph | Long jobs / multi-agent team |

OpenKnowledge / Tencent LLM-Wiki / Karpathy-style wiki ≈ **canon compiled for LLMs**, not session memory.

---

## 6. Why not the popular alternatives (as foundation)

- **Hermes native alone:** Excellent working set; cannot join Client→Offer→Proof across months.  
- **Honcho:** Best official *person* model (dialectic, peer cards, multi-agent isolation). Wrong CMS. AGPL if self-hosted.  
- **Mem0 / Supermemory / OpenViking / ByteRover / Holographic / RetainDB:** Useful satellites (facts, fencing, trees, local SQLite). Not a book-of-business graph.  
- **Hindsight:** Strong official slot (facts, entities, relations, reflect, local Postgres). Still conversation-centric vs corpus-centric. Use as faucet, not library.  
- **Open Brain:** Shared inbox across Claude/Cursor/Hermes via MCP. Not Cognee-class extraction or multi-hop world model.  
- **TencentDB:** Strong for *work* memory and later team asset hub. Extra Node sidecar + extraction tax. Not day-one.  
- **Stacking all three engines:** RAM + duplicate truth.

Official Hermes rule: **one** external MemoryProvider at a time; built-in files stay on.

---

## 7. Recommended beautiful setup (implementation target)

**Paths:**

```text
~/agency/canon/{clients,offers,voice,proofs,methods,decisions}/INDEX.md
~/agency/inbox/
~/agency/artifacts/
~/.hermes/  SOUL.md, config.yaml, profiles, skills, memories
```

**Profiles:** `operator` (default), `research`, `copy`, `marketing`, `editor`.  
Create with `hermes profile create <name> --clone` (not `--clone-all`).

**Skills to write:** drain-inbox → promote → brief → draft-copy → critique → after-action.

**VPS:** 8 GB comfortable for Hermes + Cognee (remote LLM). Browser toolset off at first.

**Backup:** git remote for `canon`; weekly tarball of `~/.hermes`. Cognee should be rebuildable from canon.

---

## 8. Initial Hermes setup (agreed first-week procedure)

1. Create `~/agency/...` and `git init` on `canon`.  
2. `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash` then `hermes doctor`.  
3. `hermes setup` — model ≥64K context; tools = files/terminal/web; browser off; approvals on; gateway later.  
4. **Memory:** built-in ON, user profile ON, skill generation ON, **`hermes memory off`**.  
5. Optional first week: `memory.write_approval: true`. Caps default 2200 / 1375.  
6. Fill short SOUL / USER / MEMORY (paths + policy only).  
7. Prove recall with `/new` and `/context`.  
8. Clone four role profiles; one `drain-inbox` skill.  
9. Do **not** run `hermes memory setup` for Honcho/Mem0/Hindsight/Cognee yet.  
10. Do **not** ingest Open Brain wholesale into Hermes or Cognee.

Install refs: hermes-agent.nousresearch.com install + `hermes setup` / `hermes memory setup|status|off`.

---

## 9. Daily knowledge loop (operator habit)

Capture: url + one-line why + role tag.  
Two–three times a week: drain → kill most → stub wiki page for keepers → only then Cognee remember that file.  
If it cannot become five honest sentences, it stays a bookmark.  
Hermes roles read INDEX + allowed folders + targeted Cognee query — never “search everything I ever liked.”

---

## 10. Open issues for the next LLM / builder

- Exact Hermes version on the box (`hermes --version`); profile CLI flags can differ by release.  
- Where Open Brain is hosted (Supabase vs local) and how Hermes should call it (MCP vs ignore until drain).  
- Cognee deploy: embedded SQLite/LanceDB/Kuzu vs Postgres; Hermes MCP vs CLI from skills.  
- Task tool of record (none specified).  
- Client count / corpus size — graph is optional until multi-hop actually fails.  
- Whether any content is shared across humans (Tencent governance vs single-operator).  
- Model vendor and spend caps.  
- Telegram/gateway timing.  
- Migration of *existing* Open Brain items: needs a one-time triage script, not auto-embed.

---

## 11. Suggested next development tickets

1. Skeleton `canon/` templates (YAML frontmatter: type, client, status, sources, role_write).  
2. `drain-inbox` and `promote` SKILL.md with file conventions.  
3. Cognee ingest script: only paths under `canon/` + `artifacts/`.  
4. `brief` skill: assemble voice + client + offer + two proofs.  
5. Acceptance tests:  
   - “Where is canon?” → native memory.  
   - “Which proofs share this pain point?” → Cognee after promotion.  
   - “What did we try last campaign?” → session search or campaign note page.  
6. Explicit non-goals in SOUL.md so future sessions do not re-enable a provider “to be safe.”

---

## 12. One-paragraph north star (paste into SOUL.md if useful)

Hermes is the desk. The library is a git wiki. The catalog is Cognee over promoted pages. Open Brain is the loading dock. Tasks are tasks. Built-in memory holds only operator rules and paths. No external Hermes memory provider until the drain→wiki→graph loop is boring. Roles load shelves, not the whole warehouse.

---

*End of handoff. Continue from §10–11; treat §3 as frozen unless the operator changes goals.*
