// Shared by the app and its tools: text in the system's language, names of the voices.

import Foundation

func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

let appLanguage = Bundle.main.preferredLocalizations.first ?? "en"
let appLocale = Locale(identifier: appLanguage)


extension Speed {
    static func text(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(2)).locale(appLocale)) }
}

// The ten voices as Supertone names and orders them, shown as plain numbers.
enum Voices {
    static let ids = ["M1", "M2", "M3", "M4", "M5", "F1", "F2", "F3", "F4", "F5"]
}


