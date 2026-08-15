import SwiftUI

/// The "General" page, pushed inside the settings sheet.
///
/// Ports `settings/__settings_detail_page.dart`. Most of that file's difficulty
/// is layout plumbing that `List` removes outright — the Dart version notes that
/// its rows land in a `Column` inside a `ListView`, so the vertical axis is
/// unbounded and `Expanded` has nothing to divide, forcing a `SizedBox(width:
/// double.infinity)` instead. A `Section` has no such trap.
struct GeneralSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        // `@Bindable` is how an `@Observable` object hands out bindings. The
        // `@Environment` property itself is a `let`, so `$settings.userAgent`
        // does not compile without this line.
        @Bindable var settings = settings

        List {
            Section("Update Playlist") {
                #if os(tvOS)
                    // `Stepper` does not exist on tvOS — there is no −/+ control
                    // idiom for a remote. A `Picker` is the native equivalent
                    // there and gets focus handling for free.
                    Picker("Frequency", selection: $settings.updateFrequency) {
                        ForEach(SettingsStore.UpdateFrequency.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                #else
                    
                HStack(spacing: 24) {
                    Button{
                        settings.updateFrequency = settings.updateFrequency.previous
                    } label: {
                        Image(systemName: "minus").font(.title3.bold()).frame(width: 30, height: 30)
                    }.buttonStyle(.glass).clipShape(Circle()).disabled(settings.updateFrequency.previous == settings.updateFrequency)
                    Spacer()
                   
                    Text(settings.updateFrequency.label)
                        .frame(minWidth: 120, alignment: .center)
                        .font(.body.monospacedDigit())
                    Spacer()
                    Button {
                        settings.updateFrequency = settings.updateFrequency.next
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.bold()).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass).clipShape(Circle()).disabled(settings.updateFrequency.next == settings.updateFrequency)
                }
#endif
            }

            Section("Clean up storage") {
                ForEach(Self.storageStubs, id: \.title) { entry in
                    NavigationLink {
                        NotBuiltView(title: entry.title)
                    } label: {
                        SettingsRowLabel(systemImage: entry.symbol, title: entry.title)
                    }
                }
            }

            Section("User Agent") {
                TextField("Enter user agent", text: $settings.userAgent)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section("Xtream Codes") {
                // `Toggle` puts the whole row in the tap target and keeps the
                // control aligned with the other sections — the Flutter version
                // wires `onTap` separately so the label is tappable too.
                Toggle(isOn: $settings.useRemoteSettings) {
                    SettingsRowLabel(systemImage: "link", title: "Use remote settings")
                }
            }

            Section("Preferred live streams format") {
                // `.inline` renders as a checked list inside the section, which
                // is the same shape as the Dart radio rows — and selecting is a
                // whole-row tap for free, which that version has to wire by hand
                // because a radio dot is a small thing to hit.
                Picker("Format", selection: $settings.streamFormat) {
                    ForEach(SettingsStore.StreamFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle("General")
        .inlineNavigationTitle()
    }

    private static let storageStubs: [(symbol: String, title: String)] = [
        ("folder", "Temporal Files"),
        ("book", "EPG Data"),
        ("film", "TMDB Data"),
    ]
}
