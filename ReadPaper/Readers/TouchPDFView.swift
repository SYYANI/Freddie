#if os(iOS)
import PDFKit
import UIKit

struct PDFPencilStrokeSample: Equatable {
    var point: CGPoint
    /// Normalized force in the closed range 0...1.
    var pressure: CGFloat
}

private struct PDFPencilDisplaySample {
    var point: CGPoint
    var width: CGFloat
}

enum PDFPencilInkDynamics {
    static func displayWidth(baseWidth: CGFloat, pressure: CGFloat) -> CGFloat {
        let normalized = min(max(pressure, 0), 1)
        // A non-zero light-touch floor keeps handwriting legible; the curved
        // response avoids the jumpy width changes of raw Pencil force values.
        let scale = 0.38 + 1.42 * CGFloat(pow(Double(normalized), 0.72))
        return max(0.18, baseWidth * scale)
    }
}

enum PDFPencilShortcutAction: Equatable {
    case undo
    case toggleEraser
    case selectColor(PDFAnnotationColorPreset)
}

/// The touch counterpart of InteractivePDFView's live-magnify handling.
final class TouchPDFView: PDFView, UIPencilInteractionDelegate {
    var onInitialLayoutReady: (() -> Void)?
    var onPencilDoubleTap: (() -> Void)?
    var onPencilShortcutAction: ((PDFPencilShortcutAction) -> Void)?
    var annotationInteractionMode: PDFInteractionMode = .browse {
        didSet { radialToolPalette.showsPenAsToggleTarget = annotationInteractionMode == .erase }
    }
    var annotationColorPreset: PDFAnnotationColorPreset = .yellow {
        didSet { radialToolPalette.currentColorPreset = annotationColorPreset }
    }
    private let observedPinches = NSHashTable<UIPinchGestureRecognizer>.weakObjects()
    private let pencilInteraction = UIPencilInteraction()
    private let radialToolPalette = PDFPencilRadialToolPaletteView()

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        configurePencilShortcuts()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePencilShortcuts()
    }

    private func configurePencilShortcuts() {
        pencilInteraction.delegate = self
        addInteraction(pencilInteraction)
        radialToolPalette.frame = bounds
        radialToolPalette.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(radialToolPalette)
    }

    func cancelPencilShortcutPalette() {
        radialToolPalette.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        radialToolPalette.frame = bounds
        bringSubviewToFront(radialToolPalette)
        observePinches(in: self)
        if window != nil, !bounds.isEmpty, let action = onInitialLayoutReady {
            onInitialLayoutReady = nil
            // Let PDFKit's child scroll view finish its first layout as well.
            Task { @MainActor in action() }
        }
    }

    private func observePinches(in view: UIView) {
        for case let pinch as UIPinchGestureRecognizer in view.gestureRecognizers ?? [] {
            guard !observedPinches.contains(pinch) else { continue }
            observedPinches.add(pinch)
            // Keep PDFKit's recognizer and delegate so zooming and text selection still work.
            pinch.addTarget(self, action: #selector(pinchChanged(_:)))
        }
        // PDFKit zooms its scroll view; don't walk every rendered page on every layout.
        if view is UIScrollView { return }
        for child in view.subviews {
            observePinches(in: child)
        }
    }

    @objc func pinchChanged(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed {
            // PDFKit can leave autoScales enabled after replacing the document. A later
            // layout would then discard the user's zoom, just as on macOS.
            autoScales = false
        }
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        onPencilDoubleTap?()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveTap tap: UIPencilInteraction.Tap
    ) {
        onPencilDoubleTap?()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        let location = squeeze.hoverPose?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
        switch squeeze.phase {
        case .began:
            radialToolPalette.begin(at: location)
        case .changed:
            radialToolPalette.update(at: location)
        case .ended:
            if let action = radialToolPalette.finish(at: location) {
                onPencilShortcutAction?(action)
            }
        case .cancelled:
            radialToolPalette.cancel()
        @unknown default:
            radialToolPalette.cancel()
        }
    }
}

