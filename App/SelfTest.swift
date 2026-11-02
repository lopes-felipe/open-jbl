import Foundation
import Security
import Darwin
import JBLKit

enum SelfTest {
    static func runAndExit() -> Never {
        let info = Bundle.main.infoDictionary ?? [:]
        var code: SecCode?
        var staticCode: SecStaticCode?
        var signing: CFDictionary?
        let codeResult = SecCodeCopySelf(SecCSFlags(), &code)
        let staticResult = code.map { SecCodeCopyStaticCode($0, SecCSFlags(), &staticCode) }
        let signingResult = staticCode.map {
            SecCodeCopySigningInformation($0, SecCSFlags(rawValue: kSecCSSigningInformation), &signing)
        }
        let entitlements = (signing as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let required = [
            "com.apple.security.app-sandbox", "com.apple.security.device.bluetooth",
            "com.apple.security.files.user-selected.read-write"
        ]
        let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
        var checks: [String: Bool] = [
            "minimumSystemVersion": info["LSMinimumSystemVersion"] as? String == "14.0",
            "menuBarApplication": info["LSUIElement"] as? Bool == true,
            "bluetoothUsageDescription": !(info["NSBluetoothAlwaysUsageDescription"] as? String ?? "").isEmpty,
            "bundleIdentifier": Bundle.main.bundleIdentifier == "io.github.lopesfelipe.OpenJBL",
            "catalog": ModelCatalog.integrityErrors().isEmpty,
            "bluetoothFramework": handle != nil,
            "signature": codeResult == errSecSuccess && staticResult == errSecSuccess && signingResult == errSecSuccess,
            "noNetworkEntitlements": entitlements["com.apple.security.network.client"] == nil &&
                entitlements["com.apple.security.network.server"] == nil
        ]
        for key in required { checks[key] = entitlements[key] as? Bool == true }
        if let handle { dlclose(handle) }
        let passed = checks.values.allSatisfy { $0 }
        let report: [String: Any] = [
            "passed": passed, "checks": checks,
            "enabledOperations": OperationCatalog.production.names.count,
            "hardwareVerified": false, "stage": "M1 pending"
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(passed ? 0 : 1)
    }
}
