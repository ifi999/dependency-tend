import Foundation

/// 스펙 §3 위험도 표의 코드화. 순수 함수 — outdated가 아니면 risk를 매기지 않는다.
public enum RiskClassifier {
    public static func classify(_ pkg: PackageInfo) -> PackageInfo {
        var out = pkg
        guard pkg.status == .outdated else {
            out.risk = nil
            return out
        }
        var flags = pkg.flags
        var jump: PackageFlag?
        if let c = pkg.current, let l = pkg.latest {
            jump = SemVer.jump(from: c, to: l)
        }
        if let j = jump { flags.insert(j) }
        out.flags = flags

        if flags.contains(.pinned) || flags.contains(.runtime) || jump == .major {
            out.risk = .high
            return out
        }
        var base: Risk
        switch jump {
        case .minor: base = .medium
        case .patch: base = .low
        default: base = .medium // 파싱 불가 → 보수적 medium (스펙 §3)
        }
        if flags.contains(.cask) { base = max(base, .medium) }
        out.risk = base
        return out
    }
}
