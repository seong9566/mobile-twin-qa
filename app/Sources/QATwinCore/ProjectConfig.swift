import Foundation

public struct ServerConfig: Equatable, Sendable {
    public let name: String
    public let health: String?
    public let start: String?
    public let cwd: String
    public let startTimeout: Int
    public let vars: [String: String]
}

public struct ProjectConfig: Equatable, Sendable {
    public let package: String?
    public let launch: String?
    public let permissions: [String]
    public let buildAndroid: String?
    public let androidAPK: String?
    public let envSource: String
    public let defaultServer: String?
    public let servers: [String: ServerConfig]

    public var usesQAAppEnv: Bool {
        buildAndroid?.contains("$QA_APP_ENV") == true
    }

    public static func parse(_ yaml: String) -> ProjectConfig {
        var package: String?
        var launch: String?
        var permissions: [String] = []
        var buildAndroid: String?
        var androidAPK: String?
        var envSource = ".env"
        var defaultServer: String?
        var serverBuilders: [String: ServerConfigBuilder] = [:]
        var path: [(indent: Int, key: String)] = []

        for rawLine in yaml.components(separatedBy: .newlines) {
            let line = stripComment(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let indent = line.prefix(while: \.isWhitespace).count
            while (path.last?.indent ?? -1) >= indent {
                path.removeLast()
            }
            let parentKeys = path.map(\.key)

            if trimmed.hasPrefix("- ") {
                if parentKeys == ["apps", "android", "permissions"] {
                    let permission = scalar(String(trimmed.dropFirst(2)))
                    if !permission.isEmpty {
                        permissions.append(permission)
                    }
                }
                continue
            }

            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = scalar(String(trimmed[trimmed.index(after: separator)...]))

            switch parentKeys {
            case ["apps", "android"]:
                if key == "package" { package = value.nilIfEmpty }
                else if key == "launch" { launch = value.nilIfEmpty }
            case ["build"]:
                if key == "android" { buildAndroid = value.nilIfEmpty }
                else if key == "android_apk" { androidAPK = value.nilIfEmpty }
                else if key == "env_source", !value.isEmpty { envSource = value }
            case ["environments"]:
                if key == "default" {
                    defaultServer = value.nilIfEmpty
                } else {
                    serverBuilders[key] = serverBuilders[key] ?? ServerConfigBuilder()
                }
            case let keys where keys.count == 2 && keys[0] == "environments":
                let serverName = keys[1]
                var server = serverBuilders[serverName] ?? ServerConfigBuilder()
                if key == "health" { server.health = value.nilIfEmpty }
                else if key == "start" { server.start = value.nilIfEmpty }
                else if key == "cwd", !value.isEmpty { server.cwd = value }
                else if key == "start_timeout", let timeout = Int(value) { server.startTimeout = timeout }
                else if key == "vars" { server.vars = inlineMap(value) }
                serverBuilders[serverName] = server
            default:
                break
            }

            if value.isEmpty {
                path.append((indent, key))
            }
        }

        if let defaultServer {
            serverBuilders[defaultServer] = serverBuilders[defaultServer] ?? ServerConfigBuilder()
        }
        let servers = Dictionary(uniqueKeysWithValues: serverBuilders.map { name, builder in
            (
                name,
                ServerConfig(
                    name: name,
                    health: builder.health,
                    start: builder.start,
                    cwd: builder.cwd,
                    startTimeout: builder.startTimeout,
                    vars: builder.vars
                )
            )
        })

        return ProjectConfig(
            package: package,
            launch: launch,
            permissions: permissions,
            buildAndroid: buildAndroid,
            androidAPK: androidAPK,
            envSource: envSource,
            defaultServer: defaultServer,
            servers: servers
        )
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
            } else if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func scalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              first == trimmed.last,
              first == "\"" || first == "'"
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func inlineMap(_ value: String) -> [String: String] {
        guard value.hasPrefix("{"), value.hasSuffix("}") else { return [:] }
        var result: [String: String] = [:]
        for item in value.dropFirst().dropLast().split(separator: ",") {
            guard let separator = item.firstIndex(of: ":") else { continue }
            let key = scalar(String(item[..<separator]))
            let mapValue = scalar(String(item[item.index(after: separator)...]))
            if !key.isEmpty {
                result[key] = mapValue
            }
        }
        return result
    }
}

private struct ServerConfigBuilder {
    var health: String?
    var start: String?
    var cwd = "."
    var startTimeout = 60
    var vars: [String: String] = [:]
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

