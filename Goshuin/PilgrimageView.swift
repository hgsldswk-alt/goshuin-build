import ActivityKit
import SwiftUI
import UIKit

struct PilgrimageView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    var openImport: () -> Void
    var openCard: (Milestone) -> Void
    var openPaywall: () -> Void
    var openEntry: (UUID) -> Void
    @State private var createRoute = false
    @State private var sharedRoute: Route?
    @State private var editingRoute: Route?
    @State private var linking: Station?
    @State private var liveActive = false

    private var current: Route? {
        model.archive.routes.first { $0.id == model.archive.currentRoute } ?? model.archive.routes.first
    }

    var body: some View {
        VStack(spacing: 12) {
            PageHeading(title: L.t("pilgrimage"), subtitle: L.t("pilgrimage.subtitle")) {
                Button(L.t("route.import"), action: openImport)
                    .buttonStyle(ActionStyle()).accessibilityIdentifier("route.import")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if let route = current {
                        routeOptions(route)
                        progress(route)
                        if let milestone = model.archive.pending.first(where: { $0.routeID == route.id }) {
                            MilestoneBanner(milestone: milestone) { openCard(milestone) }
                        }
                        if let undo = model.visitedUndo, undo.route == route.id {
                            Button(L.t("route.undo")) {
                                Task {
                                    let changed = await model.edit { $0.toggle(route: undo.route, station: undo.station) }
                                    if changed { model.visitedUndo = nil }
                                }
                            }.buttonStyle(ActionStyle()).accessibilityIdentifier("route.undo")
                        }
                        stations(route)
                        Button(L.t("route.share")) { sharedRoute = route }
                            .buttonStyle(ActionStyle()).accessibilityIdentifier("route.share")
                        if !route.complete {
                            Button(L.t(liveActive ? "activity.stop" : "activity.start")) {
                                Task {
                                    if liveActive { await model.stopActivity() }
                                    else { await model.startActivity(route) }
                                    syncActivity()
                                }
                            }.buttonStyle(ActionStyle()).accessibilityIdentifier("route.activity")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L.t("route.empty")).font(.headline)
                            Text(L.t("route.emptyHelp")).font(.subheadline).foregroundStyle(Paper.muted)
                            Button(L.t("route.template")) { addTemplate() }
                                .buttonStyle(ActionStyle(prominent: true)).accessibilityIdentifier("route.template")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16).paperCard()
                    }
                    Button(L.t("route.new")) {
                        if allowedNew { createRoute = true }
                        else { openPaywall() }
                    }.buttonStyle(ActionStyle()).accessibilityIdentifier("route.new")
                    if current != nil && (purchases.hasPro || model.archive.routes.isEmpty) {
                        Button(L.t("route.template")) { addTemplate() }
                            .buttonStyle(ActionStyle()).accessibilityIdentifier("route.template")
                    }
                }.padding(.horizontal, 20).padding(.bottom, 18)
            }
        }
        .sheet(isPresented: $createRoute) { NavigationStack { RouteImport(create: true) } }
        .sheet(item: $sharedRoute) { route in
            NavigationStack { RouteShare(route: route) }
        }
        .sheet(item: $editingRoute) { route in
            NavigationStack { RouteEditor(route: route) }
        }
        .sheet(item: $linking) { station in
            if let route = current {
                NavigationStack {
                    List {
                        Button(L.t("temple.unset")) { link(station, route: route, temple: nil) }
                            .accessibilityIdentifier("station.unlink")
                        ForEach(model.archive.temples) { temple in
                            Button([temple.name, temple.region, temple.address].filter { !$0.isEmpty }.joined(separator: " · ")) {
                                link(station, route: route, temple: temple.id)
                            }.accessibilityIdentifier("station.temple")
                        }
                    }.panelBackground().navigationTitle(L.t("route.link"))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
                        .modifier(InlineError())
                }
            }
        }
        .onAppear { syncActivity() }
        .onChange(of: current?.id) { _, _ in syncActivity() }
    }

    private var allowedNew: Bool { model.archive.routes.isEmpty || purchases.hasPro }

    private func addTemplate() {
        if allowedNew { Task { await model.addTemplate(canAdd: purchases.hasPro) } }
        else { openPaywall() }
    }

    private func routeOptions(_ route: Route) -> some View {
        Menu {
            ForEach(model.archive.routes) { item in
                Button(item.name) {
                    Task {
                        if await model.edit({ $0.currentRoute = item.id }) { model.visitedUndo = nil }
                    }
                }.accessibilityIdentifier("route.option")
            }
            Button(L.t("route.edit")) { editingRoute = route }.accessibilityIdentifier("route.edit")
        } label: {
            Label(route.name, systemImage: "chevron.down")
        }.buttonStyle(ActionStyle()).accessibilityIdentifier("route.current")
    }

    private func progress(_ route: Route) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("route.currentLabel")).font(.caption.bold()).foregroundStyle(Paper.red)
            HStack(alignment: .center) {
                Text(route.name).font(.system(.title2, design: .serif, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(L.f("progress.count", route.visited, route.stations.count))
                    .font(.system(.largeTitle, design: .default, weight: .bold).monospacedDigit())
                    .accessibilityIdentifier("route.progress")
            }
            ProgressView(value: Double(route.visited), total: Double(max(1, route.stations.count)))
                .tint(Paper.red)
            Text(route.next.map { L.f("route.next", $0.name) } ?? L.t("route.complete"))
                .font(.subheadline).foregroundStyle(Paper.muted)
        }
        .padding(15).paperCard(tint: Paper.blush)
    }

    private func stations(_ route: Route) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.t("route.unvisited")).font(.headline).padding(.bottom, 8)
            let ordered = route.stations.filter { $0.visitedAt == nil } + route.stations.filter { $0.visitedAt != nil }
            ForEach(ordered) { station in
                stationRow(station, route: route)
                if station.id != ordered.last?.id { Divider() }
            }
        }.padding(13).paperCard()
    }

    private func stationRow(_ station: Station, route: Route) -> some View {
        let entries = model.archive.filtered(book: nil, query: "", month: nil).filter {
            station.templeID != nil && $0.templeID == station.templeID
        }
        return HStack(spacing: 7) {
            Image(systemName: station.visitedAt == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(Paper.red).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name).font(.subheadline.bold())
                if !station.region.isEmpty { Text(station.region).font(.caption).foregroundStyle(Paper.muted) }
            }
            Spacer(minLength: 2)
            Menu {
                Button(L.t("route.link")) { linking = station }.accessibilityIdentifier("station.link")
                ForEach(entries) { entry in
                    Button(VisitDay.label(entry.visitDay)) { openEntry(entry.id) }.accessibilityIdentifier("station.entry")
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel(L.t("route.stationOptions")).accessibilityIdentifier("station.options")
            Button(L.t(station.visitedAt == nil ? "route.mark" : "route.marked")) {
                Task { await model.mark(route: route.id, station: station.id); syncActivity() }
            }
            .buttonStyle(ActionStyle(prominent: station.visitedAt == nil))
            .accessibilityIdentifier(station.visitedAt == nil ? "station.mark" : "station.marked")
            .disabled(model.busy)
        }.padding(.vertical, 3)
    }

    private func link(_ station: Station, route: Route, temple: UUID?) {
        Task {
            if await model.edit({ archive in
                guard let r = archive.routes.firstIndex(where: { $0.id == route.id }),
                      let s = archive.routes[r].stations.firstIndex(where: { $0.id == station.id })
                else { throw ArchiveError.missing }
                archive.routes[r].stations[s].templeID = temple
            }) { linking = nil }
        }
    }

    private func syncActivity() {
        liveActive = Activity<PilgrimageActivity>.activities.contains { $0.attributes.routeID == current?.id }
    }
}

