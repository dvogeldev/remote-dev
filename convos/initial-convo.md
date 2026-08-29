I'll compare your Contabo setup against that RackGenius 16GB offer for Hermes, Next.js containers, and a low-volume mail server. First I’m pulling current specs, real-world performance notes, and any caveats on shared cores / email.I have the plan lineup; next I’ll check RackGenius LTO pricing, port 25 / PTR policy, and how Contabo’s 4-core/8 GB box actually behaves under Docker + mail.Yes — that RackGenius 16GB LTO box can replace a Contabo 4 vCPU / 8 GB plan for this stack, with more RAM and disk headroom. It is not a straight “everything will feel faster” upgrade. The extra capacity is real; the CPU and disk quality are the tradeoff.

Assuming your Contabo is the usual Cloud VPS 10-class machine (4 shared vCPU, 8 GB RAM, ~75 GB NVMe, 200 Mbit port), here is how the two compare for Hermes + Next.js containers + low-volume mail.

## Spec comparison

| | Typical Contabo 4c/8G | RackGenius 16GB LTO |
|---|---|---|
| CPU | 4 shared vCPU, usually newer AMD EPYC | 8 **shared logical** cores on Xeon E5-2690 v4 (2016) or Xeon Gold 6140/6150 (2017) |
| RAM | 8 GB | 16 GB DDR4 |
| Disk | 75 GB NVMe (or 150 GB SATA SSD) | 200 GB **RAID 5 SSD** (not NVMe) |
| Network | 200 Mbit port, fair-use “unlimited” | 10 TB on a shared 1G/10G link |
| IPs | 1 IPv4 | 1 IPv4 + /64 IPv6 |
| Location | Many regions | Typically Michigan only |

LTO here means **limited-time offer** on leftover older nodes, not tape. Those Xeons are fine for always-on light services. They are weaker per core than a current EPYC/Ryzen, and “8 shared logical cores” is the same overselling model Contabo uses — do not treat 8 as dedicated.

## Does it fit your three workloads?

**Hermes agent — yes, comfortably.**  
If the model stays remote (OpenRouter / Anthropic / OpenAI), Hermes wants about 1–4 GB RAM and 1–2 cores. Browser/Playwright skills are the RAM hog. 16 GB leaves room that 8 GB does not. You still cannot run a serious local LLM on 16 GB.

**Next.js remote dev in containers — yes, with one caveat.**  
A realistic split:

- OS + Docker + overlay: ~1.5–2.5 GB  
- Hermes: 2–4 GB  
- Mail (Postfix/Dovecot or Mailcow-lite): 0.5–2 GB  
- Next.js dev container (`next dev` / Turbopack + node_modules): 2–4 GB idle, more during `next build`

16 GB is the right size for that. 8 GB works only if you keep swap and do not run a full Mailcow plus a heavy Next build at the same time.

The caveat is **disk and single-thread CPU**. Next.js and Docker are I/O noisy (`npm install`, image layers, `.next` cache). Contabo NVMe usually beats RAID 5 SATA SSD on random writes. RAID 5 also has a write penalty. Builds and container starts may feel the same or slower than Contabo even though you have more cores and RAM.

**Low-volume email — specs are fine; policy and IP reputation are the real test.**  
CPU/RAM/disk are enough for a few mailboxes. What matters:

1. Outbound **port 25** open, or an unblock on ticket  
2. Self-service **PTR / rDNS** (RackGenius VirtFusion generally supports this)  
3. A clean IPv4 — new VPS IPs are a lottery  
4. SPF, DKIM, DMARC on the domain  

Contabo officially documents mail-server setup and rDNS, but their ranges have mixed reputation and they have been known to rate-limit outbound mail. RackGenius is a small Michigan host; mail is usually allowed at low volume if you are not blasting lists, but that is not guaranteed on a cheap LTO node. Confirm port 25 + PTR **before** you cancel Contabo. If they will not open 25, keep inbound mail on the VPS and relay outbound through SES, Mailgun, or Postmark on 587. That is the more reliable pattern in 2026 anyway.

## Verdict

**Replace Contabo with this LTO if** you are RAM/disk bound, you want one box for Hermes + a Next.js dev container + a handful of mailboxes, and you accept older Xeon + RAID 5 SSD.

**Stay on Contabo or pick a different RackGenius line if** Next.js build speed or Docker I/O is the main pain, or if you sit in Europe/Asia (Michigan latency will feel worse for remote VS Code / SSH). In that case their **16 GB Value** plan (8 shared EPYC cores, 200 GB U.2 NVMe, $33/mo) is the better “same size, faster disk/CPU” option. A Contabo step-up to 6 vCPU / 12 GB or 8 vCPU / 24 GB is also cheaper than most US mid-tier VPS if you only need more RAM.

## Before you migrate

Ask RackGenius support, in writing:

- Is outbound TCP 25 open on LTO VPS, or will you open it for a low-volume mail server?  
- Can I set PTR to `mail.yourdomain.com` from VirtFusion?  
- Are LTO nodes eligible for the 99.95% SLA and snapshots/backups?  
- Any fair-use CPU cap on the 8 shared threads?

After provision, before cutting over mail:

- Check the new IPv4 on MXToolbox / multiRBL  
- Run a disk test (`fio` 4k random) so you know what Docker builds will feel like  
- Put Hermes, Next.js, and mail in separate Compose stacks with memory limits so one Next build cannot OOM the agent

**Bottom line:** the 16GB LTO can replace that Contabo box for this use case. Treat it as more RAM and disk on older shared hardware, not as a performance upgrade. Confirm mail ports first; if those check out, it is a reasonable move.

