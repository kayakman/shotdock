import AppKit
import ShotDockCore

/// Pinned captures and uploads for agents.
@MainActor
enum RemoteSharing {
    static var coordinator: CaptureCoordinator { RemoteCapture.coordinator }

    static let handlers: [String: RemoteHandler] = [
        "pin": { params, _ in
            let id = try RemoteDocuments.resolve(params["target"])
            let document = try RemoteDocuments.document(id)
            guard let image = document.flattened() else { throw RPCError.internalError("Cannot draw the capture") }
            let pin = coordinator.pin(image, scale: document.exportScale)
            pin.libraryItemID = id
            apply(params, to: pin)
            return json(pin)
        },
        "pins": { _, _ in
            ["pins": .array(coordinator.pins.map(json))]
        },
        "pin.update": { params, _ in
            let pin = try find(params["id"]?.stringValue ?? "")
            apply(params, to: pin)
            return json(pin)
        },
        "pin.close": { params, _ in
            let pins: [PinWindowController]
            if params["all"]?.boolValue == true {
                pins = coordinator.pins
            } else {
                let ids = params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard !ids.isEmpty else { throw RPCError.invalidParams("pin.close needs pin ids, or all") }
                pins = try ids.map(find)
            }
            pins.forEach { $0.close() }
            return ["closed": .number(Double(pins.count))]
        },
        "upload": { params, _ in
            let id = try RemoteDocuments.resolve(params["target"])
            let document = try RemoteDocuments.document(id)
            guard let image = document.flattened() else { throw RPCError.internalError("Cannot draw the capture") }
            guard Uploader.isConfigured else {
                throw RPCError(code: RPCError.notConfiguredCode,
                               message: "Uploads are not set up: Preferences › Upload, or `shotdock prefs set s3.bucket …` and `shotdock s3 credentials`")
            }
            let copy = params["copy"]?.boolValue == true
            let link = try await Uploader.upload(image, scale: document.exportScale, date: document.createdAt, libraryItem: id,
                                                 copyLink: copy, quiet: true)
            return ["id": .string(id.uuidString), "url": .string(link.absoluteString), "copied": .bool(copy)]
        },
        "upload.test": { _, _ in
            guard Uploader.isConfigured else {
                throw RPCError(code: RPCError.notConfiguredCode, message: "Uploads are not set up (Preferences › Upload)")
            }
            let key = try await Uploader.testConnection()
            return ["ok": true, "key": .string(key)]
        },
        "s3.credentials": { params, _ in
            if params["clear"]?.boolValue == true {
                Keychain.saveS3Credentials(nil)
                return ["configured": false]
            }
            guard let id = params["access_key_id"]?.stringValue, !id.isEmpty,
                  let secret = params["secret_access_key"]?.stringValue, !secret.isEmpty else {
                throw RPCError.invalidParams("Give access_key_id and secret_access_key, or clear")
            }
            guard Keychain.saveS3Credentials(S3Credentials(accessKeyID: id, secretAccessKey: secret)) else {
                throw RPCError.internalError("The keychain did not accept the keys")
            }
            return ["configured": true, "access_key_id": .string(id)]
        },
    ]

    static func find(_ prefix: String) throws -> PinWindowController {
        let text = prefix.lowercased()
        let matches = coordinator.pins.filter { $0.id.uuidString.lowercased().hasPrefix(text) }
        guard !text.isEmpty, matches.count == 1 else {
            throw matches.isEmpty ? RPCError.notFound("No pinned capture \(prefix)") : RPCError.invalidParams("\(prefix) matches several pins")
        }
        return matches[0]
    }

    static func apply(_ params: [String: JSONValue], to pin: PinWindowController) {
        if let zoom = params["zoom"]?.doubleValue { pin.setZoom(zoom) }
        if let opacity = params["opacity"]?.doubleValue { pin.opacity = opacity }
        if let at = params["at"]?.point { pin.move(topLeft: ScreenGeometry.flipped(at, primaryHeight: RemoteScreens.primaryHeight)) }
        if let through = params["click_through"]?.boolValue { pin.clickThrough = through }
    }

    static func json(_ pin: PinWindowController) -> JSONValue {
        let frame = pin.window.map { RemoteCapture.topLeft($0.frame) } ?? .zero
        return [
            "id": .string(pin.id.uuidString),
            "capture": pin.libraryItemID.map { .string($0.uuidString) } ?? .null,
            "frame": JSONValue(frame),
            "zoom": .number((pin.zoom * 100).rounded() / 100),
            "opacity": .number((pin.opacity * 100).rounded() / 100),
            "click_through": .bool(pin.clickThrough),
        ]
    }
}
