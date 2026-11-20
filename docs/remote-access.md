# Remote access to proxies

Status: design agreed in outline; **step 1 (the server) is built and tested**, everything else is
planned. Build order is at the end.

## Goal

Editors on MacBook Pros, anywhere on the internet, browse the shoot's catalogue and pull proxies
from the M1 Mac mini ingest hub, with no VPN, mesh or router changes on either side. They install
the same app, open an invite link, and see the library.

Fixed by the owner: one Mac mini is the hub (120 TB local plus network sources); editors set
nothing up; the experience is seamless; only metadata and proxies leave the building, never
originals.

## What is built (step 1)

New target `Sources/StradaMAMRemote` (macOS, Network.framework), tests in
`Tests/StradaMAMRemoteTests` (20 tests, including real sockets and TLS).

| Piece | File | What it does |
| --- | --- | --- |
| HTTP/1.1 parsing | `HTTP.swift` | Strict request parser (no bodies, 16 KB header cap), response model, `Range` parsing |
| Editors and tokens | `EditorGrants.swift` | `GrantStore` (own SQLite file), `invite`, `authenticate`, `revoke`; `InviteLink`; failed-sign-in throttle |
| The API | `RemoteAPI.swift` | Router: catalogue and proxy routes below. Pure request-in / response-out |
| The server | `RemoteServer.swift` | `NWListener`; loopback-only plain HTTP (behind a tunnel) or TLS with an identity; streams files in 512 KB chunks with back-pressure; keep-alive, idle timeout, connection cap; `PinnedCertificateDelegate` for the client side |

Routes (all `GET`/`HEAD`; every `/v1` route needs `Authorization: Bearer <token>`):

| Route | Returns |
| --- | --- |
| `/healthz` | `ok`, unauthenticated, for the tunnel's health check; says nothing about the library |
| `/v1/me` | the signed-in editor: name and locked initials (or none yet) |
| `POST /v1/me/initials?value=MR` | the one write an editor makes: lock in 2–4 letters or digits at first sign-on. Same value again is fine; a different one is refused (409) until the owner resets it |
| `/v1/info` | server name, API version, clip count, the signed-in editor's name |
| `/v1/assets?q=&bin=&day=&utcOffset=&hasProxy=1&limit=&offset=` | page of clips: name, reel, picture format, frame rate, duration, start timecode, audio channels, notes, original size, and the best ready proxy (id, bytes, etag, Mbps). `q` is the catalogue's full-text search (names, notes, dialogue, tags, markers, people); `day` is the shoot day |
| `/v1/assets/{id}` | the clip plus markers and subclips, dialogue, tags, and the bins it is in |
| `/v1/search?q=` | search hits with time offsets and snippets |
| `/v1/bins` | bin tree with clip counts (smart bins included) |
| `/v1/manifest?bin=&day=&q=` | every proxy a bin / day / search would download, with sizes and the total, for the background downloader |
| `/v1/proxies/{proxyID}` | the **marked copy** of the proxy (428 until initials are locked; 202 + `Retry-After` while it is being made; 503 if the render failed) with: `Range`, `If-Range`, `ETag` / `If-None-Match`, `HEAD`. The only route that returns media |

The service is read-only apart from the initials route. Not exposed: source paths, bookmarks, fingerprints, volume layout beyond the volume name, face
embeddings (biometric), anything writable. There is no route that accepts a file path.

## Threat model

What is worth stealing: **unreleased feature footage** (even at proxy quality), plus the dialogue
transcripts (script content). What is worth breaking: the mini, which holds the only copy of the
ingest state.

