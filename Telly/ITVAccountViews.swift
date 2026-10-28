// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CoreImage.CIFilterBuiltins

@MainActor final class ITVAccountModel: ObservableObject {
    static let shared = ITVAccountModel()
    @Published private(set) var signedIn = false
    @Published var error: String?
    func reload() async {
        do { signedIn = try await ITVAccountService.shared.isSignedIn(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func signOut() async {
        do { try await ITVAccountService.shared.signOut(); signedIn = false; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
@MainActor final class ITVPairingModel: ObservableObject {
    @Published var code: String?
    @Published var qr: UIImage?
    @Published var status = "Getting an ITV sign-in code…"
    @Published var error: String?
    @Published var retry = 0
    func pair() async -> Bool {
        code = nil; qr = nil; error = nil; status = "Getting an ITV sign-in code…"
        do {
            let code = try await ITVAccountService.shared.newCode()
            try Task.checkCancellation(); self.code = code
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data("https://www.itv.com/watch/pair?loginCode=\(code)".utf8)
            filter.correctionLevel = "M"
            if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
               let bitmap = CIContext().createCGImage(output, from: output.extent) { qr = UIImage(cgImage: bitmap) }
            status = "Waiting for you to sign in on ITV’s website…"
            let expires = Date().addingTimeInterval(3600)
            var networkFailures = 0
            while Date() < expires {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                do {
                    if try await ITVAccountService.shared.checkCode(code) { try Task.checkCancellation(); return true }
                    networkFailures = 0; status = "Waiting for you to sign in on ITV’s website…"
                } catch is CancellationError { throw CancellationError() }
                catch {
                    networkFailures += 1
                    if networkFailures >= 3 { throw error }
                    status = "Reconnecting to ITV…"
                }
            }
            self.code = nil; qr = nil
            error = "This ITV sign-in code has expired. Request a new code."
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        return false
    }
}
struct ITVAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var account = ITVAccountModel.shared
    @StateObject private var model = ITVPairingModel()
    @State private var checkedAccount = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ProviderBadge(provider: .itv)
                Text(account.signedIn ? "ITV account" : "Sign in to ITV").font(.largeTitle).bold()
                if account.signedIn {
                    Text("You’re signed in. ITV live channels are ready to watch.").font(.title3)
                    Text("Channel availability follows your ITV account and region.").foregroundStyle(.secondary)
                    Button("Sign out of ITV") { Task { await account.signOut(); model.retry += 1 } }
                } else if checkedAccount {
                    HStack(alignment: .top, spacing: 55) {
                        if let qr = model.qr {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                                .frame(width: 300, height: 300).padding(20).background(.white).cornerRadius(16)
                                .accessibilityLabel("Scan to sign in on ITV’s website")
                        }
                        VStack(alignment: .leading, spacing: 22) {
                            Text("Scan the QR code with your phone, or visit").font(.title3)
                            Text("itv.com/pair").font(.title2).bold()
                            Text("Sign in to ITV and enter this code:")
                            if let code = model.code {
                                Text(code).font(.system(size: 66, weight: .bold, design: .monospaced)).tracking(7)
                                    .accessibilityLabel("ITV code " + code.map(String.init).joined(separator: " "))
                            } else if model.error == nil { ProgressView() }
                            Text(model.status).foregroundStyle(.secondary)
                        }
                    }
                    Text("Telly will connect automatically once ITV confirms your sign-in.").foregroundStyle(.secondary)
                    if let error = model.error { Text(error).foregroundStyle(.orange) }
                    Button("Get a new code") { model.retry += 1 }
                } else { ProgressView("Checking ITV sign-in…") }
                if let error = account.error { Text(error).foregroundStyle(.orange) }
                Button("Close") { dismiss() }
            }.padding(70)
        }.task(id: "\(phase)-\(model.retry)") {
            guard phase == .active else { return }
            await account.reload(); checkedAccount = true
            guard !account.signedIn, !Task.isCancelled else { return }
            if await model.pair() { await account.reload(); dismiss() }
        }
    }
}

struct LiveChannelArtwork: View {
    let channel: LiveChannel
    var body: some View {
        if let image = channel.current?.image {
            ProgrammeThumbnail(url: image, uhd: false, provider: channel.provider, fallback: channel.logo)
        } else if channel.id == "c5:C5" {
            Color(red: 0.05, green: 0.17, blue: 0.22).aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        Image("Channel5Logo").renderingMode(.template).resizable().scaledToFit()
                            .foregroundStyle(.white.opacity(0.75)).padding(45)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 10))
        } else if let logo = channel.logo {
            Color(red: 0.05, green: 0.17, blue: 0.22).aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        ProgrammeArtwork(url: logo, fit: true).padding(45)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 10))
        } else { ProgrammeThumbnail(url: nil, uhd: false, provider: channel.provider) }
    }
}
