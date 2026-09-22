import Combine
import Foundation
import Network

final class MQTTHomeAssistantPublisher: ObservableObject {
    @Published private(set) var statusKey = "mqtt.status.disabled"
    @Published private(set) var lastPublished: Date?

    private let settings: AppSettings
    private var isPublishing = false
    private var pendingSnapshot: (windows: [CodexUsageWindow], updatedAt: Date, isStale: Bool)?
    private var discoveryFingerprint: MQTTConfiguration?

    init(settings: AppSettings) {
        self.settings = settings
        statusKey = settings.mqttConfiguration.enabled
            ? "mqtt.status.idle"
            : "mqtt.status.disabled"
    }

    func configurationDidChange() {
        discoveryFingerprint = nil
        statusKey = settings.mqttConfiguration.enabled
            ? "mqtt.status.idle"
            : "mqtt.status.disabled"
    }

    func publish(windows: [CodexUsageWindow], updatedAt: Date, isStale: Bool) {
        let configuration = settings.mqttConfiguration.normalized
        guard configuration.isReady else {
            statusKey = configuration.enabled ? "mqtt.status.invalid" : "mqtt.status.disabled"
            return
        }

        if isPublishing {
            pendingSnapshot = (windows, updatedAt, isStale)
            return
        }

        isPublishing = true
        statusKey = "mqtt.status.connecting"
        let includeDiscovery = discoveryFingerprint != configuration
        let payload = MQTTQuotaPayload.make(
            windows: windows,
            updatedAt: updatedAt,
            isStale: isStale
        )

        do {
            let messages = try HomeAssistantMQTTMessageFactory.messages(
                configuration: configuration,
                quotaPayload: payload,
                includeDiscovery: includeDiscovery
            )
            MQTTNetworkPublisher.publish(
                messages: messages,
                configuration: configuration,
                password: settings.mqttPassword
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isPublishing = false
                    switch result {
                    case .success:
                        if includeDiscovery {
                            self.discoveryFingerprint = configuration
                        }
                        self.statusKey = "mqtt.status.online"
                        self.lastPublished = Date()
                    case .failure:
                        self.discoveryFingerprint = nil
                        self.statusKey = "mqtt.status.error"
                    }

                    if let pending = self.pendingSnapshot {
                        self.pendingSnapshot = nil
                        self.publish(
                            windows: pending.windows,
                            updatedAt: pending.updatedAt,
                            isStale: pending.isStale
                        )
                    }
                }
            }
        } catch {
            isPublishing = false
            statusKey = "mqtt.status.error"
        }
    }
}

private enum MQTTNetworkPublisher {
    static func publish(
        messages: [MQTTMessage],
        configuration: MQTTConfiguration,
        password: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let queue = DispatchQueue(label: "com.codexmeter.mqtt")
        guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
            completion(.failure(MQTTError.invalidConfiguration))
            return
        }

        let parameters: NWParameters = configuration.useTLS ? .tls : .tcp
        let connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: port,
            using: parameters
        )
        var completed = false

        func finish(_ result: Result<Void, Error>) {
            guard !completed else { return }
            completed = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(result)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                do {
                    let connectPacket = try MQTTWireEncoder.connectPacket(
                        clientID: configuration.clientID,
                        username: configuration.username,
                        password: password
                    )
                    connection.send(content: connectPacket, completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(error))
                            return
                        }
                        receiveConnectionAcknowledgement(
                            connection: connection,
                            messages: messages,
                            finish: finish
                        )
                    })
                } catch {
                    finish(.failure(error))
                }
            case let .failed(error):
                finish(.failure(error))
            case let .waiting(error):
                finish(.failure(error))
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + 15) {
            finish(.failure(MQTTError.timeout))
        }
        connection.start(queue: queue)
    }

    private static func receiveConnectionAcknowledgement(
        connection: NWConnection,
        messages: [MQTTMessage],
        finish: @escaping (Result<Void, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) {
            data, _, _, error in
            if let error {
                finish(.failure(error))
                return
            }
            guard let data, data.count == 4 else {
                finish(.failure(MQTTError.invalidConnectionAcknowledgement))
                return
            }
            let bytes = [UInt8](data)
            guard bytes[0] == 0x20, bytes[1] == 0x02, bytes[3] == 0 else {
                finish(.failure(MQTTError.connectionRejected(bytes[3])))
                return
            }

            do {
                var output = Data()
                for message in messages {
                    output.append(try MQTTWireEncoder.publishPacket(message))
                }
                output.append(contentsOf: [0xE0, 0x00])
                connection.send(content: output, completion: .contentProcessed { error in
                    if let error {
                        finish(.failure(error))
                    } else {
                        finish(.success(()))
                    }
                })
            } catch {
                finish(.failure(error))
            }
        }
    }
}

private enum MQTTWireEncoder {
    static func connectPacket(
        clientID: String,
        username: String,
        password: String
    ) throws -> Data {
        var body = Data()
        body.append(try lengthPrefixed("MQTT"))
        body.append(0x04)
        var flags: UInt8 = 0x02
        if !username.isEmpty { flags |= 0x80 }
        if !password.isEmpty { flags |= 0x40 }
        body.append(flags)
        body.append(contentsOf: [0x00, 0x1E])
        body.append(try lengthPrefixed(clientID))
        if !username.isEmpty { body.append(try lengthPrefixed(username)) }
        if !password.isEmpty { body.append(try lengthPrefixed(password)) }

        var packet = Data([0x10])
        packet.append(try remainingLength(body.count))
        packet.append(body)
        return packet
    }

    static func publishPacket(_ message: MQTTMessage) throws -> Data {
        var body = Data()
        body.append(try lengthPrefixed(message.topic))
        body.append(message.payload)

        var packet = Data([message.retain ? 0x31 : 0x30])
        packet.append(try remainingLength(body.count))
        packet.append(body)
        return packet
    }

    private static func lengthPrefixed(_ string: String) throws -> Data {
        let data = Data(string.utf8)
        guard data.count <= Int(UInt16.max) else { throw MQTTError.valueTooLarge }
        var result = Data([
            UInt8((data.count >> 8) & 0xFF),
            UInt8(data.count & 0xFF)
        ])
        result.append(data)
        return result
    }

    private static func remainingLength(_ value: Int) throws -> Data {
        guard value >= 0, value <= 268_435_455 else { throw MQTTError.valueTooLarge }
        var remaining = value
        var result = Data()
        repeat {
            var encoded = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { encoded |= 0x80 }
            result.append(encoded)
        } while remaining > 0
        return result
    }
}

private enum MQTTError: Error {
    case invalidConfiguration
    case invalidConnectionAcknowledgement
    case connectionRejected(UInt8)
    case timeout
    case valueTooLarge
}