| Threat | Control |
| --- | --- |
| Internet scanner finds the endpoint | Nothing answers without a valid token, except `/healthz` (a constant string). Tokens are 256 random bits, so guessing is not feasible. Failed attempts are throttled per caller (10 per 5 minutes, then 429); valid tokens are never throttled, so a stranger cannot lock editors out |
| Invite link leaks (chat, email) | Token is per editor and revocable at once; invites can carry an expiry. Link is a credential: send it over a private channel. Planned: single-use claim that swaps it for a device-bound credential |
| Editor leaves, or laptop is lost | Revoke that editor; the next request fails (tested, including mid-session). Other editors are unaffected |
| Database copy or backup of the mini leaks tokens | Only SHA-256 of each token is stored; the token is shown once at invite time. The editor's app keeps its copy in the Keychain |
| Path traversal / reading originals through the API | No path in any request. A proxy is addressed by catalogue ID; the file must be `ready`, verified against its source (`mismatch == nil`), a regular file whose symlink-resolved path is inside a configured proxy folder, and not the source path of any catalogued clip. All tested, including symlink escapes |
| Eavesdropping or tampering on the way | Behind a tunnel: the tunnel's public TLS. Direct or via a passthrough relay: the mini terminates TLS with its own certificate and the invite carries its SHA-256 fingerprint; the client trusts only that (tested) |
| A relay operator reading footage | Only if the relay terminates TLS (Cloudflare does). With a TCP passthrough relay and a pinned certificate it sees ciphertext and sizes only |
| Slow-client or connection-flood abuse | Idle timeout 60 s, 128-connection cap, header size cap, no request bodies, chunked streaming so memory stays flat |
| Editor shares the footage onward | The clean proxy is never served (every copy carries the StradaXR mark), and the tamper-evident audit trail records which editor pulled which proxy, when and how much. That shows who had access; it does not identify the leaker from a leaked file, and cannot stop someone filming a screen |
| Mini is compromised through the server | Small surface (about 1,000 lines, read-only, no parsing of untrusted bodies). Run the server in the app's process only while Remote sharing is switched on; planned: move it into a separate low-privilege helper |

Decided by the owner: **every editor sees the whole catalogue**, so there are no per-bin permissions.
Out of scope for now: end-to-end encryption of files at rest on the editors' laptops.

## Authentication and invites

1. Owner chooses **Invite editor**, types a name. `GrantStore.invite` makes a `sxr_…` token,
   stores only its hash.
2. The app builds `stradaxr://join?host=<public host>&token=<token>[&fp=<cert sha256>]` and the
   owner sends it. The app registers the `stradaxr` scheme; opening the link in Remote mode
   stores host and token in the Keychain.
3. Every request sends `Authorization: Bearer <token>`. For AVPlayer streaming, set it through
   `AVURLAssetHTTPHeaderFieldsKey` (works on current macOS); the fallback is a local
   `AVAssetResourceLoader` that adds the header.
4. **Revoke** sets `revokedAt`; checked on every request.

## Watermark, initials and the audit trail

Two separate things, both required by the owner.

### Watermark

Every remote proxy carries the production's mark, **StradaXR**, in the **lower-left quarter** of the
picture: semi-transparent white with a soft shadow, inside that quarter (4% in from the left edge,
5% up from the bottom, scaled to fit). It is the same for every editor. A test checks that every
visible pixel of the mark is inside the lower-left quarter at three resolutions. The position is one
constant (`WatermarkImage.marginX/marginY`) if it needs to move.

- **Clean proxies never leave the mini.** The first time any editor asks for a proxy, the mini makes
  the marked copy in the background (`WatermarkRenderer`: the proxy plus a transparent overlay image
  through FFmpeg, HEVC at the remote bitrate, AAC audio), checks it against the source like any
  proxy, and caches it. Until then the answer is `202` with `Retry-After`, and the downloader polls.
  With the policy set to required and no renderer, nothing is served.
- **One shared copy per proxy**, so cost is one re-encode per proxy and about one proxy's size of
  disk, not per editor. Resume works because the copy is a static file.
- **Relinking is unchanged.** The copy keeps the source's name, start timecode, reel, frame rate,
  channel count and asset ID, and is verified against the source. It leaves out the source path that
  ordinary proxies embed, so the mini's folder layout does not go to editors.
- **It is a brand mark, not a tracing tool.** Every editor's copy is identical, so a leaked file does
  not say who leaked it. Who downloaded it is the audit trail's job. If leak tracing is ever
  required, a per-editor or forensic mark is a separate piece of work.

### Initials

At first sign-on the app asks for 2–4 letters or digits and sends them once (`POST /v1/me/initials`).
The server locks them to that editor; they cannot be changed from the editor's side, only reset by
the owner. They name the editor in every audit entry, and proxy downloads are refused (`428`) until
they are set.

### Audit trail

Built to be tamper-evident and to fail closed (`AuditLog`, in its own database file).

