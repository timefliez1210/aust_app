import Foundation
import AVFoundation
import Capacitor
import RoomPlan
import UIKit

/// Scans one room with Apple RoomPlan and returns its furniture.
///
/// All measurement is RoomPlan's: every `CapturedRoom.Object` carries a box
/// fitted to the fused LiDAR geometry. This plugin only presents Apple's
/// scanner, puts Abbrechen / Fertig / Übernehmen on top of it, and flattens the
/// result to JSON. Naming, filtering fixtures and the volume maths live in the
/// app (`src/lib/plugins/roomplan.ts`), where they can be changed without a
/// native build.
@objc(RoomPlanPlugin)
public class RoomPlanPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "RoomPlanPlugin"
    public let jsName = "RoomPlan"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isSupported", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "scanRoom", returnType: CAPPluginReturnPromise),
    ]

    @objc func isSupported(_ call: CAPPluginCall) {
        call.resolve(["supported": RoomCaptureSession.isSupported])
    }

    @objc func scanRoom(_ call: CAPPluginCall) {
        guard RoomCaptureSession.isSupported else {
            call.reject("RoomPlan wird auf diesem Gerät nicht unterstützt.", "UNSUPPORTED")
            return
        }
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .denied || cameraStatus == .restricted {
            call.reject("Kein Kamerazugriff.", "CAMERA_DENIED")
            return
        }
        let roomName = call.getString("roomName") ?? ""

        DispatchQueue.main.async { [weak self] in
            guard let presenter = self?.bridge?.viewController else {
                call.reject("Scanner konnte nicht geöffnet werden.", "NO_VIEW_CONTROLLER")
                return
            }
            let scanner = RoomScanViewController(roomName: roomName) { outcome in
                presenter.dismiss(animated: true) {
                    switch outcome {
                    case .cancelled:
                        call.resolve(["cancelled": true, "objects": [Any]()])
                    case .finished(let room):
                        call.resolve(["cancelled": false, "objects": room.objects.map(RoomPlanPlugin.json)])
                    case .failed(let error):
                        call.reject("Der Raum konnte nicht ausgewertet werden.", "SCAN_FAILED", error)
                    }
                }
            }
            presenter.present(scanner, animated: true)
        }
    }

    static func json(_ object: CapturedRoom.Object) -> [String: Any] {
        // RoomPlan: x = width, y = height, z = depth. The app wants
        // [length, width, height] with length the longer footprint side.
        let d = object.dimensions
        let a = Double(d.x)
        let b = Double(d.z)
        return [
            "category": categoryName(object.category),
            "dimsM": [max(a, b), min(a, b), Double(d.y)],
            "confidence": confidenceValue(object.confidence),
        ]
    }

    static func categoryName(_ category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .storage: return "storage"
        case .refrigerator: return "refrigerator"
        case .stove: return "stove"
        case .bed: return "bed"
        case .sink: return "sink"
        case .washerDryer: return "washerDryer"
        case .toilet: return "toilet"
        case .bathtub: return "bathtub"
        case .oven: return "oven"
        case .dishwasher: return "dishwasher"
        case .table: return "table"
        case .sofa: return "sofa"
        case .chair: return "chair"
        case .fireplace: return "fireplace"
        case .television: return "television"
        case .stairs: return "stairs"
        @unknown default: return "unknown"
        }
    }

    static func confidenceValue(_ confidence: CapturedRoom.Confidence) -> Double {
        switch confidence {
        case .high: return 0.9
        case .medium: return 0.6
        case .low: return 0.3
        @unknown default: return 0.3
        }
    }
}

/// Full-screen RoomPlan scanner for one room.
///
/// scanning ──Fertig──► processing ──(RoomPlan done)──► reviewing ──Übernehmen──► finished
///     └──────────────────── Abbrechen (any phase) ──────────────────────────────► cancelled
final class RoomScanViewController: UIViewController, RoomCaptureViewDelegate {
    enum Outcome {
        case cancelled
        case finished(CapturedRoom)
        case failed(Error)
    }

    private enum Phase {
        case scanning, processing, reviewing
    }

    private let roomName: String
    private let completion: (Outcome) -> Void

    private var captureView: RoomCaptureView!
    private var result: CapturedRoom?
    private var started = false
    private var done = false
    private var phase = Phase.scanning {
        didSet { updateControls() }
    }

    private let cancelButton = UIButton(type: .system)
    private let primaryButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    private static let accent = UIColor(red: 252 / 255, green: 96 / 255, blue: 24 / 255, alpha: 1)

    init(roomName: String, completion: @escaping (Outcome) -> Void) {
        self.roomName = roomName
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        view.addSubview(captureView)

        setUpControls()
        updateControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        if phase == .scanning {
            captureView.captureSession.stop()
        }
    }

    // MARK: - RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            DispatchQueue.main.async { self.finish(.failed(error)) }
            return false
        }
        // The session can also end on its own (e.g. interrupted), not only via Fertig.
        DispatchQueue.main.async { if self.phase == .scanning { self.phase = .processing } }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async {
            if let error {
                self.finish(.failed(error))
                return
            }
            self.result = processedResult
            self.phase = .reviewing
        }
    }

    // MARK: - Controls

    private func setUpControls() {
        var cancelConfig = UIButton.Configuration.gray()
        cancelConfig.title = "Abbrechen"
        cancelConfig.cornerStyle = .capsule
        cancelConfig.baseForegroundColor = .white
        cancelConfig.background.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        cancelButton.configuration = cancelConfig
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        var primaryConfig = UIButton.Configuration.filled()
        primaryConfig.cornerStyle = .capsule
        primaryConfig.baseBackgroundColor = Self.accent
        primaryConfig.baseForegroundColor = .white
        primaryButton.configuration = primaryConfig
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)

        titleLabel.text = roomName
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center

        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        subtitleLabel.textAlignment = .center

        for label in [titleLabel, subtitleLabel] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.5
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
        }

        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.alignment = .center

        let bar = UIStackView(arrangedSubviews: [cancelButton, titles, primaryButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addSubview(bar)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            cancelButton.heightAnchor.constraint(equalToConstant: 40),
            primaryButton.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func updateControls() {
        guard var config = primaryButton.configuration else { return }
        switch phase {
        case .scanning:
            config.title = "Fertig"
            config.showsActivityIndicator = false
            primaryButton.isEnabled = true
            subtitleLabel.text = "Langsam durch den Raum gehen"
        case .processing:
            config.title = "Fertig"
            config.showsActivityIndicator = true
            primaryButton.isEnabled = false
            subtitleLabel.text = "Wird ausgewertet …"
        case .reviewing:
            config.title = "Übernehmen"
            config.showsActivityIndicator = false
            primaryButton.isEnabled = true
            let count = result?.objects.count ?? 0
            subtitleLabel.text = count == 1 ? "1 Objekt erkannt" : "\(count) Objekte erkannt"
        }
        primaryButton.configuration = config
    }

    @objc private func primaryTapped() {
        switch phase {
        case .scanning:
            phase = .processing
            captureView.captureSession.stop()
        case .processing:
            break
        case .reviewing:
            if let result { finish(.finished(result)) }
        }
    }

    @objc private func cancelTapped() {
        if phase == .scanning {
            captureView.captureSession.stop()
        }
        finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) {
        guard !done else { return }
        done = true
        completion(outcome)
    }
}
