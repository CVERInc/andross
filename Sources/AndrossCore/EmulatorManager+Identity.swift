import Foundation

// MARK: - Identity (user profile) sandboxes & packages
//
// Identity sandboxes are Android multi-user profiles (`pm create-user`).
// All commands are pinned to an explicit device serial.

extension EmulatorManager {
    public struct AndroidUser: Sendable, Identifiable, Hashable {
        public var id: Int { userId }
        public let userId: Int
        public let name: String
        public let isRunning: Bool

        public init(userId: Int, name: String, isRunning: Bool) {
            self.userId = userId
            self.name = name
            self.isRunning = isRunning
        }
    }

    /// Retrieve all user profile identities from the given device.
    public func listUsers(serial: String) -> [AndroidUser] {
        let result = adb(serial, ["shell", "pm", "list", "users"])
        guard result.ok else { return [] }
        return AndrossParse.users(from: result.stdout).map {
            AndroidUser(userId: $0.userId, name: $0.name, isRunning: $0.isRunning)
        }
    }

    /// The user id whose UI is currently in the foreground.
    public func currentUserId(serial: String) -> Int {
        let result = adb(serial, ["shell", "am", "get-current-user"])
        guard result.ok else { return 0 }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Create a new identity sandbox; returns the new user id on success.
    @discardableResult
    public func createUser(serial: String, name: String) -> Int? {
        let result = adb(serial, ["shell", "pm", "create-user", name])
        guard result.ok,
              let userId = AndrossParse.createdUserId(from: result.stdout) else { return nil }
        adb(serial, ["shell", "am", "start-user", "\(userId)"])
        return userId
    }

    /// Switch the foreground UI to the specified identity.
    @discardableResult
    public func switchUser(serial: String, id: Int) -> Bool {
        adb(serial, ["shell", "am", "switch-user", "\(id)"]).ok
    }

    /// Remove the specified identity sandbox and its data.
    ///
    /// Android refuses to remove the foreground user, so if the target is
    /// currently in front we switch back to the owner first and wait for the
    /// switch to land (freshly-provisioned identities can take a while).
    @discardableResult
    public func deleteUser(serial: String, id: Int) -> Bool {
        guard id != 0 else { return false } // user 0 is the system owner

        if currentUserId(serial: serial) == id {
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline, currentUserId(serial: serial) != 0 {
                adb(serial, ["shell", "am", "switch-user", "0"])
                Thread.sleep(forTimeInterval: 2)
            }
            guard currentUserId(serial: serial) == 0 else { return false }
        }
        return adb(serial, ["shell", "pm", "remove-user", "\(id)"]).ok
    }

    /// Enable an app already installed on the device for another identity —
    /// no re-download, the APK is shared and the data is per-identity.
    @discardableResult
    public func cloneApp(serial: String, packageName: String, toUser userId: Int) -> Bool {
        adb(serial, ["shell", "pm", "install-existing", "--user", "\(userId)", packageName]).ok
    }

    /// Fully uninstall a package from the device (all identities).
    @discardableResult
    public func uninstallPackage(serial: String, packageName: String) -> Bool {
        adb(serial, ["uninstall", packageName]).ok
    }

    /// List third-party (user-installed) packages visible to the given identity.
    public func listThirdPartyPackages(serial: String, userId: Int) -> [String] {
        let result = adb(serial, ["shell", "pm", "list", "packages", "-3", "--user", "\(userId)"])
        guard result.ok else { return [] }
        return AndrossParse.packageNames(from: result.stdout)
    }

    // MARK: - Storage stats

    public struct AppStorageStats: Sendable, Codable, Hashable {
        public let packageName: String
        public let apkSize: Int64
        /// nil when the device denies access (data dirs need root on
        /// Google Play images) — display as unavailable, never as 0.
        public let dataSize: Int64?
        public let cacheSize: Int64?

        public var totalKnownSize: Int64 { apkSize + (dataSize ?? 0) }

        public init(packageName: String, apkSize: Int64, dataSize: Int64?, cacheSize: Int64?) {
            self.packageName = packageName
            self.apkSize = apkSize
            self.dataSize = dataSize
            self.cacheSize = cacheSize
        }
    }

    /// Get the storage footprint of an app for a given identity.
    public func getAppStorageStats(serial: String, packageName: String, userId: Int) -> AppStorageStats? {
        let pathRes = adb(serial, ["shell", "pm", "path", packageName])
        guard pathRes.ok else { return nil }
        let apkPaths = AndrossParse.apkPaths(from: pathRes.stdout)
        guard !apkPaths.isEmpty else { return nil }

        var apkSize: Int64 = 0
        for path in apkPaths {
            let sizeRes = adb(serial, ["shell", "ls", "-l", path])
            if sizeRes.ok, let bytes = AndrossParse.lsFileSize(from: sizeRes.stdout) {
                apkSize += bytes
            }
        }

        // Data/cache dirs are only readable when adb has root (AOSP images);
        // on Google Play images these honestly come back as unavailable.
        func protectedDirSize(_ path: String) -> Int64? {
            let res = adb(serial, ["shell", "du", "-sk", path])
            guard res.ok else { return nil }
            return AndrossParse.duBytes(from: res.stdout)
        }

        let dataPath = "/data/user/\(userId)/\(packageName)"
        return AppStorageStats(
            packageName: packageName,
            apkSize: apkSize,
            dataSize: protectedDirSize(dataPath),
            cacheSize: protectedDirSize(dataPath + "/cache")
        )
    }
}
