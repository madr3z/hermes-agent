import SwiftUI

extension View {
    func dispatchPage() -> some View {
        scrollContentBackground(.hidden)
            .background(DispatchStyle.paper)
            .foregroundStyle(DispatchStyle.ink)
            .tint(DispatchStyle.forest)
            .toolbarBackground(DispatchStyle.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    func dispatchTitle(_ title: String) -> some View {
        dispatchPage()
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).font(DispatchStyle.serif(24, relativeTo: .headline))
                        .foregroundStyle(DispatchStyle.ink).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}

struct DispatchList<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        List {
            Group { content }
                .listRowBackground(DispatchStyle.wash)
                .listRowSeparatorTint(DispatchStyle.rule)
        }.listStyle(.insetGrouped)
    }
}

struct DispatchForm<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        Form {
            Group { content }
                .listRowBackground(DispatchStyle.wash)
                .listRowSeparatorTint(DispatchStyle.rule)
        }
    }
}

/// Native sections keep their grouping, controls, and accessibility behavior.
struct DispatchSection<Content: View, Header: View, Footer: View>: View {
    let content: Content
    let header: Header
    let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header,
         @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }

    init(@ViewBuilder content: () -> Content) where Header == EmptyView, Footer == EmptyView {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) where Footer == EmptyView {
        self.init(content: content, header: header, footer: { EmptyView() })
    }

    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) where Header == EmptyView {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) where Header == Text, Footer == EmptyView {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }

    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) where Header == Text, Footer == EmptyView {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }

    var body: some View {
        Section { content } header: {
            header.font(DispatchStyle.serif(22, relativeTo: .title3))
                .foregroundStyle(DispatchStyle.ink).textCase(nil)
        } footer: {
            footer.foregroundStyle(DispatchStyle.secondary)
        }
        .listRowBackground(DispatchStyle.wash)
        .listRowSeparatorTint(DispatchStyle.rule)
    }
}

struct DispatchEmptyState: View {
    let title: String
    let systemImage: String
    var description: Text? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: 16) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: systemImage).font(.system(size: 30, weight: .light))
                    .foregroundStyle(DispatchStyle.forest).frame(width: 72, height: 72)
                    .background(DispatchStyle.wash, in: Circle()).accessibilityHidden(true)
            }
            Text(title).font(DispatchStyle.serif(30)).foregroundStyle(DispatchStyle.ink)
                .accessibilityAddTraits(.isHeader)
            if let description { description.font(.body).foregroundStyle(DispatchStyle.secondary) }
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.vertical, 36)
    }

    static func search(text: String) -> Self {
        Self("No matching results", systemImage: "magnifyingglass",
             description: Text("No results for “\(text)”. Try another name or search term."))
    }

    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title; self.systemImage = systemImage; self.description = description
    }
}

struct DispatchPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.medium))
            .foregroundStyle(configuration.role == .destructive ? DispatchStyle.paper : .white)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(configuration.role == .destructive ? DispatchStyle.rust : DispatchStyle.button,
                        in: RoundedRectangle(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
    }
}

struct DispatchSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium))
            .foregroundStyle(configuration.role == .destructive ? DispatchStyle.rust : DispatchStyle.forest)
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
            .background(DispatchStyle.wash, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(DispatchStyle.rule) }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
    }
}
