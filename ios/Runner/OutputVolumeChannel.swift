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

import Flutter
import MediaPlayer
import AVFoundation
import UIKit

class OutputVolumeChannel: NSObject, FlutterStreamHandler {
    static let methodChannelName = "com.unicornsonlsd.finamp/output_switcher"
    static let eventChannelName = "com.unicornsonlsd.finamp/output_volume"

    /// Hidden volume view used to control the active route's volume. It must be
    /// part of the view hierarchy and visible (non-hidden) for its embedded
    /// slider to actually change the output volume, so we keep it offscreen and
    /// nearly transparent.
    private let volumeView = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 1, height: 1))

    private var eventSink: FlutterEventSink?
    private var volumeObservation: NSKeyValueObservation?

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
            result(Double(AVAudioSession.sharedInstance().outputVolume))
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
            guard let slider = self.volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.value = max(0.0, min(1.0, volume))
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
        // Observe the system output volume so that volume changes made on the
        // AirPlay device (or via the hardware buttons) are reflected in the UI.
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

    private func emitState() {
        guard let eventSink = eventSink else { return }
        let state: [String: Any] = [
            "isAirPlayActive": isAirPlayActive(),
            "volume": Double(AVAudioSession.sharedInstance().outputVolume),
        ]
        eventSink(state)
    }

    // MARK: - Helpers

    private func attachVolumeView() {
        guard volumeView.superview == nil, let window = keyWindow() else { return }
        volumeView.isHidden = false
        volumeView.alpha = 0.01
        window.addSubview(volumeView)
    }

    private func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }
}
