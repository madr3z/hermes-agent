// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "HermesGateway", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "HermesGateway", targets: ["HermesGateway"])], targets: [.target(name: "HermesGateway"), .testTarget(name: "HermesGatewayTests", dependencies: ["HermesGateway"], resources: [.copy("Fixtures")])])
