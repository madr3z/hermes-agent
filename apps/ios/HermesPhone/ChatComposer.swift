import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatComposer: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let onPaste: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> ChatComposerInput {
        let view = ChatComposerInput()
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "chatComposer"
        return view
    }
    func updateUIView(_ view: ChatComposerInput, context: Context) {
        context.coordinator.parent = self
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.onPaste = onPaste
        view.accessibilityLabel = placeholder
        if focused, !view.isFirstResponder { view.becomeFirstResponder() }
        else if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatComposerInput, context: Context) -> CGSize? {
        guard let width = proposal.width, let font = uiView.font else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(height, font.lineHeight), font.lineHeight * 6))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatComposer
        init(_ parent: ChatComposer) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
    }
}

/// UIKit supplies providers only after the user chooses Paste or drops an item.
final class ChatComposerInput: UITextView, UITextPasteDelegate {
    var onPaste: (([NSItemProvider]) -> Void)?
    private var attachments: [NSItemProvider] = []
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        backgroundColor = .clear
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        textContainerInset = .zero; textContainer.lineFragmentPadding = 0
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: ([UTType.plainText] + ChatAttachmentImport.pasteTypes).map(\.identifier))
        pasteDelegate = self
    }
    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting, transform item: UITextPasteItem) {
        if ChatAttachmentImport.pasteTypes.contains(where: { item.itemProvider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            attachments.append(item.itemProvider)
            item.setNoResult()
        } else { item.setDefaultResult() }
    }
    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting, combineItemAttributedStrings itemStrings: [NSAttributedString], for textRange: UITextRange) -> NSAttributedString {
        if !attachments.isEmpty {
            let providers = attachments; attachments = []
            onPaste?(providers)
        }
        let text = NSMutableAttributedString(string: "")
        itemStrings.forEach { text.append($0) }
        return text
    }
}
