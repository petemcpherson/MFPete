import Foundation
import Testing
@testable import MFPeteCore

private let renderer = PatternRenderer(calendar: utcCalendar)

/// invoice.pdf in "Downloads", added 2026-03-05 08:09:10 UTC,
/// created 2025-12-31, modified 2026-02-14.
private let sample = FileSnapshot(
    url: URL(fileURLWithPath: "/Users/me/Downloads/invoice.pdf"),
    dateAdded: Date(timeIntervalSince1970: 1_772_698_150),
    dateCreated: Date(timeIntervalSince1970: 1_767_139_200),
    dateModified: Date(timeIntervalSince1970: 1_771_027_200)
)

struct PatternRendererTests {
    @Test(arguments: [
        ("{name}", "invoice"),
        ("{extension}", "pdf"),
        ("{fullname}", "invoice.pdf"),
        ("{date-added}", "2026-03-05"),
        ("{date-created}", "2025-12-31"),
        ("{date-modified}", "2026-02-14"),
        ("{year}", "2026"),
        ("{month}", "03"),
        ("{day}", "05"),
        ("{today}", "2026-10-01"),
        ("{time}", "120000"),
        ("{counter}", "1"),
        ("{folder}", "Downloads"),
        ("{kind}", "PDF"),
    ])
    func everyToken(pattern: String, expected: String) {
        #expect(renderer.render(pattern, snapshot: sample, now: testNow) == expected)
    }

    @Test func tokenListMatchesSpec() {
        #expect(PatternRenderer.tokens.count == 14)
        for token in PatternRenderer.tokens {
            #expect(renderer.render("{\(token)}", snapshot: sample, now: testNow) != "{\(token)}")
        }
    }

    @Test func combinedPattern() {
        #expect(renderer.render("{name}-{date-added}.{extension}", snapshot: sample, now: testNow) == "invoice-2026-03-05.pdf")
        #expect(renderer.render("{name} {counter}.{extension}", snapshot: sample, now: testNow, counter: 7) == "invoice 7.pdf")
    }

    @Test func sanitizesColonAndSlash() {
        #expect(renderer.render("{name}: draft/v2", snapshot: sample, now: testNow) == "invoice- draft-v2")
        #expect(PatternRenderer.sanitize("..") == "-")
    }

    @Test func unknownTokensRenderLiterally() {
        #expect(renderer.render("{name}-{bogus}", snapshot: sample, now: testNow) == "invoice-{bogus}")
        #expect(PatternRenderer.unknownTokens(in: "{name}{bogus}{x}") == ["bogus", "x"])
        #expect(PatternRenderer.unknownTokens(in: "{name}.{extension}").isEmpty)
        // Unbalanced braces are literal text.
        #expect(renderer.render("{name", snapshot: sample, now: testNow) == "{name")
        #expect(renderer.render("{}", snapshot: sample, now: testNow) == "{}")
    }

    @Test func emptyExtensionDropsDot() {
        let makefile = FileSnapshot(url: URL(fileURLWithPath: "/tmp/Makefile"))
        #expect(renderer.render("{name}.{extension}", snapshot: makefile, now: testNow) == "Makefile")
        #expect(renderer.render("{name}-old", snapshot: makefile, now: testNow) == "Makefile-old")
    }

    @Test func pathSegments() {
        #expect(renderer.renderPathSegments("{year}/{month}", snapshot: sample, now: testNow) == ["2026", "03"])
        #expect(renderer.renderPathSegments("{extension}", snapshot: sample, now: testNow) == ["pdf"])
        // Slashes inside a token value cannot create extra levels; ":" is replaced.
        #expect(renderer.renderPathSegments("a:b//{kind}/", snapshot: sample, now: testNow) == ["a-b", "PDF"])
        #expect(renderer.renderPathSegments("../{name}", snapshot: sample, now: testNow) == ["-", "invoice"])
    }

    @Test func notificationTextIsNotSanitized() {
        #expect(renderer.renderText("Saved: {fullname}", snapshot: sample, now: testNow) == "Saved: invoice.pdf")
    }

    @Test func containsCounter() {
        #expect(PatternRenderer.containsCounter("{name} {counter}"))
        #expect(!PatternRenderer.containsCounter("{name}"))
    }
}

struct ConflictResolverTests {
    @Test func keepBothFinderStyle() throws {
        let sandbox = try Sandbox()
        try sandbox.file("out/report.pdf")
        try sandbox.file("out/report 2.pdf")
        try sandbox.file("out/Makefile")
        try sandbox.file("out/archive.tar.gz")
        try sandbox.folder("out/Photos")
        let out = sandbox.root.appendingPathComponent("out")
        let resolver = ConflictResolver()

        #expect(resolver.resolve(destination: out.appendingPathComponent("new.pdf"), policy: .keepBoth)
            == .proceed(out.appendingPathComponent("new.pdf")))
        #expect(resolver.resolve(destination: out.appendingPathComponent("report.pdf"), policy: .keepBoth)
            == .proceed(out.appendingPathComponent("report 3.pdf")))
        #expect(resolver.resolve(destination: out.appendingPathComponent("Makefile"), policy: .keepBoth)
            == .proceed(out.appendingPathComponent("Makefile 2")))
        #expect(resolver.resolve(destination: out.appendingPathComponent("archive.tar.gz"), policy: .keepBoth)
            == .proceed(out.appendingPathComponent("archive.tar 2.gz")))
        #expect(resolver.resolve(destination: out.appendingPathComponent("Photos", isDirectory: true), policy: .keepBoth)
            == .proceed(out.appendingPathComponent("Photos 2", isDirectory: true)))
    }

    @Test func replaceAndSkip() throws {
        let sandbox = try Sandbox()
        let existing = try sandbox.file("out/report.pdf")
        let resolver = ConflictResolver()
        #expect(resolver.resolve(destination: existing, policy: .replace) == .replaceAfterTrashing(existing))
        #expect(resolver.resolve(destination: existing, policy: .skip) == .skip)
    }

    @Test func sameItemIsNotAConflict() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("out/report.pdf")
        let resolver = ConflictResolver()
        #expect(resolver.resolve(destination: file, policy: .skip, source: file) == .proceed(file))
        // Case-only rename on a case-insensitive volume.
        let upper = file.deletingLastPathComponent().appendingPathComponent("REPORT.pdf")
        if FileManager.default.fileExists(atPath: upper.path) {
            #expect(resolver.resolve(destination: upper, policy: .skip, source: file) == .proceed(upper))
        }
    }

    @Test func virtualExistence() {
        let taken: Set<String> = ["/v/a.txt", "/v/a 2.txt"]
        let resolver = ConflictResolver { taken.contains($0.path) }
        #expect(resolver.resolve(destination: URL(fileURLWithPath: "/v/a.txt"), policy: .keepBoth)
            == .proceed(URL(fileURLWithPath: "/v/a 3.txt")))
    }
}
