import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum FileRead {
    static func checked(_ url: URL, limit: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, let length = attributes.fileSize,
              length > 0, length <= limit else { throw ArchiveError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.isEmpty, data.count <= limit else { throw ArchiveError.tooLarge }
        return data
    }

    static func shareFile(_ data: Data, name: String) async throws -> URL {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        }.value
    }

    static func copyBackup(_ source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let attributes = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, let bytes = attributes.fileSize, bytes > 0,
              bytes <= BackupPackage.maxBytes else { throw ArchiveError.tooLarge }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let available = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        try Library.checkSpace(required: bytes, available: available)
        let copy = folder.appendingPathComponent("restore.goshuinbackup")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            try Data().write(to: copy, options: .completeFileProtectionUntilFirstUserAuthentication)
            let output = try FileHandle(forWritingTo: copy)
            defer { try? output.close() }
            var remaining = bytes
            while remaining > 0 {
                try Task.checkCancellation()
                guard let block = try input.read(upToCount: min(remaining, 1_048_576)), !block.isEmpty
                else { throw ArchiveError.badBackup }
                try output.write(contentsOf: block)
                remaining -= block.count
            }
            guard try (input.read(upToCount: 1) ?? Data()).isEmpty else { throw ArchiveError.badBackup }
            try output.synchronize()
            return copy
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func cleanTemporary(_ url: URL?) {
        guard let url else { return }
        Task.detached { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.goshuinBackup]
    var file: URL

    init(file: URL) { self.file = file }
    init(configuration: ReadConfiguration) throws { throw ArchiveError.badBackup }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: file, options: [])
    }
}

@MainActor
enum ShareRequest {
    static func present(_ items: [Any], temporaryFile: URL? = nil,
                        requested: () -> Void, completed: @escaping (Bool) -> Void) {
        if AppModel.testing {
            requested()
            FileRead.cleanTemporary(temporaryFile)
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            FileRead.cleanTemporary(temporaryFile)
            completed(false)
            return
        }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = presenter.view.bounds
        controller.completionWithItemsHandler = { _, done, _, error in
            Task { @MainActor in
                FileRead.cleanTemporary(temporaryFile)
                completed(done && error == nil)
            }
        }
        presenter.present(controller, animated: true)
    }

}

struct InlineError: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = model.error {
                HStack {
                    Text(message).font(.footnote)
                    Spacer()
                    Button(L.t("close")) { model.error = nil }
                        .accessibilityIdentifier("inlineError.close")
                }.padding(12).paperCard(tint: Paper.blush).padding(8)
            }
        }
    }
}

struct ShareCard: View {
    @EnvironmentObject private var model: AppModel
    var entry: UUID?
    var milestone: Milestone?
    var success: () -> Void
    @State private var selection: [UUID] = []
    @State private var showTemples = false
    @State private var showMonth = false
    @State private var showRoute = false
    @State private var chooseImages = false
    @State private var ready: Data?
    @State private var preview: UIImage?
    @State private var requested = false
    @State private var captionCopied = false
    @State private var started = false

    private var entries: [StampEntry] {
        selection.compactMap { id in model.archive.active.first { $0.id == id } }
    }
    private var routeName: String? {
        model.archive.routes.first { $0.id == milestone?.routeID }?.name
    }
    private var title: String { milestone?.title ?? L.t("share.title") }
    private var caption: String {
        var fragments: [String] = []
        if showRoute, let routeName { fragments.append(routeName) }
        if showTemples {
            var seen = Set<String>()
            fragments.append(entries.compactMap { model.archive.temple($0.templeID)?.name }
                .filter { seen.insert($0).inserted }.joined(separator: " · "))
        }
        if showMonth {
            let keys = Set(entries.compactMap { $0.visitDay.map { String($0.prefix(7)) } }).sorted()
            fragments.append(keys.map(VisitDay.monthLabel).joined(separator: " · "))
        }
        let result = fragments.filter { !$0.isEmpty }.joined(separator: "\n")
        return result.isEmpty ? L.t("share.caption") : result
    }

