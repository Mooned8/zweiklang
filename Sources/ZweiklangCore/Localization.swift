import Foundation
import SwiftUI

extension Bundle {
    /// The translations live in this framework, not in the app bundle.
    /// Tests can point it at a single `.lproj` folder to render one language.
    public static var zweiklang = Bundle(for: LocalizationToken.self)
}

private final class LocalizationToken {}

/// Translated text for errors and status messages.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .zweiklang)
}

/// Translated SwiftUI text.
func T(_ key: LocalizedStringKey) -> Text {
    Text(key, bundle: .zweiklang)
}
