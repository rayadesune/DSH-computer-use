// swift-tools-version:5.9
//
// SwiftPM 清单。仓库的主产物是一个单文件可执行程序，
// 所以 target 直接指向仓库根目录下的 dsh-ui.swift。
//
//   swift build -c release     -> .build/release/dsh-ui
//
// 文档里一贯使用的构建命令（不依赖 SwiftPM）依旧是：
//   swiftc -O dsh-ui.swift -o ~/.local/bin/dsh-ui

import PackageDescription

let package = Package(
    name: "dsh-ui",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "dsh-ui",
            path: ".",
            sources: ["dsh-ui.swift"]
        )
    ]
)