| Property | How |
| --- | --- |
| Complete | Every authenticated request, including refused ones, is an entry: time (ms), editor id, name and initials, method, path, sorted query, status, bytes promised, `Range`, caller address. Failed sign-ins are entries too (no token / unknown token / revoked / expired), attributed to the editor when the token is known. Owner actions (invite, revoke, reset initials) are entries. Tokens are never written down |
| Actual bytes | A second `transfer` entry, linked to its request, records the bytes really sent and whether the download `complete`d or was `interrupted` |
| Written first | The entry is stored before any response is sent. If it cannot be stored, the request gets `503` and nothing is served (tested) |
| Append-only | Database triggers refuse any update or delete of an entry (tested) |
| Tamper-evident | Each entry holds an HMAC-SHA256 over its contents and the previous entry's hash, keyed with a secret kept in a separate file (mode 0600, `loadOrCreateKey`). `verify()` re-computes the chain and names the first bad entry. Editing an entry, removing one from the middle, or rebuilding the chain without the key all fail verification (tested, with the triggers deliberately removed) |
| Truncation | Cutting entries off the end leaves a valid shorter chain, so it is caught by an **anchor**: the latest sequence number and hash, noted somewhere the file cannot reach. `verify(against: anchor)` fails if the log is shorter or differs |
| Durable | Own SQLite file, write-ahead log with `synchronous = FULL`: an entry that was acknowledged survives a crash or power loss |
| Not floodable | After 10 failed sign-ins in 5 minutes from one address nothing more is logged for it, so a scanner cannot fill the disk |
| Exportable | `exportJSONLines()`: one JSON object per line, oldest first |

**Limits, stated plainly.** Someone with both the log file *and* the key can rewrite history, so keep
the key out of the file's backups and (when the owner screen exists) record an anchor regularly, for
example emailed to the owner once a day. Bytes in a `request` entry are what the response promised;
the `transfer` entry is what was sent. A server crash between the two leaves a request without a
transfer, which is itself the record that it never finished. Nothing here stops an editor
screen-recording footage they are allowed to see. Failed sign-ins past the throttle limit are not
logged individually.

There is no screen for the log yet (step 3).

## The browser app for editors (built)

Decision: editors use the **browser**, not an installed app. The mini serves the app itself
(`WebApp.swift`: one HTML page, CSS and about 250 lines of JavaScript, no outside libraries), so there
is nothing for an editor to install or update, and it works on any computer with Safari or Chrome.

- **Open an invite:** `https://<host>/join#<token>`. The token is after the `#`, which a browser never
  sends to the server, so it cannot reach a log. The page trades it (`POST /v1/session`) for an
  `HttpOnly`, `SameSite=Strict`, `Secure` cookie, removes it from the address bar, and from then on the
  cookie authenticates everything, including video playback and downloads, which cannot carry a header.
  Revoking the editor kills the cookie at once. Sign out clears it.
- **First sign-on:** the page asks for the editor's initials (2–4 letters) and locks them.
- **Browse:** bins (nested, smart bins marked), shoot-day picker, search across names, dialogue, tags,
  markers and people; a table of clips with reel, picture format, duration, start timecode, proxy size.
