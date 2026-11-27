import SwiftUI

struct MapAtlas: Decodable {
    struct Outline: Decodable {
        let points: [Place]
        let northwest: Place
        let southeast: Place

        init(from decoder: Decoder) throws {
            let pairs = try decoder.singleValueContainer().decode([[Double]].self)
            let vertices = pairs.compactMap { pair in
                pair.count == 2 ? Place(latitude: pair[1], longitude: pair[0]) : nil
            }
            guard vertices.count >= 4, let minLat = vertices.map(\.latitude).min(),
                  let maxLat = vertices.map(\.latitude).max(), let minLon = vertices.map(\.longitude).min(),
                  let maxLon = vertices.map(\.longitude).max() else { throw ArchiveError.missing }
            points = vertices
            northwest = Place(latitude: maxLat, longitude: minLon)
            southeast = Place(latitude: minLat, longitude: maxLon)
        }
    }

    struct Region: Identifiable, Decodable {
        let id: Int
        let latitude: Double
        let longitude: Double
        var name: String { L.t("region.\(id)") }
        var center: Place { Place(latitude: latitude, longitude: longitude) }
    }

    let outlines: [Outline]
    let regions: [Region]

    static func load() async -> MapAtlas? {
        await Task.detached {
            guard let url = Bundle.main.url(forResource: "japan-outline", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(MapAtlas.self, from: data)
        }.value
    }
}

struct MapViewport: Equatable {
    var center = Place(latitude: 35.8, longitude: 137.2)
    var span = 37.0

    func pixels(in size: CGSize) -> Double {
        Double(size.width) / max(0.004, span)
    }

    func point(_ place: Place, in size: CGSize) -> CGPoint {
        let scale = pixels(in: size)
        return CGPoint(x: Double(size.width) / 2 + (place.longitude - center.longitude) * scale,
                       y: Double(size.height) / 2 - (place.latitude - center.latitude) * scale * 1.21)
    }

    func place(_ point: CGPoint, in size: CGSize) -> Place {
        let scale = pixels(in: size)
        return Place(latitude: center.latitude - (Double(point.y) - Double(size.height) / 2) / (scale * 1.21),
                     longitude: center.longitude + (Double(point.x) - Double(size.width) / 2) / scale)
    }

    mutating func scale(_ value: Double) { span = min(42, max(0.006, span / value)) }

