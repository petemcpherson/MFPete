import Foundation

/// Looks up a user-facing string in this package's String Catalog.
func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
