//
//  OutputVolumeChannel.swift
//  Runner
//
//  Exposes the active audio route's volume to Flutter so that the in-app volume
//  slider can control an AirPlay receiver's volume while casting. The in-app
//  volume slider is intentionally per-app and does not touch the system volume,
//  but that makes it ineffective when playing through AirPlay (where the audio is
//  rendered by the receiver). When the current route is AirPlay we instead drive
//  the system output volume (which is the AirPlay device's volume) through a
//  hidden MPVolumeView.
//
//  The MPVolumeView's embedded slider is also the source of truth for reading the
//  active route's volume: it reflects the AirPlay receiver's volume and fires a
//  `.valueChanged` action when that volume is changed from the system controls
//  (hardware buttons, Control Center, etc.), which we forward to Flutter so the
//  in-app slider stays in sync. `AVAudioSession.outputVolume` KVO is kept as a
//  fallback, since it does not reliably track the volume of a remote AirPlay route.
//

import Flutter
import MediaPlayer
import AVFoundation
import UIKit

class OutputVolumeChannel: NSObject, FlutterStreamHandler {
    static let methodChannelName = "com.unicornsonlsd.finamp/output_switcher"
    static let eventChannelName = "com.unicornsonlsd.finamp/output_volume"

    /// Hidden volume view used to read and control the active route's volume. It
    /// must be part of the view hierarchy and visible (non-hidden) for its
    /// embedded slider to actually change the output volume, so we keep it
    /// offscreen and nearly transparent.
    private let volumeView = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 1, height: 1))

    private var eventSink: FlutterEventSink?
    private var volumeObservation: NSKeyValueObservation?
    private var didBindSlider = false

    func register(with messenger: FlutterBinaryMessenger) {
        let methodChannel = FlutterMethodChannel(name: Self.methodChannelName, binaryMessenger: messenger)
        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        let eventChannel = FlutterEventChannel(name: Self.eventChannelName, binaryMessenger: messenger)
        eventChannel.setStreamHandler(self)

        DispatchQueue.main.async {
            self.attachVolumeView()
        }
    }

    // MARK: - Method channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        attachVolumeView()
        switch call.method {
        case "isAirPlayActive":
            result(isAirPlayActive())
        case "getOutputVolume":
            result(currentRouteVolume())
        case "setOutputVolume":
            guard let args = call.arguments as? [String: Any],
                  let volume = args["volume"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing volume argument", details: nil))
                return
            }
            setOutputVolume(Float(volume))
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func isAirPlayActive() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { $0.portType == .airPlay }
    }

    private func setOutputVolume(_ volume: Float) {
        DispatchQueue.main.async {
            self.attachVolumeView()
            // Setting the slider value programmatically does not fire its
            // `.valueChanged` action, so this does not echo back to Flutter.
            self.volumeSlider?.value = max(0.0, min(1.0, volume))
        }
    }

    // MARK: - Event channel (FlutterStreamHandler)

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        attachVolumeView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        // Fallback observer for volume changes made via the hardware buttons.
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.emitState() }
        }
        emitState()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        volumeObservation?.invalidate()
        volumeObservation = nil
        eventSink = nil
        return nil
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        DispatchQueue.main.async { self.emitState() }
    }

    /// Called when the active route's volume is changed from the system controls
    /// (the MPVolumeView slider reflects this and fires `.valueChanged`).
    @objc private func handleSliderVolumeChange(_ sender: UISlider) {
        emitState()
    }

    private func emitState() {
        guard let eventSink = eventSink else { return }
        let state: [String: Any] = [
            "isAirPlayActive": isAirPlayActive(),
            "volume": currentRouteVolume(),
        ]
        eventSink(state)
    }

    // MARK: - Helpers

    /// The MPVolumeView's embedded slider, which reflects and controls the active
    /// route's (e.g. AirPlay receiver's) volume.
    private var volumeSlider: UISlider? {
        return volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    private func currentRouteVolume() -> Double {
        if let slider = volumeSlider {
            return Double(slider.value)
        }
        return Double(AVAudioSession.sharedInstance().outputVolume)
    }

    private func attachVolumeView() {
        if volumeView.superview == nil, let window = keyWindow() {
            volumeView.isHidden = false
            volumeView.alpha = 0.01
            window.addSubview(volumeView)
        }
        bindSliderTargetIfNeeded()
        // The slider subview is created lazily after the volume view is laid out,
        // so retry shortly in case it wasn't available yet.
        if !didBindSlider {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.bindSliderTargetIfNeeded()
            }
        }
    }

    private func bindSliderTargetIfNeeded() {
        guard !didBindSlider, let slider = volumeSlider else { return }
        slider.addTarget(self, action: #selector(handleSliderVolumeChange(_:)), for: .valueChanged)
        didBindSlider = true
    }

    private func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }
}