    static func focused(_ places: [Place], fallback: Place, minimum: Double) -> Self {
        guard let left = places.map(\.longitude).min(), let right = places.map(\.longitude).max(),
              let bottom = places.map(\.latitude).min(), let top = places.map(\.latitude).max()
        else { return Self(center: fallback, span: minimum) }
        return Self(center: Place(latitude: (top + bottom) / 2, longitude: (right + left) / 2),
                    span: max(minimum, (right - left) * 1.6, (top - bottom) * 2.1))
    }
}

struct OfflineMap: View {
    let atlas: MapAtlas?
    @Binding var viewport: MapViewport
    var markers: [Temple] = []
    var selected: UUID?
    var drop: Place?
    var counts: [UUID: Int] = [:]
    var onSelect: (Temple) -> Void = { _ in }
    var onDrop: ((Place) -> Void)?
    @GestureState private var drag: CGSize = .zero
    @GestureState private var magnification = 1.0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let transform = display(in: size)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    guard let atlas else { return }
                    for outline in atlas.outlines {
                        let top = transform.point(outline.northwest, in: size)
                        let bottom = transform.point(outline.southeast, in: size)
                        let bounds = CGRect(x: top.x, y: top.y, width: bottom.x - top.x, height: bottom.y - top.y)
                        guard bounds.intersects(CGRect(origin: .zero, size: size)) else { continue }
                        let points = outline.points.map { transform.point($0, in: size) }
                        guard let first = points.first else { continue }
                        let path = Path { path in
                            path.move(to: first)
                            path.addLines(Array(points.dropFirst()))
                            path.closeSubpath()
                        }
                        context.fill(path, with: .color(Color(red: 0.85, green: 0.86, blue: 0.78).opacity(0.75)))
                        context.stroke(path, with: .color(Color(red: 0.69, green: 0.71, blue: 0.62)), lineWidth: 0.7)
                    }
                }
                .background(Color(red: 0.91, green: 0.92, blue: 0.88))
                .accessibilityHidden(true)
                .gesture(SpatialTapGesture().onEnded { event in
                    let place = transform.place(event.location, in: size)
                    if place.isValid { onDrop?(place) }
                })
                ForEach(markers) { temple in
                    if let place = temple.place {
                        let point = transform.point(place, in: size)
                        if CGRect(origin: .zero, size: size).insetBy(dx: 17, dy: 17).contains(point) {
                            Button { onSelect(temple) } label: {
                                Text((counts[temple.id] ?? 1).formatted())
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(selected == temple.id ? Color.white : Paper.red)
                                    .frame(minWidth: 28, minHeight: 28)
                                    .background(selected == temple.id ? Paper.red : Paper.surface, in: Circle())
                                    .overlay { Circle().strokeBorder(Paper.red) }
                                    .frame(width: 44, height: 44)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(temple.name)
                            .accessibilityIdentifier("map.pin")
                            .position(point)
                        }
                    }
                }
                if let drop {
                    Image(systemName: "mappin.circle.fill").font(.largeTitle).foregroundStyle(Paper.red)
                        .position(transform.point(drop, in: size)).allowsHitTesting(false)
                }
                VStack {
                    HStack {
                        Spacer()
                        Button { viewport.scale(1.8) } label: {
                            Image(systemName: "plus").frame(width: 24)
                        }.accessibilityLabel(L.t("map.zoomIn")).accessibilityIdentifier("map.zoomIn")
                        Button { viewport.scale(1 / 1.8) } label: {
                            Image(systemName: "minus").frame(width: 24)
                        }.accessibilityLabel(L.t("map.zoomOut")).accessibilityIdentifier("map.zoomOut")
                    }.buttonStyle(ActionStyle())
                    Spacer(minLength: 0)
                    Text(L.t("map.offline")).font(.caption2.weight(.semibold))
                        .padding(6).background(Paper.surface, in: .rect(cornerRadius: 5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(9)
            }
            .highPriorityGesture(DragGesture(minimumDistance: 12).updating($drag) { value, state, _ in
                state = value.translation
            }.onEnded { value in
                pan(&viewport, by: value.translation, size: size)
            })
            .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in
                state = Double(value.magnification)
            }.onEnded { value in viewport.scale(Double(value.magnification)) })
        }
        .frame(height: 280)
        .clipShape(.rect(cornerRadius: 18)).paperCard()
    }

    private func display(in size: CGSize) -> MapViewport {
        var value = viewport
        value.scale(magnification)
        pan(&value, by: drag, size: size)
        return value
    }

    private func pan(_ value: inout MapViewport, by translation: CGSize, size: CGSize) {
        let pixels = max(1, value.pixels(in: size))
        value.center.longitude = min(155, max(121, value.center.longitude - Double(translation.width) / pixels))
        value.center.latitude = min(47, max(19, value.center.latitude + Double(translation.height) / (pixels * 1.21)))
    }
}

struct MapView: View {
    @EnvironmentObject private var model: AppModel
    var openEntry: (UUID) -> Void
    @State private var atlas: MapAtlas?
    @State private var viewport = MapViewport()
    @State private var regionID: Int?
    @State private var selected: UUID?
    @State private var showRegions = false
    @State private var showUnmarked = false
    @State private var initial = true

    private var visibleTemples: [Temple] {
        let counts = counts
        return model.archive.temples.filter { counts[$0.id] != nil }
    }

