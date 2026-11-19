# Cuts editor, export for a full editor, and the Rec.709 look

Status as of 19 November 2026. This covers the Mac app. The browser app for remote editors is not
changed; the sequence model and the exports are in `StadaMAMCore` so it can use them later.

"Start the Cuts editor in APP" was read as **the Mac app first**. If the browser app was meant,
the model, layout and exports below are the part that carries over; the editor screen would be new.

## What there is now

| Part | Where | State |
| --- | --- | --- |
| Sequences in the catalogue: create, rename, duplicate, delete; cuts: add, insert, reorder, trim, remove | `Sources/StadaMAMCore/Sequence.swift`, migration `v8-sequences-and-looks` in `Catalog.swift` | Built, tested |
| Timeline export: FCPXML, Premiere XML, CMX 3600 EDL | `Sources/StadaMAMCore/EditorExport+Sequence.swift` | Built; structure and timecode tested; **not imported into Final Cut Pro, Resolve or Premiere** |
| Package export: timelines, originals copied whole, manifest, every copy checked | `Sources/StadaMAMCore/SequencePackage.swift`, `Sources/StadaMAMMedia/SequencePackageExporter.swift` | Built, tested on stand-in files; **not run on camera originals or a real external disk** |
| Playing a sequence from proxies | `Sources/StadaMAMMedia/SequencePlayback.swift` | Built, tested on FFmpeg-made clips (decoded frames checked) |
| Rec.709 viewing look, `.cube` LUTs | `Sources/StadaMAMCore/ViewingLook.swift`, `Sources/StadaMAMMedia/ViewingLookRenderer.swift` | Built, tested on FFmpeg-made clips (decoded frames checked); **not seen on real Apple Log footage** |
| The editor in the Mac app | `App/CutsEditor.swift`, `App/Views/SequenceEditorView.swift`, edits to `ContentView.swift`, `ClipDetailView.swift`, `PlayerController.swift`, `StadaMAMApp.swift` | **Compiles; not seen running** (see the end) |

## How it works in the app

The first sequence screen (a strip of cut cards with in and out timecodes, plus and minus buttons and
"To Playhead") was replaced on 19 November 2026 after the owner tried it: it asked people to think like
an editor. The screen is now built so that someone who has never edited can use it. The sequence model,
playback, exports and package are unchanged.

**Getting there.** Sequences are listed in the sidebar under Bins; the plus makes one. Clicking one
opens the cut screen. The library stays beside it. Done, in the toolbar, goes back to the ordinary clip
view; the cut is saved as it is built.

**The screen** has the picture on top and the storyboard below. The picture shows either the clip
picked in the library or the cut; a two-way switch above it says which. Picking a clip in the library
shows that clip.

**1. Hold to keep.** With a clip showing, hold the large Keep button (or the space bar) while the part
you want plays, then let go. That stretch is added to the end of the cut. No in or out points.
- Pressing starts the clip playing if it was paused; letting go pauses it again. If it was already
  playing it carries on, so several parts can be kept in one pass.
- **A press that keeps less than half a second of the clip adds nothing.** It counts as a tap, which
  plays or pauses the clip. So a slip of the finger never adds a cut of a frame or two.
- Held past the end of the clip, the part runs to the clip's last frame.
- While held, the button turns red and counts up ("Keeping 3 seconds"); on release a line says what was
  added ("Added 6 seconds to your cut").

**2. Pick by the words.** If the clip has a transcript, its sentences are listed beside the picture.
Click a sentence to choose it (the clip jumps there), shift-click to choose a run. Add to Cut makes a
part covering those words; the chosen words can also be dragged onto the storyboard, onto the card
they should go before. A quarter of a second is left before the first word and after the last, but
never reaching into a neighbouring sentence that was not chosen. A clip with no transcript shows no
words panel.

**3. Storyboard.** The cut is a wrapping row of picture cards: a frame, the clip's name and a plain
length ("24 seconds").
- Click a card to play the cut from there. Play, in the storyboard's header, plays the whole cut.
- Drag a card onto another to move it there.
- Drag the grip on a card's left or right edge to change where the part starts or ends; the card's
  picture shows the frame at that edge as it moves. An edge stops at the ends of the clip and leaves at
  least a quarter of a second. The chosen card also has Shorter and Longer buttons (a second off or on
  the end).
