import XCTest
@testable import CodexMeterCore

final class MQTTModelsTests: XCTestCase {
    private let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testConfigurationNormalizesPortsAndTopics() {
        var configuration = MQTTConfiguration()
        configuration.port = 80_000
        configuration.discoveryPrefix = "/homeassistant//"
        configuration.baseTopic = " /codex/quota/ "

        let normalized = configuration.normalized

        XCTAssertEqual(normalized.port, 65_535)
        XCTAssertEqual(normalized.discoveryPrefix, "homeassistant")
        XCTAssertEqual(normalized.baseTopic, "codex/quota")
    }

    func testQuotaPayloadKeepsReferenceFieldsAndAllWindows() throws {
        let payload = MQTTQuotaPayload.make(
            windows: [
                makeWindow(id: "codex-primary", used: 25, duration: 300),
                makeWindow(id: "codex-secondary", used: 40, duration: 10_080),
                makeWindow(id: "reserve-secondary", used: 10, duration: 10_080)
            ],
            updatedAt: updatedAt,
            isStale: false
        )

        XCTAssertEqual(payload.status, "ok")
        XCTAssertEqual(payload.fiveHour?.remainingPercent, 75)
        XCTAssertEqual(payload.weekly?.remainingPercent, 60)
        XCTAssertEqual(payload.windows.count, 3)

        let messages = try HomeAssistantMQTTMessageFactory.messages(
            configuration: MQTTConfiguration(),
            quotaPayload: payload,
            includeDiscovery: false
        )
        let state = try XCTUnwrap(messages.first { $0.topic == "codex/quota/state" })
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: state.payload) as? [String: Any]
        )
        XCTAssertEqual(object["status"] as? String, "ok")
        XCTAssertNotNil(object["five_hour"])
        XCTAssertEqual((object["windows"] as? [[String: Any]])?.count, 3)
    }

    func testDiscoveryMatchesReferenceEntityTopics() throws {
        let payload = MQTTQuotaPayload.make(
            windows: [makeWindow(id: "codex-primary", used: 25, duration: 300)],
            updatedAt: updatedAt,
            isStale: true
        )
        let messages = try HomeAssistantMQTTMessageFactory.messages(
            configuration: MQTTConfiguration(),
            quotaPayload: payload,
            includeDiscovery: true
        )

        XCTAssertEqual(messages.count, 9)
        XCTAssertTrue(messages.contains {
            $0.topic == "homeassistant/sensor/codex_quota/codex_5h_remaining_percent/config"
                && $0.retain
        })
        XCTAssertTrue(messages.contains {
            $0.topic == "codex/quota/availability" && $0.payload == Data("online".utf8)
        })
        XCTAssertEqual(messages.last?.topic, "codex/quota/state")
    }

    private func makeWindow(
        id: String,
        used: Int,
        duration: Int
    ) -> CodexUsageWindow {
        CodexUsageWindow(
            id: id,
            name: id,
            usedPercent: used,
            windowDurationMins: duration,
            resetsAt: updatedAt.addingTimeInterval(Double(duration * 60))
        )
    }
}
