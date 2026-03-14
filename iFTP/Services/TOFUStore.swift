//
//  TOFUStore.swift
//  iFTP
//
//  Created by François Monniot on 3/13/26.
//

import Foundation

// NOTE: We assume one FTP server per hostname (port is ignored).
// This simplifies certificate management since FTP over TLS typically
// uses the same certificate across all ports on a host.

final class TOFUStore {
    private let storageKey = "TOFUCertificateStore"

    private var store: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    enum Result {
        case trusted
        case firstUse(fingerprint: String)
        case mismatch(stored: String, seen: String)
    }

    func evaluate(fingerprint: String, host: String, port: UInt16) -> Result {
        // Port is intentionally ignored - we trust the same certificate for any port on this host
        let key = host
        if let stored = store[key] {
            return stored == fingerprint ? .trusted : .mismatch(stored: stored, seen: fingerprint)
        }
        store[key] = fingerprint
        return .firstUse(fingerprint: fingerprint)
    }

    func reset(host: String, port: UInt16) {
        var s = store
        s.removeValue(forKey: host)
        store = s
    }
}
