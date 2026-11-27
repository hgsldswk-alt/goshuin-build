import AVFoundation
import PhotosUI
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

enum MainTab: String, CaseIterable {
    case home, map, pilgrimage
    var icon: String {
        switch self {
        case .home: "book"
        case .map: "map"
        case .pilgrimage: "figure.walk"
        }
    }
}

enum AppSheet: Identifiable {
    case settings, pickMonth, detail(UUID), paywall, importRoute, batch(UUID)
    case card(UUID?, Milestone?), restoreBackup(URL, temporary: Bool)

    var id: String {
        switch self {
        case .settings: "settings"
        case .pickMonth: "month"
        case .detail(let id): "detail." + id.uuidString
        case .paywall: "paywall"
        case .importRoute: "importRoute"
        case .batch(let id): "batch." + id.uuidString
        case .card: "card"
        case .restoreBackup: "restoreBackup"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("rating.requested") private var rated = false
    @State private var ratingPending = false
    @State private var tab = MainTab.home
    @State private var sheet: AppSheet?
    @State private var camera = false
    @State private var deferredShot: Data?
    @State private var month: String?
    @State private var book: UUID?
    @State private var usePaperOrder = false
    @State private var query = ""
    @State private var selectedImage: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var tappedPhoto: PhotosPickerItem?
    @State private var trialBanner = true
    @State private var incomingRoute: PublicRoute?
    @State private var chooseBackup = false

    var body: some View {
        root
            .tint(Paper.red)
            .foregroundStyle(Paper.ink)
            .background(Paper.background.ignoresSafeArea())
            .sheet(item: $sheet) { destination in
                NavigationStack {
                    switch destination {
                    case .settings: SettingsView(success: markSuccessfulAction)
                    case .restoreBackup(let source, let temporary):
                        BackupView(success: markSuccessfulAction, initialSource: source, temporarySource: temporary)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
                    case .pickMonth: monthPicker
                    case .detail(let id): EntryDetail(id: id, success: markSuccessfulAction)
                    case .paywall: Paywall()
                    case .importRoute: RouteImport(initial: incomingRoute)
                    case .batch(let id): BatchView(bookID: id, success: markSuccessfulAction)
                    case .card(let entry, let milestone): ShareCard(entry: entry, milestone: milestone, success: markSuccessfulAction)
                    }
                }
                .tint(Paper.red)
            }
            .fullScreenCover(isPresented: $camera, onDismiss: saveCameraPhoto) {
                CameraScreen(finish: { data in
                    deferredShot = data
                    camera = false
                }, unavailable: {
                    camera = false
                    model.error = L.t("error.camera")
                })
            }
            .onChange(of: selectedImage) { _, item in
                guard let item else { return }
                tappedPhoto = item
                selectedImage = nil
                Task { await importPhoto(item) }
            }
            .fileImporter(isPresented: $chooseBackup, allowedContentTypes: [.goshuinBackup]) { result in
                switch result {
                case .success(let url): sheet = .restoreBackup(url, temporary: false)
                case .failure(let error): model.report(error)
                }
            }
            .onOpenURL { url in
                if url.scheme == "goshuin", url.host == "pilgrimage" { tab = .pilgrimage }
                else if url.isFileURL { Task { await openRoute(url) } }
            }
            .onChange(of: model.archive.books.map(\.id)) { _, ids in
                if let book, !ids.contains(book) { self.book = nil }
            }
            .task {
                if AppModel.testing && AppModel.arguments.contains("-paywall") { sheet = .paywall }
            }
            .reviewAfterCoreAction(when: ratingHome) { requestReview() }
            .task(id: ratingReady) {
                guard ratingReady else { return }
                do { try await Task.sleep(for: .milliseconds(700)) }
                catch { return }
                guard ratingReady else { return }
                guard CoreReview.shared.attempt({ requestReview() }) else { return }
                rated = true
                ratingPending = false
            }
    }

    private var ratingReady: Bool {
        ratingPending && !rated && ratingHome && scenePhase == .active && CoreReview.shared.canRequest
    }

    private var ratingHome: Bool {
        sheet == nil && !camera && tab == .home && !chooseBackup && incomingRoute == nil
            && !model.busy && !loadingPhoto && model.error == nil
    }

    private func markSuccessfulAction() {
        if model.archive.canRequestRating { ratingPending = true }
    }

    private var root: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .home: home
                case .map: MapView(openEntry: { sheet = .detail($0) })
                case .pilgrimage:
                    PilgrimageView(openImport: { incomingRoute = nil; openRouteImport() },
                                   openCard: { sheet = .card(nil, $0) }, openPaywall: { sheet = .paywall },
                                   openEntry: { sheet = .detail($0) })
                }
            }
            .frame(maxHeight: .infinity)
            if model.error != nil && sheet == nil { errorBanner }
            tabBar
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Label(L.t(item.rawValue), systemImage: item.icon)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(tab == item ? Paper.red : Paper.muted)
                        .background(tab == item ? Paper.blush : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab." + item.rawValue)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 6)
        .background(alignment: .top) { Divider() }
    }

