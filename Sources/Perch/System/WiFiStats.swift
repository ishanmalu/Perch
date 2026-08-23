import CoreWLAN
import Foundation

/// The Wi-Fi link's actual specifications, as opposed to how much traffic
/// happens to be crossing it.
///
/// Throughput counters answer "what am I using right now"; they say nothing
/// about how good the connection is. Link rate, signal and channel width do,
/// and CoreWLAN reports all of them without Location access. The network name
/// is the one thing that does require it, so it is left out.
struct WiFiLink {
    var interfaceName: String
    var linkRateMbps: Double        // negotiated, not achieved
    var rssi: Int                   // dBm, closer to zero is stronger
    var noise: Int                  // dBm
    var channel: Int
    var band: String                // "2.4 GHz" / "5 GHz" / "6 GHz"
    var widthMHz: Int
    var standard: String            // "Wi-Fi 5", "Wi-Fi 6", ...
    var security: String

    /// Signal-to-noise ratio in dB. Above ~40 is excellent, below ~15 is poor.
    var snr: Int { rssi - noise }

    /// Coarse 0...4 bar rating, from SNR rather than raw RSSI: a strong signal
    /// in a noisy room is not a good link.
    var bars: Int {
        switch snr {
        case ..<10:  return 0
        case ..<18:  return 1
        case ..<27:  return 2
        case ..<38:  return 3
        default:     return 4
        }
    }

    var quality: String {
        switch bars {
        case 0: return "Unusable"
        case 1: return "Poor"
        case 2: return "Fair"
        case 3: return "Good"
        default: return "Excellent"
        }
    }
}

enum WiFiStats {
    static func read() -> WiFiLink? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return nil }
        let rate = i.transmitRate()
        // A rate of zero means associated-but-idle or not associated at all.
        guard rate > 0 else { return nil }

        var channel = 0, width = 0, band = "—"
        if let ch = i.wlanChannel() {
            channel = ch.channelNumber
            switch ch.channelBand {
            case .band2GHz: band = "2.4 GHz"
            case .band5GHz: band = "5 GHz"
            case .band6GHz: band = "6 GHz"
            default:        band = "—"
            }
            switch ch.channelWidth {
            case .width20MHz:  width = 20
            case .width40MHz:  width = 40
            case .width80MHz:  width = 80
            case .width160MHz: width = 160
            default:           width = 0
            }
        }

        let standard: String
        switch i.activePHYMode() {
        case .mode11a, .mode11b, .mode11g: standard = "Legacy"
        case .mode11n:  standard = "Wi-Fi 4"
        case .mode11ac: standard = "Wi-Fi 5"
        case .mode11ax: standard = "Wi-Fi 6"
        default:        standard = "—"
        }

        let security: String
        switch i.security() {
        case .none:                      security = "Open"
        case .WEP:                       security = "WEP"
        case .wpaPersonal, .wpaEnterprise:   security = "WPA"
        case .wpa2Personal, .wpa2Enterprise: security = "WPA2"
        case .wpa3Personal, .wpa3Enterprise, .wpa3Transition: security = "WPA3"
        default:                         security = "—"
        }

        return WiFiLink(interfaceName: i.interfaceName ?? "Wi-Fi",
                        linkRateMbps: rate, rssi: i.rssiValue(),
                        noise: i.noiseMeasurement(), channel: channel,
                        band: band, widthMHz: width,
                        standard: standard, security: security)
    }
}
