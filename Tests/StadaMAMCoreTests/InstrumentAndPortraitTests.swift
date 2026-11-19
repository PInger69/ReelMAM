import Foundation
import Testing
@testable import StadaMAMCore

@Suite struct InstrumentVocabularyTests {
    @Test func knowsInstrumentsHoweverTheRecogniserSpellsThem() {
        #expect(InstrumentVocabulary.isInstrument("bongo_drum"))
        #expect(InstrumentVocabulary.isInstrument("Electric Guitar"))
        #expect(InstrumentVocabulary.isInstrument("violin_fiddle"))
        // Things that only sound like instruments.
        for other in ["computer_keyboard", "seabass", "microphone", "speech", "car_horn", "bell_pepper", "music"] {
            #expect(!InstrumentVocabulary.isInstrument(other))
        }
    }

    @Test func keepsAnInstrumentThatTheNormalBarWouldDrop() {
        // A guitar small in frame: outranked by the person and the room, below the usual 0.35.
        let frame: [(label: String, confidence: Double)] = [
            ("person", 0.9), ("indoor", 0.7), ("guitar", 0.22), ("piano", 0.05), ("string_instrument", 0.18), ("sofa", 0.3)]
        let kept = InstrumentVocabulary.extras(in: frame, known: InstrumentVocabulary.picture, alreadyKept: ["person", "indoor"],
                                               minimumConfidence: InstrumentVocabulary.pictureConfidence)
        #expect(kept.map(\.label) == ["guitar", "string instrument"])   // best first, underscores gone
        // Nothing is added twice, and nothing that is not an instrument.
        let again = InstrumentVocabulary.extras(in: frame, known: InstrumentVocabulary.picture, alreadyKept: ["guitar"],
                                                minimumConfidence: InstrumentVocabulary.pictureConfidence)
        #expect(again.map(\.label) == ["string instrument"])
        // Under dialogue: speech wins the moment, the piano is still noted.
        let moment: [(label: String, confidence: Double)] = [("speech", 0.8), ("piano", 0.35), ("music", 0.5), ("cello", 0.1)]
        let heard = InstrumentVocabulary.extras(in: moment, known: InstrumentVocabulary.sound, alreadyKept: ["speech"],
                                                minimumConfidence: InstrumentVocabulary.soundConfidence)
        #expect(heard.map(\.label) == ["piano"])
        let many = (0..<8).map { (label: Array(InstrumentVocabulary.sound).sorted()[$0], confidence: 0.9) }
        #expect(InstrumentVocabulary.extras(in: many, known: InstrumentVocabulary.sound, alreadyKept: [], minimumConfidence: 0.3).count == 3)
    }
}

@Suite struct PortraitTests {
    private func sighting(_ asset: String, time: Double = 1, x: Double, y: Double, w: Double, h: Double, person: String? = nil) -> FaceSighting {
        FaceSighting(assetID: asset, personID: person, timeSeconds: time, x: x, y: y, width: w, height: h,
                     embedding: Data([0, 0, 128, 63]))
    }

    @Test func portraitIsASquareAroundTheFaceInsideTheFrame() {
        // A face in the upper right of a 1920x1080 frame (the stored box counts up from the bottom).
        let face = sighting("a", x: 0.7, y: 0.6, w: 0.1, h: 0.2)
        let rect = face.portraitRect(imageWidth: 1920, imageHeight: 1080)
        #expect(rect.side == 410)                       // the taller side, 216, plus 45% each way
        #expect(rect.x == 1235 && rect.y == 119)        // centred on the face: (1440, 324)
        // At the very edge the square is pushed back inside rather than running off the picture.
        let corner = sighting("a", x: 0.95, y: 0.0, w: 0.05, h: 0.1).portraitRect(imageWidth: 1920, imageHeight: 1080)
        #expect(corner.x + corner.side <= 1920 && corner.y + corner.side <= 1080 && corner.x >= 0 && corner.y >= 0)
        // A face filling the frame cannot ask for more than the frame has.
        let huge = sighting("a", x: 0, y: 0, w: 1, h: 1).portraitRect(imageWidth: 1920, imageHeight: 1080)
        #expect(huge.side == 1080 && huge.y == 0)
    }

    @Test func thePortraitIsThePersonsLargestFace() throws {
        let catalog = try Catalog.inMemory()
        let asset = try catalog.save(Asset(sourcePath: "/Volumes/RAID/A.mov", fileSize: 1, width: 1920, height: 1080,
                                           durationFrames: 240))
        let person = Person(name: "Ada")
        let small = sighting(asset.id, time: 1, x: 0.1, y: 0.1, w: 0.05, h: 0.08)
        let large = sighting(asset.id, time: 5, x: 0.3, y: 0.3, w: 0.2, h: 0.3)
        let stranger = sighting(asset.id, time: 2, x: 0.5, y: 0.5, w: 0.4, h: 0.5)
        try catalog.replaceFaces(assetID: asset.id, with: [small, large, stranger])
        try catalog.assign(sightingIDs: [small.id, large.id], to: person)
        #expect(try catalog.portraitSighting(forPerson: person.id)?.id == large.id)
        #expect(try catalog.portraitSighting(forPerson: "nobody") == nil)
    }
}
