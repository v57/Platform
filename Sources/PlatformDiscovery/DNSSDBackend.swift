#if canImport(dnssd)
  import Foundation
  import dnssd

  /// dns_sd (mDNSResponder) behind the browser and advertiser on Apple platforms: every operation's callbacks run on
  /// one serial queue (DNSServiceSetDispatchQueue).
  final class BrowserBackend: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.v57.platform.discovery.browser")
    private var browseRef: DNSServiceRef?
    /// Resolutions in flight or done, per instance (their refs stay open to follow address changes).
    private var resolutions: [ServiceTable.Instance: Resolution] = [:]
    private var table = ServiceTable()
    private var onChange: (@Sendable ([DiscoveredService]) -> Void)?
    private var generation = 0

    /// One instance being resolved to a host and port, then the host to addresses.
    final class Resolution {
      let instance: ServiceTable.Instance
      weak var backend: BrowserBackend?
      var resolveRef: DNSServiceRef?
      var addressRef: DNSServiceRef?
      var service: DiscoveredService?

      init(instance: ServiceTable.Instance, backend: BrowserBackend) {
        self.instance = instance
        self.backend = backend
      }

      func cancel() {
        if let resolveRef { DNSServiceRefDeallocate(resolveRef) }
        if let addressRef { DNSServiceRefDeallocate(addressRef) }
        resolveRef = nil
        addressRef = nil
      }
    }

    func start(type: String, domain: String?, peerToPeer: Bool, onChange: @escaping @Sendable ([DiscoveredService]) -> Void) {
      queue.sync {
        stopOnQueue()
        self.onChange = onChange
        let callback: DNSServiceBrowseReply = { _, flags, interface, error, name, type, domain, context in
          let backend = Unmanaged<BrowserBackend>.fromOpaque(context!).takeUnretainedValue()
          guard error == kDNSServiceErr_NoError, let name, let type, let domain else { return }
          backend.browsed(
            added: flags & kDNSServiceFlagsAdd != 0, moreComing: flags & kDNSServiceFlagsMoreComing != 0,
            interface: interface, name: String(cString: name), type: String(cString: type),
            domain: String(cString: domain))
        }
        var ref: DNSServiceRef?
        let flags = peerToPeer ? DNSServiceFlags(kDNSServiceFlagsIncludeP2P) : 0
        let error = DNSServiceBrowse(&ref, flags, 0, type, domain, callback, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let ref else {
          onChange([])
          return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        browseRef = ref
      }
    }

    func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
      if let browseRef { DNSServiceRefDeallocate(browseRef) }
      browseRef = nil
      resolutions.values.forEach { $0.cancel() }
      resolutions = [:]
      table = ServiceTable()
      onChange = nil
    }

    private func browsed(added: Bool, moreComing: Bool, interface: UInt32, name: String, type: String, domain: String) {
      // dns_sd gives the type with a trailing dot ("_x._udp.") and the domain as "local.": shown without it.
      let instance = ServiceTable.Instance(
        name: name, type: type.trimmingSuffix("."), domain: domain.trimmingSuffix("."), interface: Int32(interface),
        proto: 0)
      if added {
        guard resolutions[instance] == nil else { return }
        let resolution = Resolution(instance: instance, backend: self)
        resolutions[instance] = resolution
        resolve(resolution, rawType: type, rawDomain: domain)
      } else {
        resolutions.removeValue(forKey: instance)?.cancel()
        table.resolved[instance] = nil
        if !moreComing { report() }
      }
    }

    private func resolve(_ resolution: Resolution, rawType: String, rawDomain: String) {
      let callback: DNSServiceResolveReply = { _, flags, interface, error, _, host, port, txtLength, txt, context in
        let resolution = Unmanaged<Resolution>.fromOpaque(context!).takeUnretainedValue()
        guard error == kDNSServiceErr_NoError, let host, let backend = resolution.backend else { return }
        var record: [String: String] = [:]
        if let txt {
          for index in 0..<TXTRecordGetCount(txtLength, txt) {
            var key = [CChar](repeating: 0, count: 256)
            var valueLength: UInt8 = 0
            var value: UnsafeRawPointer?
            guard TXTRecordGetItemAtIndex(txtLength, txt, index, UInt16(key.count), &key, &valueLength, &value)
              == kDNSServiceErr_NoError
            else { continue }
            let text = value.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(valueLength)), as: UTF8.self) }
            record[String(cString: key)] = text ?? ""
          }
        }
        let instance = resolution.instance
        let hostName = String(cString: host).trimmingSuffix(".")
        let isLocal = hostName.lowercased() == (ProcessInfo.processInfo.hostName.lowercased().trimmingSuffix(".local") + ".local")
        let service = DiscoveredService(
          name: instance.name, type: instance.type, domain: instance.domain, hostName: hostName,
          port: UInt16(bigEndian: port), addresses: resolution.service?.hostName == hostName ? resolution.service?.addresses ?? [] : [],
          txt: record, interfaceIndex: interface, isLocal: isLocal)
        resolution.service = service
        backend.table.resolved[instance] = service
        backend.report()
        if resolution.addressRef == nil { backend.lookUpAddresses(resolution, host: String(cString: host)) }
      }
      var ref: DNSServiceRef?
      let context = Unmanaged.passUnretained(resolution).toOpaque()
      let error = DNSServiceResolve(
        &ref, 0, UInt32(resolution.instance.interface), resolution.instance.name, rawType, rawDomain, callback, context)
      guard error == kDNSServiceErr_NoError, let ref else { return }
      DNSServiceSetDispatchQueue(ref, queue)
      resolution.resolveRef = ref
    }

    private func lookUpAddresses(_ resolution: Resolution, host: String) {
      let callback: DNSServiceGetAddrInfoReply = { _, flags, interface, error, _, address, _, context in
        let resolution = Unmanaged<Resolution>.fromOpaque(context!).takeUnretainedValue()
        guard error == kDNSServiceErr_NoError, let address, let backend = resolution.backend,
          var service = resolution.service, let text = BrowserBackend.numeric(address, interface: interface)
        else { return }
        if flags & kDNSServiceFlagsAdd != 0 {
          if !service.addresses.contains(text) { service.addresses.append(text) }
        } else {
          service.addresses.removeAll { $0 == text }
        }
        resolution.service = service
        backend.table.resolved[resolution.instance] = service
        if flags & kDNSServiceFlagsMoreComing == 0 { backend.report() }
      }
      var ref: DNSServiceRef?
      let error = DNSServiceGetAddrInfo(
        &ref, 0, UInt32(resolution.instance.interface), DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
        host, callback, Unmanaged.passUnretained(resolution).toOpaque())
      guard error == kDNSServiceErr_NoError, let ref else { return }
      DNSServiceSetDispatchQueue(ref, queue)
      resolution.addressRef = ref
    }

    static func numeric(_ address: UnsafePointer<sockaddr>, interface: UInt32) -> String? {
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let length = socklen_t(address.pointee.sa_family == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
      guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
      return String(cString: host)  // link-local IPv6 comes with its %interface
    }

    private func report() {
      onChange?(table.services)
    }
  }

  final class AdvertiserBackend: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.v57.platform.discovery.advertiser")
    private var ref: DNSServiceRef?
    private var onEvent: (@Sendable (ServiceAdvertiserEvent) -> Void)?

    func start(
      name: String, type: String, port: UInt16, txt: [String: String],
      onEvent: @escaping @Sendable (ServiceAdvertiserEvent) -> Void
    ) {
      queue.sync {
        stopOnQueue()
        self.onEvent = onEvent
        var record = TXTRecordRef()
        TXTRecordCreate(&record, 0, nil)
        defer { TXTRecordDeallocate(&record) }
        for (key, value) in txt.sorted(by: { $0.key < $1.key }) {
          let bytes = Array(value.utf8)
          _ = TXTRecordSetValue(&record, key, UInt8(min(bytes.count, 255)), bytes)
        }
        let callback: DNSServiceRegisterReply = { _, _, error, name, _, _, context in
          let backend = Unmanaged<AdvertiserBackend>.fromOpaque(context!).takeUnretainedValue()
          if error == kDNSServiceErr_NoError, let name {
            backend.onEvent?(.registered(name: String(cString: name)))
          } else {
            backend.onEvent?(.failed("dns_sd error \(error)"))
          }
        }
        var ref: DNSServiceRef?
        let error = DNSServiceRegister(
          &ref, 0, 0, name, type, nil, nil, port.bigEndian, TXTRecordGetLength(&record), TXTRecordGetBytesPtr(&record),
          callback, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let ref else {
          onEvent(.failed("dns_sd error \(error)"))
          return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        self.ref = ref
      }
    }

    func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
      if let ref { DNSServiceRefDeallocate(ref) }
      ref = nil
      onEvent = nil
    }
  }

  extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
      hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
  }
#elseif !os(Linux)
  import Foundation

  /// No DNS-SD here (Windows, Android): nothing is found or advertised.
  final class BrowserBackend: @unchecked Sendable {
    func start(type: String, domain: String?, peerToPeer: Bool, onChange: @escaping @Sendable ([DiscoveredService]) -> Void) {
      onChange([])
    }
    func stop() {}
  }

  final class AdvertiserBackend: @unchecked Sendable {
    func start(
      name: String, type: String, port: UInt16, txt: [String: String],
      onEvent: @escaping @Sendable (ServiceAdvertiserEvent) -> Void
    ) { onEvent(.failed("No DNS-SD on this platform")) }
    func stop() {}
  }
#endif
