# StradaXR A.I. MAM

A visually rich media asset manager for macOS. Catalogue every clip, generate proxies that
always lead back to the camera original, mark and scrub fast, and search footage by what is
said and shown in it.

## What works today

| Area | Status |
| --- | --- |
| Catalog (SQLite): assets, proxies, markers / subclips, transcripts, tags, faces, people | Built, tested |
| Full-text search across file names, notes, transcripts, tags, markers and named people | Built, tested |
| SMPTE timecode at any frame rate, with drop-frame for 29.97 / 59.94 / 119.88 | Built, tested |
| Picture formats: no limit on size or frame rate. Tested with UHD and DCI 4K at 23.976p / 24p, 8K, 8.6K, and the ATSC rasters including 1080i and anamorphic 480i | Built, tested |
| Format identification: ProRes profiles, ProRes RAW, DNxHR, XAVC, and camera RAW (Blackmagic RAW, Sony X-OCN / RAW, ARRIRAW, REDCODE, Canon, Nikon) | Built; RAW identification tested only with stand-in files, not real camera media |
| Ingest of MOV / MP4 / ProRes / MXF / MKV and other FFmpeg-readable formats | Built, tested |
| Proxy generation (ProRes Proxy and H.264) carrying source timecode, reel name, audio layout | Built, tested |
| Native Apple pipeline (AVFoundation + VideoToolbox) for ingest, proxies and thumbnails, with no external tools needed | Built; exercised by the macOS CI tests, speed not yet measured on real footage |
| Several renders at once, automatic fallback between pipelines, every proxy verified against its source, achieved speed recorded per proxy | Built, tested |
| FFmpeg as an optional extra for formats Apple's frameworks cannot open | Built, tested |
| Source recall: from a proxy file, or from a Premiere XML / Resolve FCPXML / EDL, back to the high-res source | Built, tested |
| Send to Editor: clip lists with timecode, reel, markers and subclips as FCPXML (Final Cut Pro, DaVinci Resolve) or XML (Premiere Pro), pointing at originals or at proxies only | Built; structure tested, not yet imported into the three apps |
| Finding originals that were moved or renamed, by content fingerprint; re-importing a moved original keeps its markers, proxies and A.I. data | Built, tested |
| Proxies made automatically on import; clips can be dragged from the library into an editing app | Built; not yet tried by hand |
| Bins: nested bins, smart bins saved from a search, drag clips in; sort and group by volume, folder, reel, day or format; a Locations list of drives and shares | Built; logic tested, interface verified only by the CI screenshot |
| Network storage: shares remounted under another name are re-found automatically; path mappings translate this Mac's paths to and from an editor's Windows or Linux computer | Built, tested with simulated volumes |
| More on-device A.I.: names of people, places and organisations in the speech, sound classification, animals, and how many people are in frame | Built; runs in the macOS tests on synthetic clips, not yet judged on real footage |
| External A.I. hooks: a service of your choice receives each clip's transcript and tags (never the media) and can return a summary and extra tags | Built; request and reply handling tested, not yet run against a live service |
| Caption building, SRT and WebVTT export; shot, label and face-cluster post-processing | Built, tested |
| Camera RAW decoding (Blackmagic RAW, Sony X-OCN / RAW, ARRIRAW, REDCODE ...) | Not built. These clips are catalogued, searchable and relinkable; playback and proxies need each maker's SDK |
| macOS app: library grid with hover scrub, player with JKL shuttle, frame stepping, mark in / out, markers and subclips, inspector | Written; verified only by the macOS CI build, not yet run by hand |
| On-device A.I. (Apple Vision and Speech): speech-to-text, shot detection, scene / object labels, on-screen text, face grouping | Written; verified only by the macOS CI build, not yet run on real footage |

## Cinema logging, editable labels and scale

- **Dialogue** reads every live microphone channel (not just channels 1 and 2), cuts at quiet
  moments into short stretches, skips room tone, and is primed with set vocabulary plus the
  character names you give it (Settings › Dialogue & Storage). Slates ("scene 12A, take 3") become tags.
- **Picture labels** speak cinema: framing (single, two-shot, group), shot size (close-up to
  extreme wide), INT./EXT. Right-click any tag in the Coverage tab to rename or delete it; hide
  or reword a label across the whole catalogue in Settings › Picture Labels. Hand edits survive re-analysis.
