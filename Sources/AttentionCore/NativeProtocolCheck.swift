import Foundation

/// Probe only the executable selected for launch, using a disposable Codex home.
enum NativeProtocolCheck {
    enum Failure: Error { case incompatible }
    typealias Object = [String: Any]

    static func check(_ executable: URL) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["HOME": directory.path, "CODEX_HOME": directory.path,
                           "TMPDIR": directory.path, "PATH": "/usr/bin:/bin"]
        func output(_ arguments: [String]) throws -> Data {
            try BoundedProcess.output(executable, arguments: arguments, environment: environment,
                                      workingDirectory: directory, timeout: 8)
        }
        let help = String(decoding: try output(["--help"]), as: UTF8.self)
        guard help.contains("--remote"), help.contains("--cd") else { throw Failure.incompatible }
        _ = try output(["app-server", "proxy", "--help"])
        let schemas = directory.appendingPathComponent("schemas")
        try FileManager.default.createDirectory(at: schemas, withIntermediateDirectories: false)
        _ = try output(["app-server", "generate-json-schema", "--out", schemas.path])

        func load(_ name: String) throws -> Object {
            let file = try FileHandle(forReadingFrom: schemas.appendingPathComponent(name + ".json"))
            defer { try? file.close() }
            let limit = 2_097_152
            guard let bytes = try file.read(upToCount: limit + 1), bytes.count <= limit,
                  let object = try JSONSerialization.jsonObject(with: bytes) as? Object else { throw Failure.incompatible }
            return object
        }
        try methods(load("ClientRequest"), [
            "initialize": [], "thread/start": [], "thread/fork": ["threadId"], "thread/resume": ["threadId"],
            "thread/unsubscribe": ["threadId"], "turn/start": ["threadId", "input"],
            "turn/steer": ["threadId", "input"]
        ])
        try methods(load("ServerRequest"), [
            "item/commandExecution/requestApproval": ["threadId", "turnId"],
            "item/fileChange/requestApproval": ["threadId", "turnId"], "item/permissions/requestApproval": ["threadId", "turnId"],
            "mcpServer/elicitation/request": ["threadId"], "item/tool/requestUserInput": ["threadId", "turnId", "questions[].id"]
        ])
        var notifications = ["turn/started": ["threadId", "turn.id"], "turn/completed": ["threadId", "turn.id", "turn.status"],
                             "item/completed": ["threadId", "turnId", "item"], "serverRequest/resolved": ["threadId", "requestId"]]
        for name in ["thread/closed", "thread/archived", "thread/deleted"] { notifications[name] = ["threadId"] }
        try methods(load("ServerNotification"), notifications)
        for name in ["ThreadStartResponse", "ThreadResumeResponse", "ThreadForkResponse"] {
            let response = try load("v2/" + name)
            guard let definitions = response["definitions"] as? [String: Object] else { throw Failure.incompatible }
            try fields(["thread.id", "thread.status", "thread.turns[].id"], in: response, definitions: definitions)
        }
    }

    static func methods(_ schema: Object, _ expected: [String: [String]]) throws {
        guard let variants = schema["oneOf"] as? [Object],
              let definitions = schema["definitions"] as? [String: Object] else { throw Failure.incompatible }
        var missing = Set(expected.keys)
        for variant in variants {
            guard let properties = variant["properties"] as? [String: Object],
                  let names = properties["method"]?["enum"] as? [String] else { continue }
            for name in names {
                guard let required = expected[name] else { continue }
                guard missing.remove(name) != nil, let params = properties["params"] else { throw Failure.incompatible }
                try fields(required, in: params, definitions: definitions)
            }
        }
        guard missing.isEmpty else { throw Failure.incompatible }
    }

    private static func fields(_ paths: [String], in root: Object, definitions: [String: Object]) throws {
        func resolve(_ node: Object) throws -> Object {
            let wrapper = node["allOf"] as? [Object]
            let reference = node["$ref"] ?? (wrapper?.count == 1 ? wrapper?.first?["$ref"] : nil)
            guard let ref = reference as? String else { return node }
            let prefix = "#/definitions/"
            guard ref.hasPrefix(prefix), let target = definitions[String(ref.dropFirst(prefix.count))] else { throw Failure.incompatible }
            return target
        }
        for path in paths {
            var node = root
            for element in path.split(separator: ".") {
                let array = element.hasSuffix("[]")
                let name = array ? String(element.dropLast(2)) : String(element)
                let object = try resolve(node)
                guard let properties = object["properties"] as? Object, let field = properties[name] as? Object,
                      (object["required"] as? [String])?.contains(name) == true else { throw Failure.incompatible }
                node = try resolve(field)
                if array {
                    guard node["type"] as? String == "array", let item = node["items"] as? Object else { throw Failure.incompatible }
                    node = try resolve(item)
                } else if ["id", "threadId", "turnId"].contains(name), node["type"] as? String != "string" {
                    throw Failure.incompatible
                } else if name == "input", node["type"] as? String != "array" { throw Failure.incompatible }
                else if name == "requestId" {
                    let types = (node["anyOf"] as? [Object] ?? []).compactMap { $0["type"] as? String }
                    guard Set(["integer", "string"]).isSubset(of: types) else { throw Failure.incompatible }
                } else if path == "thread.status", name == "status" {
                    let variants = node["oneOf"] as? [Object] ?? []
                    let tags = variants.flatMap { variant -> [String] in
                        guard let properties = variant["properties"] as? Object,
                              let tag = properties["type"] as? Object else { return [] }
                        return tag["enum"] as? [String] ?? []
                    }
                    guard Set(["active", "idle"]).isSubset(of: tags) else { throw Failure.incompatible }
                } else if name == "status", path == "turn.status" {
                    guard let statuses = node["enum"] as? [String],
                          Set(["completed", "failed", "interrupted", "inProgress"]).isSubset(of: statuses) else { throw Failure.incompatible }
                }
            }
        }
    }
}
