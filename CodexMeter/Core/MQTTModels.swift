import Foundation

struct MQTTConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var host = "homeassistant.local"
    var port = 1_883
    var username = ""
    var useTLS = false
    var discoveryPrefix = "homeassistant"
    var baseTopic = "codex/quota"
    var clientID = "codex-meter-macos"
    var deviceName = "Codex Quota"
    var retain = true

    var normalized: MQTTConfiguration {
        var result = self
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        result.port = min(65_535, max(1, port))
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.discoveryPrefix = Self.normalizedTopic(discoveryPrefix, fallback: "homeassistant")
        result.baseTopic = Self.normalizedTopic(baseTopic, fallback: "codex/quota")
        result.clientID = Self.bounded(clientID, fallback: "codex-meter-macos", maximum: 128)
        result.deviceName = Self.bounded(deviceName, fallback: "Codex Quota", maximum: 128)
        return result
    }

    var isReady: Bool {
        enabled && !normalized.host.isEmpty
    }

    private static func normalizedTopic(_ value: String, fallback: String) -> String {
        let components = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .filter { !$0.isEmpty }
        let result = components.joined(separator: "/")
        return bounded(result, fallback: fallback, maximum: 256)
    }

    private static func bounded(_ value: String, fallback: String, maximum: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        return String(source.prefix(maximum))
    }
}

struct MQTTQuotaPayload: Codable, Equatable, Sendable {
    let status: String
    let updatedAt: String
    let fiveHour: MQTTQuotaWindow?
    let weekly: MQTTQuotaWindow?
    let windows: [MQTTQuotaWindow]

    enum CodingKeys: String, CodingKey {
        case status
        case updatedAt = "updated_at"
        case fiveHour = "five_hour"
        case weekly
        case windows
    }

    static func make(
        windows: [CodexUsageWindow],
        updatedAt: Date,
        isStale: Bool
    ) -> MQTTQuotaPayload {
        let mapped = windows.map(MQTTQuotaWindow.init)
        return MQTTQuotaPayload(
            status: isStale ? "stale" : "ok",
            updatedAt: MQTTDateFormatter.string(from: updatedAt),
            fiveHour: mapped.first { $0.windowDurationMins == 300 },
            weekly: mapped.first { $0.windowDurationMins == 10_080 },
            windows: mapped
        )
    }
}

struct MQTTQuotaWindow: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let usedPercent: Int
    let remainingPercent: Int
    let windowDurationMins: Int?
    let resetTime: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case usedPercent = "used_percent"
        case remainingPercent = "remaining_percent"
        case windowDurationMins = "window_duration_mins"
        case resetTime = "reset_time"
    }

    init(_ window: CodexUsageWindow) {
        id = window.id
        name = window.name
        usedPercent = window.usedPercent
        remainingPercent = window.remainingPercent
        windowDurationMins = window.windowDurationMins
        resetTime = window.resetsAt.map(MQTTDateFormatter.string)
    }
}

struct MQTTMessage: Equatable, Sendable {
    let topic: String
    let payload: Data
    let retain: Bool
}

enum HomeAssistantMQTTMessageFactory {
    static func messages(
        configuration: MQTTConfiguration,
        quotaPayload: MQTTQuotaPayload,
        includeDiscovery: Bool
    ) throws -> [MQTTMessage] {
        let configuration = configuration.normalized
        var messages: [MQTTMessage] = []
        if includeDiscovery {
            messages.append(contentsOf: try discoveryMessages(configuration: configuration))
        }
        messages.append(MQTTMessage(
            topic: "\(configuration.baseTopic)/availability",
            payload: Data("online".utf8),
            retain: true
        ))
        messages.append(MQTTMessage(
            topic: "\(configuration.baseTopic)/state",
            payload: try encoder.encode(quotaPayload),
            retain: configuration.retain
        ))
        return messages
    }

