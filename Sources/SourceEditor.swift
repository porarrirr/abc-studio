import SwiftUI
import UIKit

/// ABC ソース用の等幅テキストエディタ。診断からの行ジャンプに対応する。
struct SourceEditor: UIViewRepresentable {
    @Binding var text: String
    /// nil でない行番号が来たらその行へ選択・スクロールして nil に戻す
    @Binding var jumpToLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = UIColor(red: 0.141, green: 0.255, blue: 0.259, alpha: 1)
        view.backgroundColor = UIColor(red: 0.988, green: 0.996, blue: 0.984, alpha: 1)
        view.layer.borderColor = UIColor(red: 0.847, green: 0.898, blue: 0.863, alpha: 1).cgColor
        view.layer.borderWidth = 1
        view.layer.cornerRadius = 12
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.alwaysBounceVertical = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            let selected = view.selectedRange
            view.text = text
            let max = (view.text as NSString).length
            view.selectedRange = NSRange(location: min(selected.location, max), length: 0)
        }
        if let line = jumpToLine {
            jumpToLine = nil
            jump(to: line, in: view)
        }
    }

    private func jump(to line: Int, in view: UITextView) {
        let ns = view.text as NSString
        var target = ns.length
        var current = 1
        var pos = 0
        while pos < ns.length && current < line {
            let r = ns.lineRange(for: NSRange(location: pos, length: 0))
            pos = NSMaxRange(r)
            current += 1
        }
        if pos < ns.length {
            let r = ns.lineRange(for: NSRange(location: pos, length: 0))
            target = r.location
            view.selectedRange = NSRange(location: r.location, length: min(r.length, max(0, r.length - 1)))
        } else {
            view.selectedRange = NSRange(location: ns.length, length: 0)
        }
        view.becomeFirstResponder()
        view.scrollRangeToVisible(view.selectedRange)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SourceEditor
        init(_ parent: SourceEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
