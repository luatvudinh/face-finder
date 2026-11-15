// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceFinderKit",
    defaultLocalization: "vi",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FaceFinderKit", targets: ["FaceFinderKit"]),
        .executable(name: "ffcli", targets: ["ffcli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // libjpeg-turbo (chỉ phần giải mã), chép bằng tools/vendor_libjpeg_turbo.sh. Dùng để giải mã JPEG ra đúng
        // từng pixel như Pillow của CLI Python; ImageIO cho pixel khác (PLAN.md mục 5.1).
        .target(
            name: "CJPEGTurbo",
            exclude: ["upstream/LICENSE.md", "upstream/README.ijg", "upstream/VENDORED.md"],
            sources: [
                "ffjpeg.c", "neon", "upstream/src/jdapimin.c", "upstream/src/jdatasrc.c", "upstream/src/jdhuff.c",
                "upstream/src/jdicc.c", "upstream/src/jdinput.c", "upstream/src/jdlhuff.c", "upstream/src/jdmarker.c",
                "upstream/src/jdmaster.c", "upstream/src/jdphuff.c", "upstream/src/jdarith.c",
                "upstream/src/jaricom.c", "upstream/src/jerror.c", "upstream/src/jmemmgr.c", "upstream/src/jmemnobs.c",
                "upstream/src/jcomapi.c", "upstream/src/jpeg_nbits.c", "upstream/src/wrapper/jdapistd-8.c",
                "upstream/src/wrapper/jdapistd-12.c", "upstream/src/wrapper/jdapistd-16.c",
                "upstream/src/wrapper/jdcolor-8.c", "upstream/src/wrapper/jdcolor-12.c",
                "upstream/src/wrapper/jdcolor-16.c", "upstream/src/wrapper/jddiffct-8.c",
                "upstream/src/wrapper/jddiffct-12.c", "upstream/src/wrapper/jddiffct-16.c",
                "upstream/src/wrapper/jdlossls-8.c", "upstream/src/wrapper/jdlossls-12.c",
                "upstream/src/wrapper/jdlossls-16.c", "upstream/src/wrapper/jdmainct-8.c",
                "upstream/src/wrapper/jdmainct-12.c", "upstream/src/wrapper/jdmainct-16.c",
                "upstream/src/wrapper/jdpostct-8.c", "upstream/src/wrapper/jdpostct-12.c",
                "upstream/src/wrapper/jdpostct-16.c", "upstream/src/wrapper/jdsample-8.c",
                "upstream/src/wrapper/jdsample-12.c", "upstream/src/wrapper/jdsample-16.c",
                "upstream/src/wrapper/jutils-8.c", "upstream/src/wrapper/jutils-12.c",
                "upstream/src/wrapper/jutils-16.c", "upstream/src/wrapper/jdcoefct-8.c",
                "upstream/src/wrapper/jdcoefct-12.c", "upstream/src/wrapper/jddctmgr-8.c",
                "upstream/src/wrapper/jddctmgr-12.c", "upstream/src/wrapper/jdmerge-8.c",
                "upstream/src/wrapper/jdmerge-12.c", "upstream/src/wrapper/jidctflt-8.c",
                "upstream/src/wrapper/jidctflt-12.c", "upstream/src/wrapper/jidctfst-8.c",
                "upstream/src/wrapper/jidctfst-12.c", "upstream/src/wrapper/jidctint-8.c",
                "upstream/src/wrapper/jidctint-12.c", "upstream/src/wrapper/jidctred-8.c",
                "upstream/src/wrapper/jidctred-12.c", "upstream/src/wrapper/jquant1-8.c",
                "upstream/src/wrapper/jquant1-12.c", "upstream/src/wrapper/jquant2-8.c",
                "upstream/src/wrapper/jquant2-12.c",
            ],
            cSettings: [.headerSearchPath("config"), .headerSearchPath("upstream/src"), .define("NEON_INTRINSICS"),
                        .unsafeFlags(["-O2"], .when(configuration: .debug))]
        ),
        .target(name: "FaceFinderKit", dependencies: [
            "CJPEGTurbo",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ],
        // Luôn tối ưu, kể cả bản Debug chạy từ Xcode: không tối ưu thì giải mã/thu nhỏ ảnh chậm hơn hàng chục lần
        // và lập chỉ mục trông như bị treo. (unsafeFlags chỉ dùng được vì đây là package nội bộ của dự án.)
        resources: [.process("Localizable.xcstrings")],
        swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .executableTarget(name: "ffcli", dependencies: ["FaceFinderKit"]),
        .testTarget(name: "FaceFinderKitTests", dependencies: ["FaceFinderKit"], resources: [.copy("Fixtures")]),
    ]
)