    private var renderKey: String {
        entries.map { "\($0.id):\($0.revision)" }.joined(separator: "|") + "\n" + caption
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text(L.t("share.preview")).font(.subheadline).foregroundStyle(Paper.muted)
                ZStack {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                            .accessibilityLabel(title)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 280)
                    }
                }
                .frame(maxWidth: 380).clipShape(.rect(cornerRadius: 15)).paperCard()
                Button(L.t("share.image")) { Task { await share() } }
                    .buttonStyle(ActionStyle(prominent: true))
                    .disabled(ready == nil).accessibilityIdentifier("share.image")
                if requested {
                    Text(L.t("share.requested")).accessibilityIdentifier("share.requested")
                }
                if captionCopied {
                    Text(L.t("share.copied")).font(.footnote).accessibilityIdentifier("share.copied")
                }
                Text(L.t("share.privacy")).font(.footnote).foregroundStyle(Paper.muted)
                options
                Button(L.t("share.copyCaption")) {
                    if !AppModel.testing { UIPasteboard.general.string = L.t("share.post") }
                    captionCopied = true
                }.buttonStyle(ActionStyle()).accessibilityIdentifier("share.copyCaption")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Paper.background).navigationTitle(L.t(milestone == nil ? "share.card" : "milestone.card"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if milestone != nil { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
        }
        .sheet(isPresented: $chooseImages) {
            NavigationStack {
                List {
                    ForEach(model.archive.filtered(book: nil, query: "", month: nil)) { page in
                        Button {
                            if let index = selection.firstIndex(of: page.id) {
                                if milestone != nil || selection.count > 1 { selection.remove(at: index) }
                            } else if selection.count < 6 {
                                selection.append(page.id)
                            }
                        } label: {
                            HStack {
                                StampPhoto(entry: page).frame(width: 55, height: 44).clipShape(.rect(cornerRadius: 5))
                                VStack(alignment: .leading) {
                                    Text(model.archive.name(for: page))
                                    Text(VisitDay.label(page.visitDay)).font(.caption).foregroundStyle(Paper.muted)
                                }
                                Spacer()
                                if let index = selection.firstIndex(of: page.id) {
                                    Text("\(index + 1)").font(.caption.bold())
                                }
                            }
                        }.accessibilityIdentifier("share.page")
                        if selection.contains(page.id) {
                            NavigationLink(L.t("crop")) { CropEditor(entryID: page.id) }
                                .accessibilityIdentifier("share.crop")
                        }
                    }
                }
                .panelBackground().navigationTitle(L.t("share.pages"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            if let entry { selection = [entry] }
        }
        .task(id: renderKey) {
            guard let worker = model.worker, entry == nil || !selection.isEmpty else { return }
            ready = nil
            do {
                let storeID = Bundle.main.infoDictionary?["APP_STORE_ID"] as? String
                let data = try await worker.share(entries: entries, title: title, caption: caption, storeID: storeID)
                let image = try await Task.detached { try StampImages.image(data, maxPixel: 1080) }.value
                guard !Task.isCancelled else { return }
                ready = data
                preview = image
            } catch { if !Task.isCancelled { model.report(error) } }
        }
        .modifier(InlineError())
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(L.f("share.selection", selection.count)) { chooseImages = true }
                .buttonStyle(ActionStyle()).accessibilityIdentifier("share.choose")
            Toggle(L.t("share.showTemples"), isOn: $showTemples).accessibilityIdentifier("share.temple")
            Toggle(L.t("share.showMonth"), isOn: $showMonth).accessibilityIdentifier("share.month")
            if routeName != nil {
                Toggle(L.t("share.showRoute"), isOn: $showRoute).accessibilityIdentifier("share.route")
            }
        }.padding(13).paperCard()
    }

    private func share() async {
        guard let ready else { return }
        do {
            let url = try await FileRead.shareFile(ready, name: "goshuin.png")
            ShareRequest.present([url, L.t("share.post")], temporaryFile: url, requested: { requested = true }) { done in
                if done { success() }
            }
        } catch { model.report(error) }
    }
}
