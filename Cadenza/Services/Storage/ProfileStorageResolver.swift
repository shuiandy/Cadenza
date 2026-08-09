import Foundation

/// Byte-exact UTF-8 equality for lexical path and filename identity.
/// Swift String equality applies canonical equivalence, which treats NFC
/// and NFD spellings as equal even though their stored bytes differ —
/// identity-conditioned comparisons on recorded paths must not.
enum LexicalPathIdentity {
    static func equals(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// UTF-8 lexicographic order. String `<` compares canonically like
    /// `==`, so NFC/NFD spellings tie and their relative order becomes
    /// nondeterministic; byte order is total over distinct byte strings.
    static func isOrderedBefore(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }
}

/// Resolves `AudioFileReference` values against the profile audio root and
/// produces references for files written under it. This is the single choke
/// point between stored path strings and filesystem URLs; no call site
/// outside the store boundary interprets a raw path string.
struct ProfileStorageResolver: Sendable {

    enum ResolutionError: Error, Equatable {
        /// Empty relative path.
        case emptyReference
        /// Relative path contains "." or ".." components.
        case traversalRejected(String)
        /// Canonical target leaves the canonical root (includes symlinks
        /// inside the root pointing outside it).
        case escapesRoot(String)
        /// `makeReference` was asked for a URL that is not under the root.
        case outsideRoot(String)
    }

    let root: URL

    /// Resolver for the active profile root. Reads the storage location on
    /// every access so custom-directory changes take effect immediately.
    static var current: ProfileStorageResolver {
        ProfileStorageResolver(root: StorageLocationManager.recordingsDirectory)
    }

    init(root: URL) {
        self.root = root
    }

    // MARK: - Read side

    /// Legacy absolute references resolve verbatim — the resolver never
    /// guesses. A basename probe in the current root would identify the
    /// wrong file whenever two recordings share a filename, and resolved
    /// URLs feed deletion, export, sync and playback alike. Rows whose file
    /// genuinely moved are rewritten by the directory-migration relocation
    /// step, which verifies the actual file move it performed.
    func resolveAudio(_ reference: AudioFileReference) throws -> URL {
        switch reference {
        case .relative(let path):
            return try resolveRelative(path)
        case .legacyAbsolute(let path):
            return URL(fileURLWithPath: path)
        }
    }

    /// Returns the lexical path under the root — never the symlink-resolved
    /// target. The canonical form is used for the containment check only:
    /// a symlink at the referenced path keeps the link as the file's
    /// identity, so deleting the reference deletes the link and never the
    /// (possibly shared) target file.
    private func resolveRelative(_ path: String) throws -> URL {
        guard !path.isEmpty else { throw ResolutionError.emptyReference }
        // ".." can splice out of the root before canonicalization sees it,
        // and "." components can mask the traversal — reject both outright.
        let components = (path as NSString).pathComponents
        guard !components.contains(".."), !components.contains(".") else {
            throw ResolutionError.traversalRejected(path)
        }
        // Build lexically on the canonical root, canonicalize a copy for the
        // containment check. Canonicalizing root and target independently
        // breaks for nonexistent targets: Foundation leaves them unresolved
        // while the existing root resolves, so /var vs /private/var
        // spellings of the same location stop matching.
        let canonicalRoot = canonical(root)
        let lexicalTarget = canonicalRoot.appendingPathComponent(path)
        let canonicalTarget = canonical(lexicalTarget)
        guard isInside(root: canonicalRoot, target: canonicalTarget, allowEqual: false) else {
            throw ResolutionError.escapesRoot(path)
        }
        return lexicalTarget
    }

    // MARK: - Write side

    /// Reference for a file under the root — always `.relative` (spec §10.1:
    /// the write path never produces new legacy values).
    ///
    /// The stored subpath is the lexical identity of the URL: symlink
    /// resolution applies to the directory prefix only (spelling
    /// normalization) and never to the leaf, so referencing a symlink
    /// stores the link itself, not its target. Full canonicalization is
    /// still used for the containment check, which rejects links pointing
    /// outside the root.
    func makeReference(for url: URL) throws -> AudioFileReference {
        let canonicalRoot = canonical(root)
        let canonicalTarget = canonical(url)
        guard isInside(root: canonicalRoot, target: canonicalTarget, allowEqual: false) else {
            throw ResolutionError.outsideRoot(url.path)
        }
        let identity = canonical(url.deletingLastPathComponent())
            .appendingPathComponent(url.lastPathComponent)
        guard isInside(root: canonicalRoot, target: identity, allowEqual: false) else {
            throw ResolutionError.outsideRoot(url.path)
        }
        let relativeComponents = identity.pathComponents
            .dropFirst(canonicalRoot.pathComponents.count)
        return .relative(relativeComponents.joined(separator: "/"))
    }

    // MARK: - Lexical identity

    /// Lexical subpath of an absolute URL under the root, or nil when it is
    /// not under the root. Spelling divergence is bridged by normalizing the
    /// directory prefix only — the leaf is never symlink-resolved, and no
    /// canonical containment check is applied. Callers that rewrite or
    /// delete based on this subpath must validate resolvability separately;
    /// this method exists so coverage decisions (e.g. "does this row fall
    /// inside the copied segments tree") never depend on canonical
    /// resolution succeeding.
    func lexicalSubpath(of url: URL) -> String? {
        let canonicalRoot = canonical(root)
        let targetComponents = url.pathComponents
        for candidateRoot in [root, canonicalRoot] {
            let rootComponents = candidateRoot.pathComponents
            if targetComponents.count > rootComponents.count,
               Array(targetComponents.prefix(rootComponents.count)) == rootComponents {
                return targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
            }
        }
        let identity = canonical(url.deletingLastPathComponent())
            .appendingPathComponent(url.lastPathComponent)
        let identityComponents = identity.pathComponents
        let rootComponents = canonicalRoot.pathComponents
        if identityComponents.count > rootComponents.count,
           Array(identityComponents.prefix(rootComponents.count)) == rootComponents {
            return identityComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }
        return nil
    }

    // MARK: - Canonical comparison

    /// resolvingSymlinksInPath alone, deliberately without standardizedFileURL:
    /// standardization strips the /private prefix only for paths it recognizes
    /// as equivalent, which reintroduces spelling divergence between existing
    /// and nonexistent paths. Fully resolved form is stable and idempotent.
    private func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    /// Component-wise containment on canonical URLs. String prefix
    /// comparison would accept "/root-evil" as inside "/root".
    private func isInside(root: URL, target: URL, allowEqual: Bool) -> Bool {
        let rootComponents = root.pathComponents
        let targetComponents = target.pathComponents
        if targetComponents.count < rootComponents.count { return false }
        if !allowEqual && targetComponents.count == rootComponents.count { return false }
        return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }
}