    private var counts: [UUID: Int] {
        model.archive.active.compactMap(\.templeID).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
    private var markers: [Temple] {
        visibleTemples.filter {
            guard $0.place != nil else { return false }
            guard let region = atlas?.regions.first(where: { $0.id == regionID }) else { return true }
            return matches($0.region, region)
        }
    }

    private var results: [StampEntry] {
        model.archive.filtered(book: nil, query: "", month: nil).filter { entry in
            let temple = model.archive.temple(entry.templeID)
            if showUnmarked { return temple?.place == nil }
            if let selected { return entry.templeID == selected }
            if let region = atlas?.regions.first(where: { $0.id == regionID }) {
                return temple.map { matches($0.region, region) } ?? false
            }
            return temple != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeading(title: L.t("map"), subtitle: L.t("map.subtitle")) {
                Button(atlas?.regions.first(where: { $0.id == regionID })?.name ?? L.t("map.regions")) {
                    showRegions = true
                }.buttonStyle(ActionStyle()).accessibilityIdentifier("map.regions")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    OfflineMap(atlas: atlas, viewport: $viewport, markers: markers, selected: selected, counts: counts,
                               onSelect: { selected = $0.id; showUnmarked = false })
                    HStack {
                        Button(L.t("map.allPlaces")) { selected = nil; showUnmarked = false }
                            .accessibilityIdentifier("map.all")
                        Button(L.t("map.unmarked")) { selected = nil; showUnmarked = true }
                            .accessibilityIdentifier("map.unmarked")
                    }.buttonStyle(ActionStyle())
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(model.archive.temple(selected)?.name ??
                                 L.t(showUnmarked ? "map.unmarked" : "map.results")).font(.headline)
                            Spacer()
                            Text(L.f("results.count", results.count)).font(.caption).foregroundStyle(Paper.muted)
                        }
                        if showUnmarked {
                            Text(L.t("map.unmarkedHelp")).font(.footnote).foregroundStyle(Paper.muted)
                        }
                        if results.isEmpty {
                            Text(L.t("map.empty")).font(.subheadline).foregroundStyle(Paper.muted)
                        }
                        ForEach(results) { entry in
                            EntryRow(entry: entry, action: { openEntry(entry.id) }, identifier: "map.entry")
                        }
                    }.padding(13).paperCard()
                }.padding(.horizontal, 20).padding(.bottom, 18)
            }
        }
        .task {
            if atlas == nil { atlas = await MapAtlas.load() }
            guard initial else { return }
            initial = false
            if AppModel.testing && AppModel.arguments.contains("-samples"),
               let kyoto = atlas?.regions.first(where: { $0.id == 26 }) {
                focus(kyoto)
                selected = markers.first?.id
            }
        }
        .sheet(isPresented: $showRegions) {
            NavigationStack {
                List {
                    Button(L.t("map.allRegions")) {
                        viewport = MapViewport()
                        regionID = nil
                        selected = nil
                        showUnmarked = false
                        showRegions = false
                    }.accessibilityIdentifier("region.all")
                    ForEach(atlas?.regions ?? []) { region in
                        Button(region.name) { focus(region); showRegions = false }
                            .accessibilityIdentifier("region.\(region.id)")
                    }
                }.panelBackground().navigationTitle(L.t("map.regions"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton() } }
            }
        }
    }

    private func matches(_ name: String, _ region: MapAtlas.Region) -> Bool {
        func trim(_ value: String) -> String {
            let normalized = Search.normalized(value)
            if ["県", "府", "都", "縣"].contains(String(normalized.suffix(1))), normalized.count > 2 {
                return String(normalized.dropLast())
            }
            return normalized
        }
        let candidates = [region.name, L.regionName(region.id, language: "ja"),
                          L.regionName(region.id, language: "en"), L.regionName(region.id, language: "zh-Hans"),
                          L.regionName(region.id, language: "zh-Hant")]
        return !name.isEmpty && candidates.contains { trim($0) == trim(name) }
    }

    private func focus(_ region: MapAtlas.Region) {
        regionID = region.id
        selected = nil
        showUnmarked = false
        viewport = .focused(markers.compactMap(\.place), fallback: region.center, minimum: markers.isEmpty ? 2.1 : 0.10)
    }
}

struct PinEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var place: Place?
    var preferredRegion: String
    @State private var atlas: MapAtlas?
    @State private var viewport = MapViewport()
    @State private var selection: Place?
    @State private var latitude = ""
    @State private var longitude = ""

    private var parsed: Place? {
        let lat = latitude.replacingOccurrences(of: ",", with: ".")
        let lon = longitude.replacingOccurrences(of: ",", with: ".")
        guard let y = Double(lat), let x = Double(lon) else { return nil }
        let result = Place(latitude: y, longitude: x)
        return result.isValid ? result : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L.t("map.pinHelp")).font(.subheadline)
                OfflineMap(atlas: atlas, viewport: $viewport, drop: parsed ?? selection, onDrop: { update($0) })
                TextField(L.t("map.latitude"), text: $latitude).keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("pin.latitude")
                TextField(L.t("map.longitude"), text: $longitude).keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("pin.longitude")
                Button(L.t("map.centerPin")) {
                    if let parsed { viewport = MapViewport(center: parsed, span: 0.45) }
                }.buttonStyle(ActionStyle()).accessibilityIdentifier("pin.focus").disabled(parsed == nil)
            }.padding(20)
        }
        .background(Paper.background)
        .navigationTitle(L.t("map.set"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { CloseButton() }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("save")) { place = parsed; dismiss() }
                    .accessibilityIdentifier("pin.save").disabled(parsed == nil)
            }
        }
        .task {
            atlas = await MapAtlas.load()
            if let place { update(place); viewport = MapViewport(center: place, span: 0.45) }
            else if let region = atlas?.regions.first(where: { $0.name == preferredRegion }) {
                viewport = MapViewport(center: region.center, span: 2.1)
            }
        }
    }

    private func update(_ newValue: Place) {
        selection = newValue
        latitude = String(format: "%.6f", newValue.latitude)
        longitude = String(format: "%.6f", newValue.longitude)
    }
}
