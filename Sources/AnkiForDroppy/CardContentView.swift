import AppKit
import Foundation
import SwiftUI
import WebKit

package struct CardDocument: Equatable {
    package static let scheme = "anki-card-media"
    package static let maximumDocumentBytes = 1_024 * 1_024
    package static let maximumResources = 32
    package static let maximumCachedBytes = 24 * 1_024 * 1_024
    package static let unsupportedIssue = "Some card formatting or media is unsupported here. Open this card in Anki."
    package static let missingMediaIssue = "Some card media could not be loaded. Open this card in Anki."
    package static let sizeIssue = "This card exceeds the display limits. Open it in Anki."

    package let html: String
    package let issues: Set<String>
    package let scope: String
    package var url: URL { URL(string: "\(Self.scheme)://\(scope)/__document__")! }

    package init(card: AnkiCard, showsAnswer: Bool, scope: String = UUID().uuidString.lowercased()) {
        self.scope = scope
        let selected = showsAnswer ? card.answer : card.question
        var issues: Set<String> = []
        let fragment: String
        let css: String
        if selected.utf8.count + card.css.utf8.count > Self.maximumDocumentBytes {
            fragment = "<p>This card is too large to display here.</p>"
            css = ""
            issues.insert(Self.sizeIssue)
        } else {
            var sanitizer = CardHTMLSanitizer(scope: scope)
            let rendered = sanitizer.render(selected)
            let stylesheet = sanitizer.stylesheet(card.css)
            if rendered.utf8.count + stylesheet.utf8.count > Self.maximumDocumentBytes {
                fragment = "<p>This card is too large to display here.</p>"
                css = ""
                issues.insert(Self.sizeIssue)
            } else {
                fragment = rendered
                css = stylesheet
            }
            issues.formUnion(sanitizer.issues)
        }
        if card.fields.values.contains(where: { Self.hasExtractedMedia($0.value) }) {
            issues.insert(Self.unsupportedIssue)
        }
        self.issues = issues
        let origin = "\(Self.scheme)://\(scope)"
        let policy = "default-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; manifest-src 'none'; img-src \(origin); style-src 'unsafe-inline' \(origin); font-src \(origin); media-src \(origin)"
        html = """
        <!doctype html><html class="nightMode night_mode" lang="en"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(policy)"><meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width,initial-scale=1"><style>:root{color-scheme:dark}html,body{margin:0;background:transparent;color:#eee;font:14px -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}html{background:#000}img{max-width:100%;height:auto}audio{max-width:100%}pre{white-space:pre-wrap}a{color:inherit}\(css)</style></head><body class="card nightMode night_mode">\(fragment)</body></html>
        """
    }

    package static func mediaName(for url: URL, scope: String) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == scheme, parts.host == scope, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.hasPrefix("/"),
              let name = String(parts.percentEncodedPath.dropFirst()).removingPercentEncoding,
              !name.contains("%"), AnkiConnectClient.isSafeMediaName(name), mimeType(for: name) != nil else { return nil }
        return name
    }

    package static func mediaURL(for reference: String, scope: String) -> URL? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = reference.removingPercentEncoding, !name.contains("%"),
              AnkiConnectClient.isSafeMediaName(name), !name.contains("?"), !name.contains("#"),
              mimeType(for: name) != nil else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = scope
        parts.path = "/" + name
        return parts.url
    }

    package static func mimeType(for name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "css": "text/css"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "aac": "audio/aac"
        case "wav": "audio/wav"
        case "ogg", "oga": "audio/ogg"
        case "flac": "audio/flac"
        default: nil
        }
    }

    package static func allowsNavigation(to url: URL?, documentURL: URL, isMainFrame: Bool,
                                         isInitial: Bool, isOther: Bool) -> Bool {
        isInitial && isMainFrame && isOther && url == documentURL
    }

    private static func hasExtractedMedia(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("[sound:") || lower.contains("[anki:tts") || lower.contains("{{tts ")
    }
}

