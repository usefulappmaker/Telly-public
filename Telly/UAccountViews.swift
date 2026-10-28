// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CoreImage.CIFilterBuiltins

@MainActor final class UAccountModel: ObservableObject {
    static let shared = UAccountModel()
    @Published private(set) var signedIn = false
    @Published var error: String?
    func reload() async {
        do { signedIn = try await UAccountService.shared.isSignedIn(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func signOut() async {
        do { try await UAccountService.shared.signOut(); signedIn = false; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
@MainActor final class UPairingModel: ObservableObject {
    @Published var code: String?
    @Published var qr: UIImage?
    @Published var status = "Getting a U sign-in code…"
    @Published var error: String?
    @Published var retry = 0
    func pair() async -> Bool {
        code = nil; qr = nil; error = nil; status = "Getting a U sign-in code…"
        do {
            let pairing = try await UAccountService.shared.newCode()
            defer { Task { await UAccountService.shared.cancel(pairing) } }
            try Task.checkCancellation(); code = pairing.code
            let filter = CIFilter.qrCodeGenerator(); filter.message = Data(pairing.activationURL.absoluteString.utf8); filter.correctionLevel = "M"
            if let output = filter.outputImage?.transformed(by:CGAffineTransform(scaleX:10,y:10)),
               let image = CIContext().createCGImage(output,from:output.extent) { qr = UIImage(cgImage:image) }
            var failures = 0
            while Date() < pairing.expiresAt {
                status = "Waiting for you to sign in on U’s website…"
                try await Task.sleep(nanoseconds:3_000_000_000)
                do {
                    if try await UAccountService.shared.check(pairing) { return true }
                    failures = 0
                } catch is CancellationError { throw CancellationError() }
                catch { failures += 1; if failures >= 3 { throw error }; status = "Reconnecting to U…" }
            }
            code = nil; qr = nil; error = "This code has expired. Get a new code."
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        return false
    }
}
struct UAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var account = UAccountModel.shared
    @StateObject private var model = UPairingModel()
    @State private var checked = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:26) {
                ProviderBadge(provider:.u)
                Text(account.signedIn ? "U account" : "Sign in to U").font(.largeTitle).bold()
                if account.signedIn {
                    Text("You’re signed in. U programmes are ready to watch.").font(.title3)
                    Button("Sign out of U") { Task { await account.signOut(); model.retry += 1 } }
                    Text("This signs U out of Telly on this Apple TV.").foregroundStyle(.secondary)
                } else if checked {
                    HStack(alignment:.top,spacing:55) {
                        if let qr = model.qr {
                            Image(uiImage:qr).interpolation(.none).resizable().scaledToFit().frame(width:300,height:300)
                                .padding(20).background(.white).cornerRadius(16).accessibilityLabel("Scan to sign in on U’s website")
                        }
                        VStack(alignment:.leading,spacing:22) {
                            Text("Scan the QR code with your phone, or visit").font(.title3)
                            Text("u.co.uk/activate").font(.title2).bold()
                            Text("Sign in to U and enter this code:")
                            if let code = model.code { Text(code).font(.system(size:66,weight:.bold,design:.monospaced)).tracking(7) }
                            else if model.error == nil { ProgressView() }
                            Text(model.status).foregroundStyle(.secondary)
                        }
                    }
                    Text("Telly connects automatically once U confirms your sign-in. Your password stays on U’s website.").foregroundStyle(.secondary)
                    if let error = model.error { Text(error).foregroundStyle(.orange) }
                    Button("Get a new code") { model.retry += 1 }
                } else { ProgressView("Checking U sign-in…") }
                if let error = account.error { Text(error).foregroundStyle(.orange) }
                Button("Close") { dismiss() }
            }.padding(70)
        }.task(id:"\(phase)-\(model.retry)") {
            guard phase == .active else { return }
            await account.reload(); checked = true
            guard !account.signedIn, !Task.isCancelled else { return }
            if await model.pair() { await account.reload(); dismiss() }
        }
    }
}
