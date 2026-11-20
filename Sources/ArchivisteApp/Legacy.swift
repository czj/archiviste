import Foundation
import ServiceManagement

/// Up to 1.0 the app was PDF Namer (com.github.czj.pdf-namer). On the first launch of Archiviste,
/// its preferences come over: history, pause, watched-until dates, window and list settings.
/// Rules and settings files move with the config folder (`UserConfig.directory`).
enum Legacy {
    static let bundleID = "com.github.czj.pdf-namer"
    private static let doneKey = "migratedFromPDFNamer"
    /// Set by scripts/install.sh when PDF Namer was a login item: Archiviste takes its place.
    private static let loginItemKey = "replaceLoginItem"

    /// Before anything reads UserDefaults.
    static func migrate() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: doneKey) {
            defaults.set(true, forKey: doneKey)
            for (key, value) in defaults.persistentDomain(forName: bundleID) ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        if defaults.bool(forKey: loginItemKey) {
            defaults.removeObject(forKey: loginItemKey)
            try? SMAppService.mainApp.register()
        }
    }
}
