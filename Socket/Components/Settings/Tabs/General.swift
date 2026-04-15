//
//  General.swift
//  Socket
//
//  Created by Maciek Bagiński on 07/12/2025.
//

import SwiftUI

struct SettingsGeneralTab: View {
    @Environment(\.socketSettings) var socketSettings
    @State private var showingAddSite = false
    @State private var showingAddEngine = false

    var body: some View {
        @Bindable var settings = socketSettings
        HStack(alignment: .top) {
            MemberCard()
            Form {
                Toggle("Warn before quitting Socket", isOn: $settings.askBeforeQuit)
                Toggle("Automatically update Socket", isOn: .constant(true))
                    .disabled(true)
                Toggle("Socket's Ad Blocker", isOn: $settings.blockCrossSiteTracking)

                Section(header: Text("Search")) {
                    HStack {
                        Picker(
                            "Default search engine",
                            selection: $settings.searchEngineId
                        ) {
                            ForEach(SearchProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider.rawValue)
                            }
                            ForEach(socketSettings.customSearchEngines) { engine in
                                Text(engine.name).tag(engine.id.uuidString)
                            }
                        }

                        Button {
                            showingAddEngine = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    // Show remove button for custom engines that are currently selected
                    if let selected = socketSettings.customSearchEngines.first(where: { $0.id.uuidString == socketSettings.searchEngineId }) {
                        HStack {
                            Text(selected.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") {
                                socketSettings.customSearchEngines.removeAll { $0.id == selected.id }
                                socketSettings.searchEngineId = SearchProvider.google.rawValue
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    ForEach(socketSettings.siteSearchEntries) { entry in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(entry.color)
                                .frame(width: 10, height: 10)
                            Text(entry.name)
                            Spacer()
                            Text(entry.domain)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Button {
                                socketSettings.siteSearchEntries.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        showingAddSite = true
                    } label: {
                        Label("Add Site", systemImage: "plus")
                    }

                    Button("Reset to Defaults") {
                        socketSettings.siteSearchEntries = SiteSearchEntry.defaultSites
                    }
                } header: {
                    Text("Site Search")
                } footer: {
                    Text("Type a prefix in the command palette and press Tab to search a site directly.")
                }
            }
            .formStyle(.grouped)
        }
        .sheet(isPresented: $showingAddSite) {
            SiteSearchEntryEditor(entry: nil) { newEntry in
                socketSettings.siteSearchEntries.append(newEntry)
            }
        }
        .sheet(isPresented: $showingAddEngine) {
            CustomSearchEngineEditor { newEngine in
                socketSettings.customSearchEngines.append(newEngine)
            }
        }
    }
}

// MARK: - Custom Search Engine Editor

struct CustomSearchEngineEditor: View {
    let onSave: (CustomSearchEngine) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var urlTemplate: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Custom Search Engine")
                .font(.headline)

            Form {
                TextField("Name (e.g. Startpage)", text: $name)
                TextField("URL Template (use %@ for query)", text: $urlTemplate)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save") {
                    let engine = CustomSearchEngine(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        urlTemplate: urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    onSave(engine)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || urlTemplate.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 450)
    }
}
