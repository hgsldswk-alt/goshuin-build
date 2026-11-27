import AVFoundation
import SwiftUI
import UIKit

final class StampCamera: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "goshuin.camera")
    private let configured: (Bool) -> Void
    private let captured: (Data?) -> Void

    init(configured: @escaping (Bool) -> Void, captured: @escaping (Data?) -> Void) {
        self.configured = configured
        self.captured = captured
    }

    func start() {
        queue.async {
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                DispatchQueue.main.async { self.configured(false) }
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            self.session.addInput(input)
            self.session.addOutput(self.output)
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { self.configured(true) }
        }
    }

    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    func shoot() {
        queue.async {
            if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        DispatchQueue.main.async { self.captured(data) }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: Preview, context: Context) {}
}

struct CameraScreen: View {
    var finish: (Data) -> Void
    var unavailable: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera: StampCamera?
    @State private var ready = false
    @State private var shooting = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let camera { CameraPreview(session: camera.session).ignoresSafeArea() }
            VStack {
                HStack {
                    Button(L.t("close")) { dismiss() }.accessibilityIdentifier("camera.close")
                    Spacer()
                }
                Spacer()
                if failed { Text(L.t("error.camera")).padding().background(.black.opacity(0.75)) }
                Button { take() } label: {
                    Circle().strokeBorder(.white, lineWidth: 3).frame(width: 72, height: 72)
                        .overlay { Circle().fill(.white).frame(width: 58, height: 58) }
                }
                .accessibilityLabel(L.t("camera.shutter"))
                .accessibilityIdentifier("camera.shutter")
                .disabled((!ready && !AppModel.testing) || shooting)
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .task {
            guard !AppModel.testing else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            guard granted else { unavailable(); return }
            let session = StampCamera { success in
                ready = success
                if !success { unavailable() }
            } captured: { data in
                shooting = false
                if let data { finish(data) }
                else { failed = true }
            }
            camera = session
            session.start()
        }
        .onDisappear { camera?.stop() }
    }

    private func take() {
        shooting = true
        failed = false
        if AppModel.testing {
            Task {
                if let data = try? await Task.detached(operation: { try Examples.photo() }).value { finish(data) }
                else { failed = true; shooting = false }
            }
        } else {
            camera?.shoot()
        }
    }
}
