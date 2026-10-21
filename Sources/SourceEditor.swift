import Foundation

/// Syntax is line-local. Recolor only lines touched by an edit, keeping UTF-16
/// offsets consistent with NSTextStorage and NSRegularExpression.
enum SourceSyntax {
    enum Kind: Equatable { case field, comment }
    struct Span: Equatable {
        let range: NSRange
        let kind: Kind
    }
    struct Plan {
        let range: NSRange
        let spans: [Span]
    }
    private static let fields = try! NSRegularExpression(pattern: "(?m)^[A-Za-z]:[^\\n]*")
    private static let comments = try! NSRegularExpression(pattern: "(?m)%[^\\n]*")

    static func lineCount(in source: String) -> Int {
        source.unicodeScalars.reduce(into: 1) { count, scalar in
            switch scalar.value {
            case 10...13, 0x85, 0x2028, 0x2029: count += 1
            default: break
            }
        }
    }

    static func plan(in source: String, editedRange: NSRange? = nil) -> Plan {
        let text = source as NSString
        let range: NSRange
        if let edit = editedRange, edit.location != NSNotFound,
           edit.location <= text.length, edit.length <= text.length - edit.location {
            range = text.lineRange(for: edit)
        } else {
            range = NSRange(location: 0, length: text.length)
        }
        let spans = fields.matches(in: source, range: range).map { Span(range: $0.range, kind: .field) }
            + comments.matches(in: source, range: range).map { Span(range: $0.range, kind: .comment) }
        return Plan(range: range, spans: spans)
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

/// Native ABC editor with lightweight syntax coloring and keyboard actions.
struct SourceEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var jumpToLine: Int?
    var isActive = true
    var pasteRequest = 0
    var onPasteUnavailable: () -> Void = {}

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
        guard isActive else { return }
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            context.coordinator.colorSyntax(view)
        }
        if context.coordinator.lastPasteRequest != pasteRequest {
            context.coordinator.lastPasteRequest = pasteRequest
            // Paste outside the representable update so the delegate can update
            // the source binding, validation and autosave normally.
            DispatchQueue.main.async {
                guard context.coordinator.parent.isActive else { return }
                guard UIPasteboard.general.hasStrings else {
                    context.coordinator.parent.onPasteUnavailable()
                    return
                }
                view.becomeFirstResponder()
                view.paste(nil)
                view.scrollRangeToVisible(view.selectedRange)
            }
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
        var lastPasteRequest: Int
        private var pendingEdit: NSRange?
        private var syntaxGeneration = 0
        private var syntaxWork: DispatchWorkItem?
        private var fullColorPending = false
        private static let syntaxQueue = DispatchQueue(label: "jp.porari.abcstudio.syntax", qos: .userInitiated)

        init(_ parent: SourceEditor) {
            self.parent = parent
            lastPasteRequest = parent.pasteRequest
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            pendingEdit = textView.markedTextRange == nil
                ? NSRange(location: range.location, length: (text as NSString).length) : nil
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            // Keep marked text intact when an input method is composing.
            guard textView.markedTextRange == nil else { pendingEdit = nil; return }
            let edit = pendingEdit
            pendingEdit = nil
            colorSyntax(textView, editedRange: edit)
            parent.text = textView.text
        }

        func colorSyntax(_ view: UITextView, editedRange: NSRange? = nil) {
            guard view.markedTextRange == nil else { return }
            syntaxGeneration += 1
            syntaxWork?.cancel()
            let generation = syntaxGeneration
            let source = view.text ?? ""
            if let editedRange, !fullColorPending {
                let plan = SourceSyntax.plan(in: source, editedRange: editedRange)
                apply(plan, to: view, spans: plan.spans[...], reset: true)
                return
            }
            fullColorPending = true
            let work = DispatchWorkItem { [weak self, weak view] in
                let plan = SourceSyntax.plan(in: source)
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, self.syntaxGeneration == generation else { return }
                    self.applyNextBatch(plan, to: view, generation: generation, start: 0)
                }
            }
            syntaxWork = work
            Self.syntaxQueue.async(execute: work)
        }

        private func applyNextBatch(_ plan: SourceSyntax.Plan, to view: UITextView,
                                    generation: Int, start: Int) {
            guard generation == syntaxGeneration else { return }
            // UIKit text replacement while an IME is composing invalidates the
            // old offsets; the commit callback will request a fresh full pass.
            guard view.markedTextRange == nil else { fullColorPending = true; return }
            let end = min(plan.spans.count, start + 200)
            apply(plan, to: view, spans: plan.spans[start..<end], reset: start == 0)
            if end == plan.spans.count {
                fullColorPending = false
                syntaxWork = nil
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.applyNextBatch(plan, to: view, generation: generation, start: end)
                }
            }
        }

        private func apply(_ plan: SourceSyntax.Plan, to view: UITextView,
                           spans: ArraySlice<SourceSyntax.Span>, reset: Bool) {
            let undo = view.undoManager
            let suppressUndo = undo?.isUndoRegistrationEnabled == true
            if suppressUndo { undo?.disableUndoRegistration() }
            defer { if suppressUndo { undo?.enableUndoRegistration() } }
            view.textStorage.beginEditing()
            if reset {
                view.textStorage.addAttributes([
                    .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: UIColor(StudioTheme.ink)
                ], range: plan.range)
            }
            for span in spans {
                let ink = span.kind == .field ? StudioTheme.accent : StudioTheme.secondary
                view.textStorage.addAttribute(.foregroundColor, value: UIColor(ink), range: span.range)
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

#endif
