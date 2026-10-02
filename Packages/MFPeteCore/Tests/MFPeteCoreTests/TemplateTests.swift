import Foundation
import Testing
@testable import MFPeteCore

struct RuleTemplateTests {
    @Test func sixTemplatesWithUniqueIDs() {
        #expect(RuleTemplate.all.count == 6)
        #expect(Set(RuleTemplate.all.map(\.id)).count == 6)
        #expect(RuleTemplate.featured.count == 3)
    }

    @Test func eachTemplateBuildsAFreshRuleWithActions() {
        for template in RuleTemplate.all {
            let first = template.makeRule(home: "/Users/me")
            let second = template.makeRule(home: "/Users/me")
            #expect(first.id != second.id)
            #expect(!first.actions.isEmpty)
            #expect(first.name == template.title)
        }
    }

    @Test func templatePathsExpandHome() {
        let rule = RuleTemplate.cleanDownloads.makeRule(home: "/Users/me")
        #expect(rule.scope == [FolderRef(path: "/Users/me/Downloads")])
        #expect(rule.trigger.isSchedule)
    }
}
