import SwiftUI

struct Paywall: View {
    @EnvironmentObject private var purchases: Purchases
    @State private var confirmTrial = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Image(systemName: "books.vertical.fill").font(.largeTitle).foregroundStyle(Paper.red)
                Text(L.t("purchase.title")).font(.system(.largeTitle, design: .serif, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(L.t("purchase.features")).font(.body)
                Text(L.t("purchase.free")).font(.subheadline).foregroundStyle(Paper.muted)
                if purchases.entitlement.purchasedPro {
                    Text(L.t("purchase.unlocked")).font(.headline)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L.f("purchase.price", purchases.price)).font(.title3.weight(.semibold))
                        Text(L.t("purchase.terms")).font(.subheadline)
                        let days = purchases.entitlement.remainingDays(at: Date())
                        Text(days > 0 ? L.f("purchase.days", days) : L.t("purchase.expired"))
                            .font(.subheadline.weight(.semibold))
                        Button(L.t("purchase.buy")) {
                            if let product = purchases.product { Task { await purchases.purchase(product) } }
                        }.buttonStyle(ActionStyle(prominent: true))
                            .accessibilityIdentifier("paywall.buy").disabled(purchases.product == nil || purchases.purchasing)
                        if purchases.entitlement.trialClaimedAt == nil, days > 0 {
                            Button(L.t("purchase.claim")) { confirmTrial = true }
                                .buttonStyle(ActionStyle()).accessibilityIdentifier("paywall.trial")
                                .disabled(purchases.products[Purchases.trialID] == nil || purchases.purchasing)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16).paperCard(tint: Paper.blush)
                    if purchases.product == nil {
                        Button(L.t("purchase.reload")) { Task { await purchases.loadProducts() } }
                            .buttonStyle(ActionStyle()).accessibilityIdentifier("paywall.reload")
                            .disabled(purchases.loading)
                    }
                }
                Button(L.t("purchase.restore")) { Task { await purchases.restore() } }
                    .buttonStyle(ActionStyle()).accessibilityIdentifier("paywall.restore")
                    .disabled(purchases.purchasing)
                if let message = purchases.message { Text(message).font(.footnote) }
            }.padding(23)
        }
        .background(Paper.background)
        .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
        .alert(L.t("purchase.claim"), isPresented: $confirmTrial) {
            Button(L.t("purchase.claimAccept")) {
                if let product = purchases.products[Purchases.trialID] { Task { await purchases.purchase(product) } }
            }
            Button(L.t("cancel"), role: .cancel) {}
        } message: {
            Text(L.f("purchase.claimDetail", purchases.price))
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    var success: () -> Void
    @State private var paywall = false

    var body: some View {
        List {
            NavigationLink(L.t("books")) { BooksView() }.accessibilityIdentifier("settings.books")
            NavigationLink(L.t("backup")) { BackupView(success: success) }.accessibilityIdentifier("settings.backup")
            NavigationLink(L.t("deleted")) { RecentlyDeleted() }.accessibilityIdentifier("settings.trash")
            if !Launch.isFree {
                Button {
                    paywall = true
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L.t("purchase.title")).font(.headline)
                        if purchases.entitlement.purchasedPro {
                            Text(L.t("purchase.unlocked"))
                        } else {
                            let days = purchases.entitlement.remainingDays(at: Date())
                            Text(days > 0 ? L.f("purchase.days", days) : L.t("purchase.expired"))
                            Text(L.t("purchase.features")).font(.footnote)
                            Text(L.f("purchase.price", purchases.price))
                        }
                    }.foregroundStyle(Paper.ink)
                }.accessibilityIdentifier("settings.pro")
            }
            Section(L.t("privacy")) {
                Text(L.t("privacy.body")).font(.subheadline)
                Text(L.t("map.attribution")).font(.footnote).foregroundStyle(Paper.muted)
            }
        }
        .panelBackground().navigationTitle(L.t("settings"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
        .sheet(isPresented: $paywall) { NavigationStack { Paywall() } }
        .modifier(InlineError())
    }
}

