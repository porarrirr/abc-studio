import Foundation

/// ライブラリに保存された曲のメタデータ。ABC 本体は `<filename>` のファイル、
/// 一覧(名前・保存日時・曲数)は同じフォルダの index.json に保持する。
struct LibraryItem: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var filename: String
    var createdAt: Date
    var tuneCount: Int
}

/// アプリ内ライブラリの永続化。Application Support/Library/ に曲ごとの
/// .abc ファイルを置き、index.json で名前・保存日時・曲数を管理する。
/// index.json が無い/壊れていてもフォルダ内の .abc を走査して一覧を復元する。
final class LibraryStore {
    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
    }

    /// 保存済みの曲一覧(新しい順)。index.json とディスク内容を突き合わせ、
    /// 消えた曲を除き、index にない .abc は取り込む。
    func items() -> [LibraryItem] {
        var items = decodeIndex()
        let files = Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".abc") })
        let before = items.count
        items = items.filter { files.contains($0.filename) }
        var dirty = items.count != before
        let known = Set(items.map(\.filename))
        for file in files where !known.contains(file) {
            items.append(orphanItem(file: file))
            dirty = true
        }
        if dirty { try? writeIndex(items) }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    /// 曲を保存し index を更新する。
    @discardableResult
    func save(name: String, abc: String) throws -> LibraryItem {
        let item = LibraryItem(id: UUID(), name: name, filename: UUID().uuidString + ".abc",
                               createdAt: Date(), tuneCount: Self.tuneCount(of: abc))
        try Data(abc.utf8).write(to: directory.appendingPathComponent(item.filename))
        var all = decodeIndex()
        all.append(item)
        try writeIndex(all)
        return item
    }

    /// 保存した ABC テキストを読む。
    func read(_ item: LibraryItem) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(item.filename), encoding: .utf8)
    }

    /// 曲を削除する。
    func delete(_ item: LibraryItem) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(item.filename))
        var all = items()
        all.removeAll { $0.id == item.id }
        try writeIndex(all)
    }

    /// 表示名を変更する(ファイル名は変えない)。
    @discardableResult
    func rename(_ item: LibraryItem, to name: String) throws -> LibraryItem {
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == item.id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        all[index].name = name
        try writeIndex(all)
        return all[index]
    }

    // MARK: - 内部

    /// index.json の読み出し。存在しない/壊れている場合は空配列。
    private func decodeIndex() -> [LibraryItem] {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder().decode([LibraryItem].self, from: data) else {
            return []
        }
        return items
    }

    private func writeIndex(_ items: [LibraryItem]) throws {
        try JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
    }

    /// index に載っていない .abc ファイルを一覧項目にする(T: 行から名前を取る)。
    private func orphanItem(file: String) -> LibraryItem {
        let url = directory.appendingPathComponent(file)
        let abc = try? String(contentsOf: url, encoding: .utf8)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return LibraryItem(id: UUID(),
                           name: abc.flatMap { Self.title(in: $0) }
                               ?? url.deletingPathExtension().lastPathComponent,
                           filename: file,
                           createdAt: attrs?[.creationDate] as? Date ?? Date(),
                           tuneCount: abc.map { Self.tuneCount(of: $0) } ?? 1)
    }

    /// 先頭の T: フィールドを表示名として取り出す。
    static func title(in abc: String) -> String? {
        for line in abc.components(separatedBy: .newlines) where line.hasPrefix("T:") {
            let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// X: フィールドの数 = ファイル内の曲数。なければ 1 曲扱い。
    static func tuneCount(of abc: String) -> Int {
        let count = abc.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("X:") }.count
        return max(1, count)
    }
}
