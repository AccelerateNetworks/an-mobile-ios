import Foundation

/// Values are stamped into the built product's Info.plist by the "Stamp git info into Info.plist"
/// build phase on LinphoneApp. `Bundle.main` is the extension's own bundle inside an app extension,
/// so an extension consumer needs that build phase added to its own target.
public enum AppGitInfo {
    public static let marketingVersion = value("CFBundleShortVersionString")
    public static let build = value("CFBundleVersion")
    public static let branch = value("ANGitBranch")
    public static let commit = value("ANGitCommit")
    public static let tag = value("ANGitTag")

    /// "<marketing>.<build>+<tag>", e.g. "6.2.3.94+an-6.2.3".
    public static let identifier = "\(marketingVersion).\(build)+\(tag)"

    private static func value(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }
}
