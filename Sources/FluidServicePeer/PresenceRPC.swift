import FluidContainerLoader
import FluidJS
import FluidPresence
import Synchronization

/// The service harness's presence scenario (harness/src/service-presence.ts): one `latest` state,
/// one `latestMap` state and one notification, on the real container stack. Every workspace is
/// reached through `Container.withPresence`, the native `getPresence`.

private let statesAddress: JSString = "app:cursors"
private let eventsAddress: JSString = "app:events"

/// A received notification, as the harness reads it.
struct ReceivedNotification: Sendable {
    let attendee: JSString
    let name: JSString
    let args: [JSONValue]
}

/// Notifications a client received. The listener appends on the container's executor; the
/// harness view reads on it too, and the mutex keeps the type honestly `Sendable`.
final class PresenceLog: Sendable {
    private let received = Mutex<[ReceivedNotification]>([])

    func append(_ notification: ReceivedNotification) {
        received.withLock { $0.append(notification) }
    }

    var notifications: [ReceivedNotification] { received.withLock { $0 } }
}

private func jsonObject(_ entries: [(JSString, JSONValue)]) -> JSONValue {
    var object = JSObject<JSONValue>()
    for (key, value) in entries { object[key] = value }
    return .object(object)
}

/// `getWorkspace` is idempotent: a repeated call ensures the content and returns the same workspace.
private func workspaces(
    _ presence: any Presence, _ clock: any PresenceClock, _ log: PresenceLog
) throws -> (states: PresenceStatesImpl, events: PresenceStatesImpl) {
    let states = try presence.states.getWorkspace(
        statesAddress,
        WorkspaceSchema([
            ("cursor", LatestFactory(local: jsonObject([("x", .number(0)), ("y", .number(0))]), clock: clock)),
            ("items", LatestMapFactory(local: JSObject<JSONValue>(), clock: clock)),
        ]))
    let events = try presence.notifications.getWorkspace(
        eventsAddress,
        WorkspaceSchema([
            (
                "ping",
                NotificationsFactory(initialSubscriptions: [
                    (
                        name: "ping",
                        listener: { sender, args in
                            log.append(ReceivedNotification(attendee: sender.attendeeId, name: "ping", args: args))
                        }
                    )
                ])
            )
        ]))
    return (states, events)
}

private func entries(_ items: some Sequence<(JSString, JSONValue?)>) -> JSONValue {
    .array(items.map { .array([.string($0.0), $0.1 ?? .null]) })
}

private func view(_ presence: any Presence, _ clock: any PresenceClock, _ log: PresenceLog) throws -> JSONValue {
    let (states, _) = try workspaces(presence, clock, log)
    let cursor = try states.latest("cursor")
    let items = try states.latestMap("items")
    return jsonObject([
        (
            "attendees",
            .array(presence.attendees.getAttendees().map {
                jsonObject([
                    ("id", .string($0.attendeeId)),
                    ("status", .string(JSString($0.getConnectionStatus().rawValue))),
                ])
            })
        ),
        (
            "cursor",
            jsonObject([
                ("local", cursor.local ?? .null),
                (
                    "remotes",
                    .array(try cursor.getRemotes().map {
                        jsonObject([
                            ("attendee", .string($0.attendee.attendeeId)),
                            ("value", $0.value.resolve() ?? .null),
                            ("revision", .number($0.metadata.revision)),
                        ])
                    })
                ),
            ])
        ),
        (
            "items",
            jsonObject([
                ("local", entries(items.local.keys().map { ($0, items.local.get($0)) })),
                (
                    "remotes",
                    .array(try items.getRemotes().map { remote in
                        jsonObject([
                            ("attendee", .string(remote.attendee.attendeeId)),
                            ("items", entries(remote.items.entries.map { ($0.0, $0.1.value.resolve()) })),
                        ])
                    })
                ),
            ])
        ),
        (
            "notifications",
            .array(log.notifications.map {
                jsonObject([("attendee", .string($0.attendee)), ("name", .string($0.name)), ("args", .array($0.args))])
            })
        ),
    ])
}

/// Handles the `presence*` RPCs. Returns `nil` for any other method.
func presenceMethod(
    _ method: String, _ params: JSONValue, _ key: String, _ container: Container, _ logs: inout [String: PresenceLog]
) async throws -> JSONValue? {
    if method == "presenceJoin" {
        let log = PresenceLog()
        logs[key] = log
        return try await container.withPresence { presence, clock in
            _ = try workspaces(presence, clock, log)
            return .string(presence.attendees.getMyself().attendeeId)
        }
    }
    guard method.hasPrefix("presence") else { return nil }
    guard let log = logs[key] else { throw JSONDecodingError("presence not joined") }
    switch method {
    case "presenceSet":
        let value = try params.member("value")
        return try await container.withPresence { presence, clock in
            try workspaces(presence, clock, log).states.latest("cursor").setLocal(value)
            return .null
        }
    case "presenceMapSet":
        let itemKey = try params.member("key").asString()
        let value = try params.member("value")
        return try await container.withPresence { presence, clock in
            try workspaces(presence, clock, log).states.latestMap("items").local.set(itemKey, value)
            return .null
        }
    case "presenceMapDelete":
        let itemKey = try params.member("key").asString()
        return try await container.withPresence { presence, clock in
            .bool(try workspaces(presence, clock, log).states.latestMap("items").local.delete(itemKey))
        }
    case "presenceNotify":
        let name = try params.member("name").asString()
        let args = try params.member("args").asArray()
        return try await container.withPresence { presence, clock in
            try workspaces(presence, clock, log).events.notifications("ping").emit.broadcast(name, args)
            return .null
        }
    case "presenceView":
        return try await container.withPresence { presence, clock in try view(presence, clock, log) }
    default: throw JSONDecodingError("unknown presence method")
    }
}
