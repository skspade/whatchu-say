import SwiftUI
import AVFoundation
import UIKit

/// Minimal host app for the iOS keyboard spike. Three jobs:
///
/// 1. Prompt microphone permission (the host app's Info.plist owns the
///    `NSMicrophoneUsageDescription` string the system shows).
/// 2. Persist the ElevenLabs API key somewhere the keyboard extension can
///    read it. Uses `UserDefaults(suiteName:)` if an App Group is
///    configured; falls back to plain `UserDefaults` otherwise (works
///    only when both targets share an App Group, but for the spike we
///    accept "doesn't work without App Group" as a known caveat).
/// 3. Walk the user to Settings → Keyboards so they can add SpikeKeyboard
///    and toggle "Allow Full Access."
@main
struct SpikeHostApp: App {
    var body: some Scene {
        WindowGroup {
            HostView()
        }
    }
}

private struct HostView: View {
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var apiKey: String = SpikeStorage.readKey() ?? ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Microphone") {
                    if micGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant microphone permission") {
                            AVCaptureDevice.requestAccess(for: .audio) { granted in
                                DispatchQueue.main.async { micGranted = granted }
                            }
                        }
                    }
                }

                Section("2. ElevenLabs API key") {
                    // TextField (not SecureField) — paste behaves better on
                    // iOS and the spike is throwaway anyway.
                    TextField("xi-api-key", text: $apiKey, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...4)
                    HStack {
                        Button("Paste") {
                            if let clip = UIPasteboard.general.string {
                                apiKey = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("Save") {
                            SpikeStorage.writeKey(apiKey)
                            saved = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.isEmpty)
                    }
                    if !apiKey.isEmpty {
                        Text("Length: \(apiKey.count) chars · suite: \(SpikeStorage.activeSuiteDescription)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if saved {
                        Text("Saved.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("3. Enable SpikeKeyboard") {
                    Text("Settings → General → Keyboards → Add New Keyboard → SpikeKeyboard. Then tap it and toggle Allow Full Access.")
                        .font(.callout)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section("4. Test") {
                    Text("Switch to any text app (e.g. Notes), tap the globe key until SpikeKeyboard is shown, then press-and-hold the mic button.")
                        .font(.callout)
                }
            }
            .navigationTitle("Keyboard Spike")
        }
    }
}

// `SpikeStorage` lives in `Shared/SpikeStorage.swift` and is added to both
// the host app and keyboard extension targets.
