// Shared by the app's files: text in the system's language.

import Foundation

func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

let appLanguage = Bundle.main.preferredLocalizations.first ?? "en"
let appLocale = Locale(identifier: appLanguage)

/// Defaults set before AppKit starts. ApplePersistence off: macOS keeps no saved state of the app at all (with the
/// global ApplePersistenceIgnoreState some Macs have, AppKit otherwise writes $TMPDIR/<id>.savedState even for a
/// window that is not restorable; seen 2026-11-10).
func registerAppDefaults() {
    UserDefaults.standard.register(defaults: ["ApplePersistence": false, "NSQuitAlwaysKeepsWindows": false, "speed": Speed.standard])
}