- Remove: the button on the chosen card, the Delete key, or drag the card to the bin strip under the
  storyboard. (Dragging a card out of the window cannot be detected reliably, so "drag off" became
  "drag to the bin".)
- **Undo and Redo** are in the storyboard's header, and Command-Z / Shift-Command-Z work while the
  picture has the keyboard. Every add, move, trim and remove can be undone, back to an empty cut, for
  as long as the sequence stays open. A removed part comes back in its place.

**Fine tune** is a switch in the storyboard's header, off by default and remembered. On, it shows
timecode on the picture and the cards, the frame rate, and for the chosen card the frame-nudge and
To Playhead controls. Nothing in the default view uses timecode or editing terms.

**An empty cut** says one line: "Pick a clip from the library, then hold Keep while the part you want
plays."

The ordinary clip view keeps its marks: I and O, then E or the button beside the subclip scissors,
still add a marked range to the open sequence, for people who work that way.

The rules above (the half-second press, the padding around words, the limits on an edge, plain
lengths, undo) are in `Sources/StadaMAMCore/CutGestures.swift`, with tests, so the browser version can
follow the same ones.

Cuts only: no transitions, no effects, no audio mixing. Each clip's own sound plays with its picture.

## Decisions made

**The model.** A sequence is a named, ordered list of cuts. A cut is a clip plus an in and out point in
source frames, counted from the clip's first frame with the out point being the last frame shown. This
is the convention the existing subclip markers use, and a saved subclip can be added as a cut directly
(the catalogue call exists; there is no button for it yet). `Timeline.swift` was left as it is: it reads
other tools' timelines for source recall and is not a model of a cut. The new exports read back through
it, which the tests use as a check.

**Frame rate.** A sequence takes its frame rate and drop-frame setting from the first clip added. A
clip at another rate keeps its real-time length on the timeline (a 2-second cut is 2 seconds), and its
source timecode is always written in its own rate. Lengths are added as exact fractions, so mixed
rates do not drift. Timeline timecode starts at 01:00:00:00.

**Relinking.** Every export carries, for each clip: the full path of the camera original, the file
name, the reel name, and source timecode in and out (drop-frame written with a semicolon). FCPXML and
the Premiere XML also carry the clip's start timecode, duration, raster and audio channel count. The
Premiere XML puts each audio channel on its own track, linked to its picture.

**EDL reel names are written in full by default**, not cut to the eight characters of strict CMX 3600,
because a truncated camera reel name no longer identifies the clip. A strict option exists in the code
(`TimelineExportOptions.strictEDLReels`) but is not on screen. A clip with no reel uses its file name.

**The package.** A new folder, never written over an earlier one:

```
<Sequence name> package/
    <Sequence name>.fcpxml        Final Cut Pro, DaVinci Resolve
    <Sequence name>.xml           Premiere Pro
    <Sequence name>.edl
    manifest.json                 what was copied, from where, its checksum, where the cut uses it
    checksums.sha256              the same checksums in the form `shasum -a 256 -c` reads
    Media/<volume>/<folders>/…    each original the cut uses, once, whole
```

- Originals are **copied whole**, each once however many cuts use it, with their volume and folder
  names kept so two cards holding the same file name cannot collide.
- Each file is hashed (SHA-256) while it is written, then **read back from the destination and hashed
  again**; a copy that does not match is deleted and the export stops.
- If any original is unreachable, or the disk has too little room, **nothing is written**.
- The timeline files in the package point at the copies in the package, where they are when written.
  On another Mac with the disk mounted under the same name they open linked; otherwise the editing
  app relinks by file name, reel and timecode.
- Files that sit beside an original with the same name and the extension `.sidecar`, `.RMD`, `.xmp` or
  `.cdl` are copied with it.
- This runs in the Mac app on the hub and writes to a folder chosen there. It opens no network
  connection. Nothing was added to the remote server.

**The look does not touch any file.** It is applied to each frame on its way to the screen, in the clip
player and in the sequence viewer. Proxies stay as they were made.

## How each kind of source is shown today (before the look)

Read from the code; nothing in the pipeline converted colour before this work.

