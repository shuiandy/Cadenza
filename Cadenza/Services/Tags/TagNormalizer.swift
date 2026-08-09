import Foundation

/// Deterministic tag normalization: collapses spelling/separator/case/width variants,
/// drops blocklisted tags, aligns to existing library surfaces. Pure, testable, no I/O.
/// Serves the store, MCP, and UI filters (not AI-only).
///
/// Two-layer key design:
/// - `formatKey` is the **equality key**: folds separators/case/width/dashes, keeps
///   letters+numbers+semantic symbols (`+ # : / . &`). So `one-on-one` and `oneonone`
///   merge, but `c++` ≠ `c` and `a/b` ≠ `ab`.
/// - `defaultSurface` is the **display form**: collapses separator runs to a single `-`
///   (pure-CJK drops separators entirely).
struct TagNormalizer {
    private let blocklistKeys: Set<String>

    init(blocklist: [String] = []) {
        self.blocklistKeys = Set(blocklist.map { TagNormalizer.formatKey($0) }.filter { !$0.isEmpty })
    }

    // MARK: - Character sets

    /// Semantic ASCII symbols kept in keys/surfaces (NOT treated as separators).
    private static let semanticSymbols: Set<Character> = ["+", "#", ":", "/", ".", "&"]

    /// Dash variants unified to ASCII "-" (hyphen, figure/en/em dash, minus, fullwidth, etc.).
    private static let dashChars: Set<Character> = [
        "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}",
        "\u{2015}", "\u{2043}", "\u{2212}", "\u{FE63}", "\u{FF0D}"
    ]

    /// Shared front of both keys & surfaces: trim → NFC → fullwidth→halfwidth → lowercase → unify dashes.
    private static func prepare(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let nfc = trimmed.precomposedStringWithCanonicalMapping
        let halfwidth = nfc.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? nfc
        let lowered = halfwidth.lowercased()
        return String(lowered.map { dashChars.contains($0) ? "-" : $0 })
    }

    // MARK: - Keys & surfaces

    /// Equality key: keep only letters/numbers/semantic-symbols; drop everything else
    /// (separators, emoji, other punctuation).
    static func formatKey(_ raw: String) -> String {
        String(prepare(raw).filter { $0.isLetter || $0.isNumber || semanticSymbols.contains($0) })
    }

