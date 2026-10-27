#if os(Linux)
  import Foundation
  import CAvahi

  /// An Avahi client on a threaded poll loop of its own: every callback runs on that loop's thread, and calls from
  /// elsewhere take its lock. With AVAHI_CLIENT_NO_FAIL it waits for an avahi-daemon that isn't running yet.
  final class AvahiSession: @unchecked Sendable {
    let poll: OpaquePointer
    private(set) var client: OpaquePointer?
    /// The daemon is up (AVAHI_CLIENT_S_RUNNING), and when it goes away or comes back.
    var onState: ((AvahiClientState) -> Void)?

    init?() {
      guard let poll = avahi_threaded_poll_new() else { return nil }
      self.poll = poll
    }

    /// Creates the client and starts the loop; false when Avahi can't be used at all.
    func start() -> Bool {
      let callback: AvahiClientCallback = { client, state, data in
        let session = Unmanaged<AvahiSession>.fromOpaque(data!).takeUnretainedValue()
        if session.client == nil { session.client = client }  // the first call comes from inside avahi_client_new
        session.onState?(state)
      }
      var error: Int32 = 0
      let client = avahi_client_new(
        avahi_threaded_poll_get(poll), AVAHI_CLIENT_NO_FAIL, callback, Unmanaged.passUnretained(self).toOpaque(), &error)
      guard let client else {
        discoveryLog("Avahi: \(String(cString: avahi_strerror(error)))")
        return false
      }
      self.client = client
      return avahi_threaded_poll_start(poll) == 0
    }

    /// Runs `body` with the loop held (not from the loop's own thread).
    func locked<T>(_ body: () -> T) -> T {
      avahi_threaded_poll_lock(poll)
      defer { avahi_threaded_poll_unlock(poll) }
      return body()
    }

    /// Stops the loop and frees the client (and with it every browser, resolver and entry group).
    func close() {
      avahi_threaded_poll_stop(poll)
      if let client { avahi_client_free(client) }
      client = nil
      avahi_threaded_poll_free(poll)
    }

    var lastError: String {
      guard let client else { return "no Avahi client" }
      return String(cString: avahi_strerror(avahi_client_errno(client)))
    }
  }

  func discoveryLog(_ message: String) {
    if ProcessInfo.processInfo.environment["PLATFORM_DISCOVERY_DEBUG"] != nil {
      FileHandle.standardError.write(Data("PlatformDiscovery: \(message)\n".utf8))
    }
  }

  // MARK: - Browsing

  final class BrowserBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var session: AvahiSession?
    private var browser: OpaquePointer?
    private var table = ServiceTable()
    private var onChange: (@Sendable ([DiscoveredService]) -> Void)?
    private var type = ""
    private var domain: String?

    func start(type: String, domain: String?, peerToPeer: Bool, onChange: @escaping @Sendable ([DiscoveredService]) -> Void) {
      stop()
      guard let session = AvahiSession() else { return onChange([]) }
      self.type = type
      self.domain = domain
      self.onChange = onChange
      self.session = session
      session.onState = { [unowned self] state in
        // On the loop's thread.
        switch state {
        case AVAHI_CLIENT_S_RUNNING:
          if self.browser == nil { self.createBrowser() }
        case AVAHI_CLIENT_FAILURE, AVAHI_CLIENT_CONNECTING:
          // The daemon went away: what it found is gone with it (NO_FAIL reconnects when it's back).
          if let browser = self.browser { avahi_service_browser_free(browser) }
          self.browser = nil
          self.lock.withLock { self.table = ServiceTable() }
          self.report()
        default: break
        }
      }
      if !session.start() {
        session.close()
        self.session = nil
        onChange([])
      }
    }

    func stop() {
      guard let session else { return }
      session.close()
      self.session = nil
      browser = nil
      lock.withLock { table = ServiceTable() }
    }

    private func createBrowser() {
      guard let client = session?.client else { return }
      let callback: AvahiServiceBrowserCallback = { _, interface, proto, event, name, type, domain, flags, data in
        let backend = Unmanaged<BrowserBackend>.fromOpaque(data!).takeUnretainedValue()
        backend.browsed(interface: interface, proto: proto, event: event, name: name, type: type, domain: domain)
      }
      browser = avahi_service_browser_new(
        client, AvahiIfIndex(AVAHI_IF_UNSPEC), AvahiProtocol(AVAHI_PROTO_UNSPEC), type, domain, AvahiLookupFlags(0), callback,
        Unmanaged.passUnretained(self).toOpaque())
      if browser == nil { discoveryLog("browse \(type): \(session?.lastError ?? "")") }
    }

    private func browsed(
      interface: AvahiIfIndex, proto: AvahiProtocol, event: AvahiBrowserEvent, name: UnsafePointer<CChar>?,
      type: UnsafePointer<CChar>?, domain: UnsafePointer<CChar>?
    ) {
      switch event {
      case AVAHI_BROWSER_NEW:
        guard let client = session?.client else { return }
        let callback: AvahiServiceResolverCallback = {
          resolver, interface, proto, event, name, type, domain, host, address, port, txt, flags, data in
          let backend = Unmanaged<BrowserBackend>.fromOpaque(data!).takeUnretainedValue()
          if event == AVAHI_RESOLVER_FOUND, let name, let type, let domain {
            backend.resolved(
              interface: interface, proto: proto, name: String(cString: name), type: String(cString: type),
              domain: String(cString: domain), host: host.map { String(cString: $0) } ?? "", address: address,
              port: port, txt: txt, isLocal: flags.rawValue & AVAHI_LOOKUP_RESULT_LOCAL.rawValue != 0)
          }
          avahi_service_resolver_free(resolver)
        }
        if avahi_service_resolver_new(
          client, interface, proto, name, type, domain, AvahiProtocol(AVAHI_PROTO_UNSPEC), AvahiLookupFlags(0), callback,
          Unmanaged.passUnretained(self).toOpaque()) == nil
        {
          discoveryLog("resolve: \(session?.lastError ?? "")")
        }
      case AVAHI_BROWSER_REMOVE:
        guard let name, let type, let domain else { return }
        let instance = ServiceTable.Instance(
          name: String(cString: name), type: String(cString: type), domain: String(cString: domain), interface: interface,
          proto: proto)
        lock.withLock { _ = table.resolved.removeValue(forKey: instance) }
        report()
      case AVAHI_BROWSER_FAILURE:
        discoveryLog("browser: \(session?.lastError ?? "")")
      default: break
      }
    }

    private func resolved(
      interface: AvahiIfIndex, proto: AvahiProtocol, name: String, type: String, domain: String, host: String,
      address: UnsafePointer<AvahiAddress>?, port: UInt16, txt: UnsafeMutablePointer<AvahiStringList>?, isLocal: Bool
    ) {
      var addresses: [String] = []
      if let address {
        var buffer = [CChar](repeating: 0, count: Int(AVAHI_ADDRESS_STR_MAX))
        avahi_address_snprint(&buffer, buffer.count, address)
        var text = String(cString: buffer)
        if address.pointee.proto == AvahiProtocol(AVAHI_PROTO_INET6), text.lowercased().hasPrefix("fe80") {
          var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
          if if_indextoname(UInt32(interface), &nameBuffer) != nil { text += "%" + String(cString: nameBuffer) }
        }
        addresses.append(text)
      }
      var record: [String: String] = [:]
      var item = txt
      while let current = item {
        var key: UnsafeMutablePointer<CChar>?
        var value: UnsafeMutablePointer<CChar>?
        var size = 0
        if avahi_string_list_get_pair(current, &key, &value, &size) == 0, let key {
          record[String(cString: key)] = value.map { String(cString: $0) } ?? ""
          avahi_free(key)
          if let value { avahi_free(value) }
        }
        item = avahi_string_list_get_next(current)
      }
      let instance = ServiceTable.Instance(name: name, type: type, domain: domain, interface: interface, proto: proto)
      let service = DiscoveredService(
        name: name, type: type, domain: domain, hostName: host, port: port, addresses: addresses, txt: record,
        interfaceIndex: interface >= 0 ? UInt32(interface) : nil, isLocal: isLocal)
      discoveryLog("found \(name) at \(host) \(addresses) port \(port)")
      lock.withLock { table.resolved[instance] = service }
      report()
    }

    private func report() {
      let services = lock.withLock { table.services }
      onChange?(services)
    }
  }

  // MARK: - Advertising

  final class AdvertiserBackend: @unchecked Sendable {
    private var session: AvahiSession?
    private var group: OpaquePointer?
    private var name = ""
    private var type = ""
    private var port: UInt16 = 0
    private var txt: [String: String] = [:]
    private var onEvent: (@Sendable (ServiceAdvertiserEvent) -> Void)?

    func start(
      name: String, type: String, port: UInt16, txt: [String: String],
      onEvent: @escaping @Sendable (ServiceAdvertiserEvent) -> Void
    ) {
      stop()
      guard let session = AvahiSession() else { return onEvent(.failed("Avahi isn't available")) }
      self.name = name
      self.type = type
      self.port = port
      self.txt = txt
      self.onEvent = onEvent
      self.session = session
      session.onState = { [unowned self] state in
        switch state {
        case AVAHI_CLIENT_S_RUNNING:
          if self.group == nil { self.publish() }
        case AVAHI_CLIENT_S_COLLISION, AVAHI_CLIENT_S_REGISTERING:
          // The host's own name is being (re)registered: the service goes up again once it's running.
          if let group = self.group { avahi_entry_group_reset(group) }
        case AVAHI_CLIENT_FAILURE, AVAHI_CLIENT_CONNECTING:
          self.group = nil  // freed with the old connection; NO_FAIL publishes again when the daemon is back
          self.onEvent?(.failed("avahi-daemon isn't running"))
        default: break
        }
      }
      if !session.start() {
        session.close()
        self.session = nil
        onEvent(.failed("Avahi isn't available"))
      }
    }

    func stop() {
      guard let session else { return }
      session.close()  // frees the entry group, which withdraws the service
      self.session = nil
      group = nil
    }

    /// Adds the service to the (new or reset) entry group and commits it. On the loop's thread.
    private func publish() {
      guard let client = session?.client else { return }
      if group == nil {
        let callback: AvahiEntryGroupCallback = { group, state, data in
          let backend = Unmanaged<AdvertiserBackend>.fromOpaque(data!).takeUnretainedValue()
          backend.groupChanged(state)
        }
        group = avahi_entry_group_new(client, callback, Unmanaged.passUnretained(self).toOpaque())
      }
      guard let group else { return fail() }
      var list: UnsafeMutablePointer<AvahiStringList>?
      for (key, value) in txt.sorted(by: { $0.key < $1.key }) { list = avahi_string_list_add_pair(list, key, value) }
      defer { avahi_string_list_free(list) }
      while true {
        let result = avahi_entry_group_add_service_strlst(
          group, AvahiIfIndex(AVAHI_IF_UNSPEC), AvahiProtocol(AVAHI_PROTO_UNSPEC), AvahiPublishFlags(0), name, type, nil, nil, port, list)
        if result == Int32(AVAHI_ERR_COLLISION) {
          rename()
          continue
        }
        guard result >= 0 else { return fail() }
        break
      }
      if avahi_entry_group_commit(group) < 0 { fail() }
    }

    private func rename() {
      if let alternative = avahi_alternative_service_name(name) {
        name = String(cString: alternative)
        avahi_free(alternative)
      }
    }

    private func fail() { onEvent?(.failed(session?.lastError ?? "Avahi failed")) }

    private func groupChanged(_ state: AvahiEntryGroupState) {
      switch state {
      case AVAHI_ENTRY_GROUP_ESTABLISHED:
        discoveryLog("advertising \(name) \(type) port \(port)")
        onEvent?(.registered(name: name))
      case AVAHI_ENTRY_GROUP_COLLISION:
        // Someone else on the network has the name: take "Name #2" and go again.
        rename()
        if let group { avahi_entry_group_reset(group) }
        publish()
      case AVAHI_ENTRY_GROUP_FAILURE:
        fail()
      default: break
      }
    }
  }
#endif
