import UIKit

// MARK: - Panel

/// The floating panel for arranging the controls: size and opacity, hide, reset, done. Shown over the
/// full-screen editor and over a running stream.
@MainActor
final class OSCEditorPanel: UIView {
    private let controls: TrueCloudOnScreenControls
    private let done: () -> Void
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let sizeSlider = UISlider()
    private let sizeValue = UILabel()
    private let opacitySlider = UISlider()
    private let opacityValue = UILabel()
    private let hideButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let mode = UISegmentedControl(items: ["Arrange", "Try it"])
    private let showsTryIt: Bool

    init(controls: TrueCloudOnScreenControls, showsTryIt: Bool, done: @escaping () -> Void) {
        self.controls = controls
        self.showsTryIt = showsTryIt
        self.done = done
        super.init(frame: .zero)
        overrideUserInterfaceStyle = .dark
        build()
        controls.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect()
        } else {
            effect = UIBlurEffect(style: .systemThinMaterialDark)
        }
        let background = UIVisualEffectView(effect: effect)
        background.layer.cornerRadius = 24
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 22
        layer.shadowOffset = CGSize(width: 0, height: 8)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 12.5)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.68)
        hintLabel.numberOfLines = 1
        hintLabel.adjustsFontSizeToFitWidth = true
        hintLabel.minimumScaleFactor = 0.8

        sizeSlider.minimumValue = Float(OSCLayout.scaleRange.lowerBound)
        sizeSlider.maximumValue = Float(OSCLayout.scaleRange.upperBound)
        opacitySlider.minimumValue = Float(OSCLayout.opacityRange.lowerBound)
        opacitySlider.maximumValue = Float(OSCLayout.opacityRange.upperBound)
        for slider in [sizeSlider, opacitySlider] { slider.tintColor = OSCGlass.blue }
        sizeSlider.addTarget(self, action: #selector(sizeChanged), for: .valueChanged)
        opacitySlider.addTarget(self, action: #selector(opacityChanged), for: .valueChanged)

        mode.selectedSegmentIndex = 0
        mode.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        style(hideButton, "Hide", filled: false)
        style(resetButton, "Reset", filled: false)
        style(doneButton, "Done", filled: true)
        hideButton.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)
        resetButton.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [titleLabel, hintLabel])
        header.axis = .vertical
        header.spacing = 2
        let buttons = UIStackView(arrangedSubviews: [hideButton, resetButton, doneButton])
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        var rows: [UIView] = [header]
        if showsTryIt { rows.append(mode) }
        rows += [row("Size", sizeSlider, sizeValue), row("Opacity", opacitySlider, opacityValue), buttons]
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: background.contentView.bottomAnchor, constant: -11),
            stack.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor, constant: -18),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
    }

    private func row(_ title: String, _ slider: UISlider, _ value: UILabel) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        value.textColor = UIColor.white.withAlphaComponent(0.7)
        value.textAlignment = .right
        value.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let stack = UIStackView(arrangedSubviews: [label, slider, value])
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }

    private func style(_ button: UIButton, _ title: String, filled: Bool) {
        var config: UIButton.Configuration = filled ? .filled() : .tinted()
        config.title = title
        config.cornerStyle = .capsule
        config.baseBackgroundColor = filled ? OSCGlass.blue : .white
        config.baseForegroundColor = .white
        button.configuration = config
    }

    func refresh() {
        let selected = controls.selected
        let item = selected.map { controls.layout.item($0) }
        titleLabel.text = controls.isTrying ? "Try it" : (selected?.title ?? "Arrange your controls")
        if controls.isTrying {
            hintLabel.text = "Press the controls to preview them. Nothing is sent."
        } else if let item {
            hintLabel.text = item.hidden ? "Hidden: faint here, gone while you play." : "Drag to move it, Size to resize it."
        } else {
            hintLabel.text = "Drag to move. Tap one to resize or hide."
        }
        let canEdit = item != nil && !controls.isTrying
        sizeSlider.isEnabled = canEdit
        hideButton.isEnabled = canEdit
        hideButton.configuration?.title = item?.hidden == true ? "Show" : "Hide"
        resetButton.isEnabled = !controls.layout.isDefault
        if let item { sizeSlider.value = Float(item.scale) }
        sizeValue.text = item.map { "\(Int(($0.scale * 100).rounded()))%" } ?? "–"
        opacitySlider.value = Float(controls.layout.opacity)
        opacityValue.text = "\(Int((controls.layout.opacity * 100).rounded()))%"
        mode.selectedSegmentIndex = controls.isTrying ? 1 : 0
    }

    @objc private func sizeChanged() {
        controls.setSelectedScale(Double(sizeSlider.value))
        let scale = controls.selected.map { controls.layout.item($0).scale } ?? 1
        sizeValue.text = "\(Int((scale * 100).rounded()))%"
    }

    @objc private func opacityChanged() {
        controls.setOpacity(Double(opacitySlider.value))
        opacityValue.text = "\(Int((controls.layout.opacity * 100).rounded()))%"
    }

    @objc private func modeChanged() { controls.isTrying = mode.selectedSegmentIndex == 1 }
    @objc private func hideTapped() { controls.toggleSelectedHidden() }
    @objc private func resetTapped() { controls.resetLayout() }
    @objc private func doneTapped() { done() }
}

