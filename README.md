# ReelMAM

A visually rich media asset manager for macOS. Catalogue every clip, generate proxies that
always lead back to the camera original, mark and scrub fast, and search footage by what is
said and shown in it.

## What works today

| Area | Status |
| --- | --- |
| Catalog (SQLite): assets, proxies, markers / subclips, transcripts, tags, faces, people | Built, tested |
| Full-text search across file names, notes, transcripts, tags, markers and named people | Built, tested |
| SMPTE timecode, including 29.97 / 59.94 drop-frame | Built, tested |
| Ingest of MOV / MP4 / ProRes / MXF / MKV and other FFmpeg-readable formats | Built, tested |
| Proxy generation (ProRes Proxy and H.264) carrying source timecode, reel name, audio layout | Built, tested |
| Source recall: from a proxy file, or from a Premiere XML / Resolve FCPXML / EDL, back to the high-res source | Built, tested |
| Caption building, SRT and WebVTT export; shot, label and face-cluster post-processing | Built, tested |
| Blackmagic RAW | Catalogued and relinkable; decoding needs the Blackmagic RAW SDK bridge (not built yet) |
| macOS app (library grid, player with mark in / out and JKL, inspector) | In progress |
| On-device AI (speech-to-text, faces, scene and text recognition) | In progress |

## How source recall works

Every proxy ReelMAM renders keeps the source's base file name, start timecode, duration,
frame rate, reel name and audio channel count — the properties Premiere Pro's *Attach Proxies*
and DaVinci Resolve's *Link Proxy Media* match on. It also embeds the catalog's asset ID in the
file's metadata. To get back to the original, ReelMAM tries, strongest first:

1. the embedded asset ID (survives renaming and moving),
2. the catalogued proxy path,
3. the file name, narrowed by timecode and duration when camera names repeat,
4. the reel name.

Hand it a timeline exported from the NLE and it returns the same timeline pointing at the
sources, ready for online / conform.

## Layout

- `Sources/ReelMAMCore` — platform-independent model, catalog, timecode, proxy planning,
  relink and analysis post-processing.
- `Sources/ReelMAMMedia` — ingest, proxy rendering, thumbnails and source recall via FFmpeg.
- `Tests` — unit tests plus end-to-end tests that run real FFmpeg.

## Building and testing

Requires Swift 6 and FFmpeg (`brew install ffmpeg`).

```bash
swift test
```

The media tests skip themselves when FFmpeg is not installed.