struct RouteEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let route: Route
    @State private var name = ""
    @State private var stations: [Station] = []

    var body: some View {
        Form {
            TextField(L.t("route.name"), text: $name).accessibilityIdentifier("route.editName")
            Section(L.t("route.stations")) {
                ForEach($stations) { $station in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(L.t("temple.name"), text: $station.name).accessibilityIdentifier("route.editStation")
                        TextField(L.t("temple.region"), text: $station.region).accessibilityIdentifier("route.editRegion")
                        if station.visitedAt != nil {
                            Label(L.t("route.marked"), systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(Paper.red)
                        }
                    }
                }
                .onDelete { stations.remove(atOffsets: $0) }
                .onMove { stations.move(fromOffsets: $0, toOffset: $1) }
                Button(L.t("route.addStop")) { stations.append(Station(name: "")) }
                    .accessibilityIdentifier("route.addStop").disabled(stations.count >= 120)
            }
        }
        .panelBackground().navigationTitle(L.t("route.edit"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { CloseButton() }
            ToolbarItem(placement: .primaryAction) {
                EditButton().accessibilityIdentifier("route.reorder")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("save")) { Task { await save() } }
                    .accessibilityIdentifier("route.saveEdit").disabled(model.busy || stations.isEmpty)
            }
        }
        .onAppear {
            name = route.name
            stations = route.stations
        }
        .modifier(InlineError())
    }

    private func save() async {
        if await model.edit({ archive in
            guard let index = archive.routes.firstIndex(where: { $0.id == route.id }),
                  archive.routes[index] == route else { throw ArchiveError.stale }
            let draft = Route(id: route.id, name: name, stations: stations)
            let checked = try PublicRoute(draft).validated()
            guard checked.stations.count == stations.count else { throw ArchiveError.duplicateStop }
            guard !archive.routes.contains(where: { $0.id != route.id && checked.matches($0) })
            else { throw ArchiveError.duplicate }
            var result = draft
            result.name = checked.name
            for index in result.stations.indices {
                result.stations[index].name = checked.stations[index].name
                result.stations[index].region = checked.stations[index].region
            }
            archive.routes[index] = result
        }) { dismiss() }
    }
}

