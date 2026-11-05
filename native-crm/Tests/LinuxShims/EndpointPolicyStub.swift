// Linux-only test stub. The real EndpointPolicy lives in Sources/FollowUpOSNative/Security.swift,
// which imports Apple's Compression framework and so cannot compile on Linux.
// bin/test-crm-core uses this stub only to satisfy the model layer's mail-import link check.
// It fails closed: every link is refused, so no Linux test can pass by accident through it.
// It is never compiled into the macOS app or bin/test-native-app.
enum EndpointPolicy {
    struct Result: Equatable {
        var url: String
        var removedSecrets: Bool
    }

    static func sanitize(_ value: String) -> Result? { nil }
}
