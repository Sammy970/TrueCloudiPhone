import UIKit

// MARK: - Editor chrome

/// The editor's controls, all at the screen edges so the pad being arranged stays in the clear: a slim pill at the top
/// leading corner (menu, Done), a round Appearance button at the top trailing corner (it opens a small card with Size and
/// Opacity), a hint line at the top centre, and a tray at the bottom centre that appears while a control is dragged (a bin
/// to drop it on) or when some are removed (chips to put them back). It fills its superview and lets every touch outside
/// those pieces through, so the controls underneath (and, in-stream, the stream) keep working. Shown over the full-screen
/// editor and over a running stream.
@MainActor
final class OSCEditorPanel: UIView {
    private let controls: TrueCloudOnScreenControls
    private let done: () -> Void
    private let showsTryIt: Bool
    /// Extra entries for the `…` menu (the standalone editor adds its night/day switch).
    var extraActions: [UIMenuElement] = [] {
        didSet {
            menuKey = nil
            rebuildMenu()
        }
    }
    private var menuKey: String?

    private lazy var pill = glass(radius: 22)
    private let menuButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private lazy var round = glass(radius: 22)
    private let appearanceButton = UIButton(type: .system)
    private let hintLabel = UILabel()
    private var hintTask: Task<Void, Never>?
    private var hintWanted = false

    // The Appearance card, with a full-screen catcher under it while it's open so a tap outside closes it.
    private lazy var popover = glass(radius: 18)
    private let catcher = UIControl()
    private var appearanceOpen = false
    private let sizeSlider = UISlider()
    private let sizeValue = UILabel()
    private let sizeNote = UILabel()
    private let opacitySlider = UISlider()
    private let opacityValue = UILabel()

    // The tray: a bin (the drop target while dragging) and one chip per removed control.
    private lazy var tray = glass(radius: 21)
    private let binButton = UIButton(type: .system)
    private let chipScroll = UIScrollView()
    private let chipStack = UIStackView()
    private var chipsShown: [OSCElement] = []
    private var dragging = false
    private var overBin = false
    private lazy var tick = UISelectionFeedbackGenerator()

