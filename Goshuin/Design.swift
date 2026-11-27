import SwiftUI
import UIKit

enum Paper {
    static let background = Color(red: 246/255, green: 242/255, blue: 233/255)
    static let surface = Color(red: 255/255, green: 253/255, blue: 247/255)
    static let ink = Color(red: 39/255, green: 37/255, blue: 31/255)
    static let muted = Color(red: 102/255, green: 95/255, blue: 82/255)
    static let red = Color(red: 163/255, green: 54/255, blue: 45/255)
    static let line = Color(red: 224/255, green: 216/255, blue: 202/255)
    static let blush = Color(red: 244/255, green: 229/255, blue: 218/255)
}

extension View {
    func paperCard(tint: Color = Paper.surface) -> some View {
        background(tint, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Paper.line).allowsHitTesting(false) }
    }

    func panelBackground() -> some View {
        scrollContentBackground(.hidden).background(Paper.background).tint(Paper.red)
    }
}

struct ActionStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(prominent ? .white : Paper.ink)
            .background(prominent ? Paper.red : Paper.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11).strokeBorder(prominent ? Color.clear : Paper.line)
            }
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}

struct PageHeading<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(.largeTitle, design: .serif, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.subheadline).foregroundStyle(Paper.muted)
            }
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 9)
    }
}

struct StampPhoto: View {
    @EnvironmentObject private var model: AppModel
    var entry: StampEntry
    var thumbnail = true
    var uncropped = false
    var fit = false
    @State private var photo: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Paper.blush
                if let photo {
                    Image(uiImage: photo).resizable()
                        .aspectRatio(contentMode: fit ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(Paper.muted)
                } else {
                    ProgressView()
                }
            }
            .clipped()
        }
        .task(id: "\(entry.id)-\(entry.revision)-\(uncropped)-\(thumbnail)") {
            failed = false
            if let worker = model.worker {
                do {
                    let image = try await worker.image(for: entry, thumbnail: thumbnail, uncropped: uncropped)
                    if !Task.isCancelled { photo = image }
                } catch { if !Task.isCancelled { failed = true } }
            }
        }
        .accessibilityHidden(true)
    }
}

struct EntryRow: View {
    @EnvironmentObject private var model: AppModel
    var entry: StampEntry
    var action: () -> Void
    var identifier: String = "entry.row"

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                StampPhoto(entry: entry).frame(width: 64, height: 56).clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.archive.name(for: entry)).fontWeight(.semibold)
                    Text(visitLabel(entry)).font(.footnote).foregroundStyle(Paper.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Paper.muted)
            }
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

func visitLabel(_ entry: StampEntry) -> String {
    let date = VisitDay.label(entry.visitDay)
    return entry.source == .sample ? L.f("example.visitDay", date) : date
}

struct CloseButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button(L.t("close")) { dismiss() }.accessibilityIdentifier("sheet.close")
    }
}
