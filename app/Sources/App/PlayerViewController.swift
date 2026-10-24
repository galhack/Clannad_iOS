import SwiftUI
import UIKit
import QuartzCore
import GameController

// MARK: - Metal-backed view for wgpu

/// The engine renders into a `CAMetalLayer`; this view supplies it and owns
/// the gesture recognisers (the touch input is translated to the engine's
/// logical mouse coordinates by the view controller).
final class SiglusMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = true
        if let layer = self.layer as? CAMetalLayer {
            layer.isOpaque = true
            layer.framebufferOnly = false
        }
    }

    func configure(scale: CGFloat) {
        contentScaleFactor = scale
        if let layer = self.layer as? CAMetalLayer {
            layer.contentsScale = scale
        }
    }

    func configure(drawableSize: CGSize) {
        if let layer = self.layer as? CAMetalLayer {
            layer.drawableSize = drawableSize
        }
    }
}

// MARK: - hidden text input for the game's name entry

/// A text field that never shows its own text: it only turns the system
/// keyboard (and an IME's pre-edit) into calls on the engine's editbox.
final class SiglusTextInputField: UITextField {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onPreedit: ((String) -> Void)?
    var onReturn: (() -> Void)?

    override func insertText(_ text: String) {
        if text == "\n" || text == "\r" {
            onReturn?()
            return
        }
        onInsertText?(text)
    }

    override func deleteBackward() {
        onDeleteBackward?()
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        onPreedit?(markedText ?? "")
    }

    override func unmarkText() {
        onPreedit?("")
    }
}

// MARK: - the player

/// Hosts the Siglus engine: creates it on first layout, steps it from a
/// CADisplayLink on the main thread, maps touch / keyboard / gamepad input,
/// and mirrors the engine's native message boxes as UIKit alerts.
final class SiglusPlayerViewController: UIViewController, UIGestureRecognizerDelegate {
    private let gameRoot: URL
    private let gameTitle: String
    private let onExit: () -> Void

    private var handle: UnsafeMutableRawPointer?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var lastDebugPoll: CFTimeInterval = 0
    private let performanceLog = PlayerPerformanceLog()
    private var didExit = false
    private var isActive = true

    private var metalView: SiglusMetalView { view as! SiglusMetalView }

