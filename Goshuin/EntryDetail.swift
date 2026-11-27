import SwiftUI
import UIKit

struct EntryDetail: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    var id: UUID
    var success: () -> Void
    @State private var showDelete = false
    @State private var showSplit = false
    @State private var paywall = false

    private var entry: StampEntry? { model.archive.entries.first { $0.id == id && $0.deletedAt == nil } }

    var body: some View {
        Group {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ZoomStamp(entry: entry)
                            .frame(height: 360)
                            .clipShape(.rect(cornerRadius: 14))
                            .accessibilityLabel(L.t("entry.photo"))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.archive.name(for: entry)).font(.system(.title2, design: .serif, weight: .bold))
                            Text(VisitDay.label(entry.visitDay)).foregroundStyle(Paper.muted)
                            if let book = model.archive.books.first(where: { $0.id == entry.bookID }) {
                                Text(book.name).font(.footnote).foregroundStyle(Paper.muted)
                            }
                        }
                        NavigationLink {
                            EntryEditor(entryID: id)
                        } label: {
                            Label(L.t("edit"), systemImage: "pencil")
                        }
                        .buttonStyle(ActionStyle()).accessibilityIdentifier("detail.edit")
                        NavigationLink {
                            CropEditor(entryID: id)
                        } label: {
                            Label(L.t("crop"), systemImage: "crop")
                        }
                        .buttonStyle(ActionStyle()).accessibilityIdentifier("detail.crop")
                        NavigationLink {
                            ShareCard(entry: id, milestone: nil, success: success)
                        } label: {
                            Label(L.t("share.card"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(ActionStyle(prominent: true)).accessibilityIdentifier("detail.card")
                        HStack {
                            Button { Task { await reorder(entry, direction: 1) } } label: {
                                Label(L.t("entry.earlier"), systemImage: "arrow.up")
                            }.accessibilityIdentifier("detail.earlier")
                            Button { Task { await reorder(entry, direction: -1) } } label: {
                                Label(L.t("entry.later"), systemImage: "arrow.down")
                            }.accessibilityIdentifier("detail.later")
                        }.buttonStyle(ActionStyle())
                        Button(L.t("entry.split")) {
                            if purchases.hasPro { showSplit = true }
                            else { paywall = true }
                        }.buttonStyle(ActionStyle()).accessibilityIdentifier("detail.split")
                        Button(L.t("entry.delete"), role: .destructive) { showDelete = true }
                            .buttonStyle(ActionStyle()).accessibilityIdentifier("detail.delete")
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView(L.t("error.missing"), systemImage: "photo")
            }
        }
        .background(Paper.background)
        .navigationTitle(L.t("entry"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
        .confirmationDialog(L.t("entry.deleteConfirm"), isPresented: $showDelete, titleVisibility: .visible) {
            Button(L.t("entry.delete"), role: .destructive) {
                Task {
                    if await model.edit({ archive in
                        if let index = archive.entries.firstIndex(where: { $0.id == id }) {
                            archive.entries[index].deletedAt = Date()
                        }
                    }) { dismiss() }
                }
            }
        }
        .confirmationDialog(L.t("entry.split"), isPresented: $showSplit, titleVisibility: .visible) {
            Button(L.t("split.horizontal")) { Task { await split(vertical: false) } }
            Button(L.t("split.vertical")) { Task { await split(vertical: true) } }
        }
        .sheet(isPresented: $paywall) { NavigationStack { Paywall() } }
        .modifier(InlineError())
    }

    private func reorder(_ entry: StampEntry, direction: Int) async {
        await model.edit { archive in
            let siblings = archive.paperOrder(archive.entries.filter { $0.bookID == entry.bookID })
            guard let position = siblings.firstIndex(where: { $0.id == id }),
                  siblings.indices.contains(position - direction) else { return }
            var ordered = siblings.map(\.id)
            let activeNeighbor = direction == 1
                ? siblings[..<position].lastIndex(where: { $0.deletedAt == nil })
                : siblings[(position + 1)...].firstIndex(where: { $0.deletedAt == nil })
            guard let activeNeighbor else { return }
            ordered.swapAt(position, activeNeighbor)
            archive.changeOrder(ordered, in: entry.bookID)
        }
    }

    private func split(vertical: Bool) async {
        guard purchases.hasPro else { paywall = true; return }
        await model.edit { archive in
            guard let index = archive.entries.firstIndex(where: { $0.id == id }) else { return }
            var first = archive.entries[index]
            var second = first
            second.id = UUID()
            let base = first.crop ?? Crop(x: 0, y: 0, width: 1, height: 1)
            let width = vertical ? base.width : base.width / 2
            let height = vertical ? base.height / 2 : base.height
            first.crop = Crop(x: base.x, y: base.y, width: width, height: height)
            second.crop = Crop(x: base.x + (vertical ? 0 : width), y: base.y + (vertical ? height : 0),
                               width: width, height: height)
            guard first.crop?.isValid == true, second.crop?.isValid == true else { throw ArchiveError.badPhoto }
            for location in archive.entries.indices where archive.entries[location].bookID == first.bookID
                && archive.entries[location].order > first.order {
                archive.entries[location].order += 1
            }
            first.revision += 1
            second.order = first.order
            first.order += 1
            archive.entries[index] = first
            archive.entries.append(second)
            archive.checkPageMilestones()
        }
    }
}

struct ZoomStamp: UIViewRepresentable {
    @EnvironmentObject private var model: AppModel
    var entry: StampEntry

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let image = UIImageView()
        var key: String?
        var task: Task<Void, Never>?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let view = UIScrollView()
        view.backgroundColor = ShareArtwork.paper
        view.minimumZoomScale = 1
        view.maximumZoomScale = 4
        view.delegate = context.coordinator
        let image = context.coordinator.image
        image.translatesAutoresizingMaskIntoConstraints = false
        image.contentMode = .scaleAspectFit
        view.addSubview(image)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: view.contentLayoutGuide.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: view.contentLayoutGuide.trailingAnchor),
            image.topAnchor.constraint(equalTo: view.contentLayoutGuide.topAnchor),
            image.bottomAnchor.constraint(equalTo: view.contentLayoutGuide.bottomAnchor),
            image.widthAnchor.constraint(equalTo: view.frameLayoutGuide.widthAnchor),
            image.heightAnchor.constraint(equalTo: view.frameLayoutGuide.heightAnchor)
        ])
        return view
    }

    func updateUIView(_ view: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        let key = "\(entry.id)-\(entry.revision)"
        guard coordinator.key != key, let worker = model.worker else { return }
        coordinator.key = key
        coordinator.task?.cancel()
        view.setZoomScale(1, animated: false)
        coordinator.task = Task {
            let image = try? await worker.image(for: entry, thumbnail: false)
            guard !Task.isCancelled else { return }
            coordinator.image.image = image
        }
    }

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) { coordinator.task?.cancel() }
}

