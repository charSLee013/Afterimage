import AppKit
import CryptoKit
import Foundation

struct CapturedRepresentation: Hashable, Sendable {
    let typeIdentifier: String
    let position: Int
    let data: Data
    let bookmarkData: Data?
}

struct CapturedItem: Hashable, Sendable {
    let position: Int
    let representations: [CapturedRepresentation]
}

struct ClipboardSnapshot: Hashable, Sendable {
    let items: [CapturedItem]
    let sourceBundleID: String?
    let sourceName: String?
    let sourceConfidence: String

    var byteCount: Int64 {
        items.reduce(0) { total, item in
            total + item.representations.reduce(0) { $0 + Int64($1.data.count + ($1.bookmarkData?.count ?? 0)) }
        }
    }

    var digest: String {
        var bytes = Data()
        func append(_ value: String) {
            let encoded = Data(value.utf8)
            appendLength(encoded.count, to: &bytes)
            bytes.append(encoded)
        }
        func appendLength(_ value: Int, to data: inout Data) {
            var bigEndian = UInt64(value).bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        appendLength(items.count, to: &bytes)
        for item in items.sorted(by: { $0.position < $1.position }) {
            appendLength(item.position, to: &bytes)
            appendLength(item.representations.count, to: &bytes)
            for representation in item.representations.sorted(by: { $0.position < $1.position }) {
                appendLength(representation.position, to: &bytes)
                append(representation.typeIdentifier)
                appendLength(representation.data.count, to: &bytes)
                bytes.append(representation.data)
            }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static let contentHashVersion = 2

    // Content identity is separate from the exact restoration payload digest.
    // In particular, HTML styling and source-app metadata do not identify text.
    var contentIdentity: Data {
        var bytes = Data("LocalClips.content.v2".utf8)
        func append(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(data)
        }
        append(Data(String(items.count).utf8))
        for item in items.sorted(by: { $0.position < $1.position }) {
            if let representation = item.representations.first(where: { $0.typeIdentifier == "public.file-url" }),
               let url = URL(dataRepresentation: representation.data, relativeTo: nil)
                    ?? String(data: representation.data, encoding: .utf8).flatMap(URL.init(string:)),
               url.isFileURL {
                append(Data("file".utf8))
                append(Data(url.standardizedFileURL.absoluteString.utf8))
                continue
            }
            let imageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif", "public.gif"]
            let containsImage = item.representations.contains {
                imageTypes.contains($0.typeIdentifier) || $0.typeIdentifier.hasPrefix("public.image")
            }
            let providedText = item.representations.first(where: {
                $0.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue
            }).flatMap { String(data: $0.data, encoding: .utf8) }
            if !containsImage, let text = providedText ?? Self.plainText(for: item) {
                append(Data("text".utf8))
                let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .precomposedStringWithCanonicalMapping
                append(Data(normalized.utf8))
            } else {
                append(Data("payload".utf8))
                let payload = ClipboardSnapshot(items: [item], sourceBundleID: nil, sourceName: nil, sourceConfidence: "unknown")
                append(Data(payload.digest.utf8))
            }
        }
        return bytes
    }

    var contentDigest: String {
        SHA256.hash(data: contentIdentity).map { String(format: "%02x", $0) }.joined()
    }

    var plainText: String? {
        let values = items.sorted(by: { $0.position < $1.position }).compactMap(Self.plainText(for:))
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    var title: String {
        if let text = plainText {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
        }
        if items.flatMap(\.representations).contains(where: { $0.typeIdentifier.hasPrefix("public.image") || ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif", "public.gif"].contains($0.typeIdentifier) }) {
            return "图片"
        }
        if let fileData = items.flatMap(\.representations).first(where: { $0.typeIdentifier == "public.file-url" })?.data,
           let fileURL = URL(dataRepresentation: fileData, relativeTo: nil)
                ?? String(data: fileData, encoding: .utf8).flatMap(URL.init(string:)),
           !fileURL.lastPathComponent.isEmpty {
            return fileURL.lastPathComponent
        }
        if items.flatMap(\.representations).contains(where: { $0.typeIdentifier == "public.file-url" }) {
            return "文件引用"
        }
        return "剪贴板项目"
    }

    var kind: String {
        let types = Set(items.flatMap(\.representations).map(\.typeIdentifier))
        if types.contains("public.file-url") { return "file" }
        if types.contains(where: { $0.hasPrefix("public.image") || ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif", "public.gif"].contains($0) }) { return "image" }
        if types.contains(NSRTFPboardType) || types.contains("public.html") { return "richText" }
        if types.contains("public.url") { return "link" }
        return "text"
    }

    static func plainText(for item: CapturedItem) -> String? {
        for representation in item.representations.sorted(by: { $0.position < $1.position }) {
            switch representation.typeIdentifier {
            case NSPasteboard.PasteboardType.string.rawValue:
                if let text = String(data: representation.data, encoding: .utf8) { return text }
            case "public.rtf", "com.apple.rtfd":
                if let value = try? NSAttributedString(
                    data: representation.data,
                    options: [.documentType: representation.typeIdentifier == "public.rtf" ? NSAttributedString.DocumentType.rtf : .rtfd],
                    documentAttributes: nil
                ) { return value.string }
            case "public.html":
                if let html = String(data: representation.data, encoding: .utf8) { return Self.htmlText(html) }
            case "public.url":
                if let value = String(data: representation.data, encoding: .utf8), !value.isEmpty { return value }
            default:
                continue
            }
        }
        return nil
    }

    private static func htmlText(_ html: String) -> String {
        func replace(_ pattern: String, in value: String, with template: String) -> String {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
            let range = NSRange(value.startIndex..., in: value)
            return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
        }
        var value = replace("(?s)<(script|style)\\b[^>]*>.*?</\\1\\s*>", in: html, with: "")
        value = replace("<!--.*?-->", in: value, with: "")
        value = replace("(?i)<br\\b[^>]*>|</(?:p|div|li|h[1-6]|tr)\\s*>", in: value, with: "\n")
        value = replace("(?s)<[^>]*>", in: value, with: "")
        guard let entities = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#\\d+|amp|lt|gt|quot|apos|nbsp);", options: [.caseInsensitive]) else { return value }
        let matches = entities.matches(in: value, range: NSRange(value.startIndex..., in: value))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: value), let nameRange = Range(match.range(at: 1), in: value) else { continue }
            let key = String(value[nameRange]).lowercased()
            let replacement: String
            if key.hasPrefix("#x"), let code = UInt32(key.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                replacement = String(scalar)
            } else if key.hasPrefix("#"), let code = UInt32(key.dropFirst()), let scalar = Unicode.Scalar(code) {
                replacement = String(scalar)
            } else {
                replacement = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "][key] ?? String(value[range])
            }
            value.replaceSubrange(range, with: replacement)
        }
        return value
    }
}

let NSRTFPboardType = "public.rtf"

struct ClipRow: Identifiable, Hashable, Sendable {
    let id: UUID
    let digest: String
    let title: String
    let searchText: String
    let kind: String
    let capturedAt: Date
    let sourceName: String?
    let sourceBundleID: String?
    let sourceConfidence: String
    let byteCount: Int64
    let items: [CapturedItem]
    let boards: [String]
    let boardIDs: [UUID]
    let boardPosition: Int?
}

enum CaptureStatus: Equatable {
    case waiting
    case recording
    case paused
    case filtered(String)
    case noSupportedContent
    case unstableClipboard
    case tooLarge
    case budgetFull
    case lowSpace
    case saved
    case writeFailed
    case unavailable(String)

    var label: String {
        switch self {
        case .waiting: "等待剪贴板变化"
        case .recording: "正在记录"
        case .paused: "已暂停"
        case .filtered(let reason): "已跳过：\(reason)"
        case .noSupportedContent: "格式不支持"
        case .unstableClipboard: "剪贴板持续变化，稍后重试"
        case .tooLarge: "内容超过限制"
        case .budgetFull: "收藏内容占满存储预算，未添加新记录"
        case .lowSpace: "磁盘可用空间低于安全门槛，未保存新内容"
        case .saved: "已保存"
        case .writeFailed: "存储写入失败"
        case .unavailable(let reason): reason
        }
    }
}

enum SnapshotCommitResult: Sendable {
    case saved
    case budgetFull
    case lowSpace
    case failed
}
