import AVFoundation
import SwiftUI

/// The camera for Home's mirror tile, running only while someone is looking,
/// so macOS's green camera light is on only then. AVFoundation's calls block, so they run
/// on a queue of their own.
@MainActor
@Observable
final class MirrorCamera {
    static let shared = MirrorCamera()

    enum State: Equatable {
        case idle, starting, running, denied
        case unavailable(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored let session: AVCaptureSession
    @ObservationIgnored private let box: SessionBox
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var layer: AVCaptureVideoPreviewLayer?

    private init() {
        box = SessionBox()
        session = box.session
    }

    var isRunning: Bool { box.session.isRunning }

    /// The one preview layer, made the first time it's shown and kept for good.
    /// The session keeps a connection to every preview layer it's ever had,
    /// even after the layer is gone, and only the first gets a picture: a new
    /// layer per look worked once, then showed nothing.
    var previewLayer: AVCaptureVideoPreviewLayer {
        if let layer { return layer }
        let made = AVCaptureVideoPreviewLayer(session: session)
        made.videoGravity = .resizeAspectFill
        made.cornerRadius = 16
        made.cornerCurve = .continuous
        made.masksToBounds = true
        made.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = made
        return made
    }

    /// Call from a view's `.task`; returns when the view goes away or stops
    /// looking. Two displays share one session.
    func whileVisible() async {
        viewers += 1
        if viewers == 1 { await start() }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        viewers -= 1
        if viewers == 0 {
            box.stop()
            state = .idle
        }
    }

    private func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            state = .denied
            return
        case .notDetermined:
            state = .starting
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .denied
                return
            }
        default:
            break
        }
        // Closed while macOS was asking.
        guard viewers > 0 else { return }
        state = .starting
        let problem = await box.start()
        // Closed while the camera was starting: the queue stops it after.
        guard viewers > 0 else { return }
        state = problem.map(State.unavailable) ?? .running
    }
}

/// Owns the session on its own serial queue.
private final class SessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.pranava.xotch.mirror")
    private var configured = false

    /// Starts the camera; returns what went wrong, or nil.
    func start() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.startOnQueue())
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func startOnQueue() -> String? {
        if !configured {
            // The Mac's own camera first, not an iPhone nearby.
            let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                           mediaType: .video, position: .unspecified).devices.first
            guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else { return "No camera found" }
            guard let input = try? AVCaptureDeviceInput(device: device) else { return "The camera couldn't start" }
            session.beginConfiguration()
            session.sessionPreset = .high
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            guard !session.inputs.isEmpty else { return "The camera is busy" }
            configured = true
        }
        if !session.isRunning { session.startRunning() }
        return session.isRunning ? nil : "The camera is busy"
    }
}

/// The session's picture, flipped left to right like a mirror.
struct MirrorPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> MirrorPreviewView { MirrorPreviewView(preview: layer) }
    func updateNSView(_ view: MirrorPreviewView, context: Context) { view.mirror() }
}

/// Shows the camera's one preview layer; a new view takes it from the last.
final class MirrorPreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    #if DEBUG
    /// The last one made, for `debug.sh status`.
    nonisolated(unsafe) static weak var latest: MirrorPreviewView?
    /// How many exist, to catch one that outlives its tile.
    nonisolated(unsafe) static var live = 0
    #endif

    init(preview: AVCaptureVideoPreviewLayer) {
        self.preview = preview
        super.init(frame: .zero)
        wantsLayer = true
        // Moves it here from wherever it was last shown.
        layer?.addSublayer(preview)
        fit()
        mirror()
        #if DEBUG
        Self.latest = self
        Self.live += 1
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if DEBUG
    deinit { Self.live -= 1 }
    #endif

    /// The connection appears once the session has its camera.
    func mirror() {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    /// Clicks go to the tile around it, which turns the camera off.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        fit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    private func fit() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }

    #if DEBUG
    var debugState: String {
        let connection = preview.connection
        let device = (preview.session?.inputs.first as? AVCaptureDeviceInput)?.device
        return "connections=\(preview.session?.connections.count ?? -1) liveViews=\(Self.live) preview=\(Int(preview.frame.width))x\(Int(preview.frame.height)) hosted=\(preview.superlayer === layer) inWindow=\(window != nil) connection=\(connection != nil) enabled=\(connection?.isEnabled ?? false) active=\(connection?.isActive ?? false) mirrored=\(connection?.isVideoMirrored ?? false) device=\(device?.localizedName ?? "-") busy=\(device?.isInUseByAnotherApplication ?? false)"
    }
    #endif
}
