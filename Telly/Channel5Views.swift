// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CoreImage.CIFilterBuiltins

@MainActor final class Channel5CatalogueStore: ObservableObject {
    @Published private(set) var knownShows: [CatalogueShow] = [] { didSet { searchRevision &+= 1 } }
    private(set) var searchRevision = 0
    @Published private(set) var error: String?
    private var refreshing = false
    private var refreshed = false
    private let api = Channel5CatalogueAPI()
    private static var cache: URL { FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("channel5-catalogue-v1.json") }
    init() {
        if let data = try? Data(contentsOf:Self.cache), data.count < 8_000_000, let saved = try? JSONDecoder().decode([CatalogueShow].self,from:data) { knownShows=saved }
        if knownShows.isEmpty, let url=Bundle.main.url(forResource:"Channel5Seed",withExtension:"json"), let data=try? Data(contentsOf:url) { knownShows=(try? Channel5CatalogueAPI.shows(data)) ?? [] }
    }
    var home: [CatalogueShow] {
        let preferred=["All Creatures Great and Small","The Yorkshire Vet","Home and Away","The Madame Blanc Mysteries","The Good Ship Murder","Bargain Loving Brits in the Sun","The Hotel Inspector","The Hardacres"]
        let first=preferred.compactMap { title in knownShows.first { $0.title == title } }
        let ids=Set(first.map(\.id))
        return Array((first+knownShows.filter { !ids.contains($0.id) }).prefix(20))
    }
    func refresh() async {
        guard !refreshing, !refreshed else { return };refreshing=true;defer { refreshing=false }
        do {
            let shows=try await api.all();try Task.checkCancellation()
            guard !shows.isEmpty else { throw Channel5Error.message("Channel 5 returned no programme listings.") }
            knownShows=shows;error=nil;refreshed=true
            if let data=try? JSONEncoder().encode(shows),data.count<8_000_000 { try? data.write(to:Self.cache,options:.atomic) }
        } catch { if !Task.isCancelled { self.error="Channel 5 listings could not refresh. Showing the saved catalogue." } }
    }
    func category(_ genres: [Genre]) -> [CatalogueShow] { knownShows.filter { show in genres.contains { Channel5CatalogueAPI.belongs(show,category:$0.id) } } }
    func details(_ show: CatalogueShow) async throws -> CatalogueShow { try await api.details(show) }
    func search(_ text: String) async throws -> [CatalogueShow] { try await api.search(text) }
}

struct Channel5HomeRows: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @ObservedObject var store: Channel5CatalogueStore
    var body: some View {
        if !store.home.isEmpty {
            VStack(alignment:.leading,spacing:20) {
                HomepageNetworkHeading(provider:.channel5,title:"Explore Channel 5")
                Channel5ShowRow(shows:store.home,catalogue:catalogue,library:library)
            }
        }
    }
}
private struct Channel5ShowRow: View {
    let shows: [CatalogueShow]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing:28) {
                ForEach(shows) { show in
                    NavigationLink { CatalogueShowView(show:show,catalogue:catalogue,library:library) } label: { ShowCard(show:show).frame(width:330) }.buttonStyle(ProgrammeCardStyle())
                }
            }.padding(.vertical,30).padding(.horizontal,24)
        }.scrollClipDisabled().padding(.horizontal,-24)
    }
}
struct Channel5CategoryPreview: View {
    let genres: [Genre]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @ObservedObject var store: Channel5CatalogueStore
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                ProviderBadge(provider:.channel5,categoryHeading:true).accessibilityIdentifier("category-network-channel5")
                Spacer()
                NavigationLink("View all") { Channel5CategoryView(genres:genres,catalogue:catalogue,library:library,store:store) }
            }
            Channel5ShowRow(shows:Array(CategorySorting.sorted(store.category(genres),by:.alphabetical).prefix(20)),catalogue:catalogue,library:library)
            if let error=store.error { Text(error).font(.callout).foregroundStyle(.secondary) }
        }.task { await store.refresh() }
    }
}
struct Channel5CategoryView: View {
    let genres: [Genre]
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @ObservedObject var store: Channel5CatalogueStore
    @State private var visible = 30
    @Environment(\.dismiss) private var dismiss
    private var shows: [CatalogueShow] { CategorySorting.sorted(store.category(genres),by:.alphabetical) }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:28) {
                HStack { ProviderBadge(provider:.channel5,categoryHeading:true);Text(genres.map(\.title).joined(separator:" & ")).font(.largeTitle).bold() }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:330),spacing:28)],spacing:30) {
                    ForEach(Array(shows.prefix(visible).enumerated()),id:\.element.id) { position,show in
                        NavigationLink { CatalogueShowView(show:show,catalogue:catalogue,library:library) } label: { ShowCard(show:show) }.buttonStyle(ProgrammeCardStyle())
                            .task { if position >= visible-8 { visible=min(shows.count,visible+30) } }
                    }
                }
                if shows.isEmpty { Text("No Channel 5 programmes are currently listed in this category.").foregroundStyle(.secondary) }
                if let error=store.error { Text(error).foregroundStyle(.secondary) }
            }.padding(60)
        }.task { await store.refresh() }.onExitCommand { dismiss() }
    }
}

