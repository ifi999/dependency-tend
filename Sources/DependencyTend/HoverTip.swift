import SwiftUI

/// MenuBarExtra의 비활성(non-activating) 패널에서는 네이티브 .help 툴팁이 뜨지 않는다
/// (macOS 툴팁은 앱이 active일 때만 표시). onHover/focus + overlay로 같은 창 안에 직접 그리는
/// 자체 툴팁 — 프레젠테이션 API를 쓰지 않으므로 어디서든 동작한다 (sheet/dialog 함정과 같은 계열 회피).
/// 팁이 펼쳐지는 방향 — 패널 오른쪽 가장자리 요소는 .trailing(왼쪽으로 펼침)을 써서 잘림을 피한다
enum TipEdge {
    case leading, trailing
}

struct HoverTip: ViewModifier {
    private static let minTipWidth: CGFloat = 180
    private static let maxTipWidth: CGFloat = 300

    let text: String
    let edge: TipEdge
    @State private var hoverVisible = false
    @State private var delayTask: Task<Void, Never>?
    @FocusState private var hasKeyboardFocus: Bool
    @AccessibilityFocusState private var hasAccessibilityFocus: Bool

    func body(content: Content) -> some View {
        content
            .tipAccessibilityHelp(text)
            .onHover { inside in
                delayTask?.cancel()
                // 빈 텍스트는 팁을 만들지 않는다 (빈 박스 방지 — 네이티브 .help와 동일 동작)
                if inside && !text.isEmpty {
                    delayTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        if !Task.isCancelled { hoverVisible = true }
                    }
                } else {
                    hoverVisible = false
                }
            }
            .focused($hasKeyboardFocus)
            .accessibilityFocused($hasAccessibilityFocus)
            .onChange(of: hasKeyboardFocus) { focused in
                handleFocusChange(focused)
            }
            .onChange(of: hasAccessibilityFocus) { focused in
                handleFocusChange(focused)
            }
            .onDisappear {
                delayTask?.cancel()
                hoverVisible = false
            }
            .overlay(alignment: edge == .trailing ? .bottomTrailing : .bottomLeading) {
                if shouldShowTip {
                    Text(text)
                        .font(.caption2)
                        .lineLimit(8)
                        .multilineTextAlignment(.leading)
                        .frame(minWidth: Self.minTipWidth,
                               idealWidth: Self.maxTipWidth,
                               maxWidth: Self.maxTipWidth,
                               alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: 26)
                        .allowsHitTesting(false)
                }
            }
            // 팁이 아래 행 위로 떠야 하므로 보이는 동안만 형제들보다 위로
            .zIndex(shouldShowTip ? 100 : 0)
    }

    private var shouldShowTip: Bool {
        !text.isEmpty && (hoverVisible || hasKeyboardFocus || hasAccessibilityFocus)
    }

    private func handleFocusChange(_ focused: Bool) {
        if focused {
            delayTask?.cancel()
        }
    }
}

extension View {
    /// 자체 호버/포커스 툴팁. `.help`도 접근성 fallback으로 함께 붙인다.
    /// 패널 오른쪽 가장자리 요소에는 `edge: .trailing`을 줘서 왼쪽으로 펼친다.
    func tip(_ text: String, edge: TipEdge = .leading) -> some View {
        modifier(HoverTip(text: text, edge: edge))
    }
}

private extension View {
    @ViewBuilder
    func tipAccessibilityHelp(_ text: String) -> some View {
        if text.isEmpty {
            self
        } else {
            self
                .help(text)
                .accessibilityHint(Text(text))
        }
    }
}
