import SwiftUI
import AVFoundation
import CoreImage
import CoreVideo
import Network
import UIKit

// No Record3D, paid service, ARKit face mesh, or LiDAR is used here. AVFoundation
// exposes actual front TrueDepth RGB + metric depth on supported iPhones.
@main
struct SandGuideCameraApp: App {
    var body: some Scene { WindowGroup { CameraScreen() } }
}

final class FrameTransport: ObservableObject {
    @Published private(set) var status = "Not connected"
    private let queue = DispatchQueue(label: "sandguide.network")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var listener: NWListener?
    private var ready = false
    private var sending = false
    private var generation = 0
    private var sentFrames = 0

    private func report(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.status = text }
    }

    func connect(host: String, port: String) {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, let number = UInt16(port), number > 0,
              let endpoint = NWEndpoint.Port(rawValue: number) else {
            report("Enter the PC's Wi-Fi IPv4 address and a valid port.")
            return
        }
        disconnect()
        let newConnection = NWConnection(host: NWEndpoint.Host(address), port: endpoint, using: .tcp)
        report("Connecting to \(address):\(number)...")
        attach(newConnection)
    }

    func listenUSB(port: String) {
        guard let number = UInt16(port), number > 0,
              let endpoint = NWEndpoint.Port(rawValue: number) else {
            report("Enter a valid phone port, normally 8765.")
            return
        }
        disconnect()
        do {
            let newListener = try NWListener(using: .tcp, on: endpoint)
            listener = newListener
            newListener.newConnectionHandler = { [weak self] incoming in self?.attach(incoming) }
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.report("USB listening on \(number). Start the PC USB tunnel and guidance app.")
                case .failed(let error): self?.report("USB listener failed: \(error.localizedDescription)")
                default: break
                }
            }
            newListener.start(queue: queue)
        } catch {
            report("USB listen failed: \(error.localizedDescription)")
        }
    }

    private func attach(_ newConnection: NWConnection) {
        lock.lock()
        let previous = connection
        generation += 1
        ready = false
        sending = false
        sentFrames = 0
        connection = newConnection
        lock.unlock()
        previous?.stateUpdateHandler = nil
        previous?.cancel()
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self = self, let newConnection = newConnection else { return }
            self.lock.lock()
            guard self.connection === newConnection else { self.lock.unlock(); return }
            switch state {
            case .ready: self.ready = true
            case .failed(_), .cancelled: self.ready = false
            default: break
            }
            self.lock.unlock()
            switch state {
            case .ready: self.report("Connected. Streaming to PC.")
            case .waiting(let error): self.report("Waiting: \(error.localizedDescription)")
            case .failed(let error): self.report("Connection failed: \(error.localizedDescription)")
            case .cancelled: self.report("Disconnected")
            default: break
            }
        }
        newConnection.start(queue: queue)
    }

    func disconnect() {
        lock.lock()
        let previous = connection
        connection = nil
        generation += 1
        ready = false
        sending = false
        sentFrames = 0
        lock.unlock()
        previous?.stateUpdateHandler = nil
        previous?.cancel()
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        report("Not connected")
    }

    func send(jpeg: Data, depth: Data, metadata: [String: Any]) {
        // At most one packet may be in flight. Drop frames when Wi-Fi is slow;
        // queuing old frames would turn live fabrication guidance into delayed video.
        lock.lock()
        guard ready, !sending, let current = connection else { lock.unlock(); return }
        sending = true
        let token = generation
        lock.unlock()

        guard let json = try? JSONSerialization.data(withJSONObject: metadata),
              json.count <= 8192, jpeg.count <= 8 * 1024 * 1024,
              depth.count <= 16 * 1024 * 1024 else {
            lock.lock(); if generation == token { sending = false }; lock.unlock()
            report("Frame could not be encoded.")
            return
        }
        var packet = Data("SGD1".utf8)
        for length in [json.count, jpeg.count, depth.count] {
            var value = UInt32(length).bigEndian
            withUnsafeBytes(of: &value) { packet.append(contentsOf: $0) }
        }
        packet.append(json)
        packet.append(jpeg)
        packet.append(depth)
        current.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            self.lock.lock()
            guard self.generation == token else { self.lock.unlock(); return }
            self.sending = false
            if error != nil { self.ready = false }
            self.sentFrames += 1
            let count = self.sentFrames
            self.lock.unlock()
            if let error = error {
                self.report("Send failed: \(error.localizedDescription). Tap Connect to retry.")
            } else if count % 15 == 0 {
                self.report("Streaming: \(count) frames sent")
            }
        })
    }
}

final class DepthCapture: NSObject, ObservableObject, AVCaptureDataOutputSynchronizerDelegate {
    @Published private(set) var status = "Camera permission required"
    let session = AVCaptureSession()
    var onFrame: ((Data, Data, [String: Any]) -> Void)?
    private let queue = DispatchQueue(label: "sandguide.capture")
    private let video = AVCaptureVideoDataOutput()
    private let depth = AVCaptureDepthDataOutput()
    private let context = CIContext()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var configured = false
    private var lastSentTime = 0.0