    private var lastDrawableSizePx: (UInt32, UInt32) = (0, 0)
    private var lastScale: Double = 0
    private var logicalSize: (UInt32, UInt32) = (1280, 720)
    private var viewportPx: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 1, 1)
    private var viewportPoints: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    private var isFastForwarding = false
    private var controllers: [GCController] = []

    /// The three independent fast-forward sources: the on-screen button, the
    /// long-press gesture and the gamepad's right trigger.  The engine sees
    /// one held Control key while at least one of them is active.
    private var fastForwardButtonOn = false
    private var fastForwardGestureHeld = false
    private var fastForwardControllerHeld = false
    /// Engine-maintained skip-all state of the on-screen 快进 button.
    private var skipActive = false
    private var lastSkipPoll: CFTimeInterval = 0
    private var storySelection: PlayerStorySelection?
    private var choicePanel: PlayerChoicePanel?

    /// Touch-friendly control bar (game menu and fast-forward), shown while
    /// the player view is on screen only.
    private var controlBar: PlayerControlBar?
    private var controlFadeWorkItem: DispatchWorkItem?
    private static let controlIdleDelay: TimeInterval = 4.0
    private static let controlFadedAlpha: CGFloat = 0.8

    /// Name-entry keyboard state, driven by the engine's editbox flag.
    private var isEditboxActive = false
    private var hardwareKeyboard: GCKeyboardInput?
    private var hardwareKeyboardObservers: [NSObjectProtocol] = []

    /// The engine's first `create` performs the automatic resource-key
    /// recovery (seconds on a Mac, up to a minute on a phone), so it runs off
    /// the main thread behind a progress overlay.
    private var isCreatingEngine = false
    private var engineFailed = false
    private var loadingOverlay: UIView?
    private var pendingSurface: (wPx: UInt32, hPx: UInt32, scale: Double)?

    // Two-finger scroll accumulation.
    private var scrollAccumulator: CGFloat = 0

    init(gameRoot: URL, title: String, onExit: @escaping () -> Void) {
        self.gameRoot = gameRoot
        self.gameTitle = title
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
        #if !os(visionOS)
        modalPresentationStyle = .fullScreen
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        OrientationController.shared.lockedToLandscape = false
        #endif
        NotificationCenter.default.removeObserver(self)
        hardwareKeyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        hardwareKeyboardObservers.removeAll()
        controlFadeWorkItem?.cancel()
        releaseAllFastForward()
        displayLink?.invalidate()
        displayLink = nil
        if let handle {
            siglus_ios_set_native_messagebox_callback(handle, nil, nil)
            siglus_ios_destroy(handle)
        }
        handle = nil
    }

    // MARK: - lifecycle

    override func loadView() {
        view = SiglusMetalView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        installGestures()
        installTextField()
        registerForNotifications()
        setupGameControllers()
        setupHardwareKeyboard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lockToLandscape()
        updateHomeIndicator()
        startDisplayLink()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDisplayLink()
        view.endEditing(true)
        textField.resignFirstResponder()
        forwardPreedit("")
        releaseAllFastForward()
        hideControlBar()
        unlockOrientation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }

        let scale = currentScale()
        let wPx = UInt32(max(1.0, (view.bounds.width * CGFloat(scale)).rounded(.toNearestOrAwayFromZero)))
        let hPx = UInt32(max(1.0, (view.bounds.height * CGFloat(scale)).rounded(.toNearestOrAwayFromZero)))

        metalView.configure(scale: CGFloat(scale))
        metalView.configure(drawableSize: CGSize(width: CGFloat(wPx), height: CGFloat(hPx)))
        recomputeViewport(wPx: wPx, hPx: hPx, scale: scale)

        if handle == nil {
            if isCreatingEngine {
                pendingSurface = (wPx, hPx, scale)
            } else if !engineFailed {
                startEngineCreation(wPx: wPx, hPx: hPx, scale: scale)
            }
        } else if wPx != lastDrawableSizePx.0 || hPx != lastDrawableSizePx.1 || scale != lastScale {
            lastDrawableSizePx = (wPx, hPx)
            lastScale = scale
            siglus_ios_resize_viewport(handle, wPx, hPx, viewportPx.0, viewportPx.1, viewportPx.2, viewportPx.3)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        NSLog("Clannad: memory warning while playing %@ (the engine keeps its own GPU resources)", gameTitle)
    }

    private func currentScale() -> Double {
        #if os(visionOS)
        return Double(max(1.0, traitCollection.displayScale))
        #else
        let screenScale = view.window?.screen.scale ?? traitCollection.displayScale
        return Double(max(1.0, screenScale))
        #endif
    }

    private func registerForNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appWillResignActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(updateFrameRate),
                           name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(updateFrameRate),
                           name: .NSProcessInfoPowerStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(controlPreferencesChanged),
                           name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc private func appWillResignActive() {
        isActive = false
        stopDisplayLink()
        releaseAllFastForward()
        view.endEditing(true)
    }

    @objc private func appDidEnterBackground() {
        isActive = false
        stopDisplayLink()
        releaseAllFastForward()
        view.endEditing(true)
    }

    @objc private func appDidBecomeActive() {
        isActive = true
        controlPreferencesChanged()
        if view.window != nil && handle != nil {
            lastTimestamp = nil
            startDisplayLink()
        }
    }

    // MARK: - engine

    private func startEngineCreation(wPx: UInt32, hPx: UInt32, scale: Double) {
        isCreatingEngine = true
        pendingSurface = (wPx, hPx, scale)
        showLoadingOverlay()

        let rootPath = gameRoot.path
        NSLog("Clannad: creating engine (first launch may prepare resources) root=%@", rootPath)

        if let prepare = SiglusOptionalFFI.prepare {
            // `siglus_ios_prepare` is the GPU-free/UIKit-free first-launch
            // work (key recovery, resource index, fonts).  It is background
            // safe, so the spinner keeps animating while a phone spends
            // 10-60 s there.  Only the surface creation must be on the UI
            // thread (wgpu-hal asserts "get_metal_layer cannot be called in
            // non-ui thread").
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let status = rootPath.withCString { prepare($0) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if status < 0 {
                        self.isCreatingEngine = false
                        self.engineFailed = true
                        self.hideLoadingOverlay()
                        NSLog("Clannad: siglus_ios_prepare failed status=%d root=%@", status, rootPath)
                        self.presentEngineError("游戏目录校验失败（错误码 \(status)）。请确认游戏数据完整（SceneZH.pck、GameexeZH.dat、g00 等），并检查本机剩余存储空间。")
                        return
                    }
                    self.createEngineOnMainThread(wPx: wPx, hPx: hPx, scale: scale)
                }
            }
        } else {
            // Older framework without the prepare split: create does the key
            // recovery itself, so it has to run on the main thread (blocking).
            DispatchQueue.main.async { [weak self] in
                self?.createEngineOnMainThread(wPx: wPx, hPx: hPx, scale: scale)
            }
        }
    }

    private func createEngineOnMainThread(wPx: UInt32, hPx: UInt32, scale: Double) {
        let viewPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(metalView).toOpaque())
        let rootPath = gameRoot.path
        let created: UnsafeMutableRawPointer? = rootPath.withCString { root in
            siglus_ios_create(viewPtr, wPx, hPx, scale, root)
        }
        finishEngineCreation(created)
    }

    private func finishEngineCreation(_ created: UnsafeMutableRawPointer?) {
        isCreatingEngine = false
        hideLoadingOverlay()
        guard let created else {
            engineFailed = true
            NSLog("Clannad: engine failed to start with root %@", gameRoot.path)
            presentEngineError("游戏引擎无法启动。请确认游戏数据完整（SceneZH.pck、GameexeZH.dat、g00 等），并且本机剩余存储空间充足，然后重试。")
            return
        }
        handle = created
        var lw: UInt32 = 1280
        var lh: UInt32 = 720
        siglus_ios_logical_size(created, &lw, &lh)
        logicalSize = (max(1, lw), max(1, lh))

        let surface: (wPx: UInt32, hPx: UInt32, scale: Double)
        if let pending = pendingSurface {
            surface = pending
        } else if lastDrawableSizePx.0 > 0 {
            surface = (lastDrawableSizePx.0, lastDrawableSizePx.1, lastScale)
        } else {
            surface = (logicalSize.0, logicalSize.1, 1.0)
        }
        lastDrawableSizePx = (surface.0, surface.1)
        lastScale = surface.2
        recomputeViewport(wPx: surface.0, hPx: surface.1, scale: surface.2)
        siglus_ios_resize_viewport(created, surface.0, surface.1,
                                   viewportPx.0, viewportPx.1, viewportPx.2, viewportPx.3)

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        siglus_ios_set_native_messagebox_callback(created, siglusMessageboxBridge, userData)
        NSLog("Clannad: engine started, root=%@ logical=%dx%d surface=%dx%d@%.2f",
              gameRoot.path, logicalSize.0, logicalSize.1, surface.0, surface.1, surface.2)
        NSLog("Clannad: optional APIs prepare=%@ editbox=%@ mouse=%@ wheel=%@ menu=%@ skip=%@",
              SiglusOptionalFFI.prepare != nil ? "yes" : "no",
              SiglusOptionalFFI.editboxActive != nil ? "yes" : "no",
              SiglusOptionalFFI.mouseButton != nil ? "yes" : "no",
              SiglusOptionalFFI.wheel != nil ? "yes" : "no",
              SiglusOptionalFFI.openMenu != nil ? "yes" : "no",
              SiglusOptionalFFI.setSkip != nil ? "yes" : "no")
        if view.window != nil && isActive {
            startDisplayLink()
        }
        installControlBar()
        scheduleDebugTapsIfRequested()
        scheduleDebugKeysIfRequested()
        scheduleDebugClicksIfRequested()
        scheduleDebugMenuIfRequested()
        scheduleDebugFastForwardIfRequested()
    }

    /// `CLANNAD_AUTOTAP=<n>` taps the title menu a few times, so an unattended
    /// device run reaches the story for a screenshot.  Inert unless the
    /// environment variable (or the debug UserDefault) is set.
    private func scheduleDebugTapsIfRequested() {
        let raw = ProcessInfo.processInfo.environment["CLANNAD_AUTOTAP"]
            ?? UserDefaults.standard.string(forKey: "CLANNAD_AUTOTAP")
            ?? ""
        guard let taps = Int(raw), taps > 0 else { return }
        for index in 0..<taps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20.0 + Double(index) * 3.0) { [weak self] in
                guard let self, let handle = self.handle else { return }
                let x = Double(self.logicalSize.0) * 0.675
                let y = Double(self.logicalSize.1) * 0.454
                siglus_ios_touch(handle, 0, x, y)
                // A real tap holds the touch for at least one frame; the
                // engine coalesces a down+up inside a single frame into a move.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    siglus_ios_touch(handle, 2, x, y)
                }
            }
        }
    }

    /// Unattended input for validation runs (`CLANNAD_AUTOKEYS`, `CLANNAD_AUTOHOLD`).
    /// `CLANNAD_AUTKEYS=13:4000,32:6000` presses Windows VK 13 (Enter) after
    /// 4 s and VK 32 (Space) after 6 s; `CLANNAD_AUTOHOLD=17:12000` presses VK
    /// 17 (Control, the engine's fast-forward key) at 12 s and keeps it down.
    /// Both are inert unless the environment variables are set.
    private func scheduleDebugKeysIfRequested() {
        func setting(_ key: String) -> String? {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
            if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
            return nil
        }

        func keyCode(_ value: String) -> Int32? { Int32(value.trimmingCharacters(in: .whitespaces)) }

        NSLog("Clannad: debug keys hook (keys=%@ hold=%@)", setting("CLANNAD_AUTKEYS") ?? "-", setting("CLANNAD_AUTOHOLD") ?? "-")
        if let raw = setting("CLANNAD_AUTKEYS") {
            for spec in raw.split(separator: ",") {
                let parts = spec.split(separator: ":")
                guard parts.count >= 2,
                      let code = keyCode(String(parts[0])),
                      let delay = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000.0) { [weak self] in
                    guard let self, let handle = self.handle else { return }
                    siglus_ios_key_down(handle, code)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        siglus_ios_key_up(handle, code)
                    }
                }
            }
        }

        if let raw = setting("CLANNAD_AUTOHOLD") {
            let parts = raw.split(separator: ":")
            if parts.count >= 2, let code = keyCode(String(parts[0])),
               let delay = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000.0) { [weak self] in
                    guard let self, let handle = self.handle else { return }
                    NSLog("Clannad: debug holding VK %d", code)
                    siglus_ios_key_down(handle, code)
                }
            }
        }
    }

    /// Synthesise one mouse click: move first (the menu samples the hovered
    /// item on a frame boundary), then press and release.
    private func debugClick(_ handle: UnsafeMutableRawPointer, fx: Double, fy: Double) {
        // Convert view points exactly as a real finger does. The C API consumes
        // logical game coordinates, including the aspect-fit letterbox offset.
        let bounds = metalView.bounds.size
        let (x, y) = gamePoint(CGPoint(x: Double(bounds.width) * fx, y: Double(bounds.height) * fy))
        siglus_ios_touch(handle, 1, x, y)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self, self.handle == handle, !self.didExit else { return }
            siglus_ios_touch(handle, 0, x, y)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.handle == handle, !self.didExit else { return }
                siglus_ios_touch(handle, 2, x, y)
            }
        }
    }

    /// `CLANNAD_AUTOCLICK=<fx>,<fy>,<delayMs>[,<gain>]` clicks at a fraction of
    /// the logical screen after a delay; `<gain>` is the number of extra clicks
    /// 2 s apart (default 1).  Unattended validation only.
    private func scheduleDebugClicksIfRequested() {
        func setting(_ key: String) -> String? {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
            if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
            return nil
        }
        guard let raw = setting("CLANNAD_AUTOCLICK") else { return }
        // Separate entries with `;` to drive choices and save/load menus in
        // a bounded device replay. Each entry uses the same path as a real tap.
        for spec in raw.split(separator: ";") {
            let parts = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, let fx = Double(parts[0]), let fy = Double(parts[1]), let delay = Double(parts[2]) else { continue }
            let count = parts.count >= 4 ? (Int(parts[3]) ?? 1) : 1
            for index in 0..<max(1, count) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000.0 + Double(index) * 2.5) { [weak self] in
                    guard let self, let handle = self.handle, !self.didExit else { return }
                    NSLog("Clannad: debug click %d at %.3f,%.3f", index, fx, fy)
                    self.debugClick(handle, fx: fx, fy: fy)
                }
            }
        }
    }

    // MARK: - first-launch progress overlay

    private func showLoadingOverlay() {
        guard loadingOverlay == nil else { return }
        let overlay = UIView(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .black
        overlay.isUserInteractionEnabled = true

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        let title = UILabel()
        title.text = "正在校验游戏数据…"
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .white
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = UILabel()
        detail.text = "首次启动需要恢复加密资源的密钥，约需 30 秒（设备较慢时可能更久）。\n请保持应用在前台，不要退出。"
        detail.font = .systemFont(ofSize: 14)
        detail.textColor = UIColor.white.withAlphaComponent(0.75)
        detail.numberOfLines = 0
        detail.textAlignment = .center
        detail.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [spinner, title, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32),
        ])
        loadingOverlay = overlay
    }

    private func hideLoadingOverlay() {
        guard let overlay = loadingOverlay else { return }
        loadingOverlay = nil
        overlay.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.2, animations: {
            overlay.alpha = 0
        }, completion: { _ in
            overlay.removeFromSuperview()
        })
        // A modal presentation can swallow the animation completion; removing
        // the overlay unconditionally keeps it from lingering behind alerts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            overlay.removeFromSuperview()
        }
    }

    private func startDisplayLink() {
        if displayLink != nil { return }
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
        displayLink = link
        updateFrameRate()
        if let handle { siglus_ios_invalidate_frame(handle) }
        link.add(to: .main, forMode: .common)
        lastTimestamp = nil
    }

    @objc private func updateFrameRate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateFrameRate() }
            return
        }
        let info = ProcessInfo.processInfo
        let fps = PlayerFramePolicy.framesPerSecond(thermalState: info.thermalState,
                                                    lowPower: info.isLowPowerModeEnabled)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    @objc private func onDisplayLink(_ link: CADisplayLink) {
        guard let handle else { return }
        let now = link.timestamp
        let dtSec: Double
        if let last = lastTimestamp {
            dtSec = now - last
        } else {
            dtSec = link.duration
        }
        lastTimestamp = now
        let clamped = min(max(dtSec, 0.0), 0.2)
        let dtMs = UInt32((clamped * 1000.0).rounded(.toNearestOrAwayFromZero))

        let before = siglus_ios_frame_count(handle)
        let status = siglus_ios_step(handle, dtMs)
        let after = siglus_ios_frame_count(handle)
        performanceLog.record(at: now, frameCount: after)
        switch status {
        case 0:
            // Idle callbacks do not change engine UI. In particular, avoid
            // allocating and decoding the same story-choice JSON every tick.
            if after != before {
                pollEditboxState()
                pollSkipState()
                pollStorySelection()
                pollSystemInterfaceState()
            }
            if DebugScript.controlEnabled && now - lastDebugPoll >= 0.5 {
                lastDebugPoll = now
                if let command = DebugScript.consumeCommand() {
                    NSLog("Clannad: debug command %@", command.action)
                    switch command.action {
                    case "menu": controlBar?.triggerMenuForValidation()
                    case "two_finger_tap":
                        sendRightClick(at: CGPoint(x: metalView.bounds.midX, y: metalView.bounds.midY))
                    case "skip": controlBar?.triggerSkipForValidation()
                    case "tap":
                        if let x = command.x, let y = command.y,
                           x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) {
                            tapPlayerForValidation(at: CGPoint(x: metalView.bounds.width * x, y: metalView.bounds.height * y))
                        }
                    case "key":
                        if let key = command.key { tapKey(key) }
                    case "wheel":
                        if let delta = command.delta, (-10...10).contains(delta) { sendWheel(delta) }
                    default: NSLog("Clannad: unknown debug action %@", command.action)
                    }
                }
            }
        case 1:
            NSLog("Clannad: engine requested exit; returning to the launcher")
            exitPlayer()
        default:
            NSLog("Clannad: engine step failed with status %d", status)
            stopDisplayLink()
            DispatchQueue.main.async { [weak self] in
                self?.presentEngineError("游戏引擎发生错误（状态码 \(status)）。请返回启动页后重新开始；如果反复出现，请检查游戏数据是否完整。")
            }
        }
    }

    private func exitPlayer() {
        guard !didExit else { return }
        didExit = true
        stopDisplayLink()
        releaseAllFastForward()
        view.endEditing(true)
        hideControlBar()
        DispatchQueue.main.async { [weak self] in
            self?.onExit()
        }
    }

    private func presentEngineError(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "CLANNAD", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "返回启动页", style: .default) { [weak self] _ in
            self?.exitPlayer()
        })
        present(alert, animated: true)
    }

    // MARK: - viewport

    private func recomputeViewport(wPx: UInt32, hPx: UInt32, scale: Double) {
        let lw = Double(max(1, logicalSize.0))
        let lh = Double(max(1, logicalSize.1))
        let sw = Double(max(1, wPx))
        let sh = Double(max(1, hPx))
        let fit = min(sw / lw, sh / lh)
        let vw = UInt32(max(1.0, min(sw, (lw * fit).rounded())))
        let vh = UInt32(max(1.0, min(sh, (lh * fit).rounded())))
        let vx = (max(1, wPx) - vw) / 2
        let vy = (max(1, hPx) - vh) / 2
        viewportPx = (vx, vy, vw, vh)
        viewportPoints = CGRect(
            x: CGFloat(Double(vx) / max(scale, 1.0)),
            y: CGFloat(Double(vy) / max(scale, 1.0)),
            width: CGFloat(Double(vw) / max(scale, 1.0)),
            height: CGFloat(Double(vh) / max(scale, 1.0))
        )
        NSLog("[SIGLUS_IOS_VIEWPORT] swift bounds=%.1fx%.1f scale=%.2f drawable=%dx%d logical=%dx%d viewport_px=%dx%d+%d+%d",
              view.bounds.width, view.bounds.height, scale, wPx, hPx,
              logicalSize.0, logicalSize.1, viewportPx.2, viewportPx.3, viewportPx.0, viewportPx.1)
    }

    /// UIKit points -> the engine's logical (1280x720-ish) coordinates.
    private func gamePoint(_ point: CGPoint) -> (Double, Double) {
        let rect = viewportPoints
        let gx = (Double(point.x) - Double(rect.minX)) * Double(logicalSize.0) / max(Double(rect.width), 1.0)
        let gy = (Double(point.y) - Double(rect.minY)) * Double(logicalSize.1) / max(Double(rect.height), 1.0)
        return (gx, gy)
    }

    // MARK: - touch and gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.55

        // A tap must win only when there was no drag or long press.
        tap.require(toFail: pan)
        tap.require(toFail: longPress)
        twoFingerTap.require(toFail: twoFingerPan)

        #if targetEnvironment(macCatalyst)
        // The Mac's mouse and trackpad are "indirect" pointers: let the click
        // and drag gestures see them, and deliver trackpad/wheel scrolling to
        // the pan gesture (there are no two-finger touches on a Mac).
        let pointerTypes: [NSNumber] = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.direct.rawValue),
        ]
        tap.allowedTouchTypes = pointerTypes
        pan.allowedTouchTypes = pointerTypes
        twoFingerPan.allowedScrollTypesMask = [.continuous, .discrete]
        #endif

        for recognizer in [tap, twoFingerTap, pan, twoFingerPan, longPress] as [UIGestureRecognizer] {
            recognizer.delegate = self
            // A two-finger menu tap over a choice must cancel the buttons'
            // touches instead of also deciding a route when the fingers lift.
            recognizer.cancelsTouchesInView = recognizer === twoFingerTap
            metalView.addGestureRecognizer(recognizer)
        }

        #if targetEnvironment(macCatalyst)
        // A secondary click has no UIKit gesture; the context-menu
        // interaction is the documented hook.  Returning nil suppresses the
        // menu and forwards the click as the game's right button instead.
        metalView.addInteraction(UIContextMenuInteraction(delegate: self))
        #endif
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The game recognizers are installed on the bar's parent view. A button
        // tap must reach UIKit only, or it also advances/cancels the game menu.
        let menuGesture = (gestureRecognizer as? UITapGestureRecognizer)?.numberOfTouchesRequired == 2
        return Self.acceptsGameTouch(from: touch.view, menuGesture: menuGesture)
    }

    static func acceptsGameTouch(from touchedView: UIView?, menuGesture: Bool = false) -> Bool {
        if menuGesture {
            var candidate = touchedView
            while let view = candidate {
                if view is PlayerChoicePanel { return true }
                candidate = view.superview
            }
        }
        var candidate = touchedView
        while let view = candidate {
            if view is UIControl || view is PlayerControlBar { return false }
            candidate = view.superview
        }
        return true
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        noteUserActivity()
        tapGame(at: recognizer.location(in: metalView))
    }

    private func tapGame(at point: CGPoint) {
        guard let handle, choicePanel == nil else { return }
        let (x, y) = gamePoint(point)
        siglus_ios_touch(handle, 0, x, y)
        siglus_ios_touch(handle, 2, x, y)
    }

    private func tapPlayerForValidation(at point: CGPoint) {
        view.layoutIfNeeded()
        var hit = view.hitTest(point, with: nil)
        while let candidate = hit {
            if let button = candidate as? UIButton {
                button.sendActions(for: .touchUpInside)
                return
            }
            if candidate is PlayerChoicePanel { return }
            hit = candidate.superview
        }
        tapGame(at: point)
    }

    private func pollStorySelection() {
        guard let handle else { return }
        let size = siglus_ios_selection_json(handle, nil, 0)
        guard size > 0, size <= 1_048_576 else {
            choicePanel?.removeFromSuperview()
            choicePanel = nil
            storySelection = nil
            return
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let copied = bytes.withUnsafeMutableBufferPointer {
            siglus_ios_selection_json(handle, $0.baseAddress, $0.count)
        }
        guard copied == size,
              let selection = try? JSONDecoder().decode(PlayerStorySelection.self, from: Data(bytes)),
              selection != storySelection else { return }
        releaseAllFastForward()
        choicePanel?.removeFromSuperview()
        let panel = PlayerChoicePanel(choices: selection.choices, canCancel: selection.canCancel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onSelect = { [weak self] index in
            guard let self, self.handle == handle, !self.didExit else { return }
            let accepted = siglus_ios_select_choice(handle, selection.generation, Int32(index))
            NSLog("Clannad: story choice generation=%llu index=%d accepted=%d", selection.generation, index, accepted)
            if accepted != 0 {
                self.choicePanel?.removeFromSuperview()
                self.choicePanel = nil
                self.storySelection = nil
            }
        }
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if let controlBar { view.bringSubviewToFront(controlBar) }
        choicePanel = panel
        storySelection = selection
        UIAccessibility.post(notification: .screenChanged, argument: panel)
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        noteUserActivity()
        sendRightClick(at: recognizer.location(in: metalView))
    }

    private func sendRightClick(at point: CGPoint) {
        guard let handle else { return }
        let (x, y) = gamePoint(point)
        if let button = SiglusOptionalFFI.mouseButton {
            // Move the cursor first, then press/release the right button.
            siglus_ios_touch(handle, 1, x, y)
            button(handle, 1, 1)
            button(handle, 1, 0)
        } else {
            // The engine's iOS host only exposes the left button so far; the
            // Escape key is the PC equivalent of the right-click menu.
            tapKey(SiglusVK.escape)
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let handle else { return }
        noteUserActivity()
        let point = recognizer.location(in: metalView)
        let (x, y) = gamePoint(point)
        switch recognizer.state {
        case .began:
            siglus_ios_touch(handle, 0, x, y)
        case .changed:
            siglus_ios_touch(handle, 1, x, y)
        case .ended:
            siglus_ios_touch(handle, 2, x, y)
        case .cancelled, .failed:
            siglus_ios_touch(handle, 3, x, y)
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard handle != nil else { return }
        noteUserActivity()
        switch recognizer.state {
        case .began:
            scrollAccumulator = 0
        case .changed:
            let translation = recognizer.translation(in: metalView)
            recognizer.setTranslation(.zero, in: metalView)
            scrollAccumulator += translation.y
            let step: CGFloat = 22
            while scrollAccumulator <= -step {
                scrollAccumulator += step
                sendWheel(1)   // swipe up: wheel up (backlog scroll)
            }
            while scrollAccumulator >= step {
                scrollAccumulator -= step
                sendWheel(-1)  // swipe down: wheel down
            }
        default:
            scrollAccumulator = 0
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        noteUserActivity()
        switch recognizer.state {
        case .began:
            fastForwardGestureHeld = true
            updateFastForward()
        case .ended, .cancelled, .failed:
            fastForwardGestureHeld = false
            updateFastForward()
        default:
            break
        }
    }

    // MARK: - touch control bar

    /// Docked top-right during the story; hidden over the game's system UI so
    /// its original close/navigation buttons remain visible and touchable.
    private func installControlBar() {
        guard controlBar == nil else { return }
        let bar = PlayerControlBar()
        bar.setButtonsVisible(PlayerControlPreferences.buttonsVisible())
        bar.onMenu = { [weak self] in
            self?.noteUserActivity()
            self?.openGameMenu()
        }
        bar.onFastForward = { [weak self] in
            self?.toggleFastForwardButton()
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
        ])
        bar.alpha = 1
        bar.setFastForwardActive(isFastForwarding)
        controlBar = bar
        scheduleControlFade()
    }

    @objc private func controlPreferencesChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.controlPreferencesChanged() }
            return
        }
        guard let bar = controlBar else { return }
        let visible = PlayerControlPreferences.buttonsVisible()
        if bar.buttonsVisible && !visible { releaseAllFastForward() }
        bar.setButtonsVisible(visible)
    }

    private func scheduleControlFade() {
        controlFadeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let bar = self.controlBar else { return }
            UIView.animate(withDuration: 0.4, delay: 0, options: [.allowUserInteraction]) {
                bar.alpha = Self.controlFadedAlpha
            }
        }
        controlFadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlIdleDelay, execute: work)
    }

    private func pollSystemInterfaceState() {
        guard let handle, let bar = controlBar else { return }
        let active = siglus_ios_system_interface_active(handle) != 0
        guard bar.systemInterfaceActive != active else { return }
        if active { releaseAllFastForward() }
        bar.setSystemInterfaceActive(active)
        NSLog("Clannad: system interface %@; controls %@", active ? "open" : "closed", bar.isHidden ? "hidden" : "visible")
    }

    private func noteUserActivity() {
        guard let bar = controlBar else { return }
        if bar.alpha < 1 {
            UIView.animate(withDuration: 0.15) { bar.alpha = 1 }
        }
        scheduleControlFade()
    }

    private func hideControlBar() {
        choicePanel?.removeFromSuperview()
        choicePanel = nil
        storySelection = nil
        controlFadeWorkItem?.cancel()
        controlFadeWorkItem = nil
        controlBar?.removeFromSuperview()
        controlBar = nil
    }

    /// Opens the game's system menu (设置 / 存档 / 读档).
    ///
    /// Order: the engine's direct `siglus_ios_open_menu` first (it queues the
    /// menu reliably on device), then Escape, then the old synthetic
    /// right-click as the last resort.  The pointer is still moved to the
    /// centre on every attempt (a real player action, never an autonomous
    /// cursor animation) so the menu's hover state is sensible.
    private func openGameMenu() {
        guard let handle else { return }
        NSLog("Clannad: control bar opening the game menu")
        // Do not leave a held Control/skip state behind while the player is in
        // a menu.
        releaseAllFastForward()

        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let (x, y) = gamePoint(centre)
        siglus_ios_touch(handle, 1, x, y)

        if let openMenu = SiglusOptionalFFI.openMenu {
            let queued = openMenu(handle)
            NSLog("Clannad: siglus_ios_open_menu -> %d", queued)
            if queued > 0 {
                noteUserActivity()
                return
            }
            // The engine refused (e.g. this scene has no menu).  Fall through
            // to the keyboard and mouse fallbacks in that order.
        }

        // Fallback 1: Escape (the PC menu key).
        tapKey(SiglusVK.escape)
        // Fallback 2, last: the old synthetic right-click.  Kept for engine
        // builds that have no siglus_ios_open_menu.  On a direct-API build a
        // refused menu means the engine's own guards said no, so firing a
        // right-click as well would risk a close/reopen loop on an already
        // open syscom menu.
        if SiglusOptionalFFI.openMenu == nil, let button = SiglusOptionalFFI.mouseButton {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                button(handle, 1, 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    button(handle, 1, 0)
                }
            }
        }
        noteUserActivity()
    }

    // MARK: - fast forward

    private func toggleFastForwardButton() {
        guard choicePanel == nil else { return }
        if let setSkip = SiglusOptionalFFI.setSkip, let handle {
            // Engine-maintained skip-all: it stops by itself at choices and
            // message boxes.  Keep the button tint in sync with the state the
            // engine reports back.
            let desired: Int32 = skipActive ? 0 : 1
            let state = setSkip(handle, desired)
            skipActive = state != 0
            lastSkipPoll = 0
            NSLog("Clannad: skip button request=%d engine_state=%d", desired, state)
        } else {
            // Older engine build: fall back to holding Ctrl.
            fastForwardButtonOn.toggle()
            updateFastForward()
        }
        refreshFastForwardTint()
        noteUserActivity()
    }

    /// Poll the engine's skip state while the button is active, so the button
    /// turns itself off when the engine stops skip mode at a choice or a
    /// message box. The query is read-only so polling never re-enables skip.
    private func pollSkipState() {
        guard skipActive, let handle, let skipState = SiglusOptionalFFI.skipState else {
            lastSkipPoll = 0
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastSkipPoll >= 0.25 else { return }
        lastSkipPoll = now
        let state = skipState(handle)
        if state == 0 {
            // The engine stopped skipping (choice/message box); also clear
            // its flags so a later scene cannot resume skip with the button
            // showing "off".
            _ = SiglusOptionalFFI.setSkip?(handle, 0)
            skipActive = false
            NSLog("Clannad: engine cleared skip mode; fast-forward button off")
            refreshFastForwardTint()
        }
    }

    private func updateFastForward() {
        // With the engine skip API the 快进 button no longer holds Ctrl;
        // long-press and the gamepad trigger keep the original PC behaviour.
        let buttonUsesCtrl = SiglusOptionalFFI.setSkip == nil && fastForwardButtonOn
        let active = buttonUsesCtrl || fastForwardGestureHeld || fastForwardControllerHeld
        if active != isFastForwarding {
            isFastForwarding = active
            sendKey(SiglusVK.control, down: active)
            NSLog("Clannad: fast-forward Ctrl %@", active ? "on" : "off")
        }
        refreshFastForwardTint()
    }

    private func refreshFastForwardTint() {
        let active = SiglusOptionalFFI.setSkip != nil ? skipActive : isFastForwarding
        controlBar?.setFastForwardActive(active)
    }

    private func releaseAllFastForward() {
        fastForwardButtonOn = false
        fastForwardGestureHeld = false
        fastForwardControllerHeld = false
        if skipActive, let handle, let setSkip = SiglusOptionalFFI.setSkip {
            _ = setSkip(handle, 0)
            NSLog("Clannad: skip released")
        }
        skipActive = false
        lastSkipPoll = 0
        updateFastForward()
    }

    /// `CLANNAD_AUTOFF=<delayMs>` flips the on-screen fast-forward button
    /// once for unattended validation; inert unless set.
    private func scheduleDebugFastForwardIfRequested() {
        func setting(_ key: String) -> String? {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
            if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
            return nil
        }
        guard let raw = setting("CLANNAD_AUTOFF"), let delay = Double(raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000.0) { [weak self] in
            NSLog("Clannad: debug toggling the fast-forward button")
            self?.toggleFastForwardButton()
        }
    }

    /// `CLANNAD_AUTOMENU=<delayMs>` opens the game menu by itself for
    /// unattended validation screenshots; inert unless set.
    private func scheduleDebugMenuIfRequested() {
        func setting(_ key: String) -> String? {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
            if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
            return nil
        }
        guard let raw = setting("CLANNAD_AUTOMENU"), let delay = Double(raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000.0) { [weak self] in
            NSLog("Clannad: debug opening game menu")
            self?.openGameMenu()
        }
    }

    // MARK: - keyboard input

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if let code = Self.virtualKey(for: key.keyCode) {
                sendKey(code, down: true)
                handled = true
            }
            if Self.shouldForwardAsText(key.characters, modifiers: key.modifierFlags) {
                forwardText(key.characters)
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let code = Self.virtualKey(for: key.keyCode) else { continue }
            sendKey(code, down: false)
            handled = true
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    private static func virtualKey(for usage: UIKeyboardHIDUsage) -> Int32? {
        virtualKey(forHIDUsage: Int(usage.rawValue))
    }

    /// HID usage code (UIPress and GCKeyCode use the same numbering) -> the
    /// engine's Windows virtual-key code.
    private static func virtualKey(forHIDUsage raw: Int) -> Int32? {
        switch raw {
        case 0x04...0x1D: // a...z
            return Int32(0x41 + (raw - 0x04))
        case 0x1E...0x26: // 1...9
            return Int32(0x31 + (raw - 0x1E))
        case 0x27:        // 0
            return 0x30
        case 0x28: return SiglusVK.enter
        case 0x29: return SiglusVK.escape
        case 0x2A: return SiglusVK.backspace
        case 0x2B: return SiglusVK.tab
        case 0x2C: return SiglusVK.space
        case 0x4A: return SiglusVK.home
        case 0x4C: return SiglusVK.delete
        case 0x4D: return SiglusVK.end
        case 0x4F: return SiglusVK.right
        case 0x50: return SiglusVK.left
        case 0x51: return SiglusVK.down
        case 0x52: return SiglusVK.up
        case 0xE0, 0xE4: return SiglusVK.control
        case 0xE1, 0xE5: return SiglusVK.shift
        case 0xE2, 0xE6: return SiglusVK.alt
        default: return nil
        }
    }

    private static func shouldForwardAsText(_ text: String, modifiers: UIKeyModifierFlags) -> Bool {
        guard !text.isEmpty else { return false }
        if modifiers.intersection([.command, .control, .alternate]).isEmpty == false { return false }
        if text == " " || text == "\r" || text == "\n" || text == "\t" { return false }
        return text.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.value >= 0x2E80
        }
    }

    private func sendKey(_ code: Int32, down: Bool) {
        guard let handle else { return }
        if down {
            siglus_ios_key_down(handle, code)
        } else {
            siglus_ios_key_up(handle, code)
        }
    }

    private func tapKey(_ code: Int32) {
        sendKey(code, down: true)
        sendKey(code, down: false)
    }

    private func forwardText(_ text: String) {
        guard let handle, !text.isEmpty else { return }
        text.withCString { siglus_ios_text_input(handle, $0) }
    }

    private func forwardPreedit(_ text: String) {
        guard let handle else { return }
        if text.isEmpty {
            siglus_ios_ime_preedit(handle, nil, 0, 0)
        } else {
            text.withCString { siglus_ios_ime_preedit(handle, $0, 0, Int32(text.utf16.count)) }
        }
    }

    private func sendWheel(_ delta: Int32) {
        guard let handle else { return }
        if let wheel = SiglusOptionalFFI.wheel {
            wheel(handle, delta)
        } else {
            tapKey(delta > 0 ? SiglusVK.up : SiglusVK.down)
        }
    }

    // MARK: - name-entry keyboard (engine editbox)

    /// A zero-size, invisible text field that only becomes first responder
    /// while the engine reports an active editbox (name entry).  There is no
    /// button for it any more and no way for the keyboard to get stuck.
    private func installTextField() {
        guard textField.superview == nil else { return }
        textField.frame = CGRect(x: -2, y: -2, width: 1, height: 1)
        view.addSubview(textField)
    }

    /// Called once per display-link tick to synchronize the soft keyboard
    /// with the engine's focused editbox.
    private func pollEditboxState() {
        guard let handle, let editboxActive = SiglusOptionalFFI.editboxActive else { return }
        let active = editboxActive(handle) != 0
        guard active != isEditboxActive else { return }
        isEditboxActive = active
        if active {
            installTextField()
            NSLog("Clannad: engine editbox active; showing keyboard")
            textField.becomeFirstResponder()
        } else {
            NSLog("Clannad: engine editbox inactive; hiding keyboard")
            forwardPreedit("")
            textField.resignFirstResponder()
            view.endEditing(true)
        }
    }

    private lazy var textField: SiglusTextInputField = {
        let field = SiglusTextInputField()
        field.alpha = 0.01
        field.tintColor = .clear
        field.textColor = .clear
        field.backgroundColor = .clear
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .done
        field.onInsertText = { [weak self] text in
            self?.forwardText(text)
            self?.forwardPreedit("")
        }
        field.onDeleteBackward = { [weak self] in
            self?.tapKey(SiglusVK.backspace)
        }
        field.onPreedit = { [weak self] text in
            self?.forwardPreedit(text)
        }
        field.onReturn = { [weak self] in
            self?.tapKey(SiglusVK.enter)
        }
        return field
    }()

    // MARK: - hardware keyboard (GameController, no first responder needed)

    /// Hardware keys are read through `GCKeyboard`, so they keep working
    /// while the game view is on screen without making the view controller
    /// the first responder (that is reserved for the engine's editbox).
    private func setupHardwareKeyboard() {
        let center = NotificationCenter.default
        hardwareKeyboardObservers.append(center.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let keyboard = note.object as? GCKeyboard else { return }
            self?.attachKeyboard(keyboard)
        })
        hardwareKeyboardObservers.append(center.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let keyboard = note.object as? GCKeyboard,
                  keyboard.keyboardInput === self?.hardwareKeyboard else { return }
            self?.hardwareKeyboard = nil
        })
        if let keyboard = GCKeyboard.coalesced {
            attachKeyboard(keyboard)
        }
    }

    private func attachKeyboard(_ keyboard: GCKeyboard) {
        guard let input = keyboard.keyboardInput else { return }
        keyboard.handlerQueue = .main
        hardwareKeyboard = input
        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard let self else { return }
            // While the name-entry field is first responder UIKit delivers the
            // keys to it and the text-field callbacks feed the engine.
            guard !self.textField.isFirstResponder else { return }
            guard let code = Self.virtualKey(forHIDUsage: Int(keyCode.rawValue)) else { return }
            self.sendKey(code, down: pressed)
        }
    }

    // MARK: - game controllers

    private func setupGameControllers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(controllerDidConnect(_:)),
                           name: .GCControllerDidConnect, object: nil)
        center.addObserver(self, selector: #selector(controllerDidDisconnect(_:)),
                           name: .GCControllerDidDisconnect, object: nil)
        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    @objc private func controllerDidConnect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        attach(controller)
    }

    @objc private func controllerDidDisconnect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        controllers.removeAll { $0 === controller }
    }

    private func attach(_ controller: GCController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controllers.append(controller)
        controller.handlerQueue = .main
        if let pad = controller.extendedGamepad {
            var wasA = false, wasB = false, wasTrigger = false, wasUp = false, wasDown = false
            pad.valueChangedHandler = { [weak self] pad, _ in
                guard let self else { return }
                let a = pad.buttonA.isPressed
                if a != wasA { wasA = a; self.sendKey(SiglusVK.enter, down: a) }
                let b = pad.buttonB.isPressed
                if b != wasB { wasB = b; self.sendKey(SiglusVK.escape, down: b) }
                let trigger = pad.rightTrigger.value >= 0.5
                if trigger != wasTrigger {
                    wasTrigger = trigger
                    if trigger { self.triggerFastForward(true) } else { self.triggerFastForward(false) }
                }
                let up = pad.dpad.up.isPressed
                if up != wasUp { wasUp = up; if up { self.sendWheel(1) } }
                let down = pad.dpad.down.isPressed
                if down != wasDown { wasDown = down; if down { self.sendWheel(-1) } }
            }
        } else if let pad = controller.microGamepad {
            var wasA = false, wasX = false, wasUp = false, wasDown = false
            pad.valueChangedHandler = { [weak self] pad, _ in
                guard let self else { return }
                let a = pad.buttonA.isPressed
                if a != wasA { wasA = a; self.sendKey(SiglusVK.enter, down: a) }
                let x = pad.buttonX.isPressed
                if x != wasX { wasX = x; self.sendKey(SiglusVK.escape, down: x) }
                let up = pad.dpad.up.isPressed
                if up != wasUp { wasUp = up; if up { self.sendWheel(1) } }
                let down = pad.dpad.down.isPressed
                if down != wasDown { wasDown = down; if down { self.sendWheel(-1) } }
            }
        }
        controller.playerIndex = .indexUnset
    }

    private func triggerFastForward(_ on: Bool) {
        guard fastForwardControllerHeld != on else { return }
        fastForwardControllerHeld = on
        updateFastForward()
    }

    // MARK: - native message boxes

    func showMessagebox(requestId: UInt64, kind: Int32, title: String, message: String) {
        guard let handle else { return }
        view.endEditing(true)
        textField.resignFirstResponder()
        forwardPreedit("")
        releaseAllFastForward()
        let alert = UIAlertController(title: title.isEmpty ? gameTitle : title,
                                      message: message, preferredStyle: .alert)
        func action(_ label: String, value: Int64, style: UIAlertAction.Style = .default) {
            alert.addAction(UIAlertAction(title: label, style: style) { [weak self] _ in
                guard let self, self.handle == handle, !self.didExit else { return }
                siglus_ios_submit_messagebox_result(handle, requestId, value)
            })
        }
        switch kind {
        case 0:
            action("确定", value: 0)
        case 1:
            action("确定", value: 0)
            action("取消", value: 1, style: .cancel)
        case 2:
            action("是", value: 0)
            action("否", value: 1, style: .cancel)
        case 3:
            action("是", value: 0)
            action("否", value: 1)
            action("取消", value: 2, style: .cancel)
        default:
            action("确定", value: 0)
        }
        present(alert, animated: true)
    }

    // MARK: - orientation

    /// The game is 4:3 landscape; the launcher stays free to rotate, the
    /// player does not.  The app delegate consults `OrientationController`.
    private func lockToLandscape() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        OrientationController.shared.lockedToLandscape = true
        view.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        if #available(iOS 16.0, *) {
            let scene = view.window?.windowScene
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
                NSLog("Clannad: landscape geometry update failed: %@", String(describing: error))
            }
        }
        #endif
    }

    private func unlockOrientation() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        OrientationController.shared.lockedToLandscape = false
        view.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        #endif
    }

    private func updateHomeIndicator() {
        #if os(iOS)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsStatusBarAppearanceUpdate()
        #endif
    }

    #if os(iOS)
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    #if !targetEnvironment(macCatalyst)
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    #endif
    #endif
}

