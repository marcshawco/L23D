import SwiftUI

/// Pick a format and options, export, then share the file.
struct ExportSheet: View {
    let scan: Scan

    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions()
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var exportedSize: Int64?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $options.format) {
                        ForEach(ExportOptions.Format.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(options.format.help)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Format")
                }

                Section("File name") {
                    TextField("Name", text: $options.fileName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Pivot", selection: $options.pivot) {
                        ForEach(ExportOptions.Pivot.allCases) { pivot in
                            Text(pivot.title).tag(pivot)
                        }
                    }
                    Text(options.pivot.help)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Origin point")
                }

                if options.format == .obj {
                    Section {
                        Picker("Units", selection: $options.units) {
                            ForEach(ExportOptions.Units.allCases) { units in
                                Text(units.title).tag(units)
                            }
                        }
                    } header: {
                        Text("Units")
                    } footer: {
                        Text("OBJ files don't store units. Blender, Unity and Godot expect meters; Unreal expects centimeters.")
                    }
                }

                Section {
                    Picker("Max texture size", selection: $options.maxTextureSize) {
                        ForEach(ExportOptions.TextureSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                } header: {
                    Text("Textures")
                } footer: {
                    Text("Smaller textures load faster in games and make the file smaller.")
                }

                Section {
                    Button {
                        Task { await runExport() }
                    } label: {
                        HStack {
                            Spacer()
                            if isExporting {
                                ProgressView()
                            } else {
                                Label("Export \(options.format.title)", systemImage: "square.and.arrow.down")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isExporting)

                    if let exportedURL {
                        ShareLink(item: exportedURL, preview: SharePreview(exportedURL.lastPathComponent)) {
                            HStack {
                                Label(exportedURL.lastPathComponent, systemImage: "square.and.arrow.up")
                                Spacer()
                                if let exportedSize {
                                    Text(Format.bytes(exportedSize))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else if exportedURL != nil {
                        Text("Tap the file to send it with AirDrop, save it to Files, or open it in another app.")
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                options.fileName = ExportService.safeFileName(scan.name)
            }
            .onChange(of: options) {
                // Options changed: the old file no longer matches.
                exportedURL = nil
                exportedSize = nil
                errorMessage = nil
            }
        }
    }

    private func runExport() async {
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        let size = scan.size.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
        do {
            let url = try await ExportService.export(
                modelURL: scan.folder.modelFile,
                realSize: size,
                options: options,
                to: scan.folder.exports,
                generator: "L23D \(Bundle.main.versionString)"
            )
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            exportedSize = (attributes?[.size] as? NSNumber)?.int64Value
            exportedURL = url
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