struct BooksView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @State private var editing: Book?
    @State private var name = ""
    @State private var showName = false
    @State private var showPaywall = false

    var body: some View {
        List {
            ForEach(model.archive.books) { book in
                Button {
                    editing = book
                    name = book.name
                    showName = true
                } label: {
                    HStack {
                        Text(book.name)
                        Spacer()
                        Text(L.f("results.count", model.archive.active.filter { $0.bookID == book.id }.count))
                            .foregroundStyle(Paper.muted)
                    }
                }.accessibilityIdentifier("books.rename")
            }
            Button(L.t("book.new")) {
                guard purchases.hasPro else { showPaywall = true; return }
                editing = nil
                name = ""
                showName = true
            }.accessibilityIdentifier("books.new")
        }
        .panelBackground().navigationTitle(L.t("books"))
        .alert(L.t(editing == nil ? "book.new" : "book.rename"), isPresented: $showName) {
            TextField(L.t("book.name"), text: $name)
            Button(L.t("save")) { Task { await save() } }
            Button(L.t("cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showPaywall) { NavigationStack { Paywall() } }
        .modifier(InlineError())
    }

    private func save() async {
        let cleaned = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !cleaned.isEmpty else { return }
        guard editing != nil || purchases.hasPro else { showPaywall = true; return }
        await model.edit { archive in
            if let editing, let index = archive.books.firstIndex(where: { $0.id == editing.id }) {
                archive.books[index].name = cleaned
            } else {
                archive.books.append(Book(name: cleaned))
            }
        }
    }
}

struct RecentlyDeleted: View {
    @EnvironmentObject private var model: AppModel
    private var entries: [StampEntry] {
        model.archive.entries.filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    var body: some View {
        List {
            if entries.isEmpty { Text(L.t("deleted.empty")) }
            ForEach(entries) { entry in
                HStack {
                    StampPhoto(entry: entry).frame(width: 54, height: 52).clipShape(.rect(cornerRadius: 7))
                    VStack(alignment: .leading) {
                        Text(model.archive.name(for: entry))
                        Text(VisitDay.label(entry.visitDay)).font(.footnote)
                    }
                    Spacer()
                    Button(L.t("restore")) {
                        Task {
                            await model.edit { archive in
                                if let index = archive.entries.firstIndex(where: { $0.id == entry.id }) {
                                    archive.entries[index].deletedAt = nil
                                }
                            }
                        }
                    }.buttonStyle(ActionStyle()).accessibilityIdentifier("trash.restore")
                }
            }
        }.panelBackground().navigationTitle(L.t("deleted")).modifier(InlineError())
    }
}

struct BackupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var success: () -> Void
    var initialSource: URL? = nil
    var temporarySource = false
    @State private var choose = false
    @State private var export = false
    @State private var document: ExportDocument?
    @State private var restoreSource: URL?
    @State private var plan: RestorePlan?
    @State private var running = false
    @State private var notice: String?

    var body: some View {
        Form {
            Section(L.t("backup")) {
                if initialSource == nil {
                    Text(L.t("backup.help")).font(.subheadline)
                    Button(L.t("backup.export")) { Task { await prepareExport() } }
                        .accessibilityIdentifier("backup.export").disabled(running || model.worker == nil)
                    Button(L.t("backup.read")) { choose = true }
                        .accessibilityIdentifier("backup.read").disabled(running || model.worker == nil)
                }
                if running { ProgressView() }
                if let notice { Text(notice).font(.footnote).accessibilityIdentifier("backup.notice") }
            }
            if let plan {
                Section(L.t("backup.preview")) {
                    Text(L.f("backup.counts", plan.newEntries, plan.conflicts))
                        .accessibilityIdentifier("backup.preview")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(plan.byteCount), countStyle: .file))
                    Text(L.t("backup.merge")).font(.footnote)
                    Button(L.t("backup.confirm")) {
                        Task {
                            if await model.restore(plan) {
                                self.plan = nil
                                FileRead.cleanTemporary(restoreSource)
                                restoreSource = nil
                                notice = L.t("backup.restored")
                            }
                        }
                    }.accessibilityIdentifier("backup.confirm").disabled(model.busy)
                    Button(L.t("cancel")) {
                        self.plan = nil
                        FileRead.cleanTemporary(restoreSource)
                        restoreSource = nil
                        if initialSource != nil { dismiss() }
                    }.accessibilityIdentifier("backup.cancel").disabled(model.busy)
                }
            }
        }
        .panelBackground().navigationTitle(L.t("backup"))
        .interactiveDismissDisabled(model.busy)
        .task {
            guard let initialSource else { return }
            defer { if temporarySource { FileRead.cleanTemporary(initialSource) } }
            await preflight(initialSource)
        }
        .fileImporter(isPresented: $choose, allowedContentTypes: [.goshuinBackup]) { result in
            switch result {
            case .success(let url): Task { await preflight(url) }
            case .failure(let error): model.report(error)
            }
        }
        .fileExporter(isPresented: $export, document: document, contentType: .goshuinBackup, defaultFilename: "Goshuin") { result in
            FileRead.cleanTemporary(document?.file)
            document = nil
            if case .success = result {
                notice = L.t("backup.saved")
                success()
            } else if case .failure(let error) = result {
                model.report(error)
            }
        }
        .onDisappear {
            if !export { FileRead.cleanTemporary(document?.file); document = nil }
            if !choose { FileRead.cleanTemporary(restoreSource); restoreSource = nil; plan = nil }
        }
        .modifier(InlineError())
    }

    private func prepareExport() async {
        guard let worker = model.worker, !running else { return }
        running = true
        defer { running = false }
        do {
            FileRead.cleanTemporary(document?.file)
            let file = try await worker.export(model.archive)
            if AppModel.testing { FileRead.cleanTemporary(file); notice = L.t("backup.ready") }
            else {
                document = ExportDocument(file: file)
                export = true
            }
        } catch { model.report(error) }
    }

    private func preflight(_ url: URL) async {
        guard let worker = model.worker, !running else { return }
        running = true
        defer { running = false }
        var copy: URL?
        do {
            FileRead.cleanTemporary(restoreSource)
            restoreSource = nil
            plan = nil
            let safeFile = try await Task.detached { try FileRead.copyBackup(url) }.value
            copy = safeFile
            let bytes = try await Task.detached { try Data(contentsOf: safeFile, options: .alwaysMapped) }.value
            let preview = try await worker.previewRestore(bytes, current: model.archive)
            try Task.checkCancellation()
            plan = preview
            restoreSource = safeFile
        } catch {
            FileRead.cleanTemporary(copy)
            if !Task.isCancelled { model.report(error) }
        }
    }
}