- **Play:** a clip opens with its marked copy in the player, with source timecode following the
  playhead (drop-frame correct, checked against the Swift code's own test values), markers and dialogue
  that seek on click, the search match highlighted, Space / J / K / L and frame stepping (← →, Shift for
  ten). While the mini makes the editor's copy the first time, the page waits and polls.
- **Download:** one clip at a time through the browser's own download. Bulk pulling of a whole bin or
  day into a folder, in the background, with resume, is **not** something a browser can do reliably
  (Safari cannot choose a folder or run background downloads; only Chrome can write to a chosen
  folder), so that stays the small downloader still to build. If editors mostly view and review, the
  browser alone is enough.
- **Security:** a strict content security policy (own files only, no framing, no referrer, no outside
  loads), the page builds everything with `textContent` and never as HTML (a test fails if the script
  uses `innerHTML` or any outside address) because clip names, notes and dialogue are data, not markup;
  writes (initials, sign-in, sign-out) need an `X-StradaXR` header that another website cannot add, so a
  forged cross-site request is refused.
- **Certificate:** a browser needs a certificate it trusts. Directly on the owner's line the mini now
  gets one itself from Let's Encrypt and renews it (next section). Behind a tunnel the tunnel supplies
  it. The mini's self-signed certificate (pinned by the native design) makes browsers warn, so it is
  only for a native client.
- **Not yet:** poster thumbnails in the table (they must come from the marked copy, so they exist only
  after someone has opened a clip, or after the overnight pre-render), and viewing on a phone is untested
  (the layout adapts to narrow widths).

## Directly on the owner's line, with a trusted certificate (built, not yet tried on the real line)

The owner has a symmetric 1 Gbps business fibre line with a static address and no hosting
restrictions, so the first thing to try is the simplest: editors connect straight to the mini, and
nobody else carries the video. This is the *Directly to this Mac* setting with *Get a certificate
browsers trust* switched on.

What the owner sets up once:

1. A domain name for the mini (a new domain, or a subdomain of an existing one) with an **A record**
   pointing at the line's static address. Any DNS host works; nothing is needed from it but that record.
2. On the router, **port 443 → the mini's sharing port** (8443 by default) and **port 80 → the mini's
   port 80**.
3. In *Settings › Remote Sharing*: the address, the trusted-certificate switch, and their own tick on
   the Let's Encrypt Subscriber Agreement. Nothing is requested from Let's Encrypt without that tick.

How it works (`PublicCertificate.swift`):

- `ACMEClient` speaks the ACME protocol (RFC 8555) to Let's Encrypt with an account key kept on the
  mini. It proves control of the name with the **HTTP check**: Let's Encrypt fetches
  `http://<name>/.well-known/acme-challenge/<token>` from the internet, which is why port 80 has to
  arrive at the mini, at first issue and at every renewal.
- The plain port 80 is a separate, tiny listener (`ChallengeResponder`): it answers those checks and
  redirects everything else to the HTTPS address in the settings (never to a Host header a stranger
  sent). It does not serve the catalogue or a proxy, even with a valid token (tested).
- The certificate and its intermediate are stored in a passphrase-protected file (0600) and sent as a
  chain, since browsers do not all fetch a missing intermediate. The loose private key is deleted.
- **Renewal** is automatic: while sharing is on the hub checks every six hours and renews once two
  thirds of the certificate's life has gone (day 60 of 90 today; it follows shorter lifetimes as Let's
  Encrypt brings them in). The listener swaps to the new certificate without cutting off downloads in
  progress. If a renewal fails the old certificate keeps serving, the reason shows on the owner's
  screen, and it tries again later.
- **Rate limits:** Let's Encrypt allows only a few failed checks an hour per name, so after a failure
  the next attempt waits 12 minutes, and the error says what to fix (DNS record, router port 80).
- Issues and failures are written to the audit trail as owner events.
- Invites carry no certificate fingerprint in this mode (it changes at each renewal; the system's
  trust is used instead).

Tested against a stand-in authority that enforces the protocol (signed requests, nonces, a real HTTP
fetch of the check, a root → intermediate → server chain) and a client that trusts only that root
and checks the name like a browser. **Not tested:** the real Let's Encrypt service, the real router,
and real browsers on the real name. The first real request is the test; `ACMEClient.letsEncryptStaging`
exists for a dry run that does not count against the limits but there is no switch for it on the
owner's screen yet.

Still open for this route: the mini's public address is visible to anyone who looks up the name, so
the sign-in throttle and the connection cap are what face the internet (no third party absorbs a
flood); a DNS-based check (no port 80) and automatic DNS updates for a line without a static address
would need the DNS host's API and are not built.

## Getting through the network with no router changes

The mini makes only *outbound* connections; editors connect to a public address that the relay
forwards to the mini.

Candidate: **Cloudflare Tunnel** (`cloudflared` on the mini). It needs no inbound ports and gives
a public hostname and certificate.