Grand Rapids changes the latency picture a lot. I’ll pull recent Contabo complaint patterns and confirm RackGenius is actually in that market.Working in Grand Rapids is the strongest reason to switch. RackGenius is not “a US host somewhere in the Midwest.” Their VPS nodes geo and looking-glass as **Grand Rapids / Byron Center**, they peer at **GRR-iX**, and they publish a local speedtest (`mispeed.rackgenius.com`). From a GR office or home fiber you should see **single-digit to low-teens ms RTT**, not the 90–120 ms you get to a Contabo EU box or even ~20–40 ms to Chicago/Ashburn.

That matters more for your stack than raw core count. Remote Next.js / VS Code / SSH / file sync / container rebuilds feel like a LAN machine at 5–15 ms. They feel sticky at 80–120 ms.

## What the Contabo Reddit threads are actually describing

The complaints are consistent, not random pile-ons:

- **Oversold shared CPU.** Steal shows up at peak. Node.js / Next builds and “lots of small libraries” are exactly where people say it falls over.
- **Disk lottery.** Same plan can be fine NVMe one week and 20–100 MB/s after a “migration.” That kills Docker layer pulls and `next build`.
- **Support and billing.** Slow tickets, long provision times, suspend-after-one-failed-charge stories. Fine if nothing breaks; painful if the box is your daily driver.

Those reviews match the product: cheap paper specs on dense shared nodes. For an always-on Hermes agent that sits idle, Contabo is often “good enough.” For **you sitting in GR doing remote Next.js in containers**, noisy neighbors plus high latency is a worse combo than an older Xeon 10 minutes from your desk.

## How that changes the earlier advice

The LTO 16GB is a better fit for *you* than it is as a generic upgrade:

- Latency: large win  
- RAM/disk size: win (16 GB / 200 GB vs 8 GB / 75 GB)  
- Network port: win vs Contabo’s 200 Mbit cap  
- CPU generation: still a loss vs a modern EPYC/Ryzen  
- RAID 5 SSD vs NVMe: still a question mark for Docker/Next I/O  

If remote-dev snappiness is the goal, take the LTO. If a `next build` on RAID 5 feels sluggish after you land, the next step is not “go back to Contabo” — it is RackGenius **Value 16GB (EPYC + U.2 NVMe)** or **Premium (Ryzen + Gen4 NVMe)** in the same building.

## Practical take

Switch. Grand Rapids is the rare case where the cheap local host beats a cheaper-looking EU/US-generic VPS even on older silicon.

Do this on day one:

1. Ping and `mtr` from your office — you want that local RTT confirmed.  
2. Ticket: port 25 + PTR for the mail hostname.  
3. Blacklist-check the new IPv4 before you move MX.  
4. Run a 4k random `fio` so you know what container builds will feel like.  
5. Cap Hermes / Next / mail with Docker memory limits so a Next compile cannot OOM the agent.

Contabo complaints are real for shared-node quality and support. For someone working in GR, a local RackGenius node is the more rational daily driver, LTO CPU included.

Take the Grand Rapids **12GB Value**, not the Detroit LTO 16GB.

Same city as your desk beats 4 extra GB of RAM on a 2016 Xeon and RAID 5 SATA. For Hermes + Next.js containers + light mail, the GR Value plan is the better machine.

## Side by side

| | Detroit LTO 16GB | GR 12GB Value | Contabo 4c/8G |
|---|---|---|---|
| Location | Detroit | Grand Rapids | Usually not local |
| CPU | 8 shared Xeon E5-2690 v4 / Gold 6140 | 6 shared **EPYC 7542 @ 2.9 GHz** | 4 shared EPYC (often steal-heavy) |
| RAM | 16 GB | 12 GB | 8 GB |
| Disk | 200 GB RAID 5 SSD | **150 GB RAID 1 U.2** | 75 GB NVMe |
| Network | 10 TB, 1G or 10G | 8 TB, shared 10G | 200 Mbit port |
| Panel | VirtFusion | VirtFusion | Contabo panel |

U.2 RAID 1 is NVMe in a mirrored pair. RAID 5 SSD is older SATA with a write penalty. Next.js and Docker care about that more than they care about 50 GB of extra disk.

EPYC 7542 (Rome, 2019) is also a real step up from E5-2690 v4 (Broadwell, 2016): better IPC, better memory controller, less of a dog on single-thread `next build` / `tsc` / webpack. Six of those shared threads will usually feel faster than eight old Xeon threads.

## Will 12 GB be enough?

Yes, if you cap the stacks. A sane split:

- OS + Docker: ~1.5–2 GB  
- Hermes (API models, browser tools on): 2–4 GB  
- Next.js dev container: 2–4 GB  
- Low-volume mail: 0.5–1.5 GB  

That lands around 8–11 GB in normal use. Leave 1 GB free and add 2–4 GB swap as a safety net. Do **not** run Mailcow’s full stack plus Playwright plus a production `next build` at the same time with no limits.

16 GB would be more comfortable. It is not worth going to Detroit and RAID 5 to get it.

## What you should do

Order the GR 12GB Value.

1. From the office, ping the new IP. You want a few milliseconds, not 15–25 ms to Detroit.  
2. Ask for port 25 + PTR before you move MX.  
3. Blacklist-check the IPv4.  
4. In Compose, set memory limits (`hermes` 3–4G, `next` 4G, mail 1G) so one Next compile cannot kill the agent.  
5. If 12 GB feels tight after a week of real use, ask them for the custom bump they already advertise — same GR node family, 16 GB — rather than jumping to the LTO.

The special Detroit LTO was the wrong plan for you once a Grand Rapids Value box was on the table. Local EPYC + U.2 is the one that matches how you actually work.

Email is off the table. I’ll check what actually works in 2026 for Proton Calendar ↔ Google Calendar sync.There is still **no official two-way sync** between Proton Calendar and Google Calendar. Proton does not speak CalDAV, and they say that is by design because of end-to-end encryption. What you can do is overlay one calendar on the other as read-only, plus a one-time copy.

That is enough for “see both schedules in one place.” It is not enough for “create an event in either app and have it appear editable in the other.”

