// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct NetworkSettingsTests {
    @MainActor static func main() {
        let suite = "TellyNetworkTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let networks = NetworkSettings(defaults: defaults)
        precondition(NetworkSettings.all.allSatisfy(networks.isOn), "Every network starts on")
        networks.set(.itv, on: false)
        precondition(!networks.isOn(.itv) && networks.isOn(.bbc), "Turning one off leaves the others on")
        precondition(!NetworkSettings(defaults: defaults).isOn(.itv), "The choice is kept")
        networks.set(.itv, on: true)
        precondition(NetworkSettings(defaults: defaults).isOn(.itv), "Turning it back on is kept")
        for network in [ContentProvider.bbc, .itv, .channel4, .channel5] { networks.set(network, on: false) }
        precondition(!networks.canTurnOff(.u), "The last network that is on can't be turned off")
        networks.set(.u, on: false)
        precondition(networks.isOn(.u), "At least one network stays on")
        precondition(NetworkSettings.valid(["itv", "unknown"]) == ["itv"], "Unknown names are dropped")
        precondition(NetworkSettings.valid(Set(NetworkSettings.all.map(\.rawValue))).isEmpty, "Saved settings that hide everything are ignored")
        // The Top Shelf names networks from channel ids alone: the names must match the app's.
        for id in ["bbc_one_london", "s4cpbs", "itv:itv", "itv:fast3", "c4:E4", "c5:C5", "c5:C5CH07"] {
            precondition(LiveChannelOrder.network(id) == ContentProvider.of(id).rawValue, "Network of \(id)")
        }
        print("PASS: network switches, persistence, last network kept on and Top Shelf network names")
    }
}
