import SwiftUI
import UIKit

/// Native ABC editor with lightweight syntax coloring and keyboard actions.
struct SourceEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var jumpToLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textColor = UIColor(StudioTheme.ink)
        view.backgroundColor = UIColor(StudioTheme.surface)
        view.tintColor = UIColor(StudioTheme.accent)
        view.textContainerInset = UIEdgeInsets(top: 18, left: 14, bottom: 24, right: 14)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.accessibilityLabel = "ABCソースエディタ"
        view.delegate = context.coordinator
        context.coordinator.textView = view

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain,
                            target: context.coordinator, action: #selector(Coordinator.undo)),
            UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.forward"), style: .plain,
                            target: context.coordinator, action: #selector(Coordinator.redo)),
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(title: "完了", style: .done, target: context.coordinator,
                            action: #selector(Coordinator.done))
        ]
        toolbar.items?[0].accessibilityLabel = "取り消す"
        toolbar.items?[1].accessibilityLabel = "やり直す"
        toolbar.tintColor = UIColor(StudioTheme.accent)
        view.inputAccessoryView = toolbar
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            context.coordinator.colorSyntax(view)
        }
        if let line = jumpToLine {
            // Avoid mutating a SwiftUI binding during a representable update.
            DispatchQueue.main.async {
                guard jumpToLine == line else { return }
                jumpToLine = nil
                jump(to: line, in: view)
            }
        }
    }

    private func jump(to line: Int, in view: UITextView) {
        let source = view.text as NSString
        var current = 1
        var position = 0
        while position < source.length && current < line {
            position = NSMaxRange(source.lineRange(for: NSRange(location: position, length: 0)))
            current += 1
        }
        if position < source.length {
            let range = source.lineRange(for: NSRange(location: position, length: 0))
            view.selectedRange = NSRange(location: range.location, length: max(0, range.length - 1))
        } else {
            view.selectedRange = NSRange(location: source.length, length: 0)
        }
        view.becomeFirstResponder()
        view.scrollRangeToVisible(view.selectedRange)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SourceEditor
        weak var textView: UITextView?
        private let fields = try! NSRegularExpression(pattern: "(?m)^[A-Za-z]:[^\\n]*")
        private let comments = try! NSRegularExpression(pattern: "(?m)%[^\\n]*")

        init(_ parent: SourceEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            // Keep marked text intact when an input method is composing.
            guard textView.markedTextRange == nil else { return }
            colorSyntax(textView)
            parent.text = textView.text
        }

        func colorSyntax(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            let source = view.text ?? ""
            let range = NSRange(location: 0, length: (source as NSString).length)
            view.textStorage.beginEditing()
            view.textStorage.addAttributes([
                .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor(StudioTheme.ink)
            ], range: range)
            for match in fields.matches(in: source, range: range) {
                view.textStorage.addAttribute(.foregroundColor, value: UIColor(StudioTheme.accent), range: match.range)
            }
            for match in comments.matches(in: source, range: range) {
                view.textStorage.addAttribute(.foregroundColor, value: UIColor(StudioTheme.secondary), range: match.range)
            }
            view.textStorage.endEditing()
            view.typingAttributes = [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                     .foregroundColor: UIColor(StudioTheme.ink)]
        }

        @objc func undo() { textView?.undoManager?.undo() }
        @objc func redo() { textView?.undoManager?.redo() }
        @objc func done() { textView?.resignFirstResponder() }
    }
}