| Source | How it is decoded | What colour handling there was |
| --- | --- | --- |
| ProRes 422, H.264, HEVC in MOV / MP4 (includes Apple Log and Apple Log 2 clips) | AVFoundation / VideoToolbox. Played from the proxy if there is one, else straight from the original (`MediaLibrary.playablePath`) | None by the app. `AVPlayer` shows the file according to its colour tags. Apple Log footage is tagged as log, which the system does not convert, so it shows flat and grey |
| ProRes RAW | Same path (VideoToolbox decodes it) | None by the app |
| MXF, MKV, DNxHR, XAVC and other FFmpeg-only formats | No direct playback. FFmpeg makes a proxy; the proxy plays through AVFoundation | None. The FFmpeg proxy commands in `Proxy.swift` scale and set a pixel format only; there is no colour filter |
| Blackmagic RAW (`.braw`) | **Not decoded.** `DecodePath.blackmagicRAW`, `canRender` is false | No picture: no playback, no proxy, no thumbnails. The viewer says the maker's SDK is needed |
| ARRIRAW, REDCODE, Sony X-OCN / RAW, Canon and Nikon RAW, CinemaDNG | **Not decoded.** `DecodePath.unsupported` | No picture, as above |

This confirms the README: Blackmagic RAW and the other camera RAW formats are catalogued, searchable
and relinkable, and have no picture anywhere in the tool. In the cuts editor such a clip cannot be
marked by eye, since there is nothing to look at. A cut made from one (for example by adding the whole
clip) keeps its place, plays as black with a notice, and exports and packages normally, provided the
catalogue knows its frame rate, timecode and length; for RAW files the catalogue often does not, and
the exported timecodes for those cuts would then be wrong. This is the main limit on "full raw
formats" today and is not solved here.

Proxies are made without any colour conversion (the native path re-encodes the decoded picture as it
is), so a proxy of a log clip is still log. That is what lets the look be applied at viewing time.
Whether a proxy keeps the original's log *tag* was not checked, so the look is chosen from the
original's tags, not the proxy's.

## The Rec.709 look

**How the conversion is chosen.** Apple writes a log identifier into the picture track of Apple Log
footage: `com.apple.rec2020.apple-log` for Apple Log, `com.apple.apple-wide-gamut.apple-log` for
Apple Log 2 (named in the macOS SDK headers). Import now records a clip's colour tags, including that
identifier, in the catalogue's existing `colorSpace` field. Clips imported earlier get theirs read the
first time they are opened, from the original, if it is online. From that:

- Apple Log 2 identifier: **Apple Log 2 to Rec.709**.
- Apple Log identifier: **Apple Log to Rec.709**.
- Anything else: no look. The clip is shown as it is.

**Manual override, per clip.** The Look menu offers Automatic, No look, either built-in conversion, any
`.cube` file already in use on another clip, and Load .cube LUT…. The choice is stored in the
catalogue (`clipLook` table) and follows the clip into every sequence.

**What the built-in conversions are.** They are built from the published definitions: the Apple Log
curve from Apple's Apple Log Profile White Paper, Rec.2020 primaries for Apple Log, Apple Wide Gamut
primaries for Apple Log 2, a matrix to Rec.709, a highlight roll-off, and a gamma 2.4 output. They give
a normal-looking picture with 18 % grey at about 45 % video level. They are **not Apple's own LUT** and
will not match it exactly; the roll-off in particular is this tool's choice. Where an exact match to
another tool matters, load that tool's `.cube` instead.

**`.cube` files.** 3D LUTs of any size are read (larger than 64 steps are resampled to 64, the most
Core Image takes), including files with a `DOMAIN_MIN` / `DOMAIN_MAX` other than 0 to 1. A file with
only a 1D LUT is refused with a message. The LUT is referenced by path, not copied into the catalogue;
if the file goes missing the clip is shown without it and a message says so.

**There is no built-in conversion for Blackmagic footage.** Blackmagic RAW has no picture here at all.
ProRes recorded in Blackmagic Film can be viewed by loading Blackmagic's own `.cube` on those clips.

**How it is applied.** A Core Image colour cube on each frame, through an `AVVideoComposition`, with
Core Image's colour management switched off so the table receives the camera's own code values. The
tests decode real frames through it and check the pixel values, including for a clip tagged with wide
primaries.

### Follow-on: the look for remote editors in the browser

Not built in this task. Two ways, with what each takes:

1. **Bake it into the watermarked viewing copy** (recommended). The copy served to editors is already
   re-encoded by FFmpeg to add the StradaXR mark (`WatermarkRenderer`). Baking the look is one more
   filter in that same pass, before the mark: `lut3d=file=<look>.cube`. `ColorLUT.cubeText` already
   writes the built-in conversions as `.cube` files, so the browser copy and the Mac app would use the
   same table. It also needs: the output tagged Rec.709; the look made part of the marked copy's cache
   key, so changing a clip's look makes a new copy and the old one is dropped; and a decision on
   whether the download an editor cuts with is the Rec.709 copy too (it would be, unless a second,
   log, marked copy is kept). No extra encoding time, since the copy is being encoded anyway. The
   copies already made would have to be made again.
2. **Apply it live in the browser.** The video is drawn through WebGL with the LUT as a 3D texture.
   The served copy stays log and the editor can switch the look. It costs more: a custom player
   surface in place of the plain video element (full screen, picture-in-picture and power use all get
   worse), and the downloaded proxy is still log, so the editor needs the LUT in their editing app.

Either way the mark stays on every served picture and the audit trail is unaffected.

## Not done, not tried

- **The new cut screen has not been seen running.** It compiles (built into `build-cuts/`, so the
  owner's open copy in `build/` was not touched). This session cannot capture the screen. Untried by
  hand, each of which depends on how SwiftUI delivers events and could need adjusting:
  - holding the Keep button, and holding the space bar (it relies on key-down and key-up reaching the
    picture area, and on key repeat being ignored);
  - dragging a card's edge without the card itself starting to move, and the picture following it;
  - dragging cards to reorder, to the bin, and dragging chosen words onto the storyboard;
  - shift-click in the words list; Command-Z from the keyboard (the Undo button does not depend on it);
  - how the cards wrap and how the screen looks at small window sizes.
  The rules underneath are tested: what a hold keeps and the short-press rule, words to a cut with
  padding, reorder, edge limits, plain lengths, and undo and redo against the catalogue.
- **No real camera footage**: no Apple Log or Apple Log 2 clip, no Blackmagic file, no camera card.
  Detection of Apple Log relies on the identifier named in Apple's headers and has not met a real file.
- **Nothing was imported into Final Cut Pro, DaVinci Resolve or Premiere Pro.** The files are
  well-formed and carry the right numbers; whether each app accepts every detail (mixed frame rates,
  the linked audio in the Premiere XML, long reel names in the EDL) is unknown until tried.
- **No package was written to a real external disk** or made from large files; the largest test file
  is 9 MB.
- A clip whose pictures differ in size from the first clip plays in the sequence viewer at the first
  clip's size; not checked how that looks.
- The running copy of the app was built before the catalogue change. The first launch of a new build
  adds three tables to the catalogue (`sequence`, `sequenceCut`, `clipLook`); nothing existing is
  altered.

## Questions for the owner

1. **Which editing app does the team finish in**: Premiere Pro, DaVinci Resolve or Final Cut Pro? That
   one should be tried first with a real export, and the other two can wait.
2. **Blackmagic RAW**: is the plan Blackmagic's SDK inside the tool, or proxies made in Resolve and
   attached? Until one of them exists these clips cannot be cut by eye here.
3. **Handles**: the package copies originals whole. If partial copies are wanted later (only the used
   part plus handles), how much handle: 1 second, 2 seconds, 5? Note that trimming camera RAW and
   long-GOP files without re-encoding is format-specific and is real work; whole files are the safe
   default.
4. **Where do the LUTs come from**: the DP or DIT's show LUT, each camera maker's standard LUT, or
   should the built-in conversions do? And should a LUT be set once for a whole camera, reel or shoot
   day rather than clip by clip, which is all there is now?
5. **Should a package export be written to the audit trail?** Today the trail records remote access
   only. A package is the one path by which originals leave the hub (on a disk), so it may belong
   there; it would be a small addition to the remote sharing code.
6. **EDL reel names**: full camera reel names (current), or strict eight characters for an older
   finishing system?
7. **Sound**: the timelines carry each clip's own audio channels. Is sound recorded separately
   (double system)? If so, the cut needs the synced sound, which nothing here handles.
8. **Spanned and multi-file clips** (RED `.RDC` folders, clips split across cards): the package copies
   the file the catalogue points at and the four kinds of sidecar listed above. Are any of the
   production's cameras recording clips as more than one file?
9. **Remote editors**: should they be able to build sequences in the browser, and should the look they
   see be baked in (option 1 above)?