// MARK: - Mac Catalyst secondary click

#if targetEnvironment(macCatalyst)
extension SiglusPlayerViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        sendRightClick(at: location)
        return nil
    }
}
#endif

// MARK: - on-screen control bar

/// A top-right menu with an optional fast-forward toggle. Vision Pro only
/// shows the menu. Padding never steals touches from the game underneath.
final class PlayerControlBar: UIView {
    var onMenu: (() -> Void)?
    var onFastForward: (() -> Void)?
    private(set) var buttonsVisible = true
    private(set) var systemInterfaceActive = false

    private let menuButton = UIButton(type: .system)
    private let fastForwardButton = UIButton(type: .system)

    #if os(visionOS)
    static let defaultShowsFastForward = false
    #else
    static let defaultShowsFastForward = true
    #endif

    private static let buttonSide: CGFloat = 64
    private static let padding: CGFloat = 8
    private static let spacing: CGFloat = 8

    init(frame: CGRect = .zero, showsFastForward: Bool = PlayerControlBar.defaultShowsFastForward) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

        configure(menuButton, symbol: "line.3.horizontal", label: "菜单", prominent: true)
        configure(fastForwardButton, symbol: "forward.fill", label: "快进", prominent: false)
        menuButton.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)
        fastForwardButton.addTarget(self, action: #selector(fastForwardTapped), for: .touchUpInside)

        let buttons = showsFastForward ? [menuButton, fastForwardButton] : [menuButton]
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .horizontal
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
            menuButton.widthAnchor.constraint(equalToConstant: Self.buttonSide),
            menuButton.heightAnchor.constraint(equalToConstant: Self.buttonSide),
            fastForwardButton.widthAnchor.constraint(equalToConstant: Self.buttonSide),
            fastForwardButton.heightAnchor.constraint(equalToConstant: Self.buttonSide),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(_ button: UIButton, symbol: String, label: String, prominent: Bool) {
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        if prominent {
            // A visible menu button provides a clear alternative to gestures.
            var config = UIButton.Configuration.filled()
            config.image = UIImage(systemName: symbol, withConfiguration: symbolConfig)
            config.baseBackgroundColor = .systemBlue
            config.baseForegroundColor = .white
            config.cornerStyle = .medium
            button.configuration = config
        } else {
            var config = UIButton.Configuration.gray()
            config.image = UIImage(systemName: symbol, withConfiguration: symbolConfig)
            config.baseForegroundColor = .white
            config.background.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            config.cornerStyle = .medium
            button.configuration = config
        }
        button.accessibilityLabel = label
        button.accessibilityIdentifier = label == "菜单" ? "player.menu" : "player.skip"
        if var config = button.configuration {
            config.title = label
            config.imagePlacement = .top
            config.imagePadding = 3
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = .systemFont(ofSize: 12, weight: .semibold)
                return result
            }
            button.configuration = config
        }
        button.isExclusiveTouch = true
    }

    func setFastForwardActive(_ active: Bool) {
        guard var config = fastForwardButton.configuration else { return }
        config.baseForegroundColor = active ? .black : .white
        config.background.backgroundColor = active
            ? UIColor.systemYellow
            : UIColor.white.withAlphaComponent(0.12)
        fastForwardButton.configuration = config
        fastForwardButton.accessibilityValue = active ? "开启" : "关闭"
    }

    func setSystemInterfaceActive(_ active: Bool) {
        systemInterfaceActive = active
        updateVisibility()
    }

    func setButtonsVisible(_ visible: Bool) {
        buttonsVisible = visible
        updateVisibility()
    }

    private func updateVisibility() {
        isHidden = !buttonsVisible || systemInterfaceActive
    }

    /// Only visible buttons are interactive; padding and stack spacing return
    /// nil so the touch falls through to the game view.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard let hit else { return nil }
        if hit === menuButton || hit.isDescendant(of: menuButton) {
            return hit
        }
        if hit === fastForwardButton || hit.isDescendant(of: fastForwardButton) {
            return hit
        }
        return nil
    }

    @objc private func menuTapped() { onMenu?() }
    @objc private func fastForwardTapped() { onFastForward?() }

    func triggerMenuForValidation() { menuButton.sendActions(for: .touchUpInside) }
    func triggerSkipForValidation() { fastForwardButton.sendActions(for: .touchUpInside) }
}