    private var home: some View {
        let filtered = model.archive.filtered(book: book, query: query, month: month)
        let entries = usePaperOrder ? model.archive.paperOrder(filtered) : filtered
        let clean = month == nil && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let newest = clean && !usePaperOrder ? entries.max(by: { $0.addedAt < $1.addedAt }) : nil
        return VStack(alignment: .leading, spacing: 12) {
            PageHeading(title: L.t(month == nil ? "home" : "date.find"),
                        subtitle: month == nil ? L.t("home.subtitle") : bookLabel) {
                if month == nil {
                    Button(L.t("settings")) { sheet = .settings }
                        .buttonStyle(ActionStyle()).accessibilityIdentifier("home.settings")
                } else {
                    Button(L.t("date.all")) { month = nil }
                        .buttonStyle(ActionStyle()).accessibilityIdentifier("month.clear")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if month == nil {
                        mainActions
                        HStack(spacing: 10) {
                            Button(L.t("backup.read"), action: openBackupRestore)
                                .buttonStyle(ActionStyle()).accessibilityIdentifier("home.restore")
                            Button(L.t("route.importHome")) {
                                incomingRoute = nil
                                openRouteImport()
                            }.buttonStyle(ActionStyle()).accessibilityIdentifier("home.importRoute")
                        }.disabled(model.worker == nil || model.busy)
                    } else { monthControls }
                    search
                    if month == nil && !Launch.isFree && trialBanner && !purchases.entitlement.purchasedPro {
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            let days = purchases.entitlement.remainingDays(at: timeline.date)
                            if days > 0 { trialLine(days) }
                        }
                    }
                    if !model.savedIDs.isEmpty {
                        HStack {
                            Label(L.t("photo.saved"), systemImage: "checkmark.circle")
                            Spacer()
                            Button(L.t("undo")) { Task { await model.undoSave() } }
                                .buttonStyle(ActionStyle()).accessibilityIdentifier("home.undo")
                        }.padding(10).paperCard(tint: Paper.blush)
                    }
                    if let milestone = model.archive.pending.first {
                        MilestoneBanner(milestone: milestone) { sheet = .card(nil, milestone) }
                    }
                    if model.worker == nil || loadingPhoto {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    } else if !entries.isEmpty {
                        if let newest {
                            Text(L.t("home.latest")).font(.headline).accessibilityAddTraits(.isHeader)
                            latest(newest)
                            if entries.count > 1 {
                                Text(L.t("home.pages")).font(.headline).accessibilityAddTraits(.isHeader)
                            }
                        } else if !clean {
                            Text(L.f("results.count", entries.count)).font(.headline)
                        } else {
                            Text(L.t("home.pages")).font(.headline).accessibilityAddTraits(.isHeader)
                        }
                        ForEach(entries.filter { $0.id != newest?.id }) { entry in
                            EntryRow(entry: entry) { sheet = .detail(entry.id) }.paperCard()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(L.t(clean ? "home.empty" : "search.empty")).font(.headline)
                            if clean {
                                Text(L.t("home.emptyHelp")).font(.subheadline).foregroundStyle(Paper.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(19).paperCard()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 17)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var mainActions: some View {
        HStack(spacing: 8) {
            Button { openCamera() } label: {
                Label(L.t("camera"), systemImage: "camera").frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionStyle(prominent: true)).accessibilityIdentifier("home.camera")
            if AppModel.testing && AppModel.arguments.contains("-fixture-photo") {
                Button {
                    Task { await importFixture() }
                } label: {
                    Label(L.t("library"), systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionStyle()).accessibilityIdentifier("home.library")
            } else {
                PhotosPicker(selection: $selectedImage, matching: .images, preferredItemEncoding: .current) {
                    Label(L.t("library"), systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionStyle()).accessibilityIdentifier("home.library")
            }
        }
        .disabled(model.worker == nil || model.busy || loadingPhoto)
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Paper.muted)
                    TextField(L.t("search"), text: $query).accessibilityIdentifier("home.search")
                }
                .padding(.horizontal, 12).frame(minHeight: 44).paperCard()
                if month == nil {
                    Button(L.t("date")) { sheet = .pickMonth }
                        .buttonStyle(ActionStyle()).accessibilityIdentifier("home.date")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Menu {
                        Button(L.t("book.all")) { book = nil }.accessibilityIdentifier("book.all")
                        ForEach(model.archive.books) { item in
                            Button(item.name) { book = item.id }.accessibilityIdentifier("book.option")
                        }
                    } label: {
                        Label(bookLabel, systemImage: "book.closed")
                    }
                    .buttonStyle(ActionStyle()).accessibilityIdentifier("home.books")
                    if month == nil {
                        Button(L.t(usePaperOrder ? "order.byDate" : "order.byPage")) { usePaperOrder.toggle() }
                            .buttonStyle(ActionStyle()).accessibilityIdentifier("home.order")
                        Button(L.t("batch")) {
                            if !purchases.hasPro { sheet = .paywall }
                            else if let id = book ?? model.archive.books.first?.id { sheet = .batch(id) }
                        }
                        .buttonStyle(ActionStyle()).accessibilityIdentifier("home.batch").disabled(model.worker == nil)
                    }
                }
            }
        }
    }

    private var bookLabel: String {
        model.archive.books.first { $0.id == book }?.name ??
            (model.archive.books.count == 1 ? model.archive.books[0].name : L.t("book.all"))
    }

    private var monthControls: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(L.t("month.previous")).accessibilityIdentifier("month.previous")
            Spacer(minLength: 1)
            Button(month == "unknown" ? L.t("date.unknown") : VisitDay.monthLabel(month ?? model.fixtureDate)) {
                sheet = .pickMonth
            }.accessibilityIdentifier("month.change")
            Spacer(minLength: 1)
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel(L.t("month.next")).accessibilityIdentifier("month.next")
        }.buttonStyle(ActionStyle())
    }

    private func shiftMonth(_ difference: Int) {
        let base = month.flatMap { VisitDay.date($0 + "-01") } ?? Date()
        if let date = Calendar(identifier: .gregorian).date(byAdding: .month, value: difference, to: base) {
            month = String(VisitDay.key(date).prefix(7))
        }
    }

    private func trialLine(_ days: Int) -> some View {
        HStack(alignment: .center) {
            Button { sheet = .paywall } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.f("purchase.days", days))
                        .font(.subheadline.bold())
                    Text(L.f("purchase.banner", purchases.price)).font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain).accessibilityIdentifier("home.trial")
            Button { trialBanner = false } label: {
                Text(L.t("hide")).frame(minHeight: 44).contentShape(Rectangle())
            }
                .font(.footnote)
                .accessibilityIdentifier("trial.hide")
        }
        .padding(.horizontal, 11).paperCard(tint: Paper.blush)
    }

