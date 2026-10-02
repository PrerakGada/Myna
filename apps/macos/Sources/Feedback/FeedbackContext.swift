// FeedbackContext.swift — the only facts about the Mac that travel with a
// feedback message: app version, build, platform, OS version and Mac model.
// The form shows exactly this list ("Sent with your message: …"), so the
// user sees everything that leaves with their words. Nothing else is read:
// no device or install IDs, computer name, logs or history.
import Foundation

public struct FeedbackContext: Sendable, Equatable {
    public static let appName = "Myna"
    public static let platform = "macOS"

    public let appVersion: String
    public let build: String
    /// "27.0.1 (26A434)".
    public let osVersion: String
    /// `sysctl hw.model`, e.g. "Mac17,7". Optional in the API.
    public let deviceModel: String?

    public init(appVersion: String, build: String, osVersion: String, deviceModel: String?) {
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }

    /// Read from the running app and OS.
    public static func current(bundle: Bundle = .main) -> FeedbackContext {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return FeedbackContext(
            appVersion: version,
            build: build,
            osVersion: formatOSVersion(
                major: os.majorVersion,
                minor: os.minorVersion,
                patch: os.patchVersion,
                build: sysctlString("kern.osversion")
            ),
            deviceModel: sysctlString("hw.model")
        )
    }

    /// The form's disclosure line.
    public var summary: String {
        var parts = ["\(Self.appName) \(appVersion) (\(build))", "\(Self.platform) \(osVersion)"]
        if let deviceModel { parts.append(deviceModel) }
        return "Sent with your message: " + parts.joined(separator: " · ")
    }

    /// `<App>/<version> (<build>; macOS <osVersion>)`.
    public var userAgent: String {
        "\(Self.appName)/\(appVersion) (\(build); \(Self.platform) \(osVersion))"
    }

    static func formatOSVersion(major: Int, minor: Int, patch: Int, build: String?) -> String {
        var text = "\(major).\(minor)"
        if patch > 0 { text += ".\(patch)" }
        if let build, !build.isEmpty { text += " (\(build))" }
        return text
    }

    /// A string-valued sysctl, or nil when it can't be read.
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let value = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty
        else { return nil }
        return value
    }
}
