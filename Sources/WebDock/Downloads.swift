import AppKit
import WebKit

/// Saves what pages download into ~/Downloads, never overwriting, and reports progress.
final class DownloadManager: NSObject, WKDownloadDelegate {
    enum Event {
        case started(String)
        case finished(URL)
        case failed(String)
    }

    var onEvent: (Event) -> Void = { _ in }
    /// WebKit doesn't promise to keep a download alive, so hold each until it ends.
    private var active: [ObjectIdentifier: (download: WKDownload, destination: URL?)] = [:]

    static var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        active[ObjectIdentifier(download)] = (download, nil)
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let destination = Self.uniqueURL(for: suggestedFilename.isEmpty ? "download" : suggestedFilename)
        active[ObjectIdentifier(download)] = (download, destination)
        onEvent(.started(destination.lastPathComponent))
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = active.removeValue(forKey: ObjectIdentifier(download))?.destination else { return }
        // Makes the Downloads stack in the Dock bounce, as it does for Safari.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                     object: destination.path)
        onEvent(.finished(destination))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let destination = active.removeValue(forKey: ObjectIdentifier(download))?.destination
        onEvent(.failed(destination?.lastPathComponent ?? "download"))
    }

    /// "report.pdf", then "report 2.pdf", "report 3.pdf", … as names are taken.
    private static func uniqueURL(for filename: String) -> URL {
        let safe = filename.replacingOccurrences(of: "/", with: "-")
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = folder.appendingPathComponent(safe)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(name)
            number += 1
        }
        return candidate
    }
}