    init(controls: TrueCloudOnScreenControls, showsTryIt: Bool, done: @escaping () -> Void) {
        self.controls = controls
        self.showsTryIt = showsTryIt
        self.done = done
        super.init(frame: .zero)
        overrideUserInterfaceStyle = .dark
        build()
        controls.onChange = { [weak self] in self?.refresh() }
        controls.onDragChange = { [weak self] element, location in self?.dragChanged(element, location) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Touches outside the pill, the round button, the card and the tray go to whatever is underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    /// The tray moves when chips come and go, and the controls need to know where the bin is.
    override func layoutSubviews() {
        super.layoutSubviews()
        controls.setBin(binButton.convert(binButton.bounds, to: self), in: self)
    }

    private func glass(radius: CGFloat) -> UIVisualEffectView {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect()
        } else {
            effect = UIBlurEffect(style: .systemThinMaterialDark)
        }
        let view = UIVisualEffectView(effect: effect)
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func build() {
        let symbols = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)

        // Top leading: menu and Done.
        var menu = UIButton.Configuration.plain()
        menu.image = UIImage(systemName: "ellipsis.circle")
        menu.preferredSymbolConfigurationForImage = symbols
        menu.baseForegroundColor = .white
        menuButton.configuration = menu
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = "Layout menu"
        var finish = UIButton.Configuration.filled()
        finish.image = UIImage(systemName: "checkmark")
        finish.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        finish.cornerStyle = .capsule
        finish.baseBackgroundColor = OSCGlass.blue
        finish.baseForegroundColor = .white
        finish.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        doneButton.configuration = finish
        doneButton.accessibilityLabel = "Done"
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        let pillStack = UIStackView(arrangedSubviews: [menuButton, doneButton])
        pillStack.spacing = 2
        pillStack.alignment = .center
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pill.contentView.addSubview(pillStack)

        // Top trailing: Appearance.
        var look = UIButton.Configuration.plain()
        look.image = UIImage(systemName: "slider.horizontal.3")
        look.preferredSymbolConfigurationForImage = symbols
        look.baseForegroundColor = .white
        appearanceButton.configuration = look
        appearanceButton.accessibilityLabel = "Appearance"
        appearanceButton.translatesAutoresizingMaskIntoConstraints = false
        appearanceButton.addTarget(self, action: #selector(appearanceTapped), for: .touchUpInside)
        round.contentView.addSubview(appearanceButton)

        // Top centre: a hint that gets out of the way. It takes no touches (a label doesn't by default).
        hintLabel.text = "Drag to move · pinch to resize · drag to the bin to remove"
        hintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        hintLabel.textAlignment = .center
        hintLabel.adjustsFontSizeToFitWidth = true
        hintLabel.minimumScaleFactor = 0.7
        hintLabel.layer.shadowColor = UIColor.black.cgColor
        hintLabel.layer.shadowOpacity = 0.6
        hintLabel.layer.shadowRadius = 3
        hintLabel.layer.shadowOffset = .zero
        hintLabel.alpha = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buildPopover()
        buildTray()

        for view in [pill, round, hintLabel, popover, tray] { addSubview(view) }
        popover.isHidden = true
        let safe = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // Top centre: the gap between the default Back and Start buttons, and where the eye goes first.
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            pill.heightAnchor.constraint(equalToConstant: 44),
            pillStack.topAnchor.constraint(equalTo: pill.contentView.topAnchor),
            pillStack.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor),
            pillStack.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 4),
            pillStack.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -5),
            menuButton.widthAnchor.constraint(equalToConstant: 40),
            menuButton.heightAnchor.constraint(equalToConstant: 40),
            // A fixed size, or the pill squeezes the checkmark into a narrow sliver.
            doneButton.widthAnchor.constraint(equalToConstant: 56),
            doneButton.heightAnchor.constraint(equalToConstant: 34),

            round.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            round.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            round.widthAnchor.constraint(equalToConstant: 44),
            round.heightAnchor.constraint(equalToConstant: 44),
            appearanceButton.topAnchor.constraint(equalTo: round.contentView.topAnchor),
            appearanceButton.bottomAnchor.constraint(equalTo: round.contentView.bottomAnchor),
            appearanceButton.leadingAnchor.constraint(equalTo: round.contentView.leadingAnchor),
            appearanceButton.trailingAnchor.constraint(equalTo: round.contentView.trailingAnchor),

