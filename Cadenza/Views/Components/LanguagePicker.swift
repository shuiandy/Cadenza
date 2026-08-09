import SwiftUI

struct LanguagePicker: View {
    @Binding var selection: TranscriptionLanguage

    var body: some View {
        Picker("Language", selection: $selection) {
            ForEach(TranscriptionLanguage.allCases) { language in
                Text(language.displayName).tag(language)
            }
        }
    }
}
