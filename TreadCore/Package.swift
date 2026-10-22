// swift-tools-version:5.9
import PackageDescription

// Cœur métier indépendant de la plateforme : protocole FTMS, file de commandes,
// moteur de programmes, zones cardiaques, compteurs, enregistrement et export.
// Aucune dépendance à CoreBluetooth/HealthKit/SwiftUI : testable sur macOS et Linux.
let package = Package(
    name: "TreadCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "TreadCore", targets: ["TreadCore"])
    ],
    targets: [
        .target(name: "TreadCore"),
        .testTarget(name: "TreadCoreTests", dependencies: ["TreadCore"])
    ]
)
