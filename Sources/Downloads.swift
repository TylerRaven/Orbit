import AppKit
import Observation
import SwiftUI
import WebKit

/// Saves downloads straight to ~/Downloads, like Safari, and keeps a list for the downloads panel.
@MainActor
@Observable
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    enum State { case running, done, failed, cancelled }

    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var destination: URL?
        var progress = 0.0
        var state = State.running
        var started = Date()
    }

    var items: [Item] = []
    var showPanel = false

    var activeCount: Int { items.filter { $0.state == .running }.count }
    /// Overall progress of everything still downloading, for the toolbar ring.
    var overallProgress: Double {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else { return 1 }
        return running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    @ObservationIgnored private var downloads: [ObjectIdentifier: (id: UUID, download: WKDownload)] = [:]
    @ObservationIgnored private var observers: [UUID: NSKeyValueObservation] = [:]

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

        let item = Item(name: dest.lastPathComponent, destination: dest)
        items.insert(item, at: 0)
        downloads[ObjectIdentifier(download)] = (item.id, download)
        observers[item.id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in self?.update(item.id) { $0.progress = value } }
        }
        showPanel = true
        WallpaperMood.shared.pulse(0.5)
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        observers.removeValue(forKey: entry.id)
        update(entry.id) { $0.state = .done; $0.progress = 1 }
        if let dest = items.first(where: { $0.id == entry.id })?.destination {
            Self.quarantine(dest, from: download.originalRequest?.url)
            // Bounces the Downloads stack in the Dock.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: dest.path)
        }
    }

    /// Marks a finished download as coming from the internet, so macOS checks it (Gatekeeper,
    /// "downloaded from…" warnings) before it opens, like it does for Safari downloads.
    private static func quarantine(_ file: URL, from source: URL?) {
        var props: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Orbit",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source { props[kLSQuarantineDataURLKey as String] = source }
        var url = file
        var values = URLResourceValues()
        values.quarantineProperties = props
        try? url.setResourceValues(values)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        observers.removeValue(forKey: entry.id)
        update(entry.id) { if $0.state != .cancelled { $0.state = .failed } }
    }

    func cancel(_ item: Item) {
        guard let key = downloads.first(where: { $0.value.id == item.id })?.key,
              let download = downloads[key]?.download else { return }
        update(item.id) { $0.state = .cancelled }
        download.cancel()
    }

    func open(_ item: Item) {
        if let url = item.destination { NSWorkspace.shared.open(url) }
    }

    func reveal(_ item: Item) {
        if let url = item.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
        if items.isEmpty { showPanel = false }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }
}

/// Toolbar button that shows download progress and opens the panel.
struct DownloadsButton: View {
    let accent: Accent
    private var downloads: Downloads { Downloads.shared }

    var body: some View {
        Button { downloads.showPanel.toggle() } label: {
            ZStack {
                if downloads.activeCount > 0 {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: downloads.overallProgress)
                        .stroke(accent.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.2), value: downloads.overallProgress)
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(downloads.activeCount > 0 ? AnyShapeStyle(accent.color) : AnyShapeStyle(.secondary))
            }
            .frame(width: 20, height: 20)
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Downloads")
        .popover(isPresented: Binding(get: { downloads.showPanel }, set: { downloads.showPanel = $0 }),
                 arrowEdge: .bottom) {
            DownloadsPanel(accent: accent)
        }
    }
}

struct DownloadsPanel: View {
    let accent: Accent
    private var downloads: Downloads { Downloads.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { downloads.clearFinished() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(downloads.items.allSatisfy { $0.state == .running })
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 8)

            if downloads.items.isEmpty {
                Text("Nothing downloaded yet.")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(downloads.items) { row($0) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 340)
    }

    private func row(_ item: Downloads.Item) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.destination?.path ?? ""))
                .resizable()
                .frame(width: 30, height: 30)
                .opacity(item.state == .done ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .running:
                    ProgressView(value: item.progress).tint(accent.color).controlSize(.small)
                case .done:
                    Text(sizeText(item)).font(.system(size: 11)).foregroundStyle(.secondary)
                case .failed:
                    Text("Failed").font(.system(size: 11)).foregroundStyle(.red)
                case .cancelled:
                    Text("Cancelled").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if item.state == .running {
                Button { downloads.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
            } else if item.state == .done {
                Button { downloads.reveal(item) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.state == .done { downloads.open(item) } }
        .contextMenu {
            Button("Open") { downloads.open(item) }.disabled(item.state != .done)
            Button("Show in Finder") { downloads.reveal(item) }.disabled(item.state != .done)
        }
    }

    private func sizeText(_ item: Downloads.Item) -> String {
        guard let path = item.destination?.path,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else { return "Done" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