**Terms risk, not resolved.** I could not confirm from Cloudflare's own text whether tunnelled
traffic is covered by the CDN restriction on serving a disproportionate amount of video or other
non-HTML content that is not hosted on a Cloudflare service (Stream, R2, Images). Cloudflare's 2023 post
([Goodbye, section 2.8](https://blog.cloudflare.com/updated-tos/)) moved that restriction into the
CDN service terms; whether Tunnel is "the CDN" for this purpose was not clear from what I found, and
a forum reading says video over Tunnel is still not allowed. At roughly 5 editors × 36 GB per day (maths
below) this is exactly the kind of use that could get the account throttled. **Action for the owner:**
ask Cloudflare in writing, or assume it is not allowed for bulk proxies.

Because of that the server does not care what carries it. The options, in the order to try them:

1. **Cloudflare Tunnel**, if Cloudflare confirms in writing, or for the catalogue / API only while
   bulk proxy download goes another way.
2. **Own relay on a rented server** (a small VPS with generous included traffic): the mini holds
   an outbound connection to it; it passes editors' TLS straight through to the mini (SNI
   passthrough, e.g. with `rathole` or `frp`, or a few hundred lines of our own). Costs a few euros
   a month, no third-party terms, the relay cannot read the traffic, and it is exactly what the
   direct-TLS mode and the certificate pin in the invite are for. This is my recommendation if
   option 1 is not clean.
3. **Peer-to-peer (QUIC with NAT hole punching) with relay fallback.** Best throughput and no relay
   bandwidth, but several editors will sit behind networks where hole punching fails, and it is the
   most code. Only worth it if relay bandwidth cost or latency turns out to matter.

Hosted mesh "funnel" products are the same question as option 1 (a third party carrying video)
and are not simpler than option 2, so they are not on the list.

## Bandwidth maths

Remote proxy target: **8–12 Mbps** video (planned HEVC preset; H.264 fallback), audio compressed.
Existing proxies use uncompressed PCM audio: a 2-channel track is 1.5 Mbps, but a 16-channel
location recording is 12 Mbps, which on its own breaks the budget. The remote preset keeps the
**channel count** (editing apps refuse to attach a proxy whose layout differs) but encodes it as
AAC at 64–96 kbps per channel.

| Quantity | Figure |
| --- | --- |
| 10 Mbps | 1.25 MB/s, 4.5 GB per hour of footage |
| A shoot day, assuming 8 hours of camera time | ~36 GB of proxies (~43 GB at 12 Mbps) |
| Whole library, 120 TB of originals at an assumed average 600 Mbps | ~440 hours, ~2 TB of proxies (about 1.7%); 200 TB is ~3.3 TB |
| Pulling one day at the editor's 25 / 50 / 100 Mbps real downlink | 3.2 h / 1.6 h / 48 min |
| Live scrubbing of one proxy | needs ≥ 10 Mbps sustained, so the editor's first look can stream but bulk work must be pulled |
| Mini uplink, 5 editors each pulling a day | 180 GB/day out; at saturation 1 Gbps carries 5 editors at ~200 Mbps each |

The studio line is **symmetric 1 Gbps from Bell** (about 900 Mbps real), so the mini's uplink is
not the constraint: it carries 5 editors streaming (50 Mbps) with room to spare, a shoot day leaves it
in about 6 minutes, and the first backfill of the whole proxy library (2–3 TB) takes 5–6 hours. The
limit becomes each editor's own downlink. Still planned (step 4): a per-editor rate cap of roughly
100–200 Mbps so one bulk pull cannot starve other editors or ingest.

Consequence for transport: with this uplink the cheapest, simplest path is option 2 (own relay with
TLS passthrough). Storing proxies in S3 / CloudFront would only add cost (about $450 a month of
egress at the numbers above) and put unreleased footage in a cloud account; keep it as a fallback if
the studio line ever becomes the problem. The relay needs a 1 Gbps port and a large traffic allowance.
Confirmed by the owner: it is a business fibre link with no restriction on hosting.

Resilience: downloads are resumable (`Range`, validated with `If-Range`, so a proxy re-rendered
mid-download restarts instead of splicing two files). The downloader works through the manifest in
the background, a few files at a time, and survives sleep and network changes.

## Relink on the editor's side (Find Source)

Proxies are untouched by transport: they keep the source's base name, start timecode, duration,
frame rate, reel name and channel count, plus the embedded asset ID. An editor cutting in Premiere or
Resolve with downloaded proxies exports a timeline; **Find Source** on the mini (or any copy of the
catalogue) resolves it to the originals exactly as today. Editors do not hold the catalogue's paths,
so conform stays with the owner. A read-only `resolve` route (timeline in, original names / reels /
timecodes out, no paths) is a possible later addition if editors need to check their own conform.

## Build order

1. **Server slice (done).** Token auth, catalogue read routes, proxy range serving, loopback and TLS
   modes, pinning helper, 20 tests.
2. **Remote proxy preset (done).** `ProxyPreset.remoteHEVC` ("Remote – HEVC 1080p (≈10 Mbps)"):
   height capped at 1080, 10 Mbps average (scaled down for smaller pictures, never below 3 Mbps), 12 Mbps
   peak on the FFmpeg paths, short GOP without B-frames, `hvc1` tag. Audio keeps every track's channel
   count but mono and stereo tracks are AAC (96 / 160 kbps); a single track wider than 2 channels
   stays PCM on the native path, and the FFmpeg path uses AAC up to 8 channels in total. Same
   `-timecode`, reel and embedded asset ID as every proxy, and the existing `ProxyVerifier` checks it
   against the source. Works in the native (AVFoundation) pipeline and all three FFmpeg ones; the
   server ranks it first. Tested on synthetic clips through native and FFmpeg-software; **not yet
   measured on real camera footage**, so actual bitrate, quality and render speed are unknown, and
   the native HEVC encoder's bitrate is a target, not a guarantee (check it on a real day's footage
   before relying on the 36 GB/day figure). Not yet tried in Premiere or Resolve.