    private func report(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.status = text }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else { return }
            guard granted else { self.report("Allow camera access in iPhone Settings."); return }
            self.queue.async {
                do {
                    if !self.configured { try self.configure(); self.configured = true }
                    if !self.session.isRunning { self.session.startRunning() }
                    self.report("Front TrueDepth active. Keep this app open and the phone awake.")
                } catch {
                    self.report("Camera setup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            throw CaptureFailure("No front TrueDepth camera. This app does not use rear LiDAR.")
        }
        let formats = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        let preferred = formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width == 640 && size.height == 480
        }
        guard let format = (preferred.isEmpty ? formats : preferred).min(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }) else { throw CaptureFailure("No depth-capable camera format is available.") }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureFailure("Cannot add camera input.") }
        session.addInput(input)
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        depth.isFilteringEnabled = true
        guard session.canAddOutput(video), session.canAddOutput(depth) else {
            throw CaptureFailure("Cannot add RGB and depth outputs.")
        }
        session.addOutput(video)
        session.addOutput(depth)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        let depthFormats = format.supportedDepthDataFormats.sorted {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int(a.width) * Int(a.height) > Int(b.width) * Int(b.height)
        }
        if let selected = depthFormats.first(where: {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }) ?? depthFormats.first {
            device.activeDepthDataFormat = selected
        }
        if format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
        }
        // Keep BOTH data outputs in the native landscape orientation, unmirrored.
        // The PC may mirror the display, updating K by the same pixel transform.
        for connection in [video.connection(with: .video), depth.connection(with: .depthData)].compactMap({ $0 }) {
            if connection.isVideoOrientationSupported { connection.videoOrientation = .landscapeRight }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            connection.isEnabled = true
        }
        synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [video, depth])
        synchronizer?.setDelegate(self, queue: queue)
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let rgb = collection.synchronizedData(for: video) as? AVCaptureSynchronizedSampleBufferData,
              let d = collection.synchronizedData(for: depth) as? AVCaptureSynchronizedDepthData,
              !rgb.sampleBufferWasDropped, !d.depthDataWasDropped,
              let buffer = CMSampleBufferGetImageBuffer(rgb.sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSentTime >= 1.0 / 17.0 else { return }
        lastSentTime = now
        let metric = d.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        guard let calibration = metric.cameraCalibrationData else {
            report("No camera calibration received; cannot send reliable metric geometry.")
            return
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let map = metric.depthDataMap
        let dw = CVPixelBufferGetWidth(map), dh = CVPixelBufferGetHeight(map)
        let reference = calibration.intrinsicMatrixReferenceDimensions
        guard reference.width > 0, reference.height > 0 else { return }
        let intrinsic = calibration.intrinsicMatrix
        let sx = Float(width) / Float(reference.width), sy = Float(height) / Float(reference.height)
        let coefficients = [intrinsic.columns.0.x * sx, intrinsic.columns.1.y * sy,
                            intrinsic.columns.2.x * sx, intrinsic.columns.2.y * sy]
        guard coefficients.allSatisfy({ $0.isFinite }), coefficients[0] > 0, coefficients[1] > 0 else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.75) else { return }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let stride = CVPixelBufferGetBytesPerRow(map)
        var raw = Data(capacity: dw * dh * 4)
        // iOS arm64 is little-endian. Strip pixel-buffer row padding explicitly.
        for row in 0..<dh {
            raw.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: dw * 4)
        }
        let metadata: [String: Any] = [
            "rgb_width": width, "rgb_height": height,
            "depth_width": dw, "depth_height": dh,
            "depth_dtype": "float32-le", "depth_unit": "m",
            "intrinsics": coefficients,
            "intrinsics_reference": "rgb",
            "camera": "front-truedepth",
            "timestamp": CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(rgb.sampleBuffer))
        ]
        onFrame?(jpeg, raw, metadata)
    }
}

struct CaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: PreviewUIView, context: Context) {
        // The phone's portrait preview is independent of the two landscape data outputs.
        if let connection = view.preview.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}

struct CameraScreen: View {
    @StateObject private var capture = DepthCapture()
    @StateObject private var transport = FrameTransport()
    @State private var host = ""
    @State private var port = "8765"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SandGuide Camera").font(.title.bold())
            Text("Front TrueDepth → your computer, Wi-Fi or USB").foregroundColor(.secondary)
            CameraPreview(session: capture.session)
                .background(Color.black).aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxHeight: 340)
            TextField("PC Wi-Fi IPv4 address, e.g. 192.168.1.20", text: $host)
                .textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                .autocapitalization(.none).disableAutocorrection(true)
            TextField("Port", text: $port).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
            HStack {
                Button("Wi-Fi connect") { transport.connect(host: host, port: port) }.buttonStyle(.borderedProminent)
                Button("USB: listen") { transport.listenUSB(port: port) }.buttonStyle(.bordered)
                Button("Disconnect") { transport.disconnect() }.buttonStyle(.bordered)
            }
            Text(transport.status).font(.callout)
            Text(capture.status).font(.caption).foregroundColor(.secondary)
            Text("Wi-Fi: enter the PC address. USB: tap USB listen; the PC connects through its USB tunnel. Keep this app open.")
                .font(.caption).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding()
        .onAppear {
            capture.onFrame = { jpeg, depth, metadata in transport.send(jpeg: jpeg, depth: depth, metadata: metadata) }
            capture.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            capture.stop()
            transport.disconnect()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