## What actually works

**1. See Google inside Proton (best daily setup if Proton is home)**  
Subscribe to Google’s secret iCal URL in Proton.

- Google Calendar (web) → settings for that calendar → **Integrate calendar** → copy **Secret address in iCal format**  
- Proton Calendar → Settings → Calendars → Other calendars → **Add calendar from URL**

That feed is **view-only**. Proton refreshes it about every **4–16 hours**. You cannot edit those Google events from Proton. Subscribed calendars also count toward your plan limit (3 on Free, 25 on paid). If the feed is huge, append `?start-min=2026-01-01T00:00:00Z` so old history is skipped.

**2. See Proton inside Google**  
Paid Proton can share a calendar with a public/secret link. Add that URL in Google as **Other calendars → From URL**. Also view-only, and Google is slow to refresh ICS (often 12–24+ hours). Anyone with the link can read event titles and times, so treat it as “busy + title,” not private notes.

**3. One-time copy, not a live sync**  
Easy Switch / Import from Google copies current events into Proton and encrypts them. Proton’s own docs say it is **not** ongoing sync. After that, new Google events do not land in the imported calendar unless you subscribe separately.

## What does not work

- Edit in Proton → update Google, or the reverse  
- CalDAV / DAVx⁵ / Thunderbird / Apple Calendar pointed at Proton  
- A self-hosted bridge on your new VPS that talks to both APIs in a supported, clean way (Proton has no public calendar write API for this)

A third-party Android app, **Sync Provider for Proton**, can two-way sync Proton into the phone’s system calendar. If that same phone also has a Google account, Android can then push those events toward Google. That is a phone-as-middleman hack: delay, duplicates, and your Proton events sit unencrypted in Google’s calendar store. Only use it if you accept that.

## Practical recommendation

Pick **one writable calendar**. Overlay the other as read-only.

- Work meetings, invites, Meet links → keep creating those in **Google**  
- Personal / private events → create those in **Proton**  
- In Proton, subscribe to the Google calendars you need so one view shows both  
- Optionally subscribe the Proton share link in Google if coworkers live in Google Calendar  

Do not try to keep the same events editable in both places. You will get duplicates and missed updates.

This does not change the VPS plan. Calendar sync is all SaaS. The Grand Rapids 12GB Value box can stay focused on Hermes and Next.js containers.

Yes. Make this the workhorse.

Same Grand Rapids Value family as the 12GB box — EPYC 7542, RAID 1 U.2, VirtFusion, 10G shared — with the two resources that actually matter for Hermes + Next.js containers: **16 GB RAM** and **200 GB disk**. The extra $16/mo over a 12GB plan is the right spend. The Detroit LTO 16GB is the wrong 16GB.

## Why this one

| | GR 12GB Value | **GR 16GB Value** | Detroit LTO 16GB |
|---|---|---|---|
| CPU | 6× EPYC 7542 shared | **8× EPYC 7542 shared** | 8× old Xeon shared |
| RAM | 12 GB | **16 GB** | 16 GB |
| Disk | 150 GB U.2 RAID 1 | **200 GB U.2 RAID 1** | 200 GB RAID 5 SSD |
| Transfer | 8 TB | 10 TB | 10 TB |
| Feel for Docker/Next | Tight | Comfortable | Slower I/O, worse cores |

12 GB works if you are careful with limits. 16 GB is what you want when Hermes has Playwright on, `next dev` is running, and you pull a couple of extra containers without watching `free -h`. 200 GB also leaves room for images, `.next` caches, and snapshots without playing tetris.

VPSBenchmarks has this exact plan in Michigan on EPYC 7542. It is a mid-pack shared box, not a dedicated Ryzen node — fine for an always-on agent plus remote dev, not for local LLMs or heavy CI.

## How to use the 16 GB

Leave about 1–2 GB free. Example caps:

- Hermes: 3–4 GB  
- Next.js dev container: 4–6 GB  
- Extra tools (code-server, watchtower, etc.): 1–2 GB  
- OS + Docker: ~2 GB  

Add 4 GB swap as a cushion, not as RAM.

## Before you pay

Confirm the order is **Grand Rapids / DC4**, not Detroit. Same “Value KVM” label can sit in more than one Michigan site. From the office you want a few ms, not a hop to Detroit.

Still skip self-hosted mail. Calendar stays Proton + Google subscribe-only. This VPS is for Hermes and Next.js.

**Buy the 16GB Value in GR.** That is the plan that matches the workload without buying older LTO silicon for the same RAM number.

I’ll check whether RackGenius actually sells attachable block storage, and whether 200GB on that Value plan is enough without it.You do not need block storage for this box. RackGenius also does not really sell it the way DigitalOcean or Hetzner do.

Their Value plans are a single local disk: **200 GB RAID 1 U.2** on the hypervisor. VPSBenchmarks lists RackGenius as **no block storage / no object storage**. Checkout extras are backups, not attachable volumes. “Contact us for a custom plan” is a ticket to enlarge the VM disk, not a self-serve volume you can snap on and off.

## 200 GB vs your workload

Hermes + Next.js remote dev is compute and RAM bound, not disk bound.

Rough use of the 200 GB:

- Ubuntu + Docker: 15–25 GB  
- Hermes image + data: 5–15 GB  
- Next.js repo + `node_modules` + `.next`: 5–20 GB per project  
- A few extra images / layers: 20–40 GB  
- Logs, swap file: a few GB  

You should still have **100 GB+ free** unless you start hoarding images or keeping many full Next builds. That is the right size for a workhorse. Block storage would not make `next dev` faster. The U.2 RAID 1 already is the fast path.

## When block storage would matter

Buy extra disk only if you later store things that do not belong on the boot volume:

- Lots of build artifacts / container registries  
- Databases with growth  
- Media, backups, datasets  

Even then, on a single VPS the better moves are usually:

