import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Reads a PDF in the app (no download needed), then saves it to Files or shares it.
/// An unreadable file shows an explanation instead of an empty screen.
struct PDFViewer: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var file: PDFFile
    @State private var saving = false
    @State private var savedMessage: String?

    init(url: URL, title: String) {
        self.url = url
        self.title = title
        let doc = PDFDocument(url: url)
        _document = State(initialValue: (doc?.pageCount ?? 0) > 0 ? doc : nil)
        _file = State(initialValue: PDFFile(url: url))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    PDFKitView(document: document)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("Feuille de route illisible", systemImage: "doc.questionmark",
                                           description: Text("Le PDF n'a pas pu être créé (\(file.data.count) octets). Ferme et réessaie."))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                if document != nil {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { saving = true } label: { Image(systemName: "square.and.arrow.down") }
                            .accessibilityLabel("Enregistrer dans Fichiers")
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Partager")
                    }
                }
            }
            .fileExporter(isPresented: $saving, document: file, contentType: .pdf,
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

/// PDFKit pages one under the other, fitted to the screen width (zoom with two fingers).
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> FittingPDFView {
        let view = FittingPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = UIColor(white: 0.82, alpha: 1)     // light grey around white pages, any theme
        view.document = document
        return view
    }

    func updateUIView(_ view: FittingPDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// PDFView sized to its width once it has one: a PDFView created before layout (SwiftUI) can otherwise stay at
/// zoom 0 and show nothing but its background.
final class FittingPDFView: PDFView {
    private var fittedWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != fittedWidth,
              let page = document?.page(at: 0) else { return }
        let pageWidth = page.bounds(for: displayBox).width
        guard pageWidth > 0 else { return }
        fittedWidth = bounds.width
        let fit = (bounds.width - 12) / pageWidth
        minScaleFactor = fit
        maxScaleFactor = fit * 5
        scaleFactor = fit
        if let first = document?.page(at: 0) { go(to: first) }
    }
}

/// The PDF file as a document for « Enregistrer dans Fichiers » (read once).
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
    /// A new render of the same file is a new sheet.
    let id = UUID()
}
