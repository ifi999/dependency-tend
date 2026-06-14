import Foundation

public struct SemVer: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 관용적 파싱: "v" 접두, brew revision("_3"), prerelease("-beta"), build("+5") 허용
    public static func parse(_ raw: String) -> SemVer? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s = String(s.dropFirst()) }
        for sep in ["_", "-", "+"] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        let parts = s.split(separator: ".").map(String.init)
        guard let first = parts.first, let major = Int(first) else { return nil }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let patch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        return SemVer(major: major, minor: minor, patch: patch)
    }

    /// 업그레이드 점프 종류. 파싱 불가/동일/다운그레이드는 nil.
    public static func jump(from current: String, to latest: String) -> PackageFlag? {
        guard let c = parse(current), let l = parse(latest), c < l else { return nil }
        if l.major > c.major { return .major }
        if l.minor > c.minor { return .minor }
        return .patch
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
