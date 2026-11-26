// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import SwiftUI
#if os(tvOS)
import TVServices
#endif

/// Settings › Networks: a network that is off is hidden from Home, Browse, Search, Channels, the guide and the Top
/// Shelf, for every profile on this Apple TV. Saved programmes and Continue Watching are left alone, and kids
/// profiles (CBBC and CBeebies only) ignore it.
@MainActor final class NetworkSettings: ObservableObject {
    static let shared = NetworkSettings()
    static let all: [ContentProvider] = [.bbc, .itv, .channel4, .channel5, .u]
    @Published private(set) var hidden: Set<String>
    private let defaults: UserDefaults
    private static let key = "hiddenNetworks-v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Self.valid(Set(defaults.stringArray(forKey: Self.key) ?? []))
        publishToTopShelf()
    }
    /// Unknown names are dropped, and hiding everything is never allowed.
    static func valid(_ names: Set<String>) -> Set<String> {
        let known = names.intersection(all.map(\.rawValue))
        return known.count == all.count ? [] : known
    }
    func isOn(_ network: ContentProvider) -> Bool { !hidden.contains(network.rawValue) }
    /// The last network that is on can't be turned off.
    func canTurnOff(_ network: ContentProvider) -> Bool { !isOn(network) || hidden.count < Self.all.count - 1 }
    func set(_ network: ContentProvider, on: Bool) {
        if !on, !canTurnOff(network) { return }
        if on { hidden.remove(network.rawValue) } else { hidden.insert(network.rawValue) }
        defaults.set(hidden.sorted(), forKey: Self.key)
        publishToTopShelf()
    }
    private func publishToTopShelf() {
        guard Set(TellyShared.hiddenNetworks) != hidden else { return }
        TellyShared.hiddenNetworks = hidden.sorted()
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }
}

/// The switches themselves, shown in Settings.
struct NetworkSwitches: View {
    @ObservedObject private var networks = NetworkSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Networks").font(.system(size: 32, weight: .bold))
            Text("Turn off a network to hide its programmes from Home, Browse and Search, and its channels from Channels, the guide and the Top Shelf. Saved programmes and Continue Watching stay. Applies to every profile except kids profiles.")
                .font(.system(size: 22)).foregroundStyle(.secondary)
            ForEach(NetworkSettings.all, id: \.self) { network in
                Toggle(isOn: Binding(get: { networks.isOn(network) }, set: { networks.set(network, on: $0) })) {
                    HStack(spacing: 24) {
                        Image(network.logo).renderingMode(.template).resizable().scaledToFit().frame(width: 70, height: 34).accessibilityHidden(true)
                        Text(network.title)
                    }
                }.disabled(!networks.canTurnOff(network)).accessibilityIdentifier("network-" + network.rawValue)
            }
            if networks.hidden.count == NetworkSettings.all.count - 1 {
                Text("At least one network has to stay on.").font(.system(size: 22)).foregroundStyle(.secondary)
            }
        }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
            .focusSection()
    }
}