private struct CardHTMLSanitizer {
    let scope: String
    var issues: Set<String> = []
    private static let tags: Set<String> = [
        "a", "abbr", "b", "bdi", "bdo", "blockquote", "br", "caption", "code", "col", "colgroup",
        "dd", "del", "details", "div", "dl", "dt", "em", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "i", "ins", "kbd", "li", "mark", "ol", "p", "pre", "q", "rp", "rt", "ruby", "s",
        "samp", "small", "span", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot",
        "th", "thead", "tr", "u", "ul", "var", "wbr", "img", "audio", "source", "link"
    ]
    private static let rawTags: Set<String> = ["script", "style", "iframe", "object", "svg", "math", "textarea", "title"]
    private static let attributes: Set<String> = [
        "class", "id", "title", "lang", "dir", "colspan", "rowspan", "span", "width", "height",
        "align", "valign", "start", "reversed", "open"
    ]

    mutating func stylesheet(_ css: String) -> String {
        if css.range(of: #"(?i)(https?:|file:|data:|//|javascript:|@import|expression\s*\()"#, options: .regularExpression) != nil {
            issues.insert(CardDocument.unsupportedIssue)
        }
        return css.replacingOccurrences(of: "<", with: "\\3c ")
    }

    mutating func render(_ source: String) -> String {
        if source.range(of: #"(?i)(mathjax|typeans|\{\{type:|\{\{tts |\[anki:(play|tts)|\\\(|\\\[)"#, options: .regularExpression) != nil {
            issues.insert(CardDocument.unsupportedIssue)
        }
        var result = ""
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if result.utf8.count > CardDocument.maximumDocumentBytes { return result }
            guard source[cursor] == "<" else {
                let end = source[cursor...].firstIndex(of: "<") ?? source.endIndex
                result += renderText(String(source[cursor..<end]))
                cursor = end
                continue
            }
            if source[cursor...].hasPrefix("<!--") {
                cursor = source.range(of: "-->", range: cursor..<source.endIndex)?.upperBound ?? source.endIndex
                continue
            }
            guard let token = HTMLToken.read(source, at: cursor) else {
                result += source[cursor...].replacingOccurrences(of: "<", with: "&lt;")
                issues.insert(CardDocument.unsupportedIssue)
                break
            }
            cursor = token.end
            if Self.rawTags.contains(token.name), !token.closing {
                let closing = source.range(of: "</\(token.name)", options: .caseInsensitive, range: cursor..<source.endIndex)
                let bodyEnd = closing?.lowerBound ?? source.endIndex
                if token.name == "style" {
                    result += "<style>\(stylesheet(String(source[cursor..<bodyEnd])))</style>"
                } else {
                    issues.insert(CardDocument.unsupportedIssue)
                }
                cursor = closing.flatMap { HTMLToken.read(source, at: $0.lowerBound)?.end } ?? source.endIndex
                continue
            }
            guard Self.tags.contains(token.name) else {
                if !["html", "head", "body"].contains(token.name) { issues.insert(CardDocument.unsupportedIssue) }
                continue
            }
            if token.closing {
                result += "</\(token.name)>"
                continue
            }
            var attributes: [String: String] = [:]
            for (name, value) in token.attributes {
                if Self.attributes.contains(name) || (token.name == "img" && name == "alt") {
                    attributes[name] = value
                } else if name == "style" {
                    attributes[name] = stylesheet(value)
                } else if name.hasPrefix("on") || name == "srcset" || name == "autoplay" {
                    issues.insert(CardDocument.unsupportedIssue)
                }
            }
            if token.name == "a", token.attributes["href"] != nil { issues.insert(CardDocument.unsupportedIssue) }
            if ["img", "audio", "source", "link"].contains(token.name) {
                let key = token.name == "link" ? "href" : "src"
                if token.name == "link", token.attributes["rel"]?.lowercased() != "stylesheet" {
                    issues.insert(CardDocument.unsupportedIssue)
                    continue
                }
                if let reference = token.attributes[key], let url = CardDocument.mediaURL(for: reference, scope: scope),
                   let name = CardDocument.mediaName(for: url, scope: scope),
                   Self.resourceMatches(tag: token.name, mime: CardDocument.mimeType(for: name) ?? "") {
                    attributes[key] = url.absoluteString
                } else if token.name != "audio" || token.attributes[key] != nil {
                    issues.insert(CardDocument.unsupportedIssue)
                    continue
                }
                if token.name == "link" { attributes["rel"] = "stylesheet" }
                if token.name == "audio" {
                    attributes["controls"] = ""
                    attributes["preload"] = "none"
                }
            }
            let rendered = attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(Self.escape($0.value))\"" }.joined()
            result += "<\(token.name)\(rendered)>"
        }
        return result
    }

    private static func resourceMatches(tag: String, mime: String) -> Bool {
        switch tag {
        case "img": mime.hasPrefix("image/")
        case "audio", "source": mime.hasPrefix("audio/")
        case "link": mime == "text/css"
        default: false
        }
    }

    private mutating func renderText(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[sound:([^\]\r\n]+)\]"#, options: .caseInsensitive) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var rendered = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            rendered += text[cursor..<range.lowerBound]
            let name = HTMLToken.decode(String(text[nameRange]))
            if let url = CardDocument.mediaURL(for: name, scope: scope),
               let decodedName = CardDocument.mediaName(for: url, scope: scope),
               CardDocument.mimeType(for: decodedName)?.hasPrefix("audio/") == true {
                rendered += "<audio controls preload=\"none\" src=\"\(Self.escape(url.absoluteString))\"></audio>"
            } else {
                issues.insert(CardDocument.unsupportedIssue)
            }
            cursor = range.upperBound
            if rendered.utf8.count > CardDocument.maximumDocumentBytes { return rendered }
        }
        rendered += text[cursor...]
        return rendered
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

