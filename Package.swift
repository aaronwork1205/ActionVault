// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ActionVault", platforms: [.macOS(.v13)],
    products: [.executable(name: "ActionVault", targets: ["CameraBackup"])],
    targets: [
        .target(name: "CameraBackupCore"),
        .executableTarget(name: "CameraBackup", dependencies: ["CameraBackupCore"]),
        .testTarget(name: "CameraBackupCoreTests", dependencies: ["CameraBackupCore"])
    ])