    /// Display form: sanitize to allowlist + separators, then collapse separator runs to a
    /// single "-" (ASCII context) or drop them (pure-CJK).
    static func defaultSurface(_ raw: String) -> String {
        let kept = prepare(raw).filter {
            $0.isLetter || $0.isNumber || semanticSymbols.contains($0)
                || $0 == "_" || $0 == "-" || $0.isWhitespace
        }
        // Drop separators entirely only for pure-CJK content; everything else (Latin,
        // accented Latin, Cyrillic, mixed) collapses separator runs to a single "-".
        let hasCJK = kept.contains(where: Self.isCJKScript)
        let hasOtherWord = kept.contains { ($0.isLetter && !Self.isCJKScript($0)) || $0.isNumber }
        if hasCJK && !hasOtherWord {
            return String(kept.filter { !($0 == "_" || $0 == "-" || $0.isWhitespace) })
        }
        var out = ""
        var lastWasSep = false
        for ch in kept {
            if ch == "_" || ch == "-" || ch.isWhitespace {
                if !lastWasSep && !out.isEmpty { out.append("-") }
                lastWasSep = true
            } else {
                out.append(ch)
                lastWasSep = false
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // MARK: - Alias

    /// formatKey → canonical surface. Two roles:
    /// 1) collapse spelling/separator/plural variants;
    /// 2) curated English→Chinese canonicalization of common meeting/business words.
    /// Technical terms, tools, acronyms, and common English jargon (1on1/standup/sync/demo/sprint)
    /// are intentionally absent → they stay English. Extending this map requires bumping
    /// `tagNormalizationVersion` in RecordingsStore so the migration re-runs.
    private static let aliasByKey: [String: String] = [
        // 1on1 family (kept English — common jargon)
        "1on1": "1on1", "oneonone": "1on1", "onetoone": "1on1",
        "one2one": "1on1", "1to1": "1on1", "121": "1on1",
        // singular/plural & spelling merges
        "vulnerabilities": "vulnerability", "pentesting": "pentest", "policies": "策略",
        // meeting / process words → Chinese
        "planning": "规划", "handoff": "交接", "training": "培训", "hiring": "招聘",
        "scheduling": "排期", "allhands": "全员会", "designreview": "设计评审",
        "brainstorm": "头脑风暴", "tracking": "跟踪", "tracker": "跟踪", "followup": "跟进",
        "agile": "敏捷", "engineering": "工程", "migration": "迁移", "testing": "测试",
        "debugging": "调试", "status": "状态", "statusupdate": "状态更新",
        "career": "职业发展", "leave": "请假", "remotework": "远程办公",
        "performancereview": "绩效评估", "capacityplanning": "容量规划",
        "workprogress": "工作进展", "lifesharing": "生活分享", "teamupdate": "团队更新",
        "teamalignment": "团队对齐", "weeklysync": "周同步", "goalsetting": "目标设定",
        "branches": "分支", "branching": "分支", "interruption": "中断",
        "curation": "内容整理", "program": "项目",
        // business / general concept words → Chinese
        "reporting": "报告", "metrics": "指标", "strategy": "战略", "policy": "策略",
        "operations": "运营", "procurement": "采购", "audit": "审计", "integration": "集成",
        "workflow": "工作流", "remediation": "整改", "scanning": "扫描", "triage": "分流",
        "forecast": "预测", "funding": "资金", "vendors": "供应商", "calendar": "日程",
        "dashboard": "仪表板", "opensource": "开源", "architecture": "架构",
        "backend": "后端", "workload": "工作量", "governance": "治理",
        "automation": "自动化", "compliance": "合规", "secrets": "密钥",
        "secretsmanagement": "密钥管理", "assetmanagement": "资产管理",
        "toolevaluation": "工具评估", "datadrift": "数据漂移", "rulestranslation": "规则转换",
        "identity": "身份", "permissions": "权限",
        // security business concepts → Chinese (tools/acronyms stay English)
        "piplanning": "PI规划", "aisecurity": "AI安全", "supplychainsecurity": "供应链安全",
        "productsecurity": "产品安全", "prodsec": "产品安全", "cybersecurity": "网络安全",
        "securityops": "安全运营"
    ]

    /// raw-pattern for `1:1` / `1/1` / `1-1` / `1 - 1` (their formatKey collapses to `1:1`/`1/1`/`11`,
    /// so they must match on the prepared string, NOT the formatKey).
    private static let oneOnOnePattern = "^1\\s*[:/\\-]\\s*1$"

    private static func aliasMatch(_ raw: String) -> String? {
        if let a = aliasByKey[formatKey(raw)] { return a }
        if prepare(raw).range(of: oneOnOnePattern, options: .regularExpression) != nil { return "1on1" }
        return nil
    }

    // MARK: - Normalize

    /// `vocab`: [formatKey: canonicalSurface] of existing library tags, to align new tags to
    /// the surface already in use.
    func normalize(_ raw: String, vocab: [String: String] = [:]) -> String? {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base.count <= 64 else { return nil }   // empty / over-long → reject

        let key = TagNormalizer.formatKey(raw)
        guard key.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }  // pure punctuation/emoji
        if blocklistKeys.contains(key) { return nil }               // blocklist: raw side

        let canonical: String
        if let aliased = TagNormalizer.aliasMatch(raw) {
            canonical = aliased
        } else if key.allSatisfy({ $0.isNumber }) {
            return nil                                              // all-digits w/o alias → reject
        } else if let reused = vocab[key] {
            canonical = reused                                      // reuse library surface
        } else {
            canonical = TagNormalizer.defaultSurface(raw)
        }
        guard !canonical.isEmpty else { return nil }
        if blocklistKeys.contains(TagNormalizer.formatKey(canonical)) { return nil }  // blocklist: canonical side
        return canonical
    }

    /// Normalize a batch, deduping by `formatKey(canonical)` (first surface wins). Used for
    /// per-recording writes and migration.
    func canonicalize(_ tags: [String], vocab: [String: String] = [:]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in tags {
            guard let canonical = normalize(raw, vocab: vocab) else { continue }
            let key = TagNormalizer.formatKey(canonical)
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(canonical)
        }
        return result
    }

    // MARK: - Script bucket (language-aware vocabulary filtering)

    enum ScriptBucket: Sendable { case cjk, latin, universal }

    /// Classify a tag for language filtering: non-ASCII letters → cjk; short or has-digit ASCII →
    /// universal (acronyms/codes/product names, fed to both languages); else latin.
    static func scriptBucket(_ tag: String) -> ScriptBucket {
        if tag.contains(where: isCJKScript) { return .cjk }
        if tag.count <= 6 || tag.contains(where: { $0.isNumber }) { return .universal }
        return .latin
    }

    /// True if the character belongs to a CJK script (Han / Hiragana / Katakana / Hangul).
    /// Accented Latin, Cyrillic, Arabic, etc. are NOT CJK.
    static func isCJKScript(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
                || (0x3040...0x30FF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
                || (0x1100...0x11FF).contains(s.value) || (0xF900...0xFAFF).contains(s.value)
        }
    }
}

/// A distinct tag with its usage count across the library.
struct TagCountDTO: Sendable, Hashable {
    let tag: String
    let count: Int
}
