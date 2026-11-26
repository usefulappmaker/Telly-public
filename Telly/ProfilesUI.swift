// SPDX-License-Identifier: GPL-3.0-or-later
// Profiles UI: Who's watching picker, profile avatars and editor, kids PIN pad, kids home.
import SwiftUI

struct ProfilePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ProfilePillSurface(content: configuration.label, pressed: configuration.isPressed) }
}

private struct ProfilePillSurface<Content: View>: View {
    let content: Content
    let pressed: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        content.font(.system(size: 22, weight: .semibold))
            .foregroundStyle(focused ? Color.black : Color.white.opacity(0.9))
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background { Capsule().fill(focused ? Color.white : Color.white.opacity(0.08)) }
            .shadow(color: TellyColour.blue.opacity(focused ? 0.55 : 0), radius: 20)
            .scaleEffect(pressed ? 0.96 : focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
            .focusEffectDisabled()
    }
}

/// "Who's watching?" grid for any number of profiles. Back keeps the current profile unless a choice is required.
struct WhoIsWatchingView: View {
    @ObservedObject private var store = ProfileStore.shared
    let required: Bool
    let dismiss: () -> Void
    let choose: (String) -> Void
    @FocusState private var focused: String?
    @State private var pending: String?
    var body: some View {
        VStack(spacing: 60) {
            Text("Who's watching?").font(.system(size: 56, weight: .bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 300), spacing: 40)], spacing: 40) {
                ForEach(store.profiles) { profile in
                    Button { if store.needsPIN(toSelect: profile.id) { pending = profile.id } else { choose(profile.id) } } label: {
                        ProfileAvatar(name: profile.name, current: profile.id == store.current)
                    }.buttonStyle(ProgrammeCardStyle()).focused($focused, equals: profile.id)
                }
            }.frame(maxWidth: 1400)
            if !required { Text("Press Back to keep \(store.currentProfile.name)").font(.system(size: 22)).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .background(.ultraThickMaterial)
        .defaultFocus($focused, store.current)
        .onExitCommand { if !required { dismiss() } }
        .interactiveDismissDisabled(required)
        .fullScreenCover(item: Binding(get: { pending.map { PendingProfile(id: $0) } }, set: { pending = $0?.id })) { item in
            PINPadView(title: "Enter the kids PIN to switch to \(store.name(item.id))", validate: { $0 == store.kidsPIN }) { pin in
                let id = item.id
                pending = nil
                if pin != nil { choose(id) }
            }
        }
    }
}

struct PendingProfile: Identifiable { let id: String }

/// Remote-friendly 4-digit PIN pad. validate == nil: choose a new PIN; otherwise check it. Back cancels.
struct PINPadView: View {
    let title: String
    let validate: ((String) -> Bool)?
    let done: (String?) -> Void
    @State private var digits = ""
    @State private var message = ""
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "Delete", "0", "Cancel"]
    var body: some View {
        VStack(spacing: 36) {
            Text(title).font(.system(size: 40, weight: .bold)).multilineTextAlignment(.center)
            HStack(spacing: 24) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(i < digits.count ? Color.white : Color.white.opacity(0.2)).frame(width: 30, height: 30)
                }
            }
            Text(message.isEmpty ? " " : message).font(.system(size: 24)).foregroundStyle(.orange)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(180), spacing: 24), count: 3), spacing: 24) {
                ForEach(keys, id: \.self) { key in
                    Button(key) { press(key) }.buttonStyle(OutlinedActionButtonStyle()).frame(width: 180)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .background(.ultraThickMaterial)
        .onExitCommand { done(nil) }
    }
    private func press(_ key: String) {
        switch key {
        case "Cancel": done(nil)
        case "Delete": if !digits.isEmpty { digits.removeLast() }
        default:
            guard digits.count < 4 else { return }
            digits += key; message = ""
            if digits.count == 4 {
                if let validate, !validate(digits) { message = "That PIN isn't right."; digits = "" }
                else { done(digits) }
            }
        }
    }
}

/// Home for a kids profile: their Continue Watching plus CBeebies and CBBC programmes.
struct KidsHomeView: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    private struct Row: Identifiable { let id: String; let title: String; let shows: [CatalogueShow] }
    @State private var rows: [Row] = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                ContinueWatchingRow(catalogue: catalogue, library: library)
                if rows.isEmpty && error == nil { ProgressView("Getting CBeebies and CBBC…") }
                if let error { Text(error).foregroundStyle(.orange) }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(row.title).font(.system(size: 36, weight: .bold))
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 36) {
                                ForEach(row.shows) { show in
                                    NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: {
                                        ShowCard(show: show).frame(width: 400)
                                    }.buttonStyle(ProgrammeCardStyle())
                                }
                            }.padding(.vertical, 24).padding(.horizontal, 8)
                        }.scrollClipDisabled()
                    }.focusSection()
                }
            }.padding(60)
        }.task {
            var loaded: [Row] = []
            for (id, title) in [("cbeebies", "CBeebies"), ("cbbc", "CBBC")] {
                if let page = try? await DiscoveryAPI().page(category: id, page: 1), !page.shows.isEmpty {
                    loaded.append(Row(id: id, title: title, shows: page.shows))
                }
            }
            rows = loaded
            if loaded.isEmpty { error = "CBeebies and CBBC programmes couldn't be loaded. Try again later." }
        }
    }
}