/// A page-sized, transparent interaction surface supplied through
/// `PDFPageOverlayViewProvider`. PDFKit keeps it aligned with its page while
/// scrolling and zooming, and the recognizer only accepts Apple Pencil input so
/// fingers can continue to navigate the document.
@MainActor
final class PDFPencilPageOverlayView: UIView {
    private(set) weak var pdfView: PDFView?
    private(set) weak var pdfPage: PDFPage?
    var interactionMode: PDFInteractionMode = .browse {
        didSet {
            guard oldValue != interactionMode else { return }
            cancelInteraction()
            isUserInteractionEnabled = interactionMode != .browse
        }
    }
    var inkColor: UIColor = .systemYellow {
        didSet { refreshActiveInkLayer() }
    }
    var inkLineWidth: CGFloat = 2 {
        didSet { refreshActiveInkLayer() }
    }
    var onInteractionBegan: (() -> Void)?
    var onInkStrokeCompleted: (([PDFPencilStrokeSample]) -> Void)?
    var onEraseRequested: ((CGPoint) -> Void)?
    var onTextNoteRequested: ((CGPoint) -> Void)?

    private let pencilRecognizer = PDFPencilStrokeGestureRecognizer()
    private let activeInkLayer = CAShapeLayer()
    private var persistedInkLayers: [CAShapeLayer] = []
    private var inkSamples: [PDFPencilStrokeSample] = []
    private var persistedInkRecords: [PDFAnnotationRecord] = []
    private var lastHandledPointCount = 0
    private var interactionStartPoint: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        contentScaleFactor = UIScreen.main.scale
        layer.shouldRasterize = false
        activeInkLayer.fillRule = .nonZero
        activeInkLayer.shouldRasterize = false
        activeInkLayer.allowsEdgeAntialiasing = true
        activeInkLayer.actions = [
            "path": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
        ]
        layer.addSublayer(activeInkLayer)
        isMultipleTouchEnabled = false
        isUserInteractionEnabled = false
        pencilRecognizer.addTarget(self, action: #selector(handlePencilStroke(_:)))
        addGestureRecognizer(pencilRecognizer)
    }

    func bind(to page: PDFPage, in pdfView: PDFView) {
        self.pdfPage = page
        self.pdfView = pdfView
        refreshRenderingScale()
        refreshPersistedInkLayers()
        refreshActiveInkLayer()
    }

    func displayPersistedInk(_ records: [PDFAnnotationRecord]) {
        guard persistedInkRecords != records else { return }
        persistedInkRecords = records
        refreshPersistedInkLayers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // PDFKit can resize or transform page overlays while zooming. Redrawing
        // keeps saved paths at the screen's native resolution.
        refreshRenderingScale()
        refreshPersistedInkLayers()
        refreshActiveInkLayer()
    }

    func refreshRenderingScale() {
        guard let window else { return }
        let origin = convert(CGPoint.zero, to: window)
        let unitX = convert(CGPoint(x: 1, y: 0), to: window)
        let unitY = convert(CGPoint(x: 0, y: 1), to: window)
        let transformedScale = max(
            hypot(unitX.x - origin.x, unitX.y - origin.y),
            hypot(unitY.x - origin.x, unitY.y - origin.y),
            1
        )
        // Visible page overlays are few, so spending extra backing resolution
        // here is preferable to magnifying a 1x page-layer bitmap while zoomed.
        let desiredScale = min(window.screen.scale * transformedScale, 4)
        guard abs(contentScaleFactor - desiredScale) > 0.01 else { return }
        contentScaleFactor = desiredScale
        layer.contentsScale = desiredScale
        for inkLayer in persistedInkLayers {
            inkLayer.contentsScale = desiredScale
        }
        activeInkLayer.contentsScale = desiredScale
    }

    func refreshVectorInk() {
        refreshRenderingScale()
        refreshPersistedInkLayers()
        refreshActiveInkLayer()
    }

