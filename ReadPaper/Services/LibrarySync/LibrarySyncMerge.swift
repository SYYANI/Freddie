import Foundation

enum LibrarySyncMerge {
    static func merged(base: LibrarySyncDocument?, local: LibrarySyncDocument, remote: LibrarySyncDocument) throws -> LibrarySyncDocument? {
        switch (local.content, remote.content) {
        case (.reading(let local), .reading(let remote)):
            let chosen: LibrarySyncReading
            if local.modifiedAt != remote.modifiedAt { chosen = local.modifiedAt > remote.modifiedAt ? local : remote }
            else { chosen = try LibrarySyncCoding.encoder().encode(local).lexicographicallyPrecedes(LibrarySyncCoding.encoder().encode(remote)) ? remote : local }
            return .init(content: .reading(chosen))
        case (.translations(let local), .translations(let remote)):
            guard local.paperID == remote.paperID else { return nil }
            var merged = Dictionary(uniqueKeysWithValues: remote.segments.map { ($0.cacheKey, $0) })
            for value in local.segments {
                if let other = merged[value.cacheKey] {
                    let winsTie = try LibrarySyncCoding.encoder().encode(other).lexicographicallyPrecedes(LibrarySyncCoding.encoder().encode(value))
                    if value.modifiedAt > other.modifiedAt || (value.modifiedAt == other.modifiedAt && winsTie) { merged[value.cacheKey] = value }
                } else { merged[value.cacheKey] = value }
            }
            return .init(content: .translations(.init(paperID: local.paperID, segments: merged.values.sorted { $0.cacheKey < $1.cacheKey })))
        case (.paper(let local), .paper(let remote)):
            guard case .paper(let base)? = base?.content else { return nil }
            guard let value: LibrarySyncPaper = try fields(base: base, local: local, remote: remote) else { return nil }
            return .init(content: .paper(value))
        case (.folder(let local), .folder(let remote)):
            guard case .folder(let base)? = base?.content else { return nil }
            guard let value: LibrarySyncFolder = try fields(base: base, local: local, remote: remote) else { return nil }
            return .init(content: .folder(value))
        default: return nil
        }
    }

    private static func fields<Value: Codable>(base: Value, local: Value, remote: Value) throws -> Value? {
        func object(_ value: Value) throws -> [String: NSObject] {
            try JSONSerialization.jsonObject(with: LibrarySyncCoding.encoder().encode(value)) as? [String: NSObject] ?? [:]
        }
        let b = try object(base), l = try object(local), r = try object(remote)
        var result: [String: NSObject] = [:]
        for key in Set(b.keys).union(l.keys).union(r.keys) {
            if l[key] == r[key] { result[key] = l[key] }
            else if l[key] == b[key] { result[key] = r[key] }
            else if r[key] == b[key] { result[key] = l[key] }
            else if key == "modifiedAt", let a = l[key] as? NSNumber, let z = r[key] as? NSNumber {
                result[key] = NSNumber(value: max(a.int64Value, z.int64Value))
            } else { return nil }
        }
        return try LibrarySyncCoding.decoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
}