- **Scale**: write-ahead-logged catalogue with indexes, resumable bulk import that skips clips already
  catalogued, lazy thumbnails, background offline checks, analysis and proxy runs queued a few at a
  time, adaptive frame sampling for long clips, and a proxy folder you can point at a large volume.
  Not yet measured against a real 200 TB library.

## How source recall works

Every proxy the app renders keeps the source's base file name, start timecode, duration,
frame rate, reel name and audio channel count — the properties Premiere Pro's *Attach Proxies*
and DaVinci Resolve's *Link Proxy Media* match on. It also embeds the catalog's asset ID in the
file's metadata. To get back to the original, it tries, strongest first:

1. the embedded asset ID (survives renaming and moving),
2. the catalogued proxy path,
3. the file name, narrowed by timecode and duration when camera names repeat,
4. the reel name.

Hand it a timeline exported from the NLE and it returns the same timeline pointing at the
sources, ready for online / conform.

## Working with an editor

1. **Send to Editor** writes the clips you are looking at — with markers and subclips — as a
   file the editing app imports. Choose *camera originals* when the editor has the sources
   (Final Cut Pro receives each clip with its proxy already attached), or *proxies only* when
   the editor works without them.
2. The editor cuts as usual. Every proxy matches its source's name, timecode, duration, frame
   rate and audio layout, and is checked against the source after rendering; a proxy that
   differs is flagged and never sent.
3. For a proxies-only edit, export the timeline from the editing app and open it with
   **Find Source**. Save the copy that points at the originals and import it to finish.

## Player keys

| Key | Action |
| --- | --- |
| Space | Play / pause |
| J / K / L | Shuttle reverse / stop / shuttle forward (press again to double speed) |
| ← / → | Step one frame (hold Shift for ten) |
| I / O | Mark in / mark out (Shift goes to the mark) |
| X | Clear marks |
| M | Add marker |

## Layout

- `Sources/StadaMAMCore` — platform-independent model, catalog, timecode, proxy planning,
  relink and analysis post-processing.
- `Sources/StadaMAMMedia` — ingest, proxy rendering, thumbnails and source recall via FFmpeg.
- `Sources/StadaMAMAI` — macOS-only Vision and Speech analysis.
- `App` — the SwiftUI macOS app.
- `Tests` — unit tests plus end-to-end tests that run real FFmpeg.

## Running a build without Xcode

Every build on GitHub packages the app. On the repository's **Actions** tab, open the latest
successful run and download the **StradaXR-AI-MAM** artifact. Unzip it twice to get
`StadaMAM.app`, move it to Applications, then clear the download quarantine once, because the
build is not signed with an Apple Developer ID:

```bash
xattr -dr com.apple.quarantine /Applications/StadaMAM.app
```

## Building

Requires an Apple Silicon Mac with macOS 14+ and Xcode 16+, and XcodeGen to create the Xcode project:

```bash
brew install xcodegen
```

FFmpeg is optional. Install it (`brew install ffmpeg`) only if you need formats Apple's
frameworks cannot open, such as MXF or MKV, and to run the full test suite.

Generate the Xcode project and open it:

```bash
xcodegen generate
```

```bash
open StadaMAM.xcodeproj
```

Run the tests (the media tests skip themselves when FFmpeg is not installed):

```bash
swift test
```

The catalog lives in `~/Library/Application Support/StadaXR MAM`; proxies and thumbnails in
`~/Movies/StadaXR MAM`.

## Known gaps

- Camera RAW decode, playback and proxies need a bridge to each maker's SDK (Blackmagic RAW,
  Sony RAW / X-OCN, ARRIRAW, REDCODE). Until then RAW clips are catalogued by name, size and
  format only; their raster and timecode are filled in where the container exposes them.
- Interlaced sources are deinterlaced in their proxies.
- Formats AVFoundation cannot play (MXF, MKV, ...) play through their proxy.
- Face grouping uses a general image embedding, so its matching threshold needs tuning on
  real footage; a dedicated face-recognition model is the next step.
- Speech-to-text uses Apple's recogniser; long clips may want a Whisper-based engine.
- Proxy speed on Apple Silicon has not been measured; each proxy records its speed so it can be.
