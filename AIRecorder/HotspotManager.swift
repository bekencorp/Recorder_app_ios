import Foundation
#if os(iOS)
import NetworkExtension
#endif

enum RecorderHotspotRelease: Equatable {
    case released
    case stillAssociated
}

struct HotspotManager {
    func join(_ credentials: RecorderWiFiCredentials) async throws {
        #if os(iOS)
        let configuration = NEHotspotConfiguration(
            ssid: credentials.ssid,
            passphrase: credentials.password,
            isWEP: false
        )
        // A managed temporary configuration can be explicitly removed after
        // transfer. `joinOnce` configurations are owned by iOS and removal is
        // not a reliable disconnect signal.
        configuration.joinOnce = false
        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NEHotspotConfigurationErrorDomain,
               nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                return
            }
            throw RecorderAppError.transferNetworkUnavailable
        }
        #else
        throw RecorderAppError.transferNetworkUnavailable
        #endif
    }

    func leave(_ credentials: RecorderWiFiCredentials) async -> RecorderHotspotRelease {
        #if os(iOS)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: credentials.ssid)
        return await waitUntilReleased(credentials, timeout: 12)
        #else
        return .released
        #endif
    }

    func waitUntilReleased(
        _ credentials: RecorderWiFiCredentials,
        timeout: TimeInterval
    ) async -> RecorderHotspotRelease {
        #if os(iOS)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let currentSSID = await currentWiFiSSID()
            if Self.releaseState(currentSSID: currentSSID, recorderSSID: credentials.ssid) == .released {
                return .released
            }
            try? await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        return .stillAssociated
        #else
        return .released
        #endif
    }

    static func releaseState(
        currentSSID: String?,
        recorderSSID: String
    ) -> RecorderHotspotRelease {
        currentSSID == recorderSSID ? .stillAssociated : .released
    }

    #if os(iOS)
    private func currentWiFiSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
    #endif
}