1. **Upgrade the plan** — 32 GB Value is 400 GB on the same U.2 RAID 1 family.  
2. **Ask RackGenius for a custom disk bump** on the existing VM (same node, one bigger virtual disk).  
3. **Object storage off-box** for backups and bulky files (Backblaze B2, Cloudflare R2, Wasabi). Cheaper per GB than a second “disk,” survives a VPS wipe, and does not eat IOPS on the Value node.

A network-attached volume, if they ever add one, is almost always **slower and higher latency** than the local U.2. Put OS, Docker, Hermes, and the active Next tree on local disk. Put cold copies elsewhere.

## What to buy instead of block storage

On checkout, take **their paid VirtFusion backups** if the price is small, *and* send a nightly offsite copy of `/var/lib/docker/volumes` plus your git remotes. Panel snapshots on the same host are not a second copy.

**Decision:** order the 16 GB Value with the included 200 GB. Do not wait on block storage. Revisit disk only after you have used the machine for a month and `df -h` says you are actually tight.

“Premium” here is not more RAM or more disk. Both plans are 16 GB / 200 GB / 10 TB. You are paying **double** for **fewer, faster, reserved cores** and a newer memory/storage stack.

## What actually changes

| | 16GB Value ($33) | 16GB Premium ($65) |
|---|---|---|
| Cores | **8 shared** EPYC 7542 @ ~2.9 GHz | **4 dedicated** Ryzen 9 7950X @ ~4.5 GHz |
| CPU kind | 2019 server chip, many tenants | 2022 desktop chip, your 4 threads reserved |
| RAM | 16 GB DDR4-2666 | 16 GB **DDR5-3600** |
| Disk | 200 GB RAID 1 **U.2** | 200 GB RAID 1 **Gen4 NVMe** |
| Network | 10 TB, shared 10G | 10 TB, shared 10G |
| Panel / SLA / IPs | Same | Same |

U.2 on Value is already NVMe, just an older server drive form. Premium’s Gen4 NVMe is usually snappier on 4k random I/O. The big gap is CPU, not the 200 GB number.

## Why “4 dedicated” can beat “8 shared”

Shared Value cores are timeslices on a busy EPYC 7542 node. When neighbors compile or steal cycles, your `next build`, `tsc`, and Docker pulls hitch. That is the Contabo-style problem, just on better Michigan hardware.

Dedicated Premium cores are reserved. Four 7950X threads at 4.5 GHz will crush Next.js / Node work that is bursty and often single-thread heavy. Eight slower shared Rome threads win only if you have many *simultaneous* processes and the node is quiet.

Hermes sitting idle does not care. Remote Next.js does.

## What you feel day to day

Premium is worth it if:

- You live in `next dev` / rebuilds / typecheck all day  
- You want the box to feel like a local workstation from Grand Rapids  
- You hate noisy-neighbor lag more than you hate $32/mo  

Value is enough if:

- Hermes is the main resident and Next.js is occasional  
- You are fine with “usually fast, sometimes soft”  
- You would rather put the extra money toward nothing, or a second small box later  

Benchmarks on these exact RackGenius lines show Premium winning web/single-thread, Value sometimes matching or beating it on raw multi-core and disk depending on the trial. Neither is a bad node. Premium is consistency plus clock speed.

## Practical pick

Same workload as before (Hermes + Next.js containers, no mail, no block storage):

- **Daily remote-dev workhorse:** Premium 16GB  
- **Always-on agent that you SSH into sometimes:** Value 16GB  

If the budget is “one machine in GR and I will live on it,” Premium is the one that matches that sentence. If the budget is “don’t double the bill for cores I won’t saturate,” stay on Value. RAM and disk are already the same; you are only buying CPU quality.

Buy the **16GB Value** in Grand Rapids ($33). Do not buy Premium unless you already know you hate waiting on `next build`.

Your real load is small once Cloudflare is doing the heavy parts.

## What actually runs on the VPS

| Piece | Where it lives | VPS cost |
|---|---|---|
| Hermes (remote models) | VPS | 2–4 GB RAM, little CPU while idle |
| One Next.js app at a time | VPS | 2–5 GB while `next dev` / a build |
| Extra projects for that site | Git + disk, not all running | Disk only |
| R2 blobs | Cloudflare | Zero on the VPS |
| CDN / DNS / tunnel | Cloudflare | Zero |
| Inference | API when needed | Zero GPU, some RAM only while a job runs |
| D1 + Workers | Cloudflare | Zero. D1 does not run on your server |
| Mongo for a couple of sites | Docker on the VPS *or* Atlas | ~0.5–2 GB if local and the DB is a dev copy |

One site at a time is the important constraint. You are not hosting five `next dev` processes. You are hosting Hermes + one Node app + maybe one Mongo container. That is a 16 GB Value workload, not a 4-core Ryzen workstation.

## Why not Premium

Premium is $32/mo more for 4 dedicated 7950X threads and DDR5/Gen4. That helps if you rebuild all day. It does almost nothing for:

- Hermes waiting on Telegram / an API  
- `next dev` with Turbopack on one app  
- A small Mongo dataset  
- Anything already on R2 / D1 / Workers  

Four dedicated cores would feel nicer on a cold `next build`. They will not change whether the stack fits. Save the $32 unless compile time is the thing that annoys you on Contabo today.

## Why not 12GB

12 GB works if Mongo stays in Atlas and Hermes has no browser tools. The moment you run Hermes + Next + local Mongo, you are in swap. 16 GB is the plan that matches “one site, several repos, sometimes a database container.”

200 GB local U.2 is enough. R2 holds blobs. D1 holds that site’s SQL. Do not add block storage.

## How to run it

Keep one Compose file:

- `hermes` — memory limit 3–4G  
- `web` — the current Next app, 4G  
- `mongo` — only when that project needs it, 1–2G, data on a named volume  

