import AppKit
import CoreText
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chip Badge

/// Compact unread badge: restrained red capsule, small white numerals, top-right of the chip.
/// Renders whatever string the app put on its Dock tile ("3", "99+", "•") as-is.
/// Not a hit target — taps fall through to the chip underneath.
///
/// **它由 chip 自己画（`ChipView.bareIconChip` / `LauncherChip` 的 overlay），不是由调用方
/// 套一层 ZStack 叠上去的。** 2026-08-17 之前是后者，于是它落在 `chipQuietHoverScale` 的
/// **外面**：安静档悬停时图标放大 10%，红点纹丝不动（owner 实测两帧都是 16×15pt），
/// 看着像图标从红点底下鼓出来。放进 chip 里之后，悬停放大、按压回缩、档位缩放它全都跟着走。
///
/// Sizes follow `ChipPillMetrics.badge*` and the taskbar scale.
struct ChipBadgeView: View {
    let text: String
    /// 档位系数。**故意不给默认值**——同 `scale` / `hoverStyle` 那条铁律。
    let scale: CGFloat

    var body: some View {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: ChipPillMetrics.badgeFontSize * scale, weight: .regular
        )
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.white]
        ))
        let inkBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let width = max(
            ChipPillMetrics.badgeMinimumSize * scale,
            ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                 + 2 * ChipPillMetrics.badgeHorizontalPadding * scale)
        )

        // Center the visible glyphs rather than the font's line box and side bearings.
        // This also handles other digits, multi-digit counts and symbols without a fixed nudge.
        Canvas { context, size in
            context.withCGContext { cg in
                cg.translateBy(x: size.width / 2 - inkBounds.midX,
                               y: size.height / 2 + inkBounds.midY)
                cg.scaleBy(x: 1, y: -1)
                cg.textMatrix = .identity
                cg.textPosition = .zero
                CTLineDraw(line, cg)
            }
        }
            .frame(width: width, height: ChipPillMetrics.badgeMinimumSize * scale)
            .accessibilityLabel(Text(text))
            .background(
                Capsule().fill(Color(red: 0.96, green: 0.23, blue: 0.27))
            )
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 1 * scale, x: 0, y: 0.5 * scale)
            // Tuck into the icon's upper-right corner without a heavy black outline.
            .offset(x: 0, y: ChipPillMetrics.badgeTopOffset * scale)
            .allowsHitTesting(false)
    }
}