struct RouteImport: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    var initial: PublicRoute?
    var create = false
    @State private var draft: PublicRoute?
    @State private var name = ""
    @State private var input = ""
    @State private var chooseFile = false
    @State private var paywall = false

    var body: some View {
        Form {
            if let draft {
                Section(L.t("route.preview")) {
                    Text(draft.name).font(.headline)
                    ForEach(Array(draft.stations.enumerated()), id: \.offset) { _, station in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(station.name)
                            if !station.region.isEmpty { Text(station.region).font(.caption).foregroundStyle(Paper.muted) }
                        }
                    }
                }
                Button(L.t("save")) { Task { await save(draft) } }
                    .accessibilityIdentifier("route.save").disabled(model.busy)
                Button(L.t("edit")) { self.draft = nil }.accessibilityIdentifier("route.editDraft")
            } else {
                Section(create ? L.t("route.new") : L.t("route.code")) {
                    if create {
                        TextField(L.t("route.name"), text: $name).accessibilityIdentifier("route.name")
                        Text(L.t("route.lines")).font(.footnote)
                    }
                    TextEditor(text: $input).frame(minHeight: 120)
                        .accessibilityLabel(L.t(create ? "route.stations" : "route.code"))
                        .accessibilityIdentifier("route.input")
                    Button(L.t("route.preview")) { preview() }.accessibilityIdentifier("route.preview")
                    if !create {
                        if AppModel.testing, let fixture = ProcessInfo.processInfo.environment["GOSHUIN_ROUTE_INPUT"] {
                            Button(L.t("route.paste")) { paste(fixture) }.accessibilityIdentifier("route.paste")
                        } else {
                            PasteButton(payloadType: String.self) { values in
                                if let value = values.first { paste(value) }
                            }.accessibilityLabel(Text(L.t("route.paste"))).accessibilityIdentifier("route.paste")
                        }
                        Button(L.t("route.file")) { chooseFile = true }.accessibilityIdentifier("route.file")
                    }
                }
            }
        }
        .panelBackground().navigationTitle(L.t(create ? "route.new" : "route.import"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
        .onAppear {
            if draft == nil { draft = initial }
            if AppModel.testing, input.isEmpty, let fixture = ProcessInfo.processInfo.environment["GOSHUIN_ROUTE_INPUT"] {
                input = fixture
            }
        }
        .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.goshuinRoute, .json]) { result in
            if case .success(let url) = result {
                Task {
                    do {
                        draft = try await Task.detached { try PublicRoute.read(FileRead.checked(url, limit: PublicRoute.maxBytes)) }.value
                    } catch { model.report(error) }
                }
            }
        }
        .sheet(isPresented: $paywall) { NavigationStack { Paywall() } }
        .modifier(InlineError())
    }

    private func paste(_ text: String) {
        input = text
        preview()
    }

    private func preview() {
        do {
            if create {
                let stations = input.split(whereSeparator: \.isNewline).map { line in
                    let pieces = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    return PublicRoute.Stop(name: String(pieces[0]), region: pieces.count > 1 ? String(pieces[1]) : "")
                }
                draft = try PublicRoute(name: name, stations: stations).validated()
            } else {
                draft = try PublicRoute.read(input)
            }
        } catch { model.report(error) }
    }

    private func save(_ draft: PublicRoute) async {
        guard purchases.hasPro || model.archive.routes.isEmpty else { paywall = true; return }
        if await model.addRoute(draft, canAdd: purchases.hasPro) { dismiss() }
    }
}

struct RouteShare: View {
    @EnvironmentObject private var model: AppModel
    var route: Route
    @State private var requested = false

    var body: some View {
        Form {
            Section(L.t("route.preview")) {
                Text(route.name).font(.headline)
                ForEach(route.stations) { station in
                    Text([station.name, station.region].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                Text(L.t("route.sharePrivacy")).font(.footnote)
            }
            Button(L.t("route.copy")) {
                do {
                    let code = try PublicRoute(route).code()
                    if !AppModel.testing { UIPasteboard.general.string = code }
                    requested = true
                } catch { model.report(error) }
            }.accessibilityIdentifier("route.copy")
            Button(L.t("route.shareFile")) {
                do {
                    let data = try PublicRoute(route).data()
                    Task {
                        do {
                            let url = try await FileRead.shareFile(data, name: "route.goshuinroute")
                            ShareRequest.present([url], temporaryFile: url, requested: { requested = true }) { _ in }
                        } catch { model.report(error) }
                    }
                } catch { model.report(error) }
            }.accessibilityIdentifier("route.shareFile")
            if requested { Text(L.t("share.requested")).accessibilityIdentifier("share.requested") }
        }.panelBackground().navigationTitle(L.t("route.share"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
            .modifier(InlineError())
    }
}