/// Round initial avatar used in the picker and Settings.
struct ProfileAvatar: View {
    let name: String
    let current: Bool
    var size: CGFloat = 200
    var body: some View {
        VStack(spacing: size * 0.09) {
            Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .bold))
                .frame(width: size, height: size).background(Circle().fill(TellyColour.blue.opacity(0.85)))
                .overlay { if current { Circle().strokeBorder(.white, lineWidth: max(4, size * 0.03)) } }
            Text(name.isEmpty ? " " : name).font(.system(size: max(22, size * 0.16), weight: .semibold)).lineLimit(1)
        }.padding(size * 0.12)
    }
}

/// Add or edit a profile: a real text field (opens the Apple TV keyboard), Save / Switch to / Remove / Cancel.
struct ProfileEditView: View {
    @ObservedObject private var store = ProfileStore.shared
    let profileID: String?
    let done: () -> Void
    @State private var name = ""
    @State private var confirmRemove = false
    @State private var kids = false
    @FocusState private var nameFocused: Bool
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 44) {
            Text(profileID == nil ? "Add profile" : "Edit profile").font(.system(size: 56, weight: .bold))
            HStack(spacing: 48) {
                ProfileAvatar(name: trimmed.isEmpty ? "?" : trimmed, current: profileID == store.current, size: 180)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Name").font(.system(size: 24, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("Name", text: $name).font(.system(size: 32)).frame(width: 760).focused($nameFocused)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                    Toggle("Kids profile", isOn: $kids).frame(width: 760).padding(.top, 12)
                    Text("CBeebies and CBBC only, no programmes with BBC guidance warnings, and no Settings.")
                        .font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 760, alignment: .leading)
                }
            }
            HStack(spacing: 24) {
                Button(profileID == nil ? "Add profile" : "Save") {
                    if let id = profileID { store.rename(id, to: trimmed); store.setKids(id, kids) }
                    else if let added = store.add(trimmed) { store.setKids(added.id, kids) }
                    done()
                }.buttonStyle(PrimaryPlayButtonStyle()).disabled(trimmed.isEmpty)
                if let id = profileID, id != store.current {
                    Button("Switch to") { store.rename(id, to: trimmed); store.select(id); done() }
                }
                if let id = profileID, store.profiles.count > 1, store.profiles.contains(where: { $0.id == id }) {
                    Button("Remove") { confirmRemove = true }
                }
                Button("Cancel") { done() }
            }.buttonStyle(OutlinedActionButtonStyle())
        }.padding(90).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .background(.ultraThickMaterial)
        .onAppear {
            if let id = profileID { name = store.name(id); kids = store.profiles.first { $0.id == id }?.kids ?? false } else { nameFocused = true }
        }
        .onExitCommand { done() }
        .alert("Remove \(store.name(profileID ?? ""))?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { if let id = profileID { store.remove(id) }; done() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Their Continue Watching and Saved list will be deleted on every Apple TV.") }
    }
}

/// the main Play button.
struct PrimaryPlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryPlaySurface(content: configuration.label, pressed: configuration.isPressed)
    }
}

private struct PrimaryPlaySurface<Content: View>: View {
    let content: Content
    let pressed: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        content.font(.system(size: 36, weight: .semibold)).foregroundStyle(.white)
            .lineLimit(1).fixedSize()   // never truncate "Resume 1:02:03"
            .padding(.horizontal, 48).frame(minWidth: 260, minHeight: 84)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(TellyColour.blue.opacity(focused ? 1 : 0.5)))
            .scaleEffect(pressed ? 0.97 : focused ? 1.08 : 1)
            .shadow(color: TellyColour.blue.opacity(focused ? 0.55 : 0), radius: 22, y: 6)
            .animation(.easeOut(duration: 0.15), value: focused)
            .focusEffectDisabled()
    }
}

/// Row of choices; the selected one is tinted, the focused one lifts (native bordered buttons).
struct TellySegments: View {
    let title: String
    let options: [String]
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 14) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(option).font(.system(size: 26, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 40)
                }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 12))
                    .tint(selection == option ? TellyColour.blue : .gray)
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }.padding(8).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            .focusSection().accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}
