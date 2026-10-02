import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Reads a PDF in the app (no download needed), then saves it to Files or shares it.
struct PDFViewer: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var savedMessage: String?

    var body: some View {
        NavigationStack {
            PDFKitView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { saving = true } label: { Image(systemName: "square.and.arrow.down") }
                            .accessibilityLabel("Enregistrer dans Fichiers")
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Partager")
                    }
                }
                .fileExporter(isPresented: $saving, document: PDFFile(url: url), contentType: .pdf,
                              defaultFilename: url.deletingPathExtension().lastPathComponent) { result in
                    if case .success = result { savedMessage = "Enregistré dans Fichiers ✓" }
                }
                .overlay(alignment: .bottom) {
                    if let savedMessage {
                        Text(savedMessage).font(.subheadline.bold())
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .glass(radius: 20)
                            .padding(.bottom, 24)
                            .task { try? await Task.sleep(for: .seconds(2)); self.savedMessage = nil }
                    }
                }
        }
    }
}

/// PDFKit page view (zoom, scroll), pages one under the other.
struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGray5
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

/// The PDF file as a document for « Enregistrer dans Fichiers ».
struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let data: Data

    init(url: URL) { data = (try? Data(contentsOf: url)) ?? Data() }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// A PDF to show, presentable with `.sheet(item:)`.
struct PDFToShow: Identifiable {
    let url: URL
    let title: String
    var id: String { url.path }
}
