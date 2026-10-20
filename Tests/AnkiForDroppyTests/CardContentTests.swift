import Foundation
import Testing
@testable import AnkiForDroppy

struct CardContentTests {
    private func card(question: String = "<div class='cloze'>Question</div>", answer: String = "<hr id=answer>Secret answer",
                      css: String = ".cloze { font-weight: bold; }", fields: [String: AnkiCard.Field] = [:]) -> AnkiCard {
        AnkiCard(cardId: 42, question: question, answer: answer, css: css, deckName: "Deck", fields: fields)
    }

    @Test func questionDoesNotContainAnswerOrRawFields() {
        let document = CardDocument(card: card(fields: ["Back": .init(value: "Hidden raw field")]), showsAnswer: false, scope: "card")
        #expect(document.html.contains("<div class=\"cloze\">Question</div>"))
        #expect(document.html.contains(".cloze { font-weight: bold; }"))
        #expect(!document.html.contains("Secret answer"))
        #expect(!document.html.contains("Hidden raw field"))
        #expect(document.issues.isEmpty)
    }

    @Test func revealUsesFullAnswerWithoutReconstructingFields() {
        let document = CardDocument(card: card(answer: "<div>Full front</div><hr id=answer><b>Full back</b>"), showsAnswer: true)
        #expect(document.html.contains("<div>Full front</div><hr id=\"answer\"><b>Full back</b>"))
        #expect(!document.html.contains(">Question<"))
    }

    @Test func restrictivePolicyPrecedesUntrustedContent() throws {
        let document = CardDocument(card: card(question: "<meta http-equiv=refresh content='0;url=https://example.com'><script>secretScript()</script><p>Safe</p>"), showsAnswer: false)
        let policy = try #require(document.html.range(of: "Content-Security-Policy"))
        let content = try #require(document.html.range(of: "<p>Safe</p>"))
        #expect(policy.lowerBound < content.lowerBound)
        for directive in ["default-src 'none'", "script-src 'none'", "connect-src 'none'", "frame-src 'none'",
                          "object-src 'none'", "form-action 'none'", "base-uri 'none'", "worker-src 'none'"] {
            #expect(document.html.contains(directive))
        }
        #expect(!document.html.contains("secretScript"))
        #expect(!document.html.contains("http-equiv=refresh"))
        #expect(!document.html.contains("https://example.com"))
        #expect(document.issues.contains(CardDocument.unsupportedIssue))
    }

    @Test func removesActiveElementsAndDangerousAttributes() {
        let html = """
        <img src='picture.png' onerror='steal()' srcset='https://example.com/a.png 2x'>
        <iframe src='file:///etc/passwd'>Hidden frame</iframe><object>Hidden object</object>
        <svg><script>hidden()</script></svg><form action='https://example.com'><input id=typeans></form>
        <a href='https://example.com' target='_blank'>Link text</a>
        <link rel=dns-prefetch href='//example.com'><video src=movie.mp4 autoplay></video>
        """
        let document = CardDocument(card: card(question: html), showsAnswer: false, scope: "card")
        #expect(document.html.contains("src=\"anki-card-media://card/picture.png\""))
        #expect(document.html.contains("<a>Link text</a>"))
        for forbidden in ["onerror", "srcset", "<iframe", "<object", "<svg", "<script", "<form", "<input", "<video", "dns-prefetch", "steal()", "Hidden frame", "Hidden object", "https://example.com"] {
            #expect(!document.html.contains(forbidden))
        }
        #expect(document.issues.contains(CardDocument.unsupportedIssue))
    }

    @Test func stylesheetCannotBreakOutOfItsElement() {
        let css = "body::after { content: '</style><script>bad()</script>'; }"
        let document = CardDocument(card: card(css: css), showsAnswer: false)
        #expect(!document.html.contains("<script>"))
        #expect(document.html.contains("\\3c /style>"))
        #expect(document.html.components(separatedBy: "</style>").count == 2)
    }