2b. **Watermark, initials lock and audit trail (done, server side).** As described above: 33 server
   tests plus FFmpeg tests that render a marked copy, check it against the source, confirm no server
   path is inside it, and confirm the mark is in the picture and in the lower-left quarter.
3. **Owner side in the app (built, not yet seen running).** *Settings › Remote Sharing* (`App/RemoteSharing.swift`, `App/Views/RemoteSharingView.swift`, over `RemoteHub`): on/off switch, how editors reach this Mac (relay passthrough / tunnel / direct), public address and port, proxy folder in use, editors list (status, initials, last seen, bytes pulled) with Invite, Reset Initials and Revoke, and the audit trail (entry count, Verify, Export, Copy Anchor, recent activity). The self-signed certificate is made by `ServerIdentity`. The relay or tunnel agent itself is not started by the app yet: the screen shows the local port to point it at. Compiles in Xcode; planned from here: Settings › Remote Sharing: switch on, pick proxy folder(s) and the
   watermark cache folder, choose transport; Invite editor / list / Revoke / Reset initials; audit log view
   with filters, Verify, Export, and a daily emailed anchor; the audit key in the Keychain (or a 0600 file); show the link and a QR. Start the server and the relay
   or tunnel agent as one switch. Needs the `stradaxr` URL scheme in `Info.plist`; if the app is
   ever sandboxed it also needs the network server entitlement (it is not sandboxed today).
3b. **Continuous ingest (done).** Watch folders (*Settings › Watch Folders*) import new clips by themselves and make both the local proxy and the `remoteHEVC` proxy, so editors always have something to pull; remote proxies are written under `<proxy folder>/Remote/` so they never replace the local ones. See `Sources/StradaMAMMedia/IngestEngine.swift`.
4. **Operations.** Pre-render the day's marked copies overnight and evict old ones, per-editor rate cap and concurrent
   stream cap, last-seen in the editors list, generate and persist the self-signed certificate,
   token rotation, expiry defaults.
5. **Editor mode (browser version done, see above).** Still to build: the background downloader; the original plan was a Remote mode in the same app: a `RemoteClient` (the wire types are already
   `Codable` and shared), a read-only library view that reuses the grid, search, bins and dialogue
   panes against `/v1`, streaming playback through AVPlayer with the auth header, and the background
   downloader (first-run initials prompt; polls on 202): pick a bin or day, work through the manifest, resume on failure, put files in the
   editor's proxy folder under the names and structure the NLEs expect.
6. **Transport.** Decide the Cloudflare question or stand up the own relay (option 2), put the
   health check on `/healthz`, document the owner's setup, and measure from a real remote
   connection.
7. **Hardening.** Single-use invite claim with a device-bound credential, helper process for the
   server, per-editor / forensic watermarking only if the production's insurer or distributor requires tracing from the file.

## Open questions for the owner

1. ~~Mini's upload bandwidth~~: answered, symmetric 1 Gbps (Bell). Bell business fibre, no hosting restriction (confirmed).
2. ~~Watermark and audit trail~~: decided. StradaXR mark, lower-left quarter, same for everyone; initials locked at first sign-on; robust audit trail. Still to ask the insurer or distributor: is that enough, or is per-editor tracing from the file itself required?
3. Which transport: ask Cloudflare, or go straight to a small relay server we control?
4. How many editors at once, and do they stream to review or only pull and cut locally?
5. ~~Permissions~~: every editor sees the whole catalogue (decided).
