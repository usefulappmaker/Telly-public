// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor final class UHDSetupState: ObservableObject {
    @Published var message: String?
    @Published var busy = false
    @Published var configured = UHDIdentityVault.isConfigured
    private var operation: Task<Void, Never>?
    func connectDirect() {
        guard !busy else { return }
        busy = true; message = "Downloading and validating TwinVine setup…"
        operation = Task {
            defer { busy = false; operation = nil; configured = UHDIdentityVault.isConfigured }
            do {
                let payload = try await TwinVineDirectSetup.prepare()
                try Task.checkCancellation()
                message = "Checking BBC UHD access…"
                let identity = try UHDIdentityVault.importIdentity(Data(base64Encoded: payload.p12)!, password: payload.password)
                let access = UHDPlaybackAccess(secureSession: { BBCSecureSession(identity: identity, userAgent: payload.userAgent) })
                let title = try await TwinVineUHDProbe.verify { programme in try await access.probe(programme) }
                try Task.checkCancellation()
                // Verify the candidate before replacing an existing identity.
                try UHDIdentityVault.install(payload)
                message = "Connected. BBC returned a 4K HLG stream for \(title). Play a 4K episode to check playback on your TV."
            } catch {
                message = Task.isCancelled ? "Setup cancelled. Your existing UHD setup has been kept." : error.localizedDescription
            }
        }
    }
    func cancel() { operation?.cancel() }
}
struct UHDSetupView: View {
    @StateObject private var state = UHDSetupState()
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("4K UHD · TwinVine").font(.title2).bold()
            Text(state.configured ? "UHD identity connected" : "One-time setup required").foregroundStyle(state.configured ? .green : .secondary)
            Text("Connect directly on Apple TV. Telly downloads TwinVine's UHD configuration, stores the identity on this device and checks for a compatible BBC 4K stream. No computer or helper is needed.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Button(state.busy ? "Connecting…" : "Connect using TwinVine") { state.connectDirect() }
                    .disabled(state.busy).accessibilityIdentifier("ConnectTwinVineDirect")
                if state.busy { Button("Cancel setup") { state.cancel() } }
                if state.configured {
                    Button("Forget UHD identity") {
                        UHDIdentityVault.remove(); state.configured = false
                        state.message = "UHD identity removed from this Apple TV."
                    }.disabled(state.busy)
                }
            }
            if state.busy { ProgressView().accessibilityLabel("UHD setup in progress") }
            if let message = state.message { Text(message).font(.callout).accessibilityIdentifier("TwinVineSetupResult") }
        }.onAppear { state.configured = UHDIdentityVault.isConfigured }
            .onDisappear { state.cancel() }
    }
}
