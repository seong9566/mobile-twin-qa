import Foundation

public enum EnvFileError: Error, Equatable {
    case invalidKey
    case newlineInValue
}

public struct EnvFile {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func presentKeys() -> Set<String> {
        Set(entriesInOrder().filter { !$0.value.isEmpty }.map(\.key))
    }

    /// 비어 있지 않은 값만 돌려준다. 화면에 보이기 전에 가릴 때 쓴다.
    public func values() -> [String] {
        entriesInOrder().compactMap { $0.value.isEmpty ? nil : $0.value }
    }

    public func upsert(key: String, value: String) throws {
        guard Self.isValidKey(key) else {
            throw EnvFileError.invalidKey
        }
        guard !value.contains("\n"), !value.contains("\r") else {
            throw EnvFileError.newlineInValue
        }

        let fileManager = FileManager.default
        let existed = fileManager.fileExists(atPath: url.path)
        let contents = existed ? try String(contentsOf: url, encoding: .utf8) : ""
        let updated = Self.updating(contents, key: key, value: Self.quotedIfNeeded(value))
        let permissions = try existed
            ? Self.permissions(of: url, fileManager: fileManager)
            : 0o600
        let temporaryURL = url.deletingLastPathComponent().appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )

        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        try Data(updated.utf8).write(to: temporaryURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)

        if existed {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }

    /// 읽는 쪽(entries·tools/android-login.sh)은 같은 따옴표 한 쌍을 벗긴다.
    /// 값 자체가 같은 따옴표로 감싸여 있으면 큰따옴표 한 쌍을 더 둘러 원래 값이 그대로 읽히게 한다.
    private static func quotedIfNeeded(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              first == value.last,
              first == "\"" || first == "'"
        else {
            return value
        }
        return "\"\(value)\""
    }

    private static func isValidKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    private static func updating(_ contents: String, key: String, value: String) -> String {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let prefix = "\(key)="

        if let index = lines.firstIndex(where: { line in
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            return line.hasPrefix(prefix)
        }) {
            let carriageReturn = lines[index].hasSuffix("\r") ? "\r" : ""
            lines[index] = "\(prefix)\(value)\(carriageReturn)"
            return lines.joined(separator: "\n")
        }

        if contents.isEmpty {
            return "\(prefix)\(value)\n"
        }
        if contents.hasSuffix("\n") {
            return "\(contents)\(prefix)\(value)\n"
        }
        return "\(contents)\n\(prefix)\(value)\n"
    }

    private static func permissions(of url: URL, fileManager: FileManager) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    }
}

public extension EnvFile {
    func entriesInOrder() -> [(key: String, value: String)] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        var entries: [(key: String, value: String)] = []
        var seen: Set<String> = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine[...]
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<separator])
            guard Self.isValidKey(key), seen.insert(key).inserted else {
                continue
            }

            var value = String(line[line.index(after: separator)...])
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            entries.append((key, value))
        }
        return entries
    }
}
