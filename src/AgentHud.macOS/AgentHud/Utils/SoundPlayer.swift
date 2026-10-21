import AppKit

/// Completion / question sounds. A key is a macOS system sound name or `fileKey`
/// (user-chosen audio file), mirroring the Windows SoundSetting.
enum SoundPlayer {
    static let fileKey = "File"
    static let systemSounds = ["Glass", "Ping", "Pop", "Purr", "Funk", "Hero", "Basso", "Blow",
                               "Bottle", "Frog", "Morse", "Sosumi", "Submarine", "Tink"]
    /// NSSound stops when deallocated mid-playback, so keep a reference.
    private static var current: NSSound?

    static func play(_ key: String, file: String) {
        let sound: NSSound?
        if key == fileKey {
            guard !file.isEmpty, FileManager.default.fileExists(atPath: file) else { return }
            sound = NSSound(contentsOfFile: file, byReference: true)
        } else {
            sound = NSSound(named: NSSound.Name(key))
        }
        current?.stop()
        current = sound
        sound?.play()
    }
}