// MARK: - C callback bridge

/// Called by the engine (from its own thread) when it needs a native message
/// box; bounces the presentation onto the main thread.
private func siglusMessageboxBridge(
    userData: UnsafeMutableRawPointer?,
    requestId: UInt64,
    kind: Int32,
    titleUtf8: UnsafePointer<CChar>?,
    messageUtf8: UnsafePointer<CChar>?
) {
    guard let userData else { return }
    let controller = Unmanaged<SiglusPlayerViewController>.fromOpaque(userData).takeUnretainedValue()
    let title = titleUtf8.map { String(cString: $0) } ?? "CLANNAD"
    let message = messageUtf8.map { String(cString: $0) } ?? ""
    DispatchQueue.main.async {
        controller.showMessagebox(requestId: requestId, kind: kind, title: title, message: message)
    }
}

// MARK: - SwiftUI bridge

struct SiglusPlayerContainer: UIViewControllerRepresentable {
    let gameRoot: URL
    let title: String
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> SiglusPlayerViewController {
        SiglusPlayerViewController(gameRoot: gameRoot, title: title, onExit: onExit)
    }

    func updateUIViewController(_ uiViewController: SiglusPlayerViewController, context: Context) {}
}

/// The full-screen player presentation.
struct PlayerScreen: View {
    let session: PlayerSession
    let onExit: () -> Void

    var body: some View {
        SiglusPlayerContainer(gameRoot: session.gameRoot, title: session.title, onExit: onExit)
            .ignoresSafeArea()
            .statusBarHidden(true)
    }
}
