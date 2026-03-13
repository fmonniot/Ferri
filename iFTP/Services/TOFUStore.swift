//
//  TOFUStore.swift
//  iFTP
//
//  Created by François Monniot on 3/13/26.
//

import Foundation

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
        let key = "\(host):\(port)"
        if let stored = store[key] {
            return stored == fingerprint ? .trusted : .mismatch(stored: stored, seen: fingerprint)
        }
        store[key] = fingerprint
        return .firstUse(fingerprint: fingerprint)
    }

    func reset(host: String, port: UInt16) {
        var s = store
        s.removeValue(forKey: "\(host):\(port)")
        store = s
    }
}