// MARK: - Backdrop

/// A made-up game scene to arrange the controls over, so the glass has something to be seen against.
/// Dusk is the dark case; day is the bright one, where see-through controls are hardest to read.
final class OSCBackdropView: UIView {
    var bright = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width, h = bounds.height
        let horizon = h * 0.50
        func color(_ hex: UInt32, _ a: CGFloat = 1) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
        }
        func gradient(_ colors: [UIColor], from: CGPoint, to: CGPoint) {
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
            cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        // Sky
        cg.saveGState()
        cg.clip(to: CGRect(x: 0, y: 0, width: w, height: horizon))
        gradient(bright ? [color(0x2f86d6), color(0x86c4f2), color(0xe6f3ff)] : [color(0x121a38), color(0x55447f), color(0xefa36c)],
                 from: .zero, to: CGPoint(x: 0, y: horizon))
        let sun = CGPoint(x: w * 0.66, y: horizon * 0.82)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [(bright ? color(0xffffff, 0.95) : color(0xffd9a0, 0.9)).cgColor, UIColor.clear.cgColor] as CFArray, locations: nil) {
            cg.drawRadialGradient(g, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: w * 0.30, options: [])
        }
        if bright {
            cg.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
            for (x, y, s) in [(0.16, 0.16, 1.0), (0.42, 0.10, 0.8), (0.84, 0.2, 1.1), (0.58, 0.28, 0.7)] {
                for dx in [-0.5, 0, 0.55] {
                    cg.fillEllipse(in: CGRect(x: w * x + CGFloat(dx) * 60 * CGFloat(s) - 40 * CGFloat(s), y: h * y, width: 90 * CGFloat(s), height: 30 * CGFloat(s)))
                }
            }
        }
        cg.restoreGState()

        // Ridges, farthest first.
        let ridges: [(UIColor, CGFloat, CGFloat, CGFloat)] = bright
            ? [(color(0x8fb8d8), 0.10, 0.9, 1.0), (color(0x5f9a63), 0.07, 1.7, 2.2), (color(0x3f7d3d), 0.05, 2.6, 4.1)]
            : [(color(0x3b3463), 0.10, 0.9, 1.0), (color(0x241f45), 0.07, 1.7, 2.2), (color(0x151431), 0.05, 2.6, 4.1)]
        for (fill, amplitude, frequency, phase) in ridges {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: horizon))
            var x: CGFloat = 0
            while x <= w {
                let t = x / w
                let y = horizon - h * amplitude * (0.55 + 0.45 * sin(t * .pi * 2 * frequency + phase) + 0.25 * sin(t * .pi * 7 * frequency + phase * 2))
                path.addLine(to: CGPoint(x: x, y: y))
                x += 6
            }
            path.addLine(to: CGPoint(x: w, y: horizon + 2))
            path.close()
            fill.setFill()
            path.fill()
        }

        // Water, with a few glints.
        cg.saveGState()
        cg.clip(to: CGRect(x: 0, y: horizon, width: w, height: h - horizon))
        gradient(bright ? [color(0x62b9e4), color(0x1f7fb2)] : [color(0x3a3566), color(0x0b1022)],
                 from: CGPoint(x: 0, y: horizon), to: CGPoint(x: 0, y: h))
        var seed: UInt64 = 42
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFF) / 65535
        }
        cg.setStrokeColor(UIColor.white.withAlphaComponent(bright ? 0.35 : 0.16).cgColor)
        cg.setLineCap(.round)
        for _ in 0..<46 {
            let y = horizon + (h - horizon) * pow(next(), 1.6)
            let x = w * next()
            cg.setLineWidth(1 + 2 * (y - horizon) / h)
            cg.move(to: CGPoint(x: x, y: y))
            cg.addLine(to: CGPoint(x: x + 14 + 36 * next(), y: y))
        }
        cg.strokePath()
        cg.restoreGState()
    }
}

