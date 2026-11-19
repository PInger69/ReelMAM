# StadaXR A.I. MAM

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
| Apple Silicon proxy pipeline: hardware decode, GPU scaling and hardware encode, with automatic fallback, several renders at once, and the achieved speed recorded per proxy | Built; fallback and queueing tested, the hardware paths themselves not yet run on a Mac |
| Source recall: from a proxy file, or from a Premiere XML / Resolve FCPXML / EDL, back to the high-res source | Built, tested |
| Caption building, SRT and WebVTT export; shot, label and face-cluster post-processing | Built, tested |
| Camera RAW decoding (Blackmagic RAW, Sony X-OCN / RAW, ARRIRAW, REDCODE ...) | Not built. These clips are catalogued, searchable and relinkable; playback and proxies need each maker's SDK |
| macOS app: library grid with hover scrub, player with JKL shuttle, frame stepping, mark in / out, markers and subclips, inspector | Written; verified only by the macOS CI build, not yet run by hand |
| On-device A.I. (Apple Vision and Speech): speech-to-text, shot detection, scene / object labels, on-screen text, face grouping | Written; verified only by the macOS CI build, not yet run on real footage |

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

## Building

Requires macOS 14+, Xcode 16+, and:

```bash
brew install xcodegen ffmpeg
```

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
- FFmpeg is found on the system rather than bundled with the app.