    private static func discoveryMessages(
        configuration: MQTTConfiguration
    ) throws -> [MQTTMessage] {
        let definitions = [
            SensorDefinition(
                id: "codex_5h_remaining_percent", name: "Codex 5h Remaining",
                valueTemplate: "{{ value_json.five_hour.remaining_percent }}",
                unit: "%", deviceClass: nil, stateClass: "measurement"
            ),
            SensorDefinition(
                id: "codex_5h_used_percent", name: "Codex 5h Used",
                valueTemplate: "{{ value_json.five_hour.used_percent }}",
                unit: "%", deviceClass: nil, stateClass: "measurement"
            ),
            SensorDefinition(
                id: "codex_5h_reset_time", name: "Codex 5h Reset Time",
                valueTemplate: "{{ value_json.five_hour.reset_time }}",
                unit: nil, deviceClass: "timestamp", stateClass: nil
            ),
            SensorDefinition(
                id: "codex_weekly_remaining_percent", name: "Codex Weekly Remaining",
                valueTemplate: "{{ value_json.weekly.remaining_percent }}",
                unit: "%", deviceClass: nil, stateClass: "measurement"
            ),
            SensorDefinition(
                id: "codex_weekly_used_percent", name: "Codex Weekly Used",
                valueTemplate: "{{ value_json.weekly.used_percent }}",
                unit: "%", deviceClass: nil, stateClass: "measurement"
            ),
            SensorDefinition(
                id: "codex_weekly_reset_time", name: "Codex Weekly Reset Time",
                valueTemplate: "{{ value_json.weekly.reset_time }}",
                unit: nil, deviceClass: "timestamp", stateClass: nil
            ),
            SensorDefinition(
                id: "codex_quota_status", name: "Codex Quota Status",
                valueTemplate: "{{ value_json.status }}",
                unit: nil, deviceClass: nil, stateClass: nil
            )
        ]

        return try definitions.map { definition in
            let payload = HomeAssistantDiscoveryPayload(
                name: definition.name,
                uniqueID: definition.id,
                objectID: definition.id,
                stateTopic: "\(configuration.baseTopic)/state",
                availabilityTopic: "\(configuration.baseTopic)/availability",
                payloadAvailable: "online",
                payloadNotAvailable: "offline",
                valueTemplate: definition.valueTemplate,
                unitOfMeasurement: definition.unit,
                deviceClass: definition.deviceClass,
                stateClass: definition.stateClass,
                device: HomeAssistantDevice(
                    identifiers: ["codex_quota_windows"],
                    name: configuration.deviceName,
                    manufacturer: "OpenAI Codex local monitor",
                    model: "CodexMeter macOS MQTT bridge"
                )
            )
            return MQTTMessage(
                topic: "\(configuration.discoveryPrefix)/sensor/codex_quota/\(definition.id)/config",
                payload: try encoder.encode(payload),
                retain: true
            )
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private struct SensorDefinition {
        let id: String
        let name: String
        let valueTemplate: String
        let unit: String?
        let deviceClass: String?
        let stateClass: String?
    }
}

private struct HomeAssistantDiscoveryPayload: Codable {
    let name: String
    let uniqueID: String
    let objectID: String
    let stateTopic: String
    let availabilityTopic: String
    let payloadAvailable: String
    let payloadNotAvailable: String
    let valueTemplate: String
    let unitOfMeasurement: String?
    let deviceClass: String?
    let stateClass: String?
    let device: HomeAssistantDevice

    enum CodingKeys: String, CodingKey {
        case name
        case uniqueID = "unique_id"
        case objectID = "object_id"
        case stateTopic = "state_topic"
        case availabilityTopic = "availability_topic"
        case payloadAvailable = "payload_available"
        case payloadNotAvailable = "payload_not_available"
        case valueTemplate = "value_template"
        case unitOfMeasurement = "unit_of_measurement"
        case deviceClass = "device_class"
        case stateClass = "state_class"
        case device
    }
}

private struct HomeAssistantDevice: Codable {
    let identifiers: [String]
    let name: String
    let manufacturer: String
    let model: String
}

private enum MQTTDateFormatter {
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