@MainActor final class Channel5AccountModel: ObservableObject {
    static let shared=Channel5AccountModel()
    @Published private(set) var signedIn=false
    @Published var error: String?
    func reload() async { do { signedIn=try await Channel5AccountService.shared.isSignedIn();error=nil } catch { self.error=error.localizedDescription } }
    func signOut() async { do { try await Channel5AccountService.shared.signOut();signedIn=false;error=nil } catch { self.error=error.localizedDescription } }
}
@MainActor final class Channel5PairingModel: ObservableObject {
    @Published var code: String?
    @Published var qr: UIImage?
    @Published var status="Getting a Channel 5 sign-in code…"
    @Published var error: String?
    @Published var retry=0
    func pair() async -> Bool {
        code=nil;qr=nil;error=nil;status="Getting a Channel 5 sign-in code…"
        do {
            let pairing=try await Channel5AccountService.shared.newCode()
            defer { Task { await Channel5AccountService.shared.cancel(pairing) } }
            try Task.checkCancellation();code=pairing.pin
            let filter=CIFilter.qrCodeGenerator();filter.message=Data(pairing.activationURL.absoluteString.utf8);filter.correctionLevel="M"
            if let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:10,y:10)),let image=CIContext().createCGImage(output,from:output.extent) { qr=UIImage(cgImage:image) }
            var failures=0
            while Date()<pairing.expires {
                status="Waiting for you to sign in on Channel 5’s website…"
                try await Task.sleep(nanoseconds:3_000_000_000)
                do { if try await Channel5AccountService.shared.check(pairing) { return true };failures=0 }
                catch is CancellationError { throw CancellationError() }
                catch { failures += 1;if failures>=3 { throw error };status="Reconnecting to Channel 5…" }
            }
            code=nil;qr=nil;error="This code has expired. Get a new code."
        } catch { if !Task.isCancelled { self.error=error.localizedDescription } }
        return false
    }
}
struct Channel5AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var account=Channel5AccountModel.shared
    @StateObject private var model=Channel5PairingModel()
    @State private var checked=false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:26) {
                ProviderBadge(provider:.channel5)
                Text(account.signedIn ? "Channel 5 account" : "Sign in to Channel 5").font(.largeTitle).bold()
                if account.signedIn {
                    Text("You’re signed in. Live channels and catch-up programmes are ready to try.").font(.title3)
                    Button("Sign out of Channel 5") { Task { await account.signOut();model.retry += 1 } }
                } else if checked {
                    HStack(alignment:.top,spacing:55) {
                        if let qr=model.qr { Image(uiImage:qr).interpolation(.none).resizable().scaledToFit().frame(width:300,height:300).padding(20).background(.white).cornerRadius(16).accessibilityLabel("Scan to sign in on Channel 5’s website") }
                        VStack(alignment:.leading,spacing:22) {
                            Text("Scan the QR code with your phone, or visit").font(.title3)
                            Text("activate.channel5.com").font(.title2).bold()
                            Text("Sign in to Channel 5 and enter this code:")
                            if let code=model.code { Text(code.uppercased()).font(.system(size:66,weight:.bold,design:.monospaced)).tracking(7) }
                            else if model.error == nil { ProgressView() }
                            Text(model.status).foregroundStyle(.secondary)
                        }
                    }
                    Text("Telly will connect automatically once Channel 5 confirms your sign-in.").foregroundStyle(.secondary)
                    if let error=model.error { Text(error).foregroundStyle(.orange) }
                    Button("Get a new code") { model.retry += 1 }
                } else { ProgressView("Checking Channel 5 sign-in…") }
                if let error=account.error { Text(error).foregroundStyle(.orange) }
                Button("Close") { dismiss() }
            }.padding(70)
        }.task(id:"\(phase)-\(model.retry)") {
            guard phase == .active else { return }
            await account.reload();checked=true
            guard !account.signedIn,!Task.isCancelled else { return }
            if await model.pair() { await account.reload();dismiss() }
        }
    }
}
