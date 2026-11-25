import AppKit
import ShotDockCore

/// The ruler, the eyedropper and OCR for agents, on a capture (as edited)
/// or on the screen.
@MainActor
enum RemoteInspection {
    static let handlers: [String: RemoteHandler] = [
        "measure": { params, _ in
            let tolerance = min(max(params["tolerance"]?.intValue ?? 24, 0), 255)
            let (image, point, scale, origin) = try await pixels(params)
            guard let m = Measure.edges(in: image, at: point, tolerance: tolerance) else {
                throw RPCError.invalidParams("The point is outside the image (\(image.width)×\(image.height) px)")
            }
            let box = m.rect(around: point)
            var result: [String: JSONValue] = [
                "rect": JSONValue(box.offsetBy(dx: origin.x, dy: origin.y)),
                "width": .number(Double(m.width)), "height": .number(Double(m.height)),
                "width_pt": .number(Double(m.width) / scale), "height_pt": .number(Double(m.height) / scale),
            ]
            if params["target"] == nil {
                // On the screen, also where it is in screen points.
                result["screen_rect"] = JSONValue(CGRect(x: origin.x + box.minX / scale, y: origin.y + box.minY / scale,
                                                         width: box.width / scale, height: box.height / scale))
                result["rect"] = nil
            }
            return .object(result)
        },
        "color": { params, _ in
            let (image, point, _, _) = try await pixels(params)
            guard let color = Measure.color(in: image, at: point) else {
                throw RPCError.invalidParams("The point is outside the image (\(image.width)×\(image.height) px)")
            }
            var result: [String: JSONValue] = [
                "hex": .string(ColorFormat.hex.string(for: color)),
                "rgb": .string(ColorFormat.rgb.string(for: color)),
                "red": .number((color.red * 255).rounded()), "green": .number((color.green * 255).rounded()),
                "blue": .number((color.blue * 255).rounded()), "alpha": .number((color.alpha * 100).rounded() / 100),
            ]
            if params["copy"]?.boolValue == true {
                let text = AppSettings.shared.colorFormat.string(for: color)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                result["copied"] = .string(text)
            }
            return .object(result)
        },
        "ocr": { params, _ in try await ocr(params) },
    ]

    /// The image to read and the point in its pixels: the edited capture, or
    /// the display under a screen point. `origin` maps results back (view
    /// pixels for captures; the display's top-left in points for the screen).
    static func pixels(_ params: [String: JSONValue]) async throws -> (CGImage, CGPoint, CGFloat, CGPoint) {
        guard let at = params["at"]?.point else { throw RPCError.invalidParams("at is required") }
        if params["target"] != nil {
            let id = try RemoteDocuments.resolve(params["target"])
            let document = try RemoteDocuments.document(id)
            guard let image = document.flattened() else { throw RPCError.internalError("Cannot draw the capture") }
            return (image, at, document.exportScale, .zero)
        }
        guard ScreenCapturer.hasPermission else { throw ScreenCaptureError.permissionDenied }
        guard let display = RemoteScreens.displays().first(where: { $0.frame.contains(at) }) else {
            throw RPCError.invalidParams("\(Int(at.x)),\(Int(at.y)) is not on any display")
        }
        let document = try await RemoteCapture.coordinator.displayDocument(display.screen.displayID)
        let local = CGPoint(x: (at.x - display.frame.minX) * document.scale, y: (at.y - display.frame.minY) * document.scale)
        return (document.image, local, document.scale, display.frame.origin)
    }

    static func ocr(_ params: [String: JSONValue]) async throws -> JSONValue {
        var image: CGImage
        var itemID: UUID?
        if params["target"] != nil {
            let id = try RemoteDocuments.resolve(params["target"])
            guard let flat = try RemoteDocuments.document(id).flattened() else { throw RPCError.internalError("Cannot draw the capture") }
            image = flat
            itemID = id
        } else if params["interactive"]?.boolValue == true {
            try await RemoteCapture.prepare(params)
            guard case let .area(result) = try await RemoteCapture.coordinator.pick(mode: .area) else { throw RemoteCapture.cancelled }
            image = result.image
        } else if let rect = try RemoteCapture.screenRect(params) {
            try await RemoteCapture.prepare(params)
            guard let document = try await RemoteCapture.coordinator.areaDocument(rect) else {
                throw RPCError.invalidParams("The area is outside every display")
            }
            image = document.image
        } else {
            throw RPCError.invalidParams("ocr needs a capture, a screen rect, or interactive")
        }
        let languages = params["languages"]?.arrayValue?.compactMap(\.stringValue).filter { !$0.isEmpty }
        let recognition = try await TextRecognition.recognize(image, languages: languages?.isEmpty == false ? languages! : ["es-ES", "en-US"])
        let join = params["join"]?.boolValue ?? AppSettings.shared.ocrJoinLines
        let text = recognition.text(joinLines: join)
        if let itemID, !text.isEmpty { LibraryStore.shared.setRecognizedText(itemID, text) }
        var result: [String: JSONValue] = [
            "text": .string(text),
            "lines": .array(recognition.textLines.map { ["text": .string($0.text), "box": JSONValue($0.box),
                                                         "confidence": .number((Double($0.confidence) * 100).rounded() / 100)] }),
            "codes": .array(recognition.barcodes.map { ["payload": .string($0.payload), "symbology": .string($0.symbology), "box": JSONValue($0.box)] }),
            "width": .number(Double(image.width)), "height": .number(Double(image.height)),
        ]
        if let itemID { result["id"] = .string(itemID.uuidString) }
        if params["copy"]?.boolValue == true {
            // As the global shortcut: a QR code wins over the text.
            let copied = recognition.codes.first ?? text
            if !copied.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copied, forType: .string)
                result["copied"] = .string(copied)
            }
        }
        return .object(result)
    }
}
