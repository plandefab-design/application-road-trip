import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// File picker where iOS copies the chosen files into the app before handing them over (asCopy).
/// Works with every storage provider (iCloud Drive, Google Drive, OneDrive…), unlike SwiftUI's
/// fileImporter which opens files in place and can fail with NSCocoaErrorDomain 256.
struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: ([URL]) -> Void
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onClose: onClose) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onClose: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onClose: @escaping () -> Void) {
            self.onPick = onPick
            self.onClose = onClose
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onClose()
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onClose()
        }
    }
}
