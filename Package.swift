// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Unison", platforms: [.macOS("14.4")], products: [.executable(name: "Unison", targets: ["Unison"])], targets: [.target(name: "RealtimeAudio", linkerSettings: [.linkedFramework("CoreAudio")]), .executableTarget(name: "Unison", dependencies: ["RealtimeAudio"]), .testTarget(name: "UnisonTests", dependencies: ["Unison", "RealtimeAudio"])])
