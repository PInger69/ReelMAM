import Foundation
import GRDB

/// Editing what the A.I. found: one tag at a time, or a rule that corrects a label everywhere.
extension Catalog {
    // MARK: One tag

    /// Adds a tag by hand (a person's own note on a moment) or saves a changed one.
    public func saveEdited(_ tag: SceneTag) throws {
        var tag = tag
        tag.userEdited = true
        try db.write { db in
            try tag.save(db)
            try Self.reindex(db, assetID: tag.assetID)
        }
    }

    public func deleteTag(_ tag: SceneTag) throws {
        try db.write { db in
            _ = try tag.delete(db)
            try Self.reindex(db, assetID: tag.assetID)
        }
    }

    /// Every catalogued file and its size, to recognise clips an import has already done.
    public func knownFileSizes() throws -> [String: Int64] {
        try db.read { db in
            var sizes: [String: Int64] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT sourcePath, fileSize FROM asset")
            while let row = try rows.next() { sizes[row["sourcePath"]] = row["fileSize"] }
            return sizes
        }
    }

    // MARK: Rules

    public func labelRules() throws -> [LabelRule] {
        try db.read { try LabelRule.order(Column("match")).fetchAll($0) }
    }

    /// Fills in the shipped rules the first time, and never again, so deleting one sticks.
    public func installDefaultLabelRulesIfNeeded() throws {
        try db.write { db in
            guard try LabelRule.fetchCount(db) == 0,
                  try String.fetchOne(db, sql: "SELECT value FROM catalogSetting WHERE key = 'defaultRulesInstalled'") == nil
            else { return }
            for rule in LabelRules.defaults { try rule.insert(db, onConflict: .ignore) }
            try db.execute(sql: "INSERT OR REPLACE INTO catalogSetting (key, value) VALUES ('defaultRulesInstalled', '1')")
        }
    }

    public func save(_ rule: LabelRule) throws {
        try db.write { try rule.save($0) }
    }

    public func deleteRule(_ rule: LabelRule) throws {
        try db.write { _ = try rule.delete($0) }
    }

    /// Applies a rule to labels already in the catalogue and returns how many tags changed.
    @discardableResult
    public func apply(_ rule: LabelRule) throws -> Int {
        try db.write { db in
            let label = Column("label")
            let scope = SceneTag.filter(Column("kind") == TagKind.label.rawValue && Column("userEdited") == false
                                        && sql("lower(label) = ?", arguments: [rule.match]))
            let affected = try String.fetchSet(db, scope.select(Column("assetID"), as: String.self))
            var changed = 0
            switch rule.action {
            case .hide:
                changed = try scope.deleteAll(db)
            case .rename:
                guard !rule.replacement.isEmpty else { return 0 }
                changed = try scope.updateAll(db, label.set(to: rule.replacement))
            }
            for assetID in affected { try Self.reindex(db, assetID: assetID) }
            return changed
        }
    }

    /// Renames every machine-made label with this wording across the whole catalogue.
    @discardableResult
    public func renameLabel(_ from: String, to replacement: String) throws -> Int {
        try apply(LabelRule(match: from, action: .rename, replacement: replacement))
    }

    /// The labels the picture analysis has produced, most common first, for building rules.
    public func labelCounts(limit: Int = 300) throws -> [(label: String, count: Int)] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT label, COUNT(*) AS n FROM sceneTag WHERE kind = ? AND userEdited = 0
                GROUP BY label ORDER BY n DESC LIMIT ?
                """, arguments: [TagKind.label.rawValue, limit]).map { (label: $0["label"], count: $0["n"]) }
        }
    }
}

private func sql(_ expression: String, arguments: StatementArguments) -> SQLExpression {
    SQL(sql: expression, arguments: arguments).sqlExpression
}