    @Test func stylesheetsFontsAndImagesResolveOnlyThroughScopedScheme() {
        let html = "<link rel=stylesheet href='_style.css'><img src='image%20one.png' alt='A &amp; B'>"
        let document = CardDocument(card: card(question: html, css: "@font-face { font-family: custom; src: url('_font.woff2'); }"), showsAnswer: false, scope: "card")
        #expect(document.html.contains("href=\"anki-card-media://card/_style.css\""))
        #expect(document.html.contains("src=\"anki-card-media://card/image%20one.png\""))
        #expect(document.html.contains("alt=\"A &amp; B\""))
        #expect(document.html.contains("url('_font.woff2')"))
        #expect(document.issues.isEmpty)
    }

    @Test(arguments: ["https://example.com/a.png", "//example.com/a.png", "file:///tmp/a.png", "data:image/png;base64,AA==",
                      "../a.png", "%2e%2e%2fa.png", "a%5cb.png", "%252e%252e%252fa.png", "a.png?x=1", "a.png#x",
                      "a.svg", "a.html", "a.js", "", ".", "..", "a%00.png"])
    func rejectsUnsafeMediaReferences(_ reference: String) {
        #expect(CardDocument.mediaURL(for: reference, scope: "card") == nil)
    }

    @Test(arguments: ["plain.png", "image one.jpeg", "_style.css", "音声.mp3", "_font.woff2", "a&amp;b.gif"])
    func safeMediaNamesRoundTrip(_ name: String) throws {
        let url = try #require(CardDocument.mediaURL(for: name, scope: "card"))
        #expect(CardDocument.mediaName(for: url, scope: "card") == name)
        #expect(CardDocument.mediaName(for: url, scope: "different-card") == nil)
    }

    @Test(arguments: ["anki-card-media://card/%2e%2e%2fsecret.png", "anki-card-media://card/a%5cb.png",
                      "anki-card-media://card/%252fsecret.png", "anki-card-media://card/a%00.png",
                      "anki-card-media://card/a.png?query", "anki-card-media://card/a.png#fragment",
                      "anki-card-media://user@card/a.png", "anki-card-media://card:80/a.png",
                      "https://card/a.png", "file:///a.png", "anki-card-media://card/sub/a.png"])
    func rejectsForgedResourceRequests(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(CardDocument.mediaName(for: url, scope: "card") == nil)
    }

    @Test func mimeAllowlistExcludesActiveDocuments() {
        #expect(CardDocument.mimeType(for: "A.PNG") == "image/png")
        #expect(CardDocument.mimeType(for: "sound.mp3") == "audio/mpeg")
        #expect(CardDocument.mimeType(for: "style.css") == "text/css")
        #expect(CardDocument.mimeType(for: "font.woff2") == "font/woff2")
        for name in ["page.html", "image.svg", "script.js", "document.pdf", "movie.mp4", "unknown"] {
            #expect(CardDocument.mimeType(for: name) == nil)
        }
    }

    @Test func portableSoundRequiresExplicitPlayback() {
        let html = "[sound:voice.mp3]<audio src='other.wav' autoplay loop></audio>"
        let document = CardDocument(card: card(question: html), showsAnswer: false, scope: "card")
        #expect(document.html.contains("<audio controls preload=\"none\" src=\"anki-card-media://card/voice.mp3\"></audio>"))
        #expect(document.html.contains("controls=\"\" preload=\"none\" src=\"anki-card-media://card/other.wav\""))
        #expect(!document.html.contains("autoplay"))
        #expect(!document.html.contains("loop"))
    }

    @Test func extractedSoundWarnsWithoutLeakingHiddenField() {
        let document = CardDocument(card: card(fields: ["Back": .init(value: "Secret answer [sound:secret-answer.mp3]")]), showsAnswer: false)
        #expect(document.issues == [CardDocument.unsupportedIssue])
        #expect(!document.html.contains("Secret answer"))
        #expect(!document.html.contains("secret-answer"))
    }

    @Test(arguments: ["<script>MathJax()</script>", "\\(x^2\\)", "<input id=typeans>", "{{type:Back}}", "[anki:play:q:0]",
                      "<img src='https://example.com/image.png'>", "<img src='missing.svg'>"])
    func unsupportedContentReportsGenericWarning(_ html: String) {
        let document = CardDocument(card: card(question: html), showsAnswer: false)
        #expect(document.issues.contains(CardDocument.unsupportedIssue))
        #expect(document.issues.allSatisfy { !$0.contains(html) })
    }