// MARK: - Editor screen

/// Lets a touch on the editor's background reach the controls.
private final class OSCCanvasView: UIView {
    var onDown: ((Set<UITouch>) -> Void)?
    var onMove: ((Set<UITouch>) -> Void)?
    var onUp: ((Set<UITouch>) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { onDown?(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { onMove?(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { onUp?(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onUp?(touches) }
}

/// Full-screen, landscape editor for the on-screen controls, opened from Stream Settings. It uses the same
/// controls as the stream (so what you arrange is exactly what you get), over a stand-in game scene.
@MainActor
final class OSCEditorViewController: UIViewController {
    /// What the editor opens showing; used for screenshots.
    enum Preview { case none, selected, playing }

    private let canvas = OSCCanvasView()
    private let backdrop = OSCBackdropView()
    private let recorder = OSCRecordingOutput()
    private var controls: TrueCloudOnScreenControls!
    private var panel: OSCEditorPanel?
    private let sceneButton = UIButton(type: .system)
    private let preview: Preview
    private let startsBright: Bool
    var onClose: (() -> Void)?

    init(preview: Preview = .none, bright: Bool = false) {
        self.preview = preview
        startsBright = bright
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override func loadView() { view = canvas }

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.bright = startsBright
        backdrop.isUserInteractionEnabled = false
        view.addSubview(backdrop)

        controls = TrueCloudOnScreenControls(view: view, output: recorder, swapABXY: false)
        controls.setLevel(.full)
        controls.show()
        controls.setEditing(true)
        canvas.onDown = { [weak self] touches in _ = self?.controls.handleTouchDownEvent(touches) }
        canvas.onMove = { [weak self] touches in _ = self?.controls.handleTouchMovedEvent(touches) }
        canvas.onUp = { [weak self] touches in _ = self?.controls.handleTouchUpEvent(touches) }

        if preview != .playing {
            let panel = OSCEditorPanel(controls: controls, showsTryIt: true) { [weak self] in self?.close() }
            panel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
                panel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            ])
            self.panel = panel
        }

        var config = UIButton.Configuration.tinted()
        config.image = UIImage(systemName: startsBright ? "moon.stars.fill" : "sun.max.fill")
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .white
        config.baseForegroundColor = .white
        sceneButton.configuration = config
        sceneButton.addAction(UIAction { [weak self] _ in self?.toggleScene() }, for: .touchUpInside)
        sceneButton.accessibilityLabel = "Switch the background between night and day"
        sceneButton.translatesAutoresizingMaskIntoConstraints = false
        if preview != .playing { view.addSubview(sceneButton) }
        NSLayoutConstraint.activate([
            sceneButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            sceneButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        controls.relayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        controls.relayout(force: true)
        switch preview {
        case .none:
            break
        case .selected:
            controls.select(.face)
        case .playing:
            // Hold a few controls down so the lit glass shows.
            controls.isTrying = true
            controls.simulateHold(.a, id: 9001)
            controls.simulateHold(.rb, id: 9002)
            controls.simulateHold(.right, id: 9003)
            controls.simulateStick(left: true, dx: 0.62, dy: -0.38, id: 9004)
        }
    }

    private func toggleScene() {
        backdrop.bright.toggle()
        sceneButton.configuration?.image = UIImage(systemName: backdrop.bright ? "moon.stars.fill" : "sun.max.fill")
    }

    func close() {
        controls.releaseAll()
        controls.setEditing(false)
        dismiss(animated: true) { [weak self] in self?.onClose?() }
    }
}

extension TrueCloudOnScreenControls {
    /// Presses a control's centre, for screenshots and the self-test.
    func simulateHold(_ part: OSCPart, id: Int) {
        guard let c = partCenter(part) else { return }
        _ = pointerDown(id, at: c)
    }

    func simulateStick(left: Bool, dx: CGFloat, dy: CGFloat, id: Int) {
        guard let base = partRect(left ? .leftBase : .rightBase) else { return }
        let c = CGPoint(x: base.midX, y: base.midY)
        _ = pointerDown(id, at: c)
        _ = pointerMoved(id, at: CGPoint(x: c.x + dx * base.width / 2, y: c.y + dy * base.height / 2))
    }
}
