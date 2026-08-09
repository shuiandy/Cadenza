import Testing
@testable import Cadenza

@Suite("Recordings Empty State")
struct RecordingsEmptyStateTests {
    @Test func activeSearchHasSearchingAndNoMatchStates() {
        #expect(RecordingsEmptyStateKind.resolve(
            isLoadingLibrary: false,
            isSearching: true,
            searchQuery: "missing",
            hasSmartFolder: false
        ) == .searching)
        #expect(RecordingsEmptyStateKind.resolve(
            isLoadingLibrary: false,
            isSearching: false,
            searchQuery: "missing",
            hasSmartFolder: false
        ) == .noSearchMatches)
    }

    @Test func blankSearchPreservesLibraryAndSmartFolderEmptyStates() {
        #expect(RecordingsEmptyStateKind.resolve(
            isLoadingLibrary: false,
            isSearching: false,
            searchQuery: "  \n",
            hasSmartFolder: false
        ) == .library)
        #expect(RecordingsEmptyStateKind.resolve(
            isLoadingLibrary: false,
            isSearching: false,
            searchQuery: "",
            hasSmartFolder: true
        ) == .smartFolder)
        #expect(!RecordingSearchDataSourcePolicy.usesSearchResults(query: "  \n"))
        #expect(RecordingSearchDataSourcePolicy.usesSearchResults(query: " meeting \n"))
    }

    @Test func initialLibraryLoadTakesPriorityOverSearch() {
        #expect(RecordingsEmptyStateKind.resolve(
            isLoadingLibrary: true,
            isSearching: true,
            searchQuery: "query",
            hasSmartFolder: false
        ) == .loadingLibrary)
    }
}
