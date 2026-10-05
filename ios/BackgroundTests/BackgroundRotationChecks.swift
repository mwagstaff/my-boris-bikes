import SwiftUI

@main
struct BackgroundRotationChecks {
    static func main() {
        var rotation = LondonBackgroundRotation()
        // Background launches must wait until the user actually opens the app.
        assert(!rotation.shouldAdvance(for: .background))
        assert(!rotation.shouldAdvance(for: .inactive))
        assert(rotation.shouldAdvance(for: .active))

        // Duplicate active events and foreground interruptions retain the same image.
        assert(!rotation.shouldAdvance(for: .active))
        assert(!rotation.shouldAdvance(for: .inactive))
        assert(!rotation.shouldAdvance(for: .active))

        assert(!rotation.shouldAdvance(for: .background))
        assert(!rotation.shouldAdvance(for: .inactive))
        assert(rotation.shouldAdvance(for: .active))

        // A new app process resumes from the saved selection rather than resetting.
        var relaunched = LondonBackgroundRotation()
        assert(relaunched.shouldAdvance(for: .active))

        // A stale or invalid saved selection cannot index outside the asset list.
        for invalidIndex in [-1, Int.min, Int.max, LondonBackgroundRotation.imageNames.count] {
            assert(LondonBackgroundRotation.imageName(for: invalidIndex) == "LondonEyeHeader")
        }

        let entries = LondonBackgroundRotation.imageNames.map { name in
            LondonBackgroundCatalog.Entry(id: name, file: "unused", sha256: "unused", byteCount: 1)
        }
        let catalog = LondonBackgroundCatalog(schemaVersion: 1, images: entries)
        var id: String?
        var seen = Set<String>()
        for _ in entries.indices {
            id = catalog.next(after: id)!.id
            assert(seen.insert(id!).inserted)
        }
        assert(seen.count == 12)
        assert(catalog.next(after: id) == entries[0])
        assert(catalog.next(after: "removed-image") == entries[0])
        let reordered = LondonBackgroundCatalog(schemaVersion: 1, images: Array(entries.reversed()))
        assert(reordered.next(after: entries[5].id) == entries[4])
        assert(LondonBackgroundCatalog(schemaVersion: 1, images: []).next(after: id) == nil)
        print("Passed: visit lifecycle, catalogue rotation, reordering, removals, relaunch and invalid saved selections.")
    }
}