Stop Mongo when you are on the Workers/D1 site. Do not install Mongo as a host service. Point production-like env at Atlas or a shared dev cluster if you want the VPS even quieter.

Use Cloudflare Tunnel (or similar) to the box so you are not punching random ports. Repos stay in git; the server is not the source of truth.

## Order this

**16GB Value KVM, Grand Rapids, $33**  
8 shared EPYC 7542, 16 GB DDR4, 200 GB U.2 RAID 1, 10 TB.

Confirm the location is GR, not Detroit. Turn on their cheap panel backups if it is a few dollars, and keep git + R2 as the real copies.

Premium is the upgrade path if, after a month, builds feel soft because of CPU steal. Start on Value. Your architecture already moved the storage and serverless pieces off the VPS; the remaining box does not need Ryzen.

That changes the comparison. You are not upgrading RAM. You already have 16 GB. The question is only **CPU quality, disk, and Grand Rapids**, not “more memory for Hermes + Next + Mongo.”

## What you have vs what you would buy

| | Current box | GR 16GB Value $33 | GR 16GB Premium $65 |
|---|---|---|---|
| CPU | 4 threads, shared, likely steal | **8 shared** EPYC 7542 @ 2.9 GHz | **4 dedicated** 7950X @ 4.5 GHz |
| RAM | 16 GB | 16 GB | 16 GB |
| Disk | Contabo NVMe/SSD, often contended | 200 GB U.2 RAID 1 | 200 GB Gen4 NVMe RAID 1 |
| Place | Not next to you | Grand Rapids | Grand Rapids |
| Port | Often 200 Mbit on Contabo | Shared 10G | Shared 10G |

Same RAM on all three. Cloudflare still holds R2, D1, Workers, and inference. The VPS still only needs Hermes + one Next app + optional Mongo.

## What that means

**Value 16GB** is a sidegrade on memory and an upgrade on everything else you actually feel: local ping, more threads for Docker + Hermes + `next dev` at once, a quieter disk story than typical Contabo, and leaving their support/steal lottery. For “one website at a time,” eight shared Rome cores are plenty.

**Premium 16GB** is the upgrade if those four current threads are the bottleneck — builds crawling, `tsc` pinning a core, steal in `top`. You keep 4 cores, but they become reserved 7950X threads. That is the “this machine should feel like a workstation” spend. It is not required for Hermes or for Mongo on a small dev dataset.

**Do not** go to the 12GB plan. That is a RAM cut from what you already run.

## Pick

- Current 4 threads feel **fine** most of the day → **Value 16GB in GR**.  
- Current 4 threads feel **busy or stolen** whenever you build → **Premium 16GB in GR**.

Given one site at a time, R2/D1 off-box, and Hermes on remote models, start with **Value**. You already sized RAM correctly. Premium only pays back if CPU, not memory, is what you hate about the box you have now.

That local-rig detail is the whole decision.

You are not adding a side server. You are trying to **stop using a 4-thread / 16 GB workstation** and do Next.js + Hermes on a box in Grand Rapids. Dedicated Ryzen cores are the right instinct. A *smaller* Premium plan is the wrong size.

## What “replace the desk machine” requires

Your current machine is 4 threads and 16 GB. Remote VS Code / SSH still needs:

- OS + Docker  
- Hermes (2–4 GB if browser tools are on)  
- One `next dev` (2–5 GB)  
- Optional Mongo container (0.5–2 GB)

That is why the local box is 16 GB. Cutting RAM to 6–8 GB on a Premium VPS does not get you “the same machine, fewer dollars.” It gets you dedicated cores and an OOM the first time Next and Hermes overlap.

## RackGenius Premium, sized against that rig

| Plan | Cores | RAM | Disk | Price | vs your local box |
|---|---|---|---|---|---|
| 6GB Premium | 2 dedicated 7950X | 6 GB | 75 GB | $25 | Too small |
| 8GB Premium | 2 dedicated 7950X | 8 GB | 100 GB | $33 | Faster threads, **half the RAM, half the cores** |
| **16GB Premium** | **4 dedicated 7950X** | **16 GB** | **200 GB** | **$65** | Same shape, much faster cores |
| 24GB Premium | 6 dedicated | 24 GB | 300 GB | $97 | More than you need |

The 8GB Premium is tempting because it is the same $33 as Value 16GB. It is a different product: **2** reserved 4.5 GHz threads and 8 GB. Fine for Hermes alone. Not a replacement for a 4-thread / 16 GB dev rig.

## Best option

**16GB Premium KVM in Grand Rapids — $65.**

- 4 dedicated 7950X threads ≈ your current thread count, far higher clocks  
- 16 GB so Hermes + one Next app + Mongo can coexist  
- 200 GB so you are not rotating projects off disk  
- Local ping so remote-dev feels like the machine next to you, not a 80 ms Contabo

Value 16GB is still the better *server* for an idle agent. It is the worse *workstation replacement* because those 8 EPYC cores are shared. You already decided you care about dedicated cores. Follow that all the way to 4 cores / 16 GB, not 2 cores / 8 GB.

Cloudflare stays as it is: R2, tunnel, Workers, D1. Nothing about Premium changes that. You still do not need block storage or self-hosted mail.

If $65 is firm and you will never run Mongo on the box and Hermes stays chat-only with no Playwright, 8GB Premium can limp along. That is a compromise, not a replacement for the machine you described.

Two servers is cleaner on paper. At your scale it is usually worse money and more chores.

Sites of 50–100 pages, updates once or twice a week, R2 for blobs, Atlas for Mongo, D1/Workers already on Cloudflare — the VPS is only **Hermes + a remote editor + `next dev`**. That is one machine.

## What splitting actually buys

| | One box | Two boxes |
|---|---|---|
| Isolation | A fat `next build` can squeeze Hermes | Agent keeps running no matter what you compile |
| Cost | One IPv4, one backup, one tunnel | Two of each, every month |
| Ops | One Compose file, one SSH target | Two panels, two updates, two firewalls |
| Fit for your sites | Matches the workload | Matches a team or a production agent SLA |