    @Test func malformedMarkupCannotIntroduceActiveContent() {
        let document = CardDocument(card: card(question: "Text <img src='unterminated <script>alert(1)</script>"), showsAnswer: false)
        #expect(!document.html.contains("<script>"))
        #expect(document.html.contains("&lt;script>"))
        #expect(document.issues.contains(CardDocument.unsupportedIssue))
    }

    @Test func oversizedContentUsesBoundedFallbackWithoutAnswer() {
        let value = String(repeating: "x", count: CardDocument.maximumDocumentBytes + 1)
        let document = CardDocument(card: card(question: value), showsAnswer: false)
        #expect(document.issues.contains(CardDocument.sizeIssue))
        #expect(document.html.utf8.count < 4_096)
        #expect(!document.html.contains("Secret answer"))
    }

    @Test func expandedSoundMarkupAlsoHasADocumentLimit() {
        let html = String(repeating: "[sound:voice.mp3]", count: 20_000)
        let document = CardDocument(card: card(question: html), showsAnswer: false)
        #expect(document.issues.contains(CardDocument.sizeIssue))
        #expect(document.html.utf8.count < 4_096)
    }

    @Test func remoteCSSIsBlockedByPolicyAndReportsFallback() {
        let document = CardDocument(card: card(css: "@import 'https://example.com/style.css'; div { background: url(file:///tmp/a.png); }"), showsAnswer: false, scope: "card")
        #expect(document.issues.contains(CardDocument.unsupportedIssue))
        #expect(document.html.contains("img-src anki-card-media://card;"))
        #expect(document.html.contains("style-src 'unsafe-inline' anki-card-media://card;"))
        #expect(!document.html.contains("img-src https:"))
    }

    @Test func navigationPermitsOnlyInitialMainDocument() throws {
        let url = try #require(URL(string: "anki-card-media://card/__document__"))
        #expect(CardDocument.allowsNavigation(to: url, documentURL: url, isMainFrame: true, isInitial: true, isOther: true))
        #expect(!CardDocument.allowsNavigation(to: url, documentURL: url, isMainFrame: false, isInitial: true, isOther: true))
        #expect(!CardDocument.allowsNavigation(to: url, documentURL: url, isMainFrame: true, isInitial: false, isOther: true))
        #expect(!CardDocument.allowsNavigation(to: url, documentURL: url, isMainFrame: true, isInitial: true, isOther: false))
        for target in ["about:blank", "https://example.com", "file:///tmp/file", "anki-card-media://card/a.png"] {
            #expect(!CardDocument.allowsNavigation(to: URL(string: target), documentURL: url, isMainFrame: true, isInitial: true, isOther: true))
        }
    }

    @Test func cacheEnforcesUniqueResourceLimitAndReusesBytes() throws {
        var cache = CardMediaCache()
        for index in 0..<CardDocument.maximumResources {
            let name = "\(index).png"
            #expect(try cache.begin(name) == nil)
            try cache.store(Data([UInt8(index)]), named: name)
        }
        #expect(try cache.begin("0.png") == Data([0]))
        #expect(throws: AnkiError.oversizedContent) { try cache.begin("overflow.png") }
    }

    @Test func cacheEnforcesIndividualAndTotalByteLimits() throws {
        var cache = CardMediaCache()
        _ = try cache.begin("oversized.png")
        #expect(throws: AnkiError.oversizedContent) {
            try cache.store(Data(count: AnkiConnectClient.maximumMediaBytes + 1), named: "oversized.png")
        }
        for name in ["one.png", "two.png"] {
            _ = try cache.begin(name)
            try cache.store(Data(count: AnkiConnectClient.maximumMediaBytes), named: name)
        }
        _ = try cache.begin("three.png")
        #expect(throws: AnkiError.oversizedContent) { try cache.store(Data([1]), named: "three.png") }
    }

    @Test func failedResourcesAreNotRetriedAndNewCardsHaveEmptyCache() throws {
        var cache = CardMediaCache()
        _ = try cache.begin("missing.png")
        cache.fail("missing.png")
        #expect(throws: AnkiError.missingMedia) { try cache.begin("missing.png") }
        _ = try cache.begin("image.png")
        try cache.store(Data([1]), named: "image.png")
        var nextCard = CardMediaCache()
        #expect(try nextCard.begin("image.png") == nil)
        #expect(throws: AnkiError.invalidMediaName) { try nextCard.begin("../file.png") }
    }
}