struct EntryEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var entryID: UUID
    @State private var templeID: UUID?
    @State private var bookID: UUID?
    @State private var name = ""
    @State private var kana = ""
    @State private var region = ""
    @State private var address = ""
    @State private var place: Place?
    @State private var day = Date()
    @State private var known = true
    @State private var placeSheet = false

    var body: some View {
        Form {
            Section(L.t("temple")) {
                Picker(L.t("temple.existing"), selection: $templeID) {
                    Text(L.t("temple.manual")).tag(nil as UUID?)
                    ForEach(model.archive.temples) { temple in
                        Text([temple.name, temple.region, temple.address].filter { !$0.isEmpty }.joined(separator: " · "))
                            .tag(Optional(temple.id))
                    }
                }.accessibilityIdentifier("edit.templePicker")
                TextField(L.t("temple.name"), text: $name).accessibilityIdentifier("edit.name")
                TextField(L.t("temple.kana"), text: $kana).accessibilityIdentifier("edit.kana")
                TextField(L.t("temple.region"), text: $region).accessibilityIdentifier("edit.region")
                TextField(L.t("temple.address"), text: $address).accessibilityIdentifier("edit.address")
                Button(place == nil ? L.t("map.set") : L.t("map.change")) { placeSheet = true }
                    .accessibilityIdentifier("edit.pin")
                if place != nil {
                    Button(L.t("map.remove")) { place = nil }.accessibilityIdentifier("edit.removePin")
                }
            }
            Section(L.t("date")) {
                Toggle(L.t("date.known"), isOn: $known).accessibilityIdentifier("edit.knownDate")
                if known {
                    DatePicker(L.t("date.visit"), selection: $day, displayedComponents: .date)
                        .accessibilityIdentifier("edit.visitDate")
                }
            }
            Section(L.t("books")) {
                Picker(L.t("books"), selection: $bookID) {
                    ForEach(model.archive.books) { Text($0.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("edit.book")
            }
        }
        .panelBackground().navigationTitle(L.t("edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("save")) { Task { await save() } }
                    .accessibilityIdentifier("edit.save").disabled(model.busy)
            }
        }
        .sheet(isPresented: $placeSheet) {
            NavigationStack {
                PinEditor(place: $place, preferredRegion: region)
            }
        }
        .onAppear {
            guard bookID == nil, let entry = model.archive.entries.first(where: { $0.id == entryID }) else { return }
            bookID = entry.bookID
            templeID = entry.templeID
            if let temple = model.archive.temple(entry.templeID) { copy(temple) }
            else { name = ""; kana = ""; region = ""; address = ""; place = nil }
            known = entry.visitDay != nil
            if let date = VisitDay.date(entry.visitDay) { day = date }
        }
        .onChange(of: templeID) { _, selected in
            if let temple = model.archive.temple(selected) { copy(temple) }
        }
        .modifier(InlineError())
    }

    private func copy(_ temple: Temple) {
        name = temple.name
        kana = temple.kana
        region = temple.region
        address = temple.address
        place = temple.place
    }

    private func save() async {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let region = String(region.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let address = String(address.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        let kana = String(kana.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        if await model.edit({ archive in
            guard let index = archive.entries.firstIndex(where: { $0.id == entryID }) else { throw ArchiveError.missing }
            let candidate = Temple(name: name.isEmpty ? L.t("temple.unset") : name, kana: kana,
                                   region: region, address: address, place: place)
            var id: UUID?
            if !name.isEmpty || !region.isEmpty || !address.isEmpty || !kana.isEmpty || place != nil {
                id = archive.temples.first {
                    Search.normalized($0.name) == Search.normalized(candidate.name)
                        && Search.normalized($0.region) == Search.normalized(candidate.region)
                        && Search.normalized($0.address) == Search.normalized(candidate.address)
                        && $0.place == candidate.place && $0.kana == candidate.kana
                }?.id
                if id == nil {
                    archive.temples.append(candidate)
                    id = candidate.id
                }
            }
            archive.entries[index].templeID = id
            archive.entries[index].visitDay = known ? VisitDay.key(day) : nil
            if let bookID, archive.entries[index].bookID != bookID {
                archive.entries[index].bookID = bookID
                archive.entries[index].order = 1 + (archive.entries.filter { $0.bookID == bookID }.map(\.order).max() ?? 0)
            }
            archive.entries[index].revision += 1
        }) { dismiss() }
    }
}

struct CropEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var entryID: UUID
    @State private var left = 0.0
    @State private var right = 0.0
    @State private var top = 0.0
    @State private var bottom = 0.0
    @State private var loaded = false

    private var current: StampEntry? { model.archive.entries.first { $0.id == entryID } }
    private var crop: Crop {
        Crop(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom)
    }
    private var previewEntry: StampEntry? {
        guard var item = current else { return nil }
        item.crop = crop
        return item
    }

    var body: some View {
        Form {
            if let entry = previewEntry {
                StampPhoto(entry: entry, fit: true)
                    .id("\(left),\(right),\(top),\(bottom)").frame(height: 230)
                    .listRowInsets(EdgeInsets())
            }
            Slider(value: $left, in: 0...max(0.001, 0.94 - right)) { Text(L.t("crop.left")) }
                .accessibilityIdentifier("crop.left")
            Slider(value: $right, in: 0...max(0.001, 0.94 - left)) { Text(L.t("crop.right")) }
                .accessibilityIdentifier("crop.right")
            Slider(value: $top, in: 0...max(0.001, 0.94 - bottom)) { Text(L.t("crop.top")) }
                .accessibilityIdentifier("crop.top")
            Slider(value: $bottom, in: 0...max(0.001, 0.94 - top)) { Text(L.t("crop.bottom")) }
                .accessibilityIdentifier("crop.bottom")
            Button(L.t("crop.reset")) { left = 0; right = 0; top = 0; bottom = 0 }
                .accessibilityIdentifier("crop.reset")
        }
        .panelBackground().navigationTitle(L.t("crop"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("save")) {
                    Task {
                        if await model.edit({ archive in
                            guard let index = archive.entries.firstIndex(where: { $0.id == entryID })
                            else { throw ArchiveError.missing }
                            archive.entries[index].crop = crop
                            archive.entries[index].revision += 1
                        }) { dismiss() }
                    }
                }.accessibilityIdentifier("crop.save").disabled(!crop.isValid || model.busy)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let selection = current?.crop {
                left = selection.x
                right = max(0, 1 - selection.x - selection.width)
                top = selection.y
                bottom = max(0, 1 - selection.y - selection.height)
            }
        }
        .modifier(InlineError())
    }
}