            // Just under the pill, so it never sits on a control.
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: pill.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -16),

            popover.topAnchor.constraint(equalTo: round.bottomAnchor, constant: 8),
            popover.trailingAnchor.constraint(equalTo: round.trailingAnchor),
            popover.widthAnchor.constraint(equalToConstant: 280),

            tray.centerXAnchor.constraint(equalTo: centerXAnchor),
            tray.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -6),
            tray.heightAnchor.constraint(equalToConstant: 42),
        ])
        rebuildMenu()
    }

    /// The Appearance card: Size for the selected control, Opacity for the whole pad.
    private func buildPopover() {
        let title = UILabel()
        title.text = "Appearance"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = UIColor.white.withAlphaComponent(0.9)
        sizeNote.text = "Select a control to resize it"
        sizeNote.font = .systemFont(ofSize: 11.5)
        sizeNote.textColor = UIColor.white.withAlphaComponent(0.55)

        sizeSlider.minimumValue = Float(OSCLayout.scaleRange.lowerBound)
        sizeSlider.maximumValue = Float(OSCLayout.scaleRange.upperBound)
        opacitySlider.minimumValue = Float(OSCLayout.opacityRange.lowerBound)
        opacitySlider.maximumValue = Float(OSCLayout.opacityRange.upperBound)
        for slider in [sizeSlider, opacitySlider] {
            slider.tintColor = OSCGlass.blue
            slider.addTarget(self, action: #selector(sliderReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        sizeSlider.addTarget(self, action: #selector(sizeChanged), for: .valueChanged)
        opacitySlider.addTarget(self, action: #selector(opacityChanged), for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [title, row("Size", sizeSlider, sizeValue), sizeNote, row("Opacity", opacitySlider, opacityValue)])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        popover.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: popover.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: popover.contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: popover.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: popover.contentView.trailingAnchor, constant: -14),
        ])

        catcher.translatesAutoresizingMaskIntoConstraints = false
        catcher.addTarget(self, action: #selector(catcherTapped), for: .touchDown)
    }

    /// The bin is always in the tray; the chips scroll beside it when something is removed.
    private func buildTray() {
        binButton.setImage(UIImage(systemName: "trash"), for: .normal)
        binButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .medium), forImageIn: .normal)
        binButton.tintColor = UIColor.white.withAlphaComponent(0.9)
        binButton.layer.cornerRadius = 17
        binButton.accessibilityLabel = "Remove the selected control"
        binButton.addTarget(self, action: #selector(binTapped), for: .touchUpInside)

        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.isHidden = true
        chipStack.axis = .horizontal
        chipStack.spacing = 6
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.addSubview(chipStack)
        let width = chipScroll.widthAnchor.constraint(equalTo: chipStack.widthAnchor)
        width.priority = .defaultHigh

        let row = UIStackView(arrangedSubviews: [binButton, chipScroll])
        row.spacing = 4
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        tray.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: tray.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: tray.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: tray.contentView.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: tray.contentView.trailingAnchor, constant: -8),
            binButton.widthAnchor.constraint(equalToConstant: 34),
            binButton.heightAnchor.constraint(equalToConstant: 34),
            chipStack.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor),
            chipStack.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor),
            chipStack.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
            chipScroll.heightAnchor.constraint(equalToConstant: 30),
            chipScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 190),
            width,
        ])
        tray.alpha = 0
        tray.isUserInteractionEnabled = false
    }

    // MARK: Menu

    /// Rebuilt only when what it shows changes (Try it on/off, whether there is anything to reset).
    private func rebuildMenu() {
        let key = "\(controls.isTrying)\(controls.layout.isDefault)\(extraActions.count)"
        guard key != menuKey else { return }
        menuKey = key
        var items: [UIMenuElement] = []
        if showsTryIt {
            items.append(UIAction(title: "Try it", image: UIImage(systemName: "hand.tap"), state: controls.isTrying ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.controls.isTrying.toggle()
            })
        }
        items += extraActions
        let reset = UIAction(title: "Reset layout", image: UIImage(systemName: "arrow.counterclockwise"),
                             attributes: controls.layout.isDefault ? [.destructive, .disabled] : [.destructive]) { [weak self] _ in
            self?.controls.resetLayout()
        }
        items.append(UIMenu(options: .displayInline, children: [reset]))
        menuButton.menu = UIMenu(children: items)
    }

    // MARK: Appearance card

    func setAppearanceOpen(_ open: Bool, animated: Bool = true) {
        guard open != appearanceOpen else { return }
        appearanceOpen = open
        appearanceButton.configuration?.baseForegroundColor = open ? OSCGlass.blue : .white
        if open {
            refresh()
            insertSubview(catcher, belowSubview: popover)
            NSLayoutConstraint.activate([
                catcher.topAnchor.constraint(equalTo: topAnchor),
                catcher.bottomAnchor.constraint(equalTo: bottomAnchor),
                catcher.leadingAnchor.constraint(equalTo: leadingAnchor),
                catcher.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            popover.isHidden = false
            popover.alpha = 0
            popover.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        } else {
            catcher.removeFromSuperview()
        }
        let change = {
            self.popover.alpha = open ? 1 : 0
            self.popover.transform = open ? .identity : CGAffineTransform(scaleX: 0.94, y: 0.94)
        }
        let finish: (Bool) -> Void = { _ in
            if !self.appearanceOpen { self.popover.isHidden = true }
        }
        if animated {
            UIView.animate(withDuration: 0.18, animations: change, completion: finish)
        } else {
            change()
            finish(true)
        }
    }

    private func row(_ title: String, _ slider: UISlider, _ value: UILabel) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        value.textColor = UIColor.white.withAlphaComponent(0.7)
        value.textAlignment = .right
        value.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let stack = UIStackView(arrangedSubviews: [label, slider, value])
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }

    // MARK: Hint

    /// Shows the hint, then lets it fade after a few seconds.
    private func showHint() {
        hintTask?.cancel()
        UIView.animate(withDuration: 0.25) { self.hintLabel.alpha = 1 }
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.fadeHint()
        }
    }

    private func fadeHint() {
        UIView.animate(withDuration: 0.5) { self.hintLabel.alpha = 0 }
    }

    private func hideHint() {
        hintTask?.cancel()
        hintTask = nil
        UIView.animate(withDuration: 0.15) { self.hintLabel.alpha = 0 }
    }

    /// It's wanted while nothing is selected (and nothing is being dragged); it comes back each time that becomes true.
    private func updateHint() {
        let want = controls.selected == nil && !controls.isTrying && !dragging
        guard want != hintWanted else { return }
        hintWanted = want
        if want { showHint() } else { hideHint() }
    }

    // MARK: Tray

    /// "Left bumper (LB)" is long for a chip, so the bracketed short form wins where there is one.
    private func chipTitle(_ element: OSCElement) -> String {
        let title = element.title
        if let open = title.firstIndex(of: "("), let close = title.firstIndex(of: ")"), open < close {
            return String(title[title.index(after: open)..<close])
        }
        return title
    }

    private func rebuildChips() {
        let removed = controls.hiddenElements
        chipScroll.isHidden = removed.isEmpty
        guard removed != chipsShown else { return }
        chipsShown = removed
        for chip in chipStack.arrangedSubviews { chip.removeFromSuperview() }
        for element in removed {
            var config = UIButton.Configuration.tinted()
            config.title = "+ " + chipTitle(element)
            config.cornerStyle = .capsule
            config.buttonSize = .small
            config.baseBackgroundColor = OSCGlass.blue
            config.baseForegroundColor = .white
            let chip = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.controls.restore(element) })
            chip.accessibilityLabel = "Put back \(element.title)"
            chipStack.addArrangedSubview(chip)
        }
    }

    /// The tray shows while a control is dragged or something is removed.
    private func updateTray(animated: Bool) {
        let visible = !controls.isTrying && (dragging || !controls.hiddenElements.isEmpty)
        tray.isUserInteractionEnabled = visible
        if animated {
            UIView.animate(withDuration: 0.18) { self.tray.alpha = visible ? 1 : 0 }
        } else {
            tray.alpha = visible ? 1 : 0
        }
    }

    /// The controller reports a drag in progress (element and finger position in its view), and its end (nil, nil).
    private func dragChanged(_ element: OSCElement?, _ location: CGPoint?) {
        let now = element != nil
        if now != dragging {
            dragging = now
            updateHint()
            updateTray(animated: true)
            layoutIfNeeded()  // `layoutSubviews` hands the controls the bin's frame
        }
        let over = now && location.map { controls.binFrame?.contains($0) ?? false } == true
        guard over != overBin else { return }
        overBin = over
        if over { tick.selectionChanged() }
        binButton.setImage(UIImage(systemName: over ? "trash.fill" : "trash"), for: .normal)
        UIView.animate(withDuration: 0.15) {
            self.binButton.backgroundColor = over ? UIColor.systemRed.withAlphaComponent(0.4) : .clear
            self.binButton.tintColor = over ? UIColor.systemRed : UIColor.white.withAlphaComponent(0.9)
            self.binButton.transform = over ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity
        }
    }

    func refresh() {
        let selected = controls.selected
        let item = selected.map { controls.layout.item($0) }
        let canEdit = item != nil && !controls.isTrying
        sizeSlider.isEnabled = canEdit
        sizeNote.isHidden = canEdit
        if let item { sizeSlider.value = Float(item.scale) }
        sizeValue.text = item.map { "\(Int(($0.scale * 100).rounded()))%" } ?? "–"
        opacitySlider.value = Float(controls.layout.opacity)
        opacityValue.text = "\(Int((controls.layout.opacity * 100).rounded()))%"
        rebuildChips()
        rebuildMenu()
        updateTray(animated: window != nil)
        updateHint()
    }

    // MARK: Actions

    @objc private func sizeChanged() {
        controls.setSelectedScale(Double(sizeSlider.value))
        let scale = controls.selected.map { controls.layout.item($0).scale } ?? 1
        sizeValue.text = "\(Int((scale * 100).rounded()))%"
    }

    @objc private func opacityChanged() {
        controls.setOpacity(Double(opacitySlider.value))
        opacityValue.text = "\(Int((controls.layout.opacity * 100).rounded()))%"
    }

    @objc private func sliderReleased() { controls.persistLayout() }
    @objc private func appearanceTapped() { setAppearanceOpen(!appearanceOpen) }
    @objc private func catcherTapped() { setAppearanceOpen(false) }

    /// Tapping the bin removes the selected control, for a player who would rather tap than drag.
    @objc private func binTapped() {
        guard let selected = controls.selected, !controls.layout.item(selected).hidden else { return }
        controls.toggleSelectedHidden()
        controls.select(nil)
    }

    @objc private func doneTapped() {
        controls.persistLayout()
        done()
    }
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
    enum Preview { case none, selected, playing, options, removed, toggle, trying }

    private let canvas = OSCCanvasView()
    private let backdrop = OSCBackdropView()
    private let recorder = OSCRecordingOutput()
    private var controls: TrueCloudOnScreenControls!
    private var panel: OSCEditorPanel?
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

        if preview != .playing && preview != .toggle {
            let panel = OSCEditorPanel(controls: controls, showsTryIt: true) { [weak self] in self?.close() }
            panel.translatesAutoresizingMaskIntoConstraints = false
            // The controls are drawn on high layers; the chrome has to sit above them so the bin shows under a dragged control.
            panel.layer.zPosition = 2000
            view.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: view.topAnchor),
                panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            panel.extraActions = [sceneAction()]
            self.panel = panel
        }
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
        case .options:
            controls.select(.face)
            panel?.setAppearanceOpen(true, animated: false)
        case .removed:
            // Two controls out, so the tray's chips show.
            for element in [OSCElement.lb, .rb] {
                controls.select(element)
                if !controls.layout.item(element).hidden { controls.toggleSelectedHidden() }
            }
            controls.select(.face)
        case .toggle:
            // The in-stream gamepad switch over a fake stream: controls live (not arranging), floating sticks on.
            controls.isTrying = true
            controls.setFloatingSticks(true)
            controls.installGamepadToggle(force: true)
        case .trying:
            controls.isTrying = true
        case .playing:
            // Hold a few controls down so the lit glass shows.
            controls.isTrying = true
            controls.simulateHold(.a, id: 9001)
            controls.simulateHold(.rb, id: 9002)
            controls.simulateHold(.right, id: 9003)
            controls.simulateStick(left: true, dx: 0.62, dy: -0.38, id: 9004)
        }
    }

    /// The `…` menu's switch between the night and day stand-in scenes.
    private func sceneAction() -> UIAction {
        UIAction(title: backdrop.bright ? "Night background" : "Day background",
                 image: UIImage(systemName: backdrop.bright ? "moon.stars" : "sun.max")) { [weak self] _ in self?.toggleScene() }
    }

    private func toggleScene() {
        backdrop.bright.toggle()
        panel?.extraActions = [sceneAction()]
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