    @objc private func handlePencilStroke(_ recognizer: PDFPencilStrokeGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onInteractionBegan?()
            interactionStartPoint = recognizer.samples.first?.point
            lastHandledPointCount = 0
            handleNewSamples(from: recognizer)
        case .changed:
            handleNewSamples(from: recognizer)
        case .ended:
            handleNewSamples(from: recognizer)
            finishInteraction(at: recognizer.samples.last?.point)
        case .cancelled, .failed:
            cancelInteraction()
        case .possible:
            break
        @unknown default:
            cancelInteraction()
        }
    }

    private func handleNewSamples(from recognizer: PDFPencilStrokeGestureRecognizer) {
        guard lastHandledPointCount < recognizer.samples.count else { return }
        let newSamples = recognizer.samples[lastHandledPointCount...]
        lastHandledPointCount = recognizer.samples.count

        switch interactionMode {
        case .ink:
            inkSamples.append(contentsOf: newSamples)
            refreshActiveInkLayer()
        case .erase:
            for sample in newSamples {
                onEraseRequested?(sample.point)
            }
        case .browse, .textNote, .debugRegion:
            break
        }
    }

    private func finishInteraction(at point: CGPoint?) {
        defer { cancelInteraction() }
        switch interactionMode {
        case .ink:
            guard inkSamples.count >= 2 else { return }
            onInkStrokeCompleted?(inkSamples)
        case .textNote:
            guard let start = interactionStartPoint,
                  let point,
                  hypot(point.x - start.x, point.y - start.y) <= 12
            else {
                return
            }
            onTextNoteRequested?(point)
        case .browse, .erase, .debugRegion:
            break
        }
    }

    func cancelInteraction() {
        interactionStartPoint = nil
        inkSamples = []
        lastHandledPointCount = 0
        activeInkLayer.path = nil
    }

    private func refreshPersistedInkLayers() {
        for inkLayer in persistedInkLayers {
            inkLayer.removeFromSuperlayer()
        }
        persistedInkLayers = []

        for record in persistedInkRecords {
            let color = record.color.platformColor(inverted: false).withAlphaComponent(1)
            if let samplePaths = record.inkSamplePaths, samplePaths.isEmpty == false {
                for path in samplePaths {
                    let samples = path.compactMap { sample -> PDFPencilDisplaySample? in
                        guard let point = overlayPoint(for: sample.cgPoint) else { return nil }
                        return PDFPencilDisplaySample(
                            point: point,
                            width: overlayLineWidth(forPageWidth: CGFloat(sample.width))
                        )
                    }
                    guard let outline = variableOutlinePath(for: samples) else { continue }
                    let shapeLayer = makeInkShapeLayer()
                    shapeLayer.path = outline
                    shapeLayer.fillColor = color.cgColor
                    shapeLayer.strokeColor = nil
                    installPersistedInkLayer(shapeLayer)
                }
            } else {
                let width = overlayLineWidth(forPageWidth: record.lineWidth)
                for path in record.inkPaths {
                    guard let centerline = fixedPath(
                        for: path.map(\.cgPoint).compactMap(overlayPoint(for:))
                    ) else {
                        continue
                    }
                    let shapeLayer = makeInkShapeLayer()
                    shapeLayer.path = centerline
                    shapeLayer.fillColor = nil
                    shapeLayer.strokeColor = color.cgColor
                    shapeLayer.lineWidth = width
                    shapeLayer.lineCap = .round
                    shapeLayer.lineJoin = .round
                    installPersistedInkLayer(shapeLayer)
                }
            }
        }
    }

    private func refreshActiveInkLayer() {
        activeInkLayer.frame = bounds
        activeInkLayer.contentsScale = contentScaleFactor
        guard interactionMode == .ink else {
            activeInkLayer.path = nil
            return
        }
        let displaySamples = inkSamples.map { sample in
            PDFPencilDisplaySample(
                point: sample.point,
                width: max(
                    0.5,
                    PDFPencilInkDynamics.displayWidth(
                        baseWidth: inkLineWidth,
                        pressure: sample.pressure
                    )
                )
            )
        }
        activeInkLayer.path = variableOutlinePath(for: displaySamples)
        activeInkLayer.fillColor = inkColor.withAlphaComponent(1).cgColor
        activeInkLayer.strokeColor = nil
    }

    private func installPersistedInkLayer(_ inkLayer: CAShapeLayer) {
        inkLayer.frame = bounds
        inkLayer.contentsScale = contentScaleFactor
        persistedInkLayers.append(inkLayer)
        layer.insertSublayer(inkLayer, below: activeInkLayer)
    }

    private func makeInkShapeLayer() -> CAShapeLayer {
        let shapeLayer = CAShapeLayer()
        shapeLayer.fillRule = .nonZero
        shapeLayer.shouldRasterize = false
        shapeLayer.allowsEdgeAntialiasing = true
        shapeLayer.actions = [
            "path": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
        ]
        return shapeLayer
    }

    private func fixedPath(for points: [CGPoint]) -> CGPath? {
        guard let firstPoint = points.first, points.count > 1 else { return nil }
        let path = UIBezierPath()
        path.move(to: firstPoint)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path.cgPath
    }

    private func variableOutlinePath(for samples: [PDFPencilDisplaySample]) -> CGPath? {
        guard let first = samples.first else { return nil }
        guard samples.count > 1 else {
            return UIBezierPath(
                ovalIn: CGRect(
                    x: first.point.x - first.width / 2,
                    y: first.point.y - first.width / 2,
                    width: first.width,
                    height: first.width
                )
            ).cgPath
        }

        let outlineSamples = samples.indices.map { index -> (left: CGPoint, right: CGPoint) in
            let sample = samples[index]
            let previous = samples[max(index - 1, 0)].point
            let next = samples[min(index + 1, samples.count - 1)].point
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(hypot(dx, dy), 0.001)
            let normal = CGVector(dx: -dy / length, dy: dx / length)
            let radius = sample.width / 2
            return (
                CGPoint(x: sample.point.x + normal.dx * radius, y: sample.point.y + normal.dy * radius),
                CGPoint(x: sample.point.x - normal.dx * radius, y: sample.point.y - normal.dy * radius)
            )
        }

        let outline = UIBezierPath()
        appendSmoothed(outlineSamples.map { $0.left }, to: outline, moveToStart: true)
        appendSmoothed(outlineSamples.reversed().map { $0.right }, to: outline, moveToStart: false)
        outline.close()

        for endpoint in [first, samples[samples.count - 1]] {
            outline.append(UIBezierPath(
                ovalIn: CGRect(
                    x: endpoint.point.x - endpoint.width / 2,
                    y: endpoint.point.y - endpoint.width / 2,
                    width: endpoint.width,
                    height: endpoint.width
                )
            ))
        }
        return outline.cgPath
    }

    private func appendSmoothed(
        _ points: [CGPoint],
        to path: UIBezierPath,
        moveToStart: Bool
    ) {
        guard let first = points.first else { return }
        if moveToStart {
            path.move(to: first)
        } else {
            path.addLine(to: first)
        }
        guard points.count > 2 else {
            if let last = points.last { path.addLine(to: last) }
            return
        }
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, controlPoint: control)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
    }

    private func overlayPoint(for pagePoint: CGPoint) -> CGPoint? {
        guard let pdfView, let pdfPage else { return nil }
        return convert(pdfView.convert(pagePoint, from: pdfPage), from: pdfView)
    }

    private func overlayLineWidth(forPageWidth pageWidth: CGFloat) -> CGFloat {
        guard let pdfView, let pdfPage else { return max(0.5, pageWidth) }
        let pageBounds = pdfPage.bounds(for: .cropBox)
        let origin = pageBounds.origin
        let end = CGPoint(x: origin.x + pageWidth, y: origin.y)
        let overlayOrigin = convert(pdfView.convert(origin, from: pdfPage), from: pdfView)
        let overlayEnd = convert(pdfView.convert(end, from: pdfPage), from: pdfView)
        return max(0.5, hypot(overlayEnd.x - overlayOrigin.x, overlayEnd.y - overlayOrigin.y))
    }
}

