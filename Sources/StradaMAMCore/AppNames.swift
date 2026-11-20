import Foundation

/// Names the app stores things under, and the names it used before a spelling correction
/// ("Stada" became "Strada"). Anything already on disk or inside a file under the old name is
/// still found, so nothing ingested before the correction is lost.
public enum AppNames {
    /// The folder holding the catalog (in Application Support) and the proxies (in Movies).
    public static let libraryFolder = "StradaXR MAM"
    public static let legacyLibraryFolder = "StadaXR MAM"

    /// The app's identifier, and the one its settings were saved under before.
    public static let bundleIdentifier = "com.stradaxr.mam"
    public static let legacyBundleIdentifier = "com.stadaxr.mam"

    /// The library folder inside `parent`. A library that exists under the old name, where there
    /// is none under the new, keeps being used where it is: the catalog records full paths to
    /// its proxies, so moving it would break them.
    public static func libraryFolder(in parent: URL) -> URL {
        let current = parent.appendingPathComponent(libraryFolder)
        let legacy = parent.appendingPathComponent(legacyLibraryFolder)
        let fm = FileManager.default
        return !fm.fileExists(atPath: current.path) && fm.fileExists(atPath: legacy.path) ? legacy : current
    }
}