Split when Hermes is customer-facing and must not hitch. You described a personal/work agent plus small marketing/content sites. That is not two-host territory yet.

Atlas is the right call. A local Mongo container was the main reason to fear 8 GB. Take that off the VPS and the RAM problem shrinks a lot.

## Better layouts, cheapest first

**1. One 8GB Premium ($33) — best default now**  
2 dedicated 7950X threads, 8 GB, 100 GB.

- Hermes capped at ~2 GB, no Playwright unless you bump the limit  
- One Next app at a time  
- Atlas + R2 + D1 off-box  
- Dedicated cores so remote-dev feels closer to the desk rig than shared Value cores will  

Tight if you turn on Hermes browser tools *and* a heavy Next compile together. Fine if you do not.

**2. One 16GB Premium ($65) — if the 8 GB box should feel like the old 16 GB rig**  
Same shape as the machine you are replacing. Buy this if you want zero thinking about limits.

**3. Two small boxes — only if isolation matters more than simplicity**  
Example: 4GB Value (~$9) for Hermes + 8GB Premium ($33) for Next = ~$42.

You pay $9 more than a single 8GB Premium, run two tunnels, and still have a weaker Next box than 16GB Premium. Worth it only if a Next OOM taking down Hermes is unacceptable.

Do not do two Premiums. Do not put Next on Value and Hermes on Premium. Dedicated cores belong on the compile box.

## Recommendation

Stay on **one server**. Use Atlas. Skip block storage and self-hosted Mongo.

- Want the simple, cheaper remote-dev setup: **8GB Premium in Grand Rapids**  
- Want it to feel like the 4-thread / 16 GB desk machine: **16GB Premium**  
- Split later only if Hermes is uptime-critical and you have already watched one process starve the other

For 50–100 pages and weekly edits, start with the **8GB Premium**. You can open a ticket and jump to 16GB Premium on the same product line if 8 GB feels small after a week of real remote-dev. Two VPS is solving a problem you do not have yet.

No. The desktop GUI is a big part of why that rig is 16 GB. The VPS will not run it.

A normal Windows or macOS desktop plus Chrome, Slack, the local editor, and background junk often sits at **6–10 GB before you even start Next**. Headless Ubuntu does not.

On the VPS you get something closer to:

- OS: ~0.3–0.5 GB  
- Docker: ~0.3 GB  
- Hermes without Playwright: ~0.3–1 GB (2–4 GB if you turn browser tools on)  
- One `next dev`: ~0.5–2 GB idle, maybe 3–4 GB during a build  
- code-server / VS Code Remote: a few hundred MB on the server; the heavy UI stays on your laptop  

With Atlas, R2, and D1 off-box, **8 GB usable on a headless box is more free RAM than 16 GB on a full desktop** for this stack.

You need 16 GB on the VPS only if several of these are true at once: Hermes with Playwright, two Next apps, local Mongo, and no memory limits. You already dropped Mongo and you work on one site at a time.

**8GB Premium is the right size.** Dedicated 7950X cores replace the “snappy workstation” part. You are not replacing Explorer, a window manager, and 40 browser tabs. Cap Hermes at 2 GB and Next at 4 GB and you will still have headroom. Move to 16GB Premium later only if `free -h` says otherwise after a real work week.

That usage pattern points at **8GB Premium**, not 16GB.

Most of the day the box is Hermes plus text/markdown workflows. That is idle RAM and almost no CPU. `next dev` is a four-hour burst, and even that is moving onto Hermes instead of you sitting in a local toolchain.

So you are paying for:

- Always-on: Hermes (small)  
- 4 hours: Hermes + one Next dev server  
- Never: desktop GUI, Atlas/R2/D1, five apps at once  

Two dedicated 7950X threads cover that burst. 8 GB covers the overlap without watching `free -h`. 16 GB would sit empty 20 hours a day.

**4GB Premium** ($17, 1 core) is enough for Hermes-only days and will feel small the moment Next and the agent run together.  
**6GB Premium** ($25, 2 cores) is the minimum I would actually try.  
**8GB Premium** ($33, 2 cores, 100 GB) is the one that matches “4 hours of real Next + all-day Hermes” without being a workstation you no longer have.

Stay on one server. Atlas stays off-box. Do not split boxes for this schedule. If those four hours later become all-day compiles again, bump the same Premium line to 16 GB. You are not there now.

I’ll map storage options that sit beside R2 so docs and images don’t eat the VPS disk.Keep website assets on R2. Do not put personal docs and photos on the 8GB Premium disk. That disk is for OS, Docker, Hermes, and the current repo.

Split storage by job.

## 1. Website files — stay on R2  

Public images, PDFs the site serves, user uploads. S3 API, Workers, no egress. Free tier is 10 GB; after that about $0.015/GB-month. Already the right tool. Use a **separate bucket** from personal files so a site deploy cannot touch tax PDFs.

## 2. Personal docs and private images — Proton Drive  

You already live in Proton Calendar. Drive is E2E encrypted, has desktop/mobile apps, Docs/Sheets, share links.

- Free: 5 GB  
- Drive Plus: 200 GB  
- Unlimited bundle: 500 GB with Mail/Calendar/VPN/Pass  

Use this for contracts, scans, notes, private photos you open like a folder. Not for a public image CDN. Hermes will not treat this as a first-class disk unless you copy files down.

## 3. Cheap bulk / backups — B2 or more R2  

Cold copies, VPS backups, photo dumps you rarely open.

- **Backblaze B2:** about $6–7/TB-month, S3-compatible, good for rclone from the VPS  
- **R2 Infrequent Access:** $0.01/GB-month plus a small retrieval fee, still no egress  
- **Wasabi:** simple flat TB pricing, 1 TB minimum, skip unless you already have a terabyte  

