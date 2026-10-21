import AppKit
import SwiftUI

/// One opaque control from Form's perspective: native children cannot be redistributed as fields.
struct DockBottomGapControl: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeNSView(context: Context) -> DockBottomGapControlView {
        let view = DockBottomGapControlView(range: range)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DockBottomGapControlView, context: Context) {
        view.onChange = { value = $0 }
        view.setValue(value)
    }
}

final class DockBottomGapControlView: NSView {
    static let controlSize = NSSize(width: 284, height: 28)
    let minusButton = NSButton(title: "−", target: nil, action: nil)
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 20, target: nil, action: nil)
    let plusButton = NSButton(title: "+", target: nil, action: nil)
    let readout = NSTextField(labelWithString: "")
    private let range: ClosedRange<Double>
    var onChange: ((Double) -> Void)?

    init(range: ClosedRange<Double>) {
        self.range = range
        super.init(frame: NSRect(origin: .zero, size: Self.controlSize))
        for button in [minusButton, plusButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            addSubview(button)
        }
        minusButton.action = #selector(decrease)
        plusButton.action = #selector(increase)
        minusButton.setAccessibilityLabel("−1 pt")
        plusButton.setAccessibilityLabel("+1 pt")
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.numberOfTickMarks = 0
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel(String(localized: "Taskbar bottom spacing"))
        addSubview(slider)
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        readout.alignment = .right
        addSubview(readout)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { Self.controlSize }

    override func layout() {
        super.layout()
        // Trailing anchored even if an enclosing Form proposes extra width.
        let x = max(0, bounds.width - Self.controlSize.width)
        let y = (bounds.height - 24) / 2
        minusButton.frame = NSRect(x: x, y: y, width: 28, height: 24)
        slider.frame = NSRect(x: x + 36, y: y + 2, width: 160, height: 20)
        plusButton.frame = NSRect(x: x + 204, y: y, width: 28, height: 24)
        readout.frame = NSRect(x: x + 240, y: (bounds.height - 18) / 2, width: 44, height: 18)
    }

    func setValue(_ raw: Double) {
        let value = min(max(raw.rounded(), range.lowerBound), range.upperBound)
        slider.doubleValue = value
        readout.stringValue = "\(Int(value)) pt"
        minusButton.isEnabled = value > range.lowerBound
        plusButton.isEnabled = value < range.upperBound
    }

    private func commit(_ raw: Double) {
        setValue(raw)
        onChange?(slider.doubleValue)
    }

    @objc private func decrease() { commit(slider.doubleValue - 1) }
    @objc private func increase() { commit(slider.doubleValue + 1) }
    @objc private func sliderChanged() { commit(slider.doubleValue) }
}
