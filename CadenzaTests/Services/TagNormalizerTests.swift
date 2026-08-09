import Foundation
import Testing
@testable import Cadenza

@Suite("TagNormalizer")
struct TagNormalizerTests {

    // MARK: - formatKey (判等键)

    @Test func formatKeyFoldsSeparatorsAndCase() {
        #expect(TagNormalizer.formatKey("1-on-1") == "1on1")
        #expect(TagNormalizer.formatKey("One_On_One") == "oneonone")
        #expect(TagNormalizer.formatKey("Code Review") == "codereview")
        #expect(TagNormalizer.formatKey("设计 评审") == "设计评审")
    }

    @Test func formatKeyPreservesSemanticSymbols() {
        #expect(TagNormalizer.formatKey("c++") == "c++")
        #expect(TagNormalizer.formatKey("c#") == "c#")
        #expect(TagNormalizer.formatKey("a/b") == "a/b")
    }

    @Test func formatKeyFoldsFullwidthAndDashes() {
        #expect(TagNormalizer.formatKey("１on１") == "1on1")          // 全角数字
        #expect(TagNormalizer.formatKey("one\u{2013}on\u{2014}one") == "oneonone")  // en/em dash
    }

    @Test func formatKeyDropsNonAllowlistedSymbols() {
        #expect(TagNormalizer.formatKey("🔥") == "")
        #expect(TagNormalizer.formatKey("!!!") == "")
        #expect(TagNormalizer.formatKey("design🔥") == "design")
    }

    // MARK: - normalize: 变体合并

    @Test func normalizeCollapsesOneOnOneVariants() {
        let n = TagNormalizer()
        for raw in ["1on1", "1-on-1", "one_on_one", "oneonone", "1to1", "121", "1:1", "1/1", "1 - 1", "One On One"] {
            #expect(n.normalize(raw) == "1on1", "\(raw) should normalize to 1on1")
        }
    }

    @Test func normalizeDoesNotMergeDistinctSemantics() {
        let n = TagNormalizer()
        #expect(n.normalize("c++") == "c++")
        #expect(n.normalize("c") == "c")
        #expect(n.normalize("a/b") == "a/b")
    }

    @Test func normalizeRejectsJunk() {
        let n = TagNormalizer()
        #expect(n.normalize("!!!") == nil)
        #expect(n.normalize("🔥") == nil)
        #expect(n.normalize("2024") == nil)       // 纯数字无 alias
        #expect(n.normalize("11") == nil)         // 裸 11 不是 1on1
        #expect(n.normalize("") == nil)
        #expect(n.normalize("   ") == nil)
        #expect(n.normalize(String(repeating: "x", count: 65)) == nil)  // 超长
    }

    @Test func normalizeSanitizesSurface() {
        let n = TagNormalizer()
        #expect(n.normalize("design🔥") == "design")
        #expect(n.normalize("Code Review") == "code-review")
    }

    @Test func normalizeReusesVocabSurface() {
        let n = TagNormalizer()
        let vocab = ["codereview": "code-review"]
        #expect(n.normalize("Code Review", vocab: vocab) == "code-review")
        #expect(n.normalize("codereview", vocab: vocab) == "code-review")
    }

    // MARK: - blocklist

    @Test func normalizeDropsBlocklistedTags() {
        let n = TagNormalizer(blocklist: ["security", "会议"])
        #expect(n.normalize("Security") == nil)
        #expect(n.normalize("security") == nil)
        #expect(n.normalize("会议") == nil)
        #expect(n.normalize("standup") == "standup")
    }

    @Test func normalizeBlocksAliasedTagByCanonical() {
        // one_on_one → alias 1on1，blocklist 含 1on1 → 须丢弃(canonical 侧拦截)
        let n = TagNormalizer(blocklist: ["1on1"])
        #expect(n.normalize("one_on_one") == nil)
        #expect(n.normalize("1-on-1") == nil)
    }

    // MARK: - canonicalize: 批内去重

    @Test func canonicalizeMergesVariantsInBatch() {
        let n = TagNormalizer()
        #expect(n.canonicalize(["Code Review", "codereview"]) == ["code-review"])
    }

    @Test func canonicalizeMergesCJKSpacing() {
        let n = TagNormalizer()
        #expect(n.canonicalize(["设计 评审", "设计评审"]) == ["设计评审"])
    }

    @Test func canonicalizeDropsBlockedAndKeepsOrder() {
        let n = TagNormalizer(blocklist: ["meeting"])
        #expect(n.canonicalize(["standup", "meeting", "1on1", "1-on-1"]) == ["standup", "1on1"])
    }

    @Test func canonicalizeAlignsToVocab() {
        let n = TagNormalizer()
        let vocab = ["1on1": "1on1", "codereview": "code-review"]
        #expect(n.canonicalize(["One_On_One", "Code Review"], vocab: vocab) == ["1on1", "code-review"])
    }

    // MARK: - scriptBucket

    @Test func scriptBucketClassifies() {
        #expect(TagNormalizer.scriptBucket("设计评审") == .cjk)
        #expect(TagNormalizer.scriptBucket("1on1") == .universal)        // 含数字
        #expect(TagNormalizer.scriptBucket("retro") == .universal)       // ≤6
        #expect(TagNormalizer.scriptBucket("code-review") == .latin)   // 长、无数字
        #expect(TagNormalizer.scriptBucket("standup") == .latin)         // 7、无数字
    }

    @Test func scriptBucketTreatsNonCJKScriptsCorrectly() {
        #expect(TagNormalizer.scriptBucket("réunion") == .latin)     // 重音拉丁，7 chars → latin（非 CJK）
        #expect(TagNormalizer.scriptBucket("café") == .universal)    // 重音拉丁，≤6
        #expect(TagNormalizer.scriptBucket("日本語") == .cjk)
        #expect(TagNormalizer.scriptBucket("회의") == .cjk)           // Hangul
    }

    @Test func defaultSurfaceHyphenatesNonCJK() {
        let n = TagNormalizer()
        #expect(n.normalize("réunion sécurité") == "réunion-sécurité")  // 折连字符，不是去空格
        #expect(n.normalize("设计 评审") == "设计评审")                  // 纯 CJK 去空格
    }

    // MARK: - 英→中会议/业务词映射（v2）

    @Test func aliasTranslatesMeetingAndBusinessWords() {
        let n = TagNormalizer()
        #expect(n.normalize("planning") == "规划")
        #expect(n.normalize("compliance") == "合规")
        #expect(n.normalize("Design-Review") == "设计评审")
        #expect(n.normalize("product-security") == "产品安全")
        #expect(n.normalize("secrets-management") == "密钥管理")
        #expect(n.normalize("vulnerabilities") == "vulnerability")   // 单复数合并
        #expect(n.normalize("policies") == "策略")
        #expect(n.normalize("strategy") == "战略")                    // 与 policy→策略 分开
    }

    @Test func jargonAndTechTermsStayEnglish() {
        let n = TagNormalizer()
        #expect(n.normalize("1on1") == "1on1")        // jargon 保留
        #expect(n.normalize("standup") == "standup")  // jargon 保留(不在表)
        #expect(n.normalize("sync") == "sync")
        #expect(n.normalize("demo") == "demo")
        #expect(n.normalize("vulnerability") == "vulnerability")  // 技术词保留
        #expect(n.normalize("cycode") == "cycode")
        #expect(n.normalize("devsecops") == "devsecops")
    }
}