B2 wins if most of the bytes are “keep this, almost never serve it.” R2 wins if Hermes or a Worker will read those files.

## 4. Whole-laptop safety net — Backblaze Personal or IDrive  

If the question is “the Windows/Mac desk machine dies,” that is a backup product, not Drive and not R2. Backblaze Personal is unlimited per computer for a flat fee. Different problem than site blobs.

## 5. What not to use

- **VPS disk** as the library. 100 GB on Premium will vanish into images.  
- **Nextcloud / Immich on this VPS.** Wrong size machine, fights Hermes for RAM.  
- **Google Drive as the private vault** if Proton is already the privacy box. Fine as a second copy of non-sensitive files you must share with Google-only people.

## Simple layout

| What | Where |
|---|---|
| Site images, public PDFs | R2 bucket `sites` |
| Private docs, scans, personal photos | Proton Drive |
| Encrypted VPS / repo snapshots | B2 or a second R2 bucket `backups` |
| Working copy this week | Git + the VPS |

Hermes can use R2 with an API token for anything it should fetch. Keep Proton Drive for you, not as the agent’s object store, unless you are fine manually placing files where the agent can see them.

If you already pay for Proton Unlimited, start there for documents and only add B2 when Drive gets tight or you want a second off-site copy of the VPS.

You are overthinking it. That local array already solves “documents and images.” The VPS and R2 do not need to.

**512 GB NVMe** — OS, apps, current working files.  
**2 TB HDD RAID** — photos, scans, archives, old project folders. That is your library. RAID on site is not off-site backup, but it is plenty of working storage.

Use the cloud only where the local RAID cannot help:

- **R2** — files the websites must serve. Small, on purpose.  
- **Git** (GitHub/Forgejo/whatever) — source code, not binary dumps.  
- **One off-site copy** of the stuff you would actually cry about (tax docs, unique photos). Proton Drive if it is already in the Proton bundle, or a cheap B2/rclone job of a few folders. Not a second 2 TB in the cloud.

Do not put the photo library on the 8GB Premium VPS. Do not buy block storage. Do not stand up Nextcloud. Hermes can read what you copy into the project or into an R2 prefix; it does not need the RAID mounted over the network.

Daily shape:

- Desk machine: RAID + NVMe, same as now, for files  
- Laptop/office: remote VS Code into the GR VPS for Next + Hermes  
- Sites: Cloudflare + R2 + Atlas/D1  
- Worst-case: one encrypted folder synced off-site

The RAID is the document store. Treat cloud as publish + spare parachute, not a replacement for 2 TB you already own.

Google Meet will still run on the machine in front of you. A Grand Rapids VPS does not carry your camera, mic, or the Meet call. Offloading workflows helps Meet **only if** the spotty calls are caused by that workstation being busy, not by Wi‑Fi or a weak upload.

## What the VPS actually fixes

If Meet dies when you are also doing `next build`, Docker, big uploads, or the box is paging, remote-dev helps. The PC becomes a thin client:

- Browser + Meet  
- VS Code Remote / SSH into the VPS  
- Local files on the 2 TB RAID when you need them  

CPU, Node, Hermes, and container I/O move to Grand Rapids. The workstation stays quiet, so Meet gets the CPU and NIC.

## What it does not fix

- Bad Wi‑Fi, bufferbloat, or a 10–20 Mbit uplink  
- VPN + Meet + a full desktop on the same congested path  
- ISP drops  

Those stay local no matter how nice the 7950X VPS is. Wired Ethernet and a quiet uplink matter more for Meet than dedicated cores in a datacenter.

## How to aim the setup at that goal

Keep the plan you were already landing on:

- **One 8GB Premium in GR** for Hermes + the 4-hour Next burst  
- Atlas / R2 / D1 stay on Cloudflare  
- RAID stays the document/photo library  
- During a Meet: do not rclone the RAID, do not push big R2 trees, do not run Next on the **local** machine  

Optional but useful: on the home router, give Meet/UDP priority and cap backup jobs. If you can plug the workstation in with a cable, do that first. It is the cheapest Meet fix.

**Bottom line:** remote servers are the right move for “this PC is both my compiler and my conference phone.” They are the wrong move if Meet is failing on an empty machine. If calls are still bad when nothing is compiling, fix the path to the internet before you spend $33–65 on cores Meet will never use.

**Your wired Ethernet connection is perfect for this.** It gives you a stable, low-latency link from your desk to the router, so the only variable left is how fast the VPS responds from Grand Rapids.

Since you're in GR, **RackGenius in their Grand Rapids facility** is the clear winner for remote dev. You'll get single-digit to low teens ms ping instead of 80–120 ms to a distant host. That makes SSH, remote VS Code, and `next dev` feel snappy, almost like the machine is local.

For your exact workload — Hermes agent running most of the time + occasional Next.js dev on one site at a time, with R2/D1/Atlas handling storage and DB — the **16GB Value KVM VPS in Grand Rapids** at $33/month is the best fit. It gives you 8 shared EPYC cores, 16 GB RAM, and 200 GB fast U.2 storage, which comfortably covers Hermes, one Next container, and light extras without constant memory juggling.

The Premium 16GB at $65 is only worth it if you notice CPU steal slowing down builds on the Value plan — it gives you 4 dedicated Ryzen 7950X cores instead of shared ones. Most people in your spot start on Value and only upgrade if they feel lag.

RackGenius doesn't offer easy attachable block storage like some bigger hosts, so the included 200 GB is what you get. That's plenty — keep active projects and Docker stuff on it, and leave blobs on R2.

**Quick next step:** Order the 16GB Value in Grand Rapids, then test the ping from your wired desktop once it's up. If it feels great (it should), migrate your workflows over. Want me to walk through the Docker Compose setup for Hermes + Next on it?

The 12GB Premium is a solid middle. Just be precise about what you are buying.