private struct HTMLToken {
    let name: String
    let closing: Bool
    let attributes: [String: String]
    let end: String.Index

    static func read(_ html: String, at start: String.Index) -> Self? {
        var cursor = html.index(after: start)
        guard cursor < html.endIndex else { return nil }
        let closing = html[cursor] == "/"
        if closing { cursor = html.index(after: cursor) }
        let nameStart = cursor
        while cursor < html.endIndex, html[cursor].isASCII, html[cursor].isLetter || html[cursor].isNumber {
            cursor = html.index(after: cursor)
        }
        guard cursor > nameStart else { return nil }
        let name = html[nameStart..<cursor].lowercased()
        var attributes: [String: String] = [:]
        while cursor < html.endIndex {
            while cursor < html.endIndex, html[cursor].isWhitespace || html[cursor] == "/" { cursor = html.index(after: cursor) }
            guard cursor < html.endIndex else { return nil }
            if html[cursor] == ">" { return Self(name: name, closing: closing, attributes: attributes, end: html.index(after: cursor)) }
            let keyStart = cursor
            while cursor < html.endIndex, !html[cursor].isWhitespace, !["=", ">", "/"].contains(html[cursor]) {
                cursor = html.index(after: cursor)
            }
            guard cursor > keyStart else { return nil }
            let key = html[keyStart..<cursor].lowercased()
            while cursor < html.endIndex, html[cursor].isWhitespace { cursor = html.index(after: cursor) }
            var value = ""
            if cursor < html.endIndex, html[cursor] == "=" {
                cursor = html.index(after: cursor)
                while cursor < html.endIndex, html[cursor].isWhitespace { cursor = html.index(after: cursor) }
                guard cursor < html.endIndex else { return nil }
                if html[cursor] == "\"" || html[cursor] == "'" {
                    let quote = html[cursor]
                    cursor = html.index(after: cursor)
                    let valueStart = cursor
                    while cursor < html.endIndex, html[cursor] != quote { cursor = html.index(after: cursor) }
                    guard cursor < html.endIndex else { return nil }
                    value = String(html[valueStart..<cursor])
                    cursor = html.index(after: cursor)
                } else {
                    let valueStart = cursor
                    while cursor < html.endIndex, !html[cursor].isWhitespace, html[cursor] != ">" { cursor = html.index(after: cursor) }
                    value = String(html[valueStart..<cursor])
                }
            }
            if attributes[key] == nil { attributes[key] = decode(value) }
        }
        return nil
    }

    static func decode(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);"#) else { return value }
        var result = ""
        var cursor = value.startIndex
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let range = Range(match.range, in: value), let bodyRange = Range(match.range(at: 1), in: value) else { continue }
            result += value[cursor..<range.lowerBound]
            let body = String(value[bodyRange])
            let decoded: String?
            switch body {
            case "amp": decoded = "&"
            case "quot": decoded = "\""
            case "apos": decoded = "'"
            case "lt": decoded = "<"
            case "gt": decoded = ">"
            case "nbsp": decoded = "\u{00a0}"
            default:
                let number = body.hasPrefix("#x") ? UInt32(body.dropFirst(2), radix: 16) : UInt32(body.dropFirst())
                decoded = number.flatMap(UnicodeScalar.init).map(String.init)
            }
            result += decoded ?? String(value[range])
            cursor = range.upperBound
        }
        result += value[cursor...]
        return result
    }
}

