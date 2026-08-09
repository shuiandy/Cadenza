import SwiftUI
import Testing

@testable import Cadenza

@Suite("Accessibility text scaling")
struct AccessibilityTextScaleTests {
    @Test func standardLargeCategoryKeepsProductScaleUnchanged() {
        #expect(CadenzaTextScale.combined(uiScale: 1.15, dynamicTypeSize: .large) == 1.15)
    }

    @Test func accessibilityCategoriesGrowBeyondProductPresetCap() {
        let factor = CadenzaTextScale.combined(
            uiScale: 1.15,
            dynamicTypeSize: .accessibility3
        )

        #expect(factor > 1.15)
        #expect(factor > 2.0)
    }

    @Test func dynamicTypeFactorsAreMonotonicAcrossSupportedCategories() {
        let sizes: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5,
        ]
        let factors = sizes.map(CadenzaTextScale.factor)

        for pair in zip(factors, factors.dropFirst()) {
            #expect(pair.0 < pair.1)
        }
    }
}