@MainActor
private final class PDFPencilRadialToolPaletteView: UIView {
    private enum Stage {
        case root
        case colors
    }

    private enum RootSelection: Equatable {
        case undo
        case colors
        case toggleEraser
    }

    var showsPenAsToggleTarget = false {
        didSet { setNeedsDisplay() }
    }
    var currentColorPreset: PDFAnnotationColorPreset = .yellow {
        didSet { setNeedsDisplay() }
    }

    private var paletteCenter: CGPoint = .zero
    private var gestureOrigin: CGPoint = .zero
    private var stage: Stage = .root
    private var rootSelection: RootSelection?
    private var selectedColor: PDFAnnotationColorPreset?
    private let innerRadius: CGFloat = 28
    private let outerRadius: CGFloat = 82
    private let colorPresets: [PDFAnnotationColorPreset] = [.red, .yellow, .green, .blue, .purple]

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isHidden = true
    }

    func begin(at location: CGPoint) {
        layer.removeAllAnimations()
        gestureOrigin = location
        paletteCenter = CGPoint(
            x: min(max(location.x, outerRadius + 8), max(bounds.width - outerRadius - 8, outerRadius + 8)),
            y: min(max(location.y, outerRadius + 8), max(bounds.height - 16, outerRadius + 8))
        )
        stage = .root
        rootSelection = nil
        selectedColor = nil
        alpha = 0
        isHidden = false
        setNeedsDisplay()
        UIView.animate(withDuration: 0.12) { self.alpha = 1 }
    }

    func update(at location: CGPoint) {
        let polar = polarPosition(of: location)
        switch stage {
        case .root:
            let nextSelection = rootSelection(for: polar)
            guard rootSelection != nextSelection else { return }
            rootSelection = nextSelection
            if nextSelection == .colors {
                stage = .colors
                rootSelection = nil
                selectedColor = colorSelection(for: polar)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } else if nextSelection != nil {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        case .colors:
            let nextColor = colorSelection(for: polar)
            guard selectedColor != nextColor else { return }
            selectedColor = nextColor
            if nextColor != nil {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        setNeedsDisplay()
    }

    func finish(at location: CGPoint) -> PDFPencilShortcutAction? {
        update(at: location)
        let action: PDFPencilShortcutAction? = switch stage {
        case .colors:
            selectedColor.map { .selectColor($0) }
        case .root:
            switch rootSelection {
            case .undo: .undo
            case .toggleEraser: .toggleEraser
            case .colors, nil: nil
            }
        }
        cancel()
        return action
    }

    func cancel() {
        UIView.animate(withDuration: 0.1, animations: {
            self.alpha = 0
        }) { _ in
            self.isHidden = true
            self.stage = .root
            self.rootSelection = nil
            self.selectedColor = nil
        }
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard isHidden == false else { return }

        switch stage {
        case .root:
            drawRootPalette()
        case .colors:
            drawColorPalette()
        }
    }

    private func drawRootPalette() {
        let sectorAngle = CGFloat.pi / 3
        let items: [(RootSelection, String)] = [
            (.undo, "arrow.uturn.backward"),
            (.colors, "paintpalette.fill"),
            (.toggleEraser, showsPenAsToggleTarget ? "pencil.tip" : "eraser.fill"),
        ]
        for (index, item) in items.enumerated() {
            let start = CGFloat.pi + CGFloat(index) * sectorAngle
            let end = start + sectorAngle
            let selected = rootSelection == item.0
            drawSector(
                from: start,
                to: end,
                selected: selected,
                fillColor: .secondarySystemBackground
            )
            drawSymbol(
                item.1,
                angle: (start + end) / 2,
                tint: selected ? .white : .label
            )
        }
    }

    private func drawColorPalette() {
        let sectorAngle = CGFloat.pi / CGFloat(colorPresets.count)
        for (index, preset) in colorPresets.enumerated() {
            let start = CGFloat.pi + CGFloat(index) * sectorAngle
            let end = start + sectorAngle
            let selected = selectedColor == preset
            drawSector(
                from: start,
                to: end,
                selected: selected,
                fillColor: preset.color(for: .ink).platformColor(inverted: false),
                preservesSelectedFill: true
            )
            if preset == currentColorPreset, selected == false {
                drawSymbol("checkmark", angle: (start + end) / 2, tint: .white)
            }
        }
    }

    private func drawSector(
        from startAngle: CGFloat,
        to endAngle: CGFloat,
        selected: Bool,
        fillColor: UIColor,
        preservesSelectedFill: Bool = false
    ) {
        let path = UIBezierPath()
        path.addArc(
            withCenter: paletteCenter,
            radius: outerRadius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        path.addArc(
            withCenter: paletteCenter,
            radius: innerRadius,
            startAngle: endAngle,
            endAngle: startAngle,
            clockwise: false
        )
        path.close()
        let resolvedFill = selected && preservesSelectedFill == false
            ? UIColor.systemBlue
            : fillColor.withAlphaComponent(0.96)
        resolvedFill.setFill()
        path.fill()
        (selected ? UIColor.white : UIColor.separator).setStroke()
        path.lineWidth = selected ? 3 : 1
        path.stroke()
    }

    private func drawSymbol(_ name: String, angle: CGFloat, tint: UIColor) {
        guard let image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        ) else {
            return
        }
        let radius = (innerRadius + outerRadius) / 2
        let center = CGPoint(
            x: paletteCenter.x + cos(angle) * radius,
            y: paletteCenter.y + sin(angle) * radius
        )
        let size = image.size
        image.withTintColor(tint, renderingMode: .alwaysOriginal).draw(
            in: CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        )
    }

    private func polarPosition(of location: CGPoint) -> (distance: CGFloat, angle: CGFloat?) {
        let dx = location.x - gestureOrigin.x
        let dy = location.y - gestureOrigin.y
        let distance = hypot(dx, dy)
        var angle = atan2(dy, dx)
        if angle < 0 { angle += .pi * 2 }
        guard angle >= .pi, angle <= .pi * 2 else {
            return (distance, nil)
        }
        return (distance, angle)
    }

    private func rootSelection(
        for polar: (distance: CGFloat, angle: CGFloat?)
    ) -> RootSelection? {
        guard polar.distance >= 18, let angle = polar.angle else { return nil }
        let offset = angle - .pi
        if offset < .pi / 3 { return .undo }
        if offset < .pi * 2 / 3 { return .colors }
        return .toggleEraser
    }

    private func colorSelection(
        for polar: (distance: CGFloat, angle: CGFloat?)
    ) -> PDFAnnotationColorPreset? {
        guard polar.distance >= 18, let angle = polar.angle else { return nil }
        let normalized = min(max((angle - .pi) / .pi, 0), 0.999_999)
        let index = min(Int(normalized * CGFloat(colorPresets.count)), colorPresets.count - 1)
        return colorPresets[index]
    }
}

/// Captures the full Apple Pencil sample stream. Only actual and coalesced
/// samples are retained; predicted samples are intentionally excluded from the
/// persisted PDF path.
@MainActor
private final class PDFPencilStrokeGestureRecognizer: UIGestureRecognizer {
    private(set) var samples: [PDFPencilStrokeSample] = []
    private weak var trackedTouch: UITouch?
    private var estimatedForceSampleIndices: [NSNumber: Int] = [:]

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil,
              let touch = touches.first,
              let view
        else {
            state = .failed
            return
        }
        trackedTouch = touch
        samples = [makeSample(from: touch, in: view)]
        registerEstimatedForce(for: touch, sampleIndex: 0)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch,
              touches.contains(trackedTouch),
              let view
        else {
            return
        }
        appendSamples(for: trackedTouch, event: event, in: view)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch,
              touches.contains(trackedTouch),
              let view
        else {
            return
        }
        appendSamples(for: trackedTouch, event: event, in: view)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches {
            guard touch.estimatedPropertiesExpectingUpdates.contains(.force) == false,
                  let updateIndex = touch.estimationUpdateIndex,
                  let sampleIndex = estimatedForceSampleIndices.removeValue(forKey: updateIndex),
                  samples.indices.contains(sampleIndex)
            else {
                continue
            }
            samples[sampleIndex].pressure = normalizedPressure(for: touch)
        }
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        samples = []
        estimatedForceSampleIndices = [:]
    }

    private func appendSamples(for touch: UITouch, event: UIEvent, in view: UIView) {
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        for touchSample in samples {
            let sample = makeSample(from: touchSample, in: view)
            if let previous = self.samples.last,
               hypot(sample.point.x - previous.point.x, sample.point.y - previous.point.y) < 0.1 {
                continue
            }
            self.samples.append(sample)
            registerEstimatedForce(for: touchSample, sampleIndex: self.samples.count - 1)
        }
    }

    private func makeSample(from touch: UITouch, in view: UIView) -> PDFPencilStrokeSample {
        let rawPoint = touch.preciseLocation(in: view)
        let rawPressure = normalizedPressure(for: touch)
        guard let previous = samples.last else {
            return PDFPencilStrokeSample(
                point: rawPoint,
                pressure: rawPressure
            )
        }

        // Low-latency position filtering plus stronger pressure filtering gives
        // a stable, filled stroke without the waviness of raw sensor samples.
        return PDFPencilStrokeSample(
            point: CGPoint(
                x: previous.point.x * 0.24 + rawPoint.x * 0.76,
                y: previous.point.y * 0.24 + rawPoint.y * 0.76
            ),
            pressure: previous.pressure * 0.68 + rawPressure * 0.32
        )
    }

    private func normalizedPressure(for touch: UITouch) -> CGFloat {
        let maximumForce = touch.maximumPossibleForce
        let pressure = maximumForce > 0 ? touch.force / maximumForce : 0.5
        return min(max(pressure, 0.05), 1)
    }

    private func registerEstimatedForce(for touch: UITouch, sampleIndex: Int) {
        guard touch.estimatedPropertiesExpectingUpdates.contains(.force),
              let updateIndex = touch.estimationUpdateIndex
        else {
            return
        }
        estimatedForceSampleIndices[updateIndex] = sampleIndex
    }
}
#endif
