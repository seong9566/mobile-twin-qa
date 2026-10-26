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
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        return Set(contents.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let line = line.last == "\r" ? line.dropLast() : line[...]
            guard let separator = line.firstIndex(of: "=") else {
                return nil
            }

            let key = String(line[..<separator])
            guard Self.isValidKey(key) else {
                return nil
            }

            var value = String(line[line.index(after: separator)...])
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            return value.isEmpty ? nil : key
        })
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
        let updated = Self.updating(contents, key: key, value: value)
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
