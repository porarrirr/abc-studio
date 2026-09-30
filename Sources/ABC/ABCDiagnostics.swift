import Foundation

/// app.js の validateABC の移植。テキストレベルの静的チェックのみ行う
/// (パース由来の診断は ABCParser が別途返し、呼び出し側でマージする)。
public enum ABCDiagnostics {
    /// Text-level checks ported from validateABC in app.js
    /// (missing X:/K:/M:/L:/T:, dropped lines after blank line,
    ///  undefined V:/%%score voices).
    public static func validate(_ source: String) -> [ABCDiagnostic] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var diags: [ABCDiagnostic] = []

        func push(_ line: Int, _ severity: ABCDiagnostic.Severity, _ message: String) {
            let ctx = (line >= 1 && line <= lines.count)
                ? lines[line - 1].trimmingCharacters(in: .whitespaces)
                : ""
            diags.append(ABCDiagnostic(severity: severity, line: line,
                                       message: message, context: ctx))
        }

        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            push(0, .error, "ABC の内容が空です。X:、T:、M:、L:、K: を含むテキストを入力してください")
            return diags
        }
        if !lines.contains(where: { $0.hasPrefix("X:") }) {
            push(0, .error, "X:（曲番号）の行がありません。曲の先頭に「X:1」を書いてください")
        }
        if !lines.contains(where: hasKeyField) {
            push(0, .error, "K:（調号）の行がありません。ヘッダの最後に「K:C」などを書いてください")
        }
        if !lines.contains(where: { $0.hasPrefix("M:") }) {
            push(0, .warning, "M:（拍子）の行がありません。「M:4/4」などを追加してください")
        }
        if !lines.contains(where: { $0.hasPrefix("L:") }) {
            push(0, .warning, "L:（基本の音長）の行がありません。「L:1/8」などを追加してください")
        }
        if !lines.contains(where: { $0.hasPrefix("T:") }) {
            push(0, .warning, "T:（タイトル）の行がありません。タイトルなしで表示されます")
        }
        let dropped = droppedLine(lines)
        if dropped > 0 {
            push(dropped, .error,
                 "直前の空行で曲が終了したため、この行以降は読み込まれません。ABC では空行が曲の終わりを意味します。曲の途中の空行を削除してください")
        }

        // V: の定義(K: より前)と使用(本文・[V:x])の対応
        var defined = Set<String>()
        var used: [(id: String, line: Int)] = []
        var usedSeen = Set<String>()
        var seenKey = false
        for (i, l) in lines.enumerated() {
            if hasKeyField(l) { seenKey = true }
            if let v = voiceFieldId(l) {
                if seenKey {
                    if !usedSeen.contains(v) { used.append((v, i + 1)); usedSeen.insert(v) }
                } else {
                    defined.insert(v)
                }
            }
            if let v = inlineVoiceId(l), !usedSeen.contains(v) {
                used.append((v, i + 1))
                usedSeen.insert(v)
            }
        }
        for (v, ln) in used where !defined.isEmpty && !defined.contains(v) {
            push(ln, .warning,
                 "声部 \"\(v)\" が V: で定義されていません。ヘッダに「V:\(v)」を追加するか、表記を確認してください")
        }

        // %%score の声部が V: で定義されているか
        if let si = lines.firstIndex(where: { $0.hasPrefix("%%score") }) {
            let rest = String(lines[si].dropFirst("%%score".count))
            let cleaned = rest.map { "(){}[]|*".contains($0) ? " " : $0 }
            for tok in String(cleaned).split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let v = String(tok)
                if v.isEmpty || v.contains("=") { continue }
                if !defined.isEmpty && !defined.contains(v) {
                    push(si + 1, .warning, "%%score の声部 \"\(v)\" が V: で定義されていません")
                }
            }
        }

        return diags.sorted { a, b in
            if a.line != b.line { return a.line < b.line }
            if a.severity == b.severity { return false }
            return a.severity == .error
        }
    }

    /// /^K:\s*\S/ — K: 行で内容が空でないもの
    private static func hasKeyField(_ l: String) -> Bool {
        guard l.hasPrefix("K:") else { return false }
        return l.dropFirst(2).contains(where: { !$0.isWhitespace })
    }

    /// /^V:\s*([^\s]+)/
    private static func voiceFieldId(_ l: String) -> String? {
        guard l.hasPrefix("V:") else { return nil }
        let rest = l.dropFirst(2).drop(while: { $0 == " " || $0 == "\t" })
        let id = rest.prefix(while: { !$0.isWhitespace })
        return id.isEmpty ? nil : String(id)
    }

    /// /^\[V:\s*([^\s\]]+)\]/
    private static func inlineVoiceId(_ l: String) -> String? {
        guard l.hasPrefix("[V:") else { return nil }
        let rest = l.dropFirst(3).drop(while: { $0 == " " || $0 == "\t" })
        let id = rest.prefix(while: { !$0.isWhitespace && $0 != "]" })
        return id.isEmpty ? nil : String(id)
    }

    /// 空行で曲が切れた後に読み捨てられる行の番号(app.js droppedLine)
    /// 空行以降の最初の実行行(コメント・新しい X: 以外)を 1 パスで返す。
    private static func droppedLine(_ lines: [String]) -> Int {
        var inTune = false
        var afterBlank = false
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("X:") { inTune = true; afterBlank = false; continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if inTune { afterBlank = true }
                continue
            }
            if line.hasPrefix("%") { continue }
            if afterBlank { return i + 1 }
        }
        return 0
    }
}
