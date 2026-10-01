import SwiftUI
import UIKit

/// iOS share sheet (save to Files, Messages, Mail, AirDrop…) for a file made on the fly, e.g. a road book PDF.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file to share, presentable with `.sheet(item:)`.
struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
