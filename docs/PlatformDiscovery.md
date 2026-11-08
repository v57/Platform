# PlatformDiscovery

Browsing and advertising DNS-SD (Bonjour, mDNS) services on the local network. Part of [Platform](../README.md).

## Purpose

`PlatformDiscovery` replaces `NetService`, `NWBrowser` and the `dns_sd` C API with one browser and one advertiser:
the services of a type as they come and go, each resolved to a host name, port, addresses and TXT record; and one
service of the app's own, renamed when its name is taken.

It is not a connection API: it finds services and their addresses, and the app connects with its own networking.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformDiscovery", package: "Platform"),
```

```swift
import PlatformDiscovery

let advertiser = ServiceAdvertiser(name: nil, type: "_myapp._tcp", port: 45678, txt: ["v": "1"])
advertiser.start { event in
  if case .failed(let reason) = event { print(reason) }
}

let browser = ServiceBrowser(type: "_myapp._tcp")
browser.start { services in          // on a background queue
  for service in services where !service.isLocal {
    print(service.name, service.hostName, service.port, service.addresses)
  }
}
// Later: browser.stop(), advertiser.stop() (or release them).
```

## Main API

- `ServiceBrowser(type:domain:)`: `domain` nil browses the default domains.
  - `includesPeerToPeer`: on Apple platforms, also browse over peer-to-peer links (AWDL). Set before `start`.
  - `start(onChange:)`: `onChange` gets the whole list, sorted by name, whenever it changes, on a background queue.
  - `stop()`; releasing the browser stops it too.
- `DiscoveredService`: `name`, `type`, `domain`, `hostName`, `port`, `addresses` (IPv4 first; IPv6 link-local ones
  with their `%interface`), `txt`, `interfaceIndex`, `isLocal` (published by this machine), `id`.
- `ServiceAdvertiser(name:type:port:txt:)`: `name` nil takes the machine's name (`ServiceAdvertiser.machineName`, the
  host name without its domain).
  - `start(onEvent:)`: reports `ServiceAdvertiserEvent.registered(name:)` (the name it got, another one when the asked
    one was taken) or `.failed(String)`.
  - `stop()`; releasing the advertiser stops it too.

## Backends

- **macOS, iOS**: `dns_sd` (browse, resolve and address lookups) on a dispatch queue. On iOS the app's Info.plist
  needs `NSBonjourServices` with its types and `NSLocalNetworkUsageDescription`, as for any Bonjour code.
- **Linux**: the avahi-daemon through `libavahi-client` on its threaded poll loop (`apt install libavahi-client-dev`).
  Without a running avahi-daemon the browser finds nothing and the advertiser reports
  `.failed("avahi-daemon isn't running")`; both carry on when the daemon comes back.
- **Windows, Android**: none. The browser reports an empty list and the advertiser reports
  `.failed("No DNS-SD on this platform")`.

## Platform notes

- **macOS, iOS**: supported.
- **Linux**: builds on the Ubuntu VM; desktops run avahi-daemon.
- **Windows, Android**: no backend yet.

## Testing

```bash
swift test --filter PlatformDiscoveryTests
```

The test advertises a service of a type made for the run and finds it with a browser on the same machine. It needs
the system's mDNS service (mDNSResponder; on Linux avahi-daemon, and it's skipped when `/run/avahi-daemon/socket` is
missing).