    private func latest(_ entry: StampEntry) -> some View {
        Button { sheet = .detail(entry.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                StampPhoto(entry: entry).frame(height: 162)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.archive.name(for: entry)).font(.headline)
                        Text(visitLabel(entry)).font(.footnote).foregroundStyle(Paper.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Paper.muted)
                }.padding(13)
            }
            .contentShape(.rect)
            .clipShape(.rect(cornerRadius: 18)).paperCard()
        }
        .buttonStyle(.plain).accessibilityIdentifier("home.latest")
    }

    private var monthPicker: some View {
        let calendar = Calendar(identifier: .gregorian)
        let recent = (0..<12).compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: Date()).map { String(VisitDay.key($0).prefix(7)) }
        }
        let archived = Set(model.archive.active.compactMap { $0.visitDay.map { String($0.prefix(7)) } })
        let keys = archived.sorted(by: >) + Set(recent).union([model.fixtureDate]).subtracting(archived).sorted(by: >)
        return List {
            Button(L.t("date.all")) { month = nil; sheet = nil }.accessibilityIdentifier("month.all")
            Button(L.t("date.unknown")) { month = "unknown"; sheet = nil }.accessibilityIdentifier("month.unknown")
            ForEach(keys, id: \.self) { key in
                Button(VisitDay.monthLabel(key)) { month = key; sheet = nil }.accessibilityIdentifier("month." + key)
            }
        }
        .panelBackground().navigationTitle(L.t("date.find"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
    }

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.error ?? "").font(.subheadline)
            HStack {
                if model.worker == nil {
                    Button(L.t("retry")) { model.error = nil; Task { await model.start() } }
                        .accessibilityIdentifier("error.retryOpen")
                } else if model.canRetryPhoto {
                    Button(L.t("retry")) { model.error = nil; Task { await model.retryPhoto() } }
                        .accessibilityIdentifier("error.retryPhoto")
                } else if let tappedPhoto {
                    Button(L.t("retry")) { model.error = nil; Task { await importPhoto(tappedPhoto) } }
                        .accessibilityIdentifier("error.retryImport")
                }
                Spacer()
                Button(L.t("close")) { model.error = nil }.accessibilityIdentifier("error.close")
            }.buttonStyle(ActionStyle())
        }.padding(12).paperCard(tint: Paper.blush).padding(.horizontal, 16)
    }

    private func openCamera() {
        model.error = nil
        tappedPhoto = nil
        let denied = AppModel.testing
            ? AppModel.arguments.contains("-camera-denied")
            : [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
        if denied {
            model.error = L.t("error.camera")
        } else {
            camera = true
        }
    }

    private func saveCameraPhoto() {
        guard let data = deferredShot else { return }
        deferredShot = nil
        Task { await model.savePhotos([.fromCamera(data)], book: book) }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard !loadingPhoto else { return }
        loadingPhoto = true
        defer { loadingPhoto = false }
        model.error = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ArchiveError.badPhoto }
            let photo = await Task.detached { IncomingPhoto.fromLibrary(data) }.value
            tappedPhoto = nil
            await model.savePhotos([photo], book: book)
        } catch { model.error = L.t("error.library") }
    }

    private func importFixture() async {
        model.error = nil
        do {
            let photo = try await Task.detached { try IncomingPhoto.fromLibrary(Examples.photo()) }.value
            await model.savePhotos([photo], book: book)
        } catch { model.report(error) }
    }

    private func openBackupRestore() {
        if AppModel.testing && AppModel.arguments.contains("-fixture-backup") {
            Task {
                do {
                    var archive = Archive()
                    let entry = StampEntry(bookID: archive.books[0].id, order: 0, source: .camera)
                    archive.entries = [entry]
                    let bytes = try BackupPackage.encode(.init(archive: archive, photos: [
                        BackupPhoto(id: entry.assetID, data: try Examples.photo())
                    ]))
                    let file = try await FileRead.shareFile(bytes, name: "Fixture.goshuinbackup")
                    sheet = .restoreBackup(file, temporary: true)
                } catch { model.report(error) }
            }
        } else { chooseBackup = true }
    }

    private func openRouteImport() {
        sheet = purchases.hasPro || model.archive.routes.isEmpty ? .importRoute : .paywall
    }

    private func openRoute(_ url: URL) async {
        do {
            incomingRoute = try await Task.detached {
                try PublicRoute.read(FileRead.checked(url, limit: PublicRoute.maxBytes))
            }.value
            tab = .pilgrimage
            openRouteImport()
        } catch { model.report(error) }
    }
}

struct MilestoneBanner: View {
    @EnvironmentObject private var model: AppModel
    var milestone: Milestone
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(milestone.title).font(.headline)
            HStack {
                Button(L.t("milestone.card"), action: open).accessibilityIdentifier("milestone.card")
                Button(L.t("hide")) {
                    Task { await model.edit { $0.pending.removeAll { $0.id == milestone.id } } }
                }.accessibilityIdentifier("milestone.dismiss")
            }
            .buttonStyle(ActionStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12).paperCard(tint: Paper.blush)
    }
}