struct CardContentView: NSViewRepresentable {
    let card: AnkiCard
    let showsAnswer: Bool
    let client: any AnkiReviewing
    var onIssue: @MainActor (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(in: view, card: card, showsAnswer: showsAnswer, client: client, onIssue: onIssue)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var card: AnkiCard?
        private var showsAnswer = false
        private var webView: WKWebView?
        private var media: CardMediaHandler?
        private var documentURL: URL?
        private var initialNavigation = false
        private var onIssue: @MainActor (String) -> Void = { _ in }
        private var reported: Set<String> = []

        func update(in container: NSView, card: AnkiCard, showsAnswer: Bool, client: any AnkiReviewing,
                    onIssue: @escaping @MainActor (String) -> Void) {
            self.onIssue = onIssue
            guard self.card != card || self.showsAnswer != showsAnswer else { return }
            stop()
            self.card = card
            self.showsAnswer = showsAnswer
            let document = CardDocument(card: card, showsAnswer: showsAnswer)
            documentURL = document.url
            initialNavigation = true
            let media = CardMediaHandler(document: document, client: client) { [weak self] issue in self?.report(issue) }
            self.media = media
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            configuration.setURLSchemeHandler(media, forURLScheme: CardDocument.scheme)
            let webView = WKWebView(frame: container.bounds, configuration: configuration)
            webView.autoresizingMask = [.width, .height]
            webView.underPageBackgroundColor = .clear
            webView.appearance = NSAppearance(named: .darkAqua)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            container.addSubview(webView)
            self.webView = webView
            webView.load(URLRequest(url: document.url))
            for issue in document.issues { report(issue) }
        }

        func stop() {
            webView?.pauseAllMediaPlayback(completionHandler: {})
            webView?.setAllMediaPlaybackSuspended(true, completionHandler: {})
            webView?.stopLoading()
            media?.cancel()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView?.removeFromSuperview()
            webView = nil
            media = nil
            card = nil
            documentURL = nil
            initialNavigation = false
            reported.removeAll()
        }

        private func report(_ issue: String) {
            guard reported.insert(issue).inserted, let documentURL else { return }
            Task { @MainActor [weak self] in
                guard let self, self.documentURL == documentURL else { return }
                self.onIssue(issue)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let documentURL else { return .cancel }
            let allowed = CardDocument.allowsNavigation(to: navigationAction.request.url,
                documentURL: documentURL,
                isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                isInitial: initialNavigation, isOther: navigationAction.navigationType == .other)
            if allowed { initialNavigation = false }
            return allowed ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            navigationResponse.isForMainFrame && navigationResponse.response.url == documentURL
                && navigationResponse.response.mimeType == "text/html" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if (error as? URLError)?.code != .cancelled { report(CardDocument.missingMediaIssue) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if (error as? URLError)?.code != .cancelled { report(CardDocument.missingMediaIssue) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { report(CardDocument.missingMediaIssue) }
    }
}

struct CardMediaCache {
    private var data: [String: Data] = [:]
    private var visited: Set<String> = []
    private var failures: Set<String> = []
    private var byteCount = 0

    mutating func begin(_ name: String) throws -> Data? {
        guard AnkiConnectClient.isSafeMediaName(name), CardDocument.mimeType(for: name) != nil else {
            throw AnkiError.invalidMediaName
        }
        if let cached = data[name] { return cached }
        guard !failures.contains(name) else { throw AnkiError.missingMedia }
        guard visited.contains(name) || visited.count < CardDocument.maximumResources else { throw AnkiError.oversizedContent }
        visited.insert(name)
        return nil
    }

    mutating func store(_ bytes: Data, named name: String) throws {
        guard visited.contains(name), bytes.count <= AnkiConnectClient.maximumMediaBytes,
              bytes.count <= CardDocument.maximumCachedBytes - byteCount + (data[name]?.count ?? 0) else {
            throw AnkiError.oversizedContent
        }
        byteCount += bytes.count - (data[name]?.count ?? 0)
        data[name] = bytes
    }

    mutating func fail(_ name: String) { failures.insert(name) }
}

@MainActor private final class CardMediaHandler: NSObject, WKURLSchemeHandler {
    private let document: CardDocument
    private let client: any AnkiReviewing
    private let onIssue: @MainActor (String) -> Void
    private var cache = CardMediaCache()
    private var pending: [String: [ObjectIdentifier: any WKURLSchemeTask]] = [:]
    private var queue: [String] = []
    private var activeName: String?
    private var loader: Task<Void, Never>?
    private var generation = UUID()
    private var cancelled = false

    init(document: CardDocument, client: any AnkiReviewing, onIssue: @escaping @MainActor (String) -> Void) {
        self.document = document
        self.client = client
        self.onIssue = onIssue
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard !cancelled, let url = urlSchemeTask.request.url, urlSchemeTask.request.httpMethod == "GET" else {
            urlSchemeTask.didFailWithError(URLError(.cancelled))
            return
        }
        if url == document.url {
            respond(urlSchemeTask, data: Data(document.html.utf8), mime: "text/html")
            return
        }
        guard let name = CardDocument.mediaName(for: url, scope: document.scope) else {
            onIssue(CardDocument.unsupportedIssue)
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        do {
            if let data = try cache.begin(name) {
                respond(urlSchemeTask, data: data, mime: CardDocument.mimeType(for: name) ?? "application/octet-stream")
                return
            }
            guard pending.values.reduce(0, { $0 + $1.count }) < 64 else { throw AnkiError.oversizedContent }
        } catch {
            onIssue((error as? AnkiError) == .oversizedContent ? CardDocument.sizeIssue : CardDocument.missingMediaIssue)
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        if pending[name] == nil { queue.append(name) }
        pending[name, default: [:]][ObjectIdentifier(urlSchemeTask)] = urlSchemeTask
        pump()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        for name in Array(pending.keys) {
            pending[name]?.removeValue(forKey: id)
            if pending[name]?.isEmpty == true {
                pending.removeValue(forKey: name)
                queue.removeAll { $0 == name }
                if activeName == name {
                    generation = UUID()
                    loader?.cancel()
                    loader = nil
                    activeName = nil
                }
            }
        }
        pump()
    }

    func cancel() {
        cancelled = true
        generation = UUID()
        loader?.cancel()
        loader = nil
        activeName = nil
        let tasks = pending.values.flatMap { $0.values }
        pending.removeAll()
        queue.removeAll()
        cache = CardMediaCache()
        for task in tasks { task.didFailWithError(URLError(.cancelled)) }
    }

    private func pump() {
        guard !cancelled, loader == nil, !queue.isEmpty else { return }
        let name = queue.removeFirst()
        activeName = name
        let generation = generation
        let client = client
        loader = Task { @MainActor [weak self] in
            do {
                var data = try await client.media(named: name)
                try Task.checkCancellation()
                guard let self, self.generation == generation, !self.cancelled else { return }
                if CardDocument.mimeType(for: name) == "text/css" {
                    guard data.count <= CardDocument.maximumDocumentBytes else { throw AnkiError.oversizedContent }
                    guard let css = String(data: data, encoding: .utf8) else { throw AnkiError.invalidResponse }
                    var sanitizer = CardHTMLSanitizer(scope: self.document.scope)
                    data = Data(sanitizer.stylesheet(css).utf8)
                    guard data.count <= CardDocument.maximumDocumentBytes else { throw AnkiError.oversizedContent }
                    for issue in sanitizer.issues { self.onIssue(issue) }
                }
                try self.cache.store(data, named: name)
                self.finish(name: name, data: data, error: nil)
            } catch {
                guard let self, self.generation == generation, !self.cancelled else { return }
                if !(error is CancellationError) {
                    self.cache.fail(name)
                    self.onIssue((error as? AnkiError) == .oversizedContent ? CardDocument.sizeIssue : CardDocument.missingMediaIssue)
                }
                self.finish(name: name, data: nil, error: error)
            }
        }
    }

    private func finish(name: String, data: Data?, error: (any Error)?) {
        let tasks = pending.removeValue(forKey: name) ?? [:]
        loader = nil
        activeName = nil
        for task in tasks.values {
            if let data { respond(task, data: data, mime: CardDocument.mimeType(for: name) ?? "application/octet-stream") }
            else { task.didFailWithError(error ?? URLError(.resourceUnavailable)) }
        }
        pump()
    }

    private func respond(_ task: any WKURLSchemeTask, data: Data, mime: String) {
        guard let url = task.request.url else { return }
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                   textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
