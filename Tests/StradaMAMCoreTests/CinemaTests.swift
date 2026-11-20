import XCTest
@testable import StradaMAMCore

final class CinemaTests: XCTestCase {
    private func tag(_ label: String, kind: TagKind = .label, start: Double = 0, end: Double = 2,
                     edited: Bool = false) -> SceneTag {
        SceneTag(assetID: "a", kind: kind, label: label, confidence: 0.9, startSeconds: start, endSeconds: end,
                 userEdited: edited)
    }

    func testRulesHideRenameAndMerge() {
        let rules = [LabelRule(match: "Structure", action: .hide),
                     LabelRule(match: "indoor", action: .rename, replacement: "INT."),
                     LabelRule(match: "inside", action: .rename, replacement: "INT.")]
        let out = LabelRules.apply(rules, to: [tag("structure"), tag("indoor", start: 0, end: 2),
                                               tag("inside", start: 2, end: 4), tag("beach")])
        XCTAssertEqual(out.map(\.label).sorted(), ["INT.", "beach"])
        XCTAssertEqual(out.first { $0.label == "INT." }?.endSeconds, 4)
    }

    func testRulesNeverTouchHandEditedTags() {
        let rules = [LabelRule(match: "structure", action: .hide)]
        XCTAssertEqual(LabelRules.apply(rules, to: [tag("structure", edited: true)]).count, 1)
    }

    func testShotScale() {
        XCTAssertEqual(ShotScale.classify(largestFaceHeight: 0.4), .closeUp)
        XCTAssertEqual(ShotScale.classify(largestFaceHeight: 0.15), .mediumShot)
        XCTAssertEqual(ShotScale.classify(largestFaceHeight: 0.02), .wide)
        XCTAssertEqual(CinemaVocabulary.framing(headcount: 2), "two-shot")
        XCTAssertNil(CinemaVocabulary.framing(headcount: 0))
    }

    func testSlateParsing() {
        XCTAssertEqual(SlateParser.parse("Scene twelve A take three")?.label, "Scene 12A, Take 3")
        XCTAssertEqual(SlateParser.parse("SC 45 TK 12 ROLL A003")?.label, "Scene 45, Take 12, Roll A003")
        XCTAssertEqual(SlateParser.parse("scene twenty three, take 2")?.label, "Scene 23, Take 2")
        XCTAssertNil(SlateParser.parse("take it easy and go home"))
    }

    func testSpeechChunkerCutsInQuietPlacesAndFlagsSilence() {
        // 100 s of speech with a pause at 43 s, then 20 s of room tone.
        var levels = [Double](repeating: 0.1, count: 1000) + [Double](repeating: 0.001, count: 600)
        levels[430] = 0.0005
        let chunks = SpeechChunker.plan(levels: levels, window: 0.1)
        XCTAssertEqual(chunks.first?.end ?? 0, 43.05, accuracy: 0.2)
        XCTAssertEqual(chunks.first?.start, 0)
        XCTAssertEqual(chunks.last?.end ?? 0, 160, accuracy: 0.01)
        XCTAssertTrue(chunks.last!.level < SpeechChunker.silenceLevel)
        for (a, b) in zip(chunks, chunks.dropFirst()) { XCTAssertEqual(a.end, b.start, accuracy: 1e-9) }
    }

    func testEditedTagsSurviveReanalysisAndRulesApplyToCatalogue() throws {
        let catalog = try Catalog.inMemory()
        let asset = try catalog.save(Asset(sourcePath: "/Volumes/A/clip.mov", durationFrames: 240))
        try catalog.replaceTags(assetID: asset.id, kinds: [.label], with: [
            SceneTag(assetID: asset.id, kind: .label, label: "structure", confidence: 1, startSeconds: 0, endSeconds: 2),
            SceneTag(assetID: asset.id, kind: .label, label: "indoor", confidence: 1, startSeconds: 0, endSeconds: 2)])
        try catalog.saveEdited(SceneTag(assetID: asset.id, kind: .label, label: "best take", confidence: 1,
                                        startSeconds: 1, endSeconds: 3))
        try catalog.apply(LabelRule(match: "structure", action: .hide))
        try catalog.apply(LabelRule(match: "indoor", action: .rename, replacement: "INT."))
        XCTAssertEqual(try catalog.tags(forAsset: asset.id).map(\.label).sorted(), ["INT.", "best take"])
        XCTAssertEqual(try catalog.search("best").count, 1)
        // Re-analysis replaces machine tags only.
        try catalog.replaceTags(assetID: asset.id, kinds: [.label], with: [])
        XCTAssertEqual(try catalog.tags(forAsset: asset.id).map(\.label), ["best take"])
        // Default rules install once and a deleted rule stays deleted.
        try catalog.installDefaultLabelRulesIfNeeded()
        let rules = try catalog.labelRules()
        XCTAssertFalse(rules.isEmpty)
        try catalog.deleteRule(rules[0])
        try catalog.installDefaultLabelRulesIfNeeded()
        XCTAssertEqual(try catalog.labelRules().count, rules.count - 1)
    }

    func testFaceReferencesAreBoundedPerPerson() throws {
        let catalog = try Catalog.inMemory()
        let asset = try catalog.save(Asset(sourcePath: "/Volumes/A/clip.mov", durationFrames: 240))
        let person = Person(name: "Ana")
        let sightings = (0..<40).map {
            FaceSighting(assetID: asset.id, timeSeconds: Double($0), x: 0, y: 0, width: 0.1, height: 0.1,
                         embedding: FaceSighting.data(from: [1, 0, 0]))
        }
        try catalog.replaceFaces(assetID: asset.id, with: sightings)
        try catalog.assign(sightingIDs: sightings.map(\.id), to: person)
        XCTAssertEqual(try catalog.faceReferences(perPerson: 10).count, 10)
    }
}
