import Foundation
import SwiftUI

/// The lookup of a key. It is apart from `L10n.swift`, which holds only the cases.
extension L10n {
    /// For `Text` and `Button`: SwiftUI looks the key up in `Bundle.main`.
    var key: LocalizedStringKey { LocalizedStringKey(rawValue) }

    /// The value from the table of the app language in `Bundle.main`.
    var text: String { Bundle.main.localizedString(forKey: rawValue, value: nil, table: nil) }

    /// The value with its format specifiers filled.
    func format(_ arguments: any CVarArg...) -> String {
        String(format: text, locale: .current, arguments: arguments)
    }
}