You do not get more cores than the desk rig. You get **fewer threads that are much faster and reserved**.

## Versus the machine you have

| | Desk rig | 12GB Premium $49 |
|---|---|---|
| Threads | 4 | **3 dedicated** 7950X @ 4.5 GHz |
| RAM | 16 GB + full GUI | **12 GB DDR5**, no GUI |
| Disk | 512 GB NVMe + 2 TB RAID | 150 GB Gen4 NVMe RAID 1 |
| Role | Meet + desktop + leftover RAM | Hermes + 4 h of `next dev` |

Three 7950X threads at 4.5 GHz will beat a typical 4-thread desktop on Next builds and Node. That is clock and IPC, not core count. If the local box is already a 7950X or similar, the win is smaller and you only gain “the compile is not on the Meet machine.”

12 GB headless is more free RAM than 16 GB with Windows/macOS, Chrome, and the desktop. Atlas + R2 + D1 stay off the VPS, so 12 GB is comfortable for Hermes + one Next app. 150 GB is enough when blobs are not on the box.

## Versus the other Premium sizes

| | 8GB Premium $33 | **12GB Premium $49** | 16GB Premium $65 |
|---|---|---|---|
| Cores | 2 dedicated | **3 dedicated** | 4 dedicated |
| RAM | 8 GB | **12 GB** | 16 GB |
| Disk | 100 GB | **150 GB** | 200 GB |

8 GB works. 16 GB matches the old rig on paper. **12 GB / 3 cores is the one that matches how you actually work** without paying for RAM that sits empty 20 hours a day.

## Verdict

Take it **if it is Grand Rapids**, not Detroit.

You are paying $49 for dedicated Ryzen so Meet on the wired desktop stays quiet and the four-hour Next window feels fast. That is the right reason. You are not increasing core count; you are replacing 4 ordinary threads plus a GUI tax with 3 reserved 4.5 GHz threads and 12 GB that Hermes and Next can actually use.

Order GR 12GB Premium. Cap Hermes at ~3 GB and Next at ~5 GB. If a week of real use shows steal-free cores but RAM pressure, ask them to bump the same line to 16 GB.

That makes the 12GB Premium an upgrade, not a sidegrade.

**Four threads on a desktop almost always means two physical cores with hyperthreading** (2c / 4t). Each “thread” shares a core. A 7950X logical core at 4.5 GHz is a much stronger worker than one of those.

So you are going from:

- **2 real cores / 4 threads**, plus a desktop eating RAM  
- to **3 dedicated 7950X threads at 4.5 GHz**, 12 GB that the OS is not sharing with Explorer/Chrome  

That is more usable CPU for `next build` / Hermes, not less. RackGenius “dedicated logical cores” on Premium are reserved 7950X threads with the clock they advertise; they are not two people timeslicing one old dual-core.

12 GB on a headless box still beats 16 GB with a full GUI for this stack.

**12GB Premium in Grand Rapids is a good fit** for replacing that 4-thread desk machine as the compile/agent box, while Meet stays on the wired desktop.

No. Leave port 25 closed.

Resend sends site and app mail through their API or SMTP on **587/465**. Your VPS never talks to other mail servers on 25. Inbound 25 is only for a box that *receives* mail as `mail.yourdomain.com`. You are not doing that.

What you actually need outbound:

- **443** — Hermes APIs, Git, R2, Atlas, Resend’s API, package installs  
- **587 or 465** — only if some app sends via Resend SMTP instead of the HTTP API (Resend’s API on 443 is enough for most Next apps)  
- **SSH (22)** or Cloudflare Tunnel so you are not even exposing 22  

Do not ask RackGenius to open 25. Unused SMTP on a new VPS IP is how you get the range listed when something gets misconfigured. Resend already owns deliverability.

Still no. Agent mail does not use port 25 on your VPS.

Hermes (and similar agents) read and send through a **provider API or IMAP/SMTP submission**:

- Gmail / Google API  
- Proton Bridge or Proton API  
- Resend / similar for outbound  
- Sometimes IMAP on **993** and submission on **587**

None of that is “this VPS is an MX and speaks SMTP to the world on 25.” Receiving on the box would mean DNS `MX` → your IPv4 → Postfix on 25. Agent mail skips that. Mail stays at Google/Proton/Resend; the agent logs in as a client.

Keep 25 closed. If the agent needs a mailbox, point it at the existing provider, not at a mail stack on the 12GB Premium.

There is **no public code I can confirm is live today** (28 Aug 2026). RackGenius runs short holiday sales; the last official ones are expired.

**Recent official codes** (try at checkout; most will fail):

| Code | What it was | When |
|---|---|---|
| `FREEDOM25` | 25% off **lifetime** recurring | Memorial Day 2026 weekend |
| `SNOWEDIN40` | 40% off first month | Jan 2026 winter sale |
| `RG4LIFE25LET` | 25% off monthly for life | BF 2025, LET-only, ended 1 Dec 2025 |
| `ROUNDUP70LET` | 70% off first month | same BF window |

`FREEDOM25` is the only one that might still work if they never turned it off. Do not count on it.

**Where live codes actually show up**

1. Checkout on [rackgenius.com](https://rackgenius.com) — paste a code and see if the total drops  
2. Their Discord (they push client-only deals there)  
3. [blog.rackgenius.com](https://blog.rackgenius.com) and @RackGenius on X  
4. Ticket: “new customer, 12GB Premium GR — any first-month code?” They often honor a first-month cut if you ask  
5. **Genius Impact** if you are a student or nonprofit — discounted or free plans, separate from coupons  

They also advertise a **7-day money-back** for first-time customers, so you can order at $49, test ping from the wired desk, and cancel if the node is wrong.

On a $49/mo 12GB Premium, a working first-month 40% code is about $20 off once. A lifetime 25% code would matter more ($36.75/mo). Ask support before you pay if nothing applies at checkout.
