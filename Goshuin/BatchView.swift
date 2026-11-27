import PhotosUI
import SwiftUI

struct BatchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    var bookID: UUID
    var success: () -> Void
    @State private var photos: [PhotosPickerItem] = []
    @State private var retryItems: [PhotosPickerItem] = []
    @State private var selected: Set<UUID> = []
    @State private var queue: [UUID] = []
    @State private var loading = false
    @State private var showEdit = false
    @State private var showPaywall = false
    @State private var notice: String?

    private var entries: [StampEntry] {
        model.archive.paperOrder(model.archive.active.filter { $0.bookID == bookID })
    }

    var body: some View {
        List {
            Section(L.t("batch.import")) {
                PhotosPicker(selection: $photos, maxSelectionCount: 20, selectionBehavior: .ordered,
                             matching: .images, preferredItemEncoding: .current) {
                    Label(L.t("batch.photos"), systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("batch.photos").disabled(model.busy || loading)
                if loading { ProgressView() }
                if model.canRetryPhoto || !retryItems.isEmpty {
                    Button(L.t("retry")) {
                        model.error = nil
                        Task {
                            if !retryItems.isEmpty { await importItems(retryItems) }
                            else { await model.retryPhoto() }
                        }
                    }.accessibilityIdentifier("batch.retry").disabled(model.busy || loading)
                }
                if let notice { Text(notice).font(.footnote) }
            }
            Section(L.t("batch.actions")) {
                Button(L.t("batch.edit")) {
                    guard purchases.hasPro else { showPaywall = true; return }
                    showEdit = true
                }.accessibilityIdentifier("batch.edit").disabled(selected.isEmpty)
                Button(L.t("batch.export")) { Task { await export() } }
                    .accessibilityIdentifier("batch.export").disabled(selected.isEmpty || loading)
                Button(L.t("batch.reorder")) { Task { await reorder() } }
                    .accessibilityIdentifier("batch.reorder").disabled(queue.count < 2 || model.busy)
                Text(L.t("batch.reorderHelp")).font(.footnote).foregroundStyle(Paper.muted)
            }
            Section(L.f("share.selection", selected.count)) {
                ForEach(entries) { entry in
                    Button { select(entry.id) } label: {
                        HStack(spacing: 10) {
                            StampPhoto(entry: entry).frame(width: 50, height: 44).clipShape(.rect(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(model.archive.name(for: entry))
                                Text(VisitDay.label(entry.visitDay)).font(.caption)
                            }
                            Spacer()
                            if let position = queue.firstIndex(of: entry.id) {
                                Text("\(position + 1)").foregroundStyle(Paper.red)
                            }
                        }
                    }.accessibilityIdentifier("batch.entry")
                }
            }
        }
        .panelBackground().navigationTitle(L.t("batch"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { await importItems(items) }
        }
        .sheet(isPresented: $showEdit) {
            NavigationStack { BatchEditor(ids: selected) }
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack { Paywall() }
        }
        .modifier(InlineError())
    }

    private func select(_ id: UUID) {
        if selected.remove(id) != nil {
            queue.removeAll { $0 == id }
        } else {
            selected.insert(id)
            queue.append(id)
        }
    }

    private func importItems(_ items: [PhotosPickerItem]) async {
        guard purchases.hasPro else { showPaywall = true; return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        retryItems = []
        do {
            var incoming: [IncomingPhoto] = []
            var size = 0
            for item in items {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self) else { throw ArchiveError.badPhoto }
                size += data.count
                guard size <= 120_000_000 else { throw ArchiveError.tooLarge }
                incoming.append(await Task.detached { IncomingPhoto.fromLibrary(data) }.value)
            }
            await model.savePhotos(incoming, book: bookID)
        } catch {
            if !Task.isCancelled {
                retryItems = items
                model.report(error)
            }
        }
    }

    private func reorder() async {
        guard purchases.hasPro else { showPaywall = true; return }
        if await model.edit({ archive in
            let allPages = archive.paperOrder(archive.entries.filter { $0.bookID == bookID })
            let activeIDs = Set(allPages.filter { $0.deletedAt == nil }.map(\.id))
            var arranged = queue.filter { activeIDs.contains($0) }.makeIterator()
            let next = allPages.map { page in
                page.deletedAt == nil && selected.contains(page.id) ? arranged.next() ?? page.id : page.id
            }
            archive.changeOrder(next, in: bookID)
        }) { notice = L.t("batch.reordered") }
    }

    private func export() async {
        guard purchases.hasPro else { showPaywall = true; return }
        guard let worker = model.worker, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            var subset = Archive()
            subset.books = model.archive.books.filter { $0.id == bookID }
            subset.entries = entries.filter { selected.contains($0.id) }
            let included = Set(subset.entries.compactMap(\.templeID))
            subset.temples = model.archive.temples.filter { included.contains($0.id) }
            let url = try await worker.export(subset, filename: "pages.goshuinbackup")
            ShareRequest.present([url], temporaryFile: url, requested: { notice = L.t("share.requested") }) { done in
                if done { success() }
            }
        } catch { model.report(error) }
    }
}

struct BatchEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    var ids: Set<UUID>
    @State private var dateRule = "keep"
    @State private var day = Date()
    @State private var templeRule = "keep"
    @State private var temple: UUID?
    @State private var book: UUID?
    @State private var paywall = false

    var body: some View {
        Form {
            Section(L.t("date")) {
                Picker(L.t("date"), selection: $dateRule) {
                    Text(L.t("batch.keep")).tag("keep")
                    Text(L.t("date.unknown")).tag("clear")
                    Text(L.t("batch.set")).tag("set")
                }.accessibilityIdentifier("batch.dateRule")
                if dateRule == "set" {
                    DatePicker(L.t("date.visit"), selection: $day, displayedComponents: .date)
                        .accessibilityIdentifier("batch.date")
                }
            }
            Section(L.t("temple")) {
                Picker(L.t("temple"), selection: $templeRule) {
                    Text(L.t("batch.keep")).tag("keep")
                    Text(L.t("temple.unset")).tag("clear")
                    Text(L.t("batch.set")).tag("set")
                }.accessibilityIdentifier("batch.templeRule")
                if templeRule == "set" {
                    Picker(L.t("temple"), selection: $temple) {
                        Text(L.t("temple.unset")).tag(nil as UUID?)
                        ForEach(model.archive.temples) { Text($0.name + ($0.region.isEmpty ? "" : " · " + $0.region)).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("batch.temple")
                }
            }
            Picker(L.t("books"), selection: $book) {
                Text(L.t("batch.keep")).tag(nil as UUID?)
                ForEach(model.archive.books) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("batch.book")
        }
        .panelBackground().navigationTitle(L.t("batch.edit"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { CloseButton() }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("save")) { Task { await save() } }.accessibilityIdentifier("batch.save")
                    .disabled(model.busy || (templeRule == "set" && temple == nil))
            }
        }
        .sheet(isPresented: $paywall) { NavigationStack { Paywall() } }
        .modifier(InlineError())
    }

    private func save() async {
        guard purchases.hasPro else { paywall = true; return }
        if await model.edit({ archive in
            var order = book.map { id in archive.entries.filter { $0.bookID == id }.map(\.order).max() ?? 0 } ?? 0
            for index in archive.entries.indices where ids.contains(archive.entries[index].id) {
                if dateRule != "keep" { archive.entries[index].visitDay = dateRule == "clear" ? nil : VisitDay.key(day) }
                if templeRule != "keep" { archive.entries[index].templeID = templeRule == "clear" ? nil : temple }
                if let book, archive.entries[index].bookID != book {
                    order += 1
                    archive.entries[index].bookID = book
                    archive.entries[index].order = order
                }
                archive.entries[index].revision += 1
            }
        }) { dismiss() }
    }
}
