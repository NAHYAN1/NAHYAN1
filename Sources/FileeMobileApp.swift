import SwiftUI
import UniformTypeIdentifiers

@main
struct FileeMobileApp: App {
    var body: some Scene { WindowGroup { ConversionView() } }
}

struct ConversionView: View {
    @State private var inputs: [URL] = []
    @State private var outputs: [URL] = []
    @State private var format: OutputFormat = .jpg
    @State private var quality = 0.85
    @State private var maxDimension = 2048
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?

    private let worker = DispatchQueue(label: "filee.mobile.conversion", qos: .userInitiated)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Convert on your device", systemImage: "arrow.triangle.2.circlepath")
                        .font(.title2.bold())
                    Text("Images and PDFs. No account or server uploads.")
                        .foregroundStyle(.secondary)
                }
                Section("1. Choose files") {
                    Button { importing = true } label: {
                        Label("Browse Files", systemImage: "folder.badge.plus")
                    }
                    ForEach(inputs, id: \.self) { file in
                        Label(file.lastPathComponent, systemImage: "doc")
                            .lineLimit(2)
                    }
                    Text("Up to 20 files, 40 MB each. Still images and unlocked PDFs only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("2. Choose output") {
                    Picker("Format", selection: $format) {
                        ForEach(OutputFormat.allCases) { item in Text(item.rawValue).tag(item) }
                    }.pickerStyle(.segmented)
                    Picker("Maximum image edge", selection: $maxDimension) {
                        Text("1024 pixels").tag(1024)
                        Text("2048 pixels").tag(2048)
                        Text("4096 pixels").tag(4096)
                    }
                    if format == .jpg {
                        LabeledContent("JPEG quality", value: "\(Int(quality * 100))%")
                        Slider(value: $quality, in: 0.1...1, step: 0.05)
                            .accessibilityLabel("JPEG quality")
                    }
                    Text("PDF → JPG/PNG exports each page. Image → PDF creates one PDF per image. Images are resized to the selected maximum edge.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(action: convert) {
                        HStack {
                            if busy { ProgressView() }
                            Text(busy ? "Converting…" : "Convert files").fontWeight(.semibold)
                        }.frame(maxWidth: .infinity)
                    }.disabled(inputs.isEmpty || busy)
                }
                if !outputs.isEmpty {
                    Section("3. Save or share") {
                        ShareLink(items: outputs) { Label("Share all / Save to Files", systemImage: "square.and.arrow.up") }
                        ForEach(outputs, id: \.self) { file in
                            ShareLink(item: file) { Text(file.lastPathComponent).lineLimit(2) }
                        }
                    }
                }
                Section {
                    Text("Originals are kept. Imported copies and results stay in this app until you remove its data. Saving to a cloud provider uses that provider.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(busy)
            .navigationTitle("Filee Mobile")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure(let error): message = error.localizedDescription
                }
            }
            .alert("Filee Mobile", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, urls.count <= 20 else {
            message = "Choose between 1 and 20 files."; return
        }
        busy = true
        worker.async {
            do {
                let folder = try appFolder("Imports").appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var copied: [URL] = []
                do {
                    for (index, url) in urls.enumerated() {
                        let granted = url.startAccessingSecurityScopedResource()
                        defer { if granted { url.stopAccessingSecurityScopedResource() } }
                        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        guard info.isRegularFile == true, let size = info.fileSize, size <= Converter.maxFileBytes else {
                            throw ConversionError.invalid("Choose regular files of 40 MB or smaller.")
                        }
                        let target = folder.appendingPathComponent("\(index + 1)-\(url.lastPathComponent)")
                        try FileManager.default.copyItem(at: url, to: target)
                        copied.append(target)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
                DispatchQueue.main.async { inputs = copied; outputs = []; busy = false }
            } catch {
                DispatchQueue.main.async { message = error.localizedDescription; busy = false }
            }
        }
    }

    private func convert() {
        busy = true
        outputs = []
        let selected = inputs, selectedFormat = format, selectedQuality = quality, selectedSize = maxDimension
        worker.async {
            do {
                let folder = try appFolder("Results").appendingPathComponent(UUID().uuidString)
                let files = try Converter.run(inputs: selected, format: selectedFormat,
                                              quality: selectedQuality, maxDimension: selectedSize, output: folder)
                DispatchQueue.main.async { outputs = files; busy = false }
            } catch {
                DispatchQueue.main.async { message = error.localizedDescription; busy = false }
            }
        }
    }

    private func appFolder(_ name: String) throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true).appendingPathComponent(name)
    }
}
