import AppKit
import WebKit

/// Saves downloads straight to ~/Downloads, like Safari.
@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()
    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var dest = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        destinations[ObjectIdentifier(download)] = dest
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let dest = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Bounces the Downloads stack in the Dock.
        DistributedNotificationCenter.default().post(
            name: .init("com.apple.DownloadFileFinished"), object: dest.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        NSLog("Orbit download failed: \(error.localizedDescription)")
    }
}
