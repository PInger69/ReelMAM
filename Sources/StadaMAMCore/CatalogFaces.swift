import Foundation
import GRDB

extension Catalog {
    /// Re-analysis of a clip: swaps in its new faces and groups them into people.
    /// The clip's previous, already-grouped sightings stay in the matching pool as references, so
    /// people (and their names) whose only footage is this clip are re-attached rather than recreated.
    /// Finishes by removing people who are left with no name and no sightings.
    public func replaceAndGroupFaces(assetID: String, with sightings: [FaceSighting]) throws {
        let previous = try faces(forAsset: assetID).filter { $0.personID != nil }
        try replaceFaces(assetID: assetID, with: sightings)
        let known = Dictionary(uniqueKeysWithValues: try people().map { ($0.id, $0) })
        let pool = try faceReferences() + previous + faces(forAsset: assetID).filter { $0.personID == nil }
        for (personID, sightingIDs) in FaceClusterer.cluster(pool) {
            try assign(sightingIDs: sightingIDs, to: known[personID] ?? Person(id: personID))
        }
        try deleteEmptyPeople()
    }

    /// Deletes people who have no name and no sightings. Named people are never removed.
    /// Returns how many were deleted.
    @discardableResult
    public func deleteEmptyPeople() throws -> Int {
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM person
                WHERE (name IS NULL OR TRIM(name) = '')
                  AND id NOT IN (SELECT DISTINCT personID FROM faceSighting WHERE personID IS NOT NULL)
                """)
            return db.changesCount
        }
    }
}

extension Catalog {
    /// The sighting that shows a person best, for their picture in the People list: the largest face.
    public func portraitSighting(forPerson personID: String) throws -> FaceSighting? {
        try db.read {
            try FaceSighting.filter(Column("personID") == personID).order(sql: "width * height DESC, timeSeconds").fetchOne($0)
        }
    }
}

extension FaceSighting {
    /// The square to cut out of a frame of `imageWidth` × `imageHeight` pixels to show this face
    /// with some room around it, in pixels from the top-left corner. The stored box is
    /// normalised with its origin at the bottom-left.
    public func portraitRect(imageWidth: Int, imageHeight: Int, margin: Double = 0.45) -> (x: Int, y: Int, side: Int) {
        let w = Double(imageWidth), h = Double(imageHeight)
        let centreX = (x + width / 2) * w
        let centreY = (1 - (y + height / 2)) * h
        let side = min(max(width * w, height * h) * (1 + 2 * margin), w, h)
        let left = min(max(centreX - side / 2, 0), w - side)
        let top = min(max(centreY - side / 2, 0), h - side)
        return (Int(left.rounded()), Int(top.rounded()), max(Int(side.rounded(.down)), 1))
    }
}
