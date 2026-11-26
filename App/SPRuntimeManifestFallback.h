//
//  SPRuntimeManifestFallback.h
//  **自动生成，不要手改**
//
//  由 scripts/gen-runtime-manifest.py 从
//  Native/Resources/runtime-manifest.json 生成。
//  改数据请改 JSON，然后跑：
//      python3 scripts/gen-runtime-manifest.py
//

#import <Foundation/Foundation.h>

/// bundle 里没有 runtime-manifest.json 时用的兜底（内容与 JSON 完全一致）
static NSArray<NSDictionary *> *SPRuntimeManifestFallback(void) {
    return @[
        @{@"id": @"coretools", @"name": @"核心工具集", @"detail": @"git / curl / jq / rg / zip / unzip / diff / patch / file", @"symbol": @"terminal.fill", @"archive": @"https://github.com/susu123oss/CodexApp-Runtime/releases/download/runtime-core-tools-a7e97567217a/CoreToolsRuntime.tar.gz", @"size": @(9921181), @"order": @(5), @"optional": @(NO), @"probe": @"bin/git", @"pathEntries": @[@"bin"]},
        @{@"id": @"reverse", @"name": @"逆向工具", @"detail": @"radare2 / mt-macho / mt-inject-dylib", @"symbol": @"binoculars.fill", @"archive": @"https://github.com/susu123oss/CodexApp-Runtime/releases/download/runtime-reverse-tools-9d3ca9ea3340/ReverseToolsRuntime.tar.gz", @"size": @(17376078), @"order": @(10), @"optional": @(YES), @"probe": @"bin/rabin2", @"pathEntries": @[@"bin"]},
        @{@"id": @"theos", @"name": @"Theos 完整版", @"detail": @"Theos 本体 + iPhoneOS16.5.sdk（归档顶层为 theos-root/ 与 sdks/）", @"symbol": @"wrench.and.screwdriver.fill", @"archive": @"https://github.com/JiuJiuyu77/Workbench-Runtime/releases/download/runtime-v3/SparkTheosRuntimeV3.tar.gz", @"size": @(272221041), @"order": @(25), @"optional": @(YES), @"probe": @"theos-root/theos/bin/logos.pl", @"pathEntries": @[@"theos-root/theos/bin", @"theos-root/usr/bin", @"theos-root/bin"]},
        @{@"id": @"ollvm", @"name": @"OLLVM 混淆", @"detail": @"Arkari LLVM 23.1.1，7 个 pass（arm64e 已验证）", @"symbol": @"wand.and.stars", @"archive": @"https://github.com/susu123oss/CodexApp-Runtime/releases/download/runtime-ollvm-23.1.1-e54f2878240e/OLLVMRuntime.tar.gz", @"size": @(36348135), @"order": @(30), @"optional": @(YES), @"probe": @"bin/clang", @"pathEntries": @[@"bin"]},
        @{@"id": @"sdk17", @"name": @"iPhoneOS17.0.sdk", @"detail": @"17.0 SDK（按需下载，归档内自带 sdks/ 前缀）", @"symbol": @"shippingbox", @"archive": @"https://github.com/JiuJiuyu77/Workbench-Runtime/releases/download/runtime-v3/iPhoneOS17.0.sdk.tar.gz", @"size": @(45935486), @"order": @(0), @"optional": @(YES), @"probe": @"sdks/iPhoneOS17.0.sdk/SDKSettings.json", @"pathEntries": @[], @"sdkName": @"iPhoneOS17.0.sdk"},
        @{@"id": @"sdk26", @"name": @"iPhoneOS26.5.sdk", @"detail": @"26.5 SDK（按需下载，归档内自带 sdks/ 前缀）", @"symbol": @"shippingbox", @"archive": @"https://github.com/JiuJiuyu77/Workbench-Runtime/releases/download/runtime-v3/iPhoneOS26.5.sdk.tar.gz", @"size": @(35017300), @"order": @(0), @"optional": @(YES), @"probe": @"sdks/iPhoneOS26.5.sdk/SDKSettings.json", @"pathEntries": @[], @"sdkName": @"iPhoneOS26.5.sdk"},
        @{@"id": @"swift-toolchain", @"name": @"Swift 6.4.3 工具链", @"detail": @"swiftc + 标准库（已随包内置，可从 Release 重新下载）", @"symbol": @"swift", @"archive": @"https://github.com/JiuJiuyu77/Workbench2/releases/download/swift-6.4.3/SwiftToolchain.tar.gz", @"size": @(239851291), @"order": @(35), @"optional": @(YES), @"probe": @"usr/bin/swiftc", @"pathEntries": @[@"usr/bin", @"usr/lib"]},
    ];
}
