import CoreBluetooth
import Foundation

/// Coordinates peer discovery and bidirectional session management over Bluetooth LE.
/// Operates simultaneously as a GATT Server (CBPeripheralManager) to receive handoff commands
/// and as a GATT Client (CBCentralManager) to discover and dispatch commands to peer Macs.
final class BLETransportManager: NSObject, ObservableObject {
  // MARK: - Singleton

  static let shared = BLETransportManager()

  // MARK: - Properties

  private let centralQueue = DispatchQueue(label: "com.magicswitch.ble.central.queue")
  private let peripheralQueue = DispatchQueue(label: "com.magicswitch.ble.peripheral.queue")
  private let rateLimiter = RateLimiter()

  private var centralManager: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?

  // Peripheral (Server) state
  private var serviceAdded = false
  private var responseCharacteristic: CBMutableCharacteristic?
  private var activeServerConnections: [UUID: BLETransportConnection] = [:]

  // Central (Client) state
  private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
  private var activeClientConnections: [UUID: BLETransportConnection] = [:]
  private var pendingClientConnects: [UUID: (Result<BLETransportConnection, Error>) -> Void] = [:]

  // MARK: - Lifecycle

  func start() {
    centralManager = CBCentralManager(delegate: self, queue: centralQueue)
    peripheralManager = CBPeripheralManager(delegate: self, queue: peripheralQueue)
    Log.network.notice("BLETransportManager: started Bluetooth transport services")
  }

  func stop() {
    centralManager?.stopScan()
    peripheralManager?.stopAdvertising()
    Log.network.notice("BLETransportManager: stopped Bluetooth transport services")
  }

  /// Checks whether a peer device is currently known and reachable over Bluetooth.
  func isPeerAvailable(identifier: UUID) -> Bool {
    centralQueue.sync {
      guard let p = discoveredPeripherals[identifier] else { return false }
      return p.state == .connected || centralManager?.state == .poweredOn
    }
  }

  /// Establishes an authenticated transport connection to a discovered peer Mac over BLE.
  func connect(
    to peripheralIdentifier: UUID,
    timeout: TimeInterval = MagicSwitchBLE.bleConnectTimeout,
    completion: @escaping (Result<BLETransportConnection, Error>) -> Void
  ) {
    centralQueue.async {
      guard let central = self.centralManager, central.state == .poweredOn else {
        completion(.failure(BLETransportError.notConnected))
        return
      }

      guard let peripheral = self.discoveredPeripherals[peripheralIdentifier] else {
        completion(.failure(BLETransportError.characteristicNotFound))
        return
      }

      self.pendingClientConnects[peripheralIdentifier] = completion

      // If already connected, discover characteristics directly
      if peripheral.state == .connected {
        self.prepareConnectedPeripheral(peripheral)
      } else {
        central.connect(peripheral, options: nil)
      }

      // Enforce connection timeout
      self.centralQueue.asyncAfter(deadline: .now() + timeout) {
        if let pending = self.pendingClientConnects.removeValue(forKey: peripheralIdentifier) {
          pending(.failure(BLETransportError.timeout))
        }
      }
    }
  }

  private func prepareConnectedPeripheral(_ peripheral: CBPeripheral) {
    peripheral.delegate = self
    peripheral.discoverServices([MagicSwitchBLE.serviceUUID])
  }
}

// MARK: - CBPeripheralManagerDelegate (Server / Peripheral Role)

extension BLETransportManager: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard peripheral.state == .poweredOn else { return }

    if !serviceAdded {
      setupGATTService(peripheral)
    } else {
      startAdvertising()
    }
  }

  private func setupGATTService(_ manager: CBPeripheralManager) {
    let service = CBMutableService(type: MagicSwitchBLE.serviceUUID, primary: true)

    let commandChar = CBMutableCharacteristic(
      type: MagicSwitchBLE.commandCharacteristicUUID,
      properties: [.write, .writeWithoutResponse],
      value: nil,
      permissions: [.writeable]
    )

    let responseChar = CBMutableCharacteristic(
      type: MagicSwitchBLE.responseCharacteristicUUID,
      properties: [.notify],
      value: nil,
      permissions: [.readable]
    )
    self.responseCharacteristic = responseChar

    let metadataChar = CBMutableCharacteristic(
      type: MagicSwitchBLE.metadataCharacteristicUUID,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )

    service.characteristics = [commandChar, responseChar, metadataChar]
    manager.add(service)
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?
  ) {
    if let error = error {
      Log.network.error("BLETransportManager: failed to add GATT service: \(error)")
      return
    }
    serviceAdded = true
    startAdvertising()
  }

  private func startAdvertising() {
    guard let manager = peripheralManager, manager.state == .poweredOn else { return }
    let name = Host.current().localizedName ?? "Mac"
    let advertisementData: [String: Any] = [
      CBAdvertisementDataServiceUUIDsKey: [MagicSwitchBLE.serviceUUID],
      CBAdvertisementDataLocalNameKey: name,
    ]
    manager.startAdvertising(advertisementData)
    Log.network.notice("BLETransportManager: advertising Magic Switch service as '\(name)'")
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard request.characteristic.uuid == MagicSwitchBLE.metadataCharacteristicUUID else {
      peripheral.respond(to: request, withResult: .requestNotSupported)
      return
    }

    let localName = Host.current().localizedName ?? "Mac"
    let fingerprint = PairingStore.shared.fingerprint
    let metadata = BLEPeerMetadata(
      name: localName,
      fingerprint: fingerprint,
      version: MagicSwitchBLE.protocolVersion
    )

    do {
      let data = try JSONEncoder().encode(metadata)
      if request.offset > data.count {
        peripheral.respond(to: request, withResult: .invalidOffset)
        return
      }
      request.value = data.subdata(in: request.offset..<data.count)
      peripheral.respond(to: request, withResult: .success)
    } catch {
      peripheral.respond(to: request, withResult: .unlikelyError)
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]
  ) {
    for request in requests {
      guard request.characteristic.uuid == MagicSwitchBLE.commandCharacteristicUUID,
        let data = request.value
      else {
        peripheral.respond(to: request, withResult: .requestNotSupported)
        continue
      }

      let centralID = request.central.identifier
      var connection = activeServerConnections[centralID]

      if connection == nil, let responseChar = responseCharacteristic {
        // Create new incoming connection session
        let newConn = BLETransportConnection(
          central: request.central,
          peripheralManager: peripheral,
          responseCharacteristic: responseChar,
          queue: peripheralQueue
        )
        activeServerConnections[centralID] = newConn
        connection = newConn

        // Spawn IncomingConnection to handle mutual handshake and commands
        DispatchQueue.main.async { [weak self] in
          guard let self = self else { return }
          let incoming = IncomingConnection(
            transport: newConn,
            endpointDesc: "Bluetooth (\(centralID))",
            rateLimiter: self.rateLimiter,
            pairingStore: PairingStore.shared,
            queue: DispatchQueue(label: "com.magicswitch.ble.incoming.\(centralID)"),
            localIdentity: {
              IntroducedIdentity(
                name: Host.current().localizedName ?? "Mac",
                port: 0
              )
            }
          )
          incoming.start()
        }
      }

      connection?.ingestIncomingData(data)
      peripheral.respond(to: request, withResult: .success)
    }
  }
}

// MARK: - CBCentralManagerDelegate (Client / Central Role)

extension BLETransportManager: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central.state == .poweredOn else { return }
    central.scanForPeripherals(
      withServices: [MagicSwitchBLE.serviceUUID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
    Log.network.notice("BLETransportManager: scanning for peer Macs over BLE")
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    discoveredPeripherals[peripheral.identifier] = peripheral
    peripheral.delegate = self
    // Connect to read metadata and identify the peer
    central.connect(peripheral, options: nil)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    prepareConnectedPeripheral(peripheral)
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    if let pending = pendingClientConnects.removeValue(forKey: peripheral.identifier) {
      pending(.failure(error ?? BLETransportError.notConnected))
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    if let conn = activeClientConnections.removeValue(forKey: peripheral.identifier) {
      conn.cancel()
    }
    if let pending = pendingClientConnects.removeValue(forKey: peripheral.identifier) {
      pending(.failure(BLETransportError.disconnected))
    }
  }
}

// MARK: - CBPeripheralDelegate (Client characteristics and I/O)

extension BLETransportManager: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let services = peripheral.services else { return }
    for service in services where service.uuid == MagicSwitchBLE.serviceUUID {
      peripheral.discoverCharacteristics(
        [
          MagicSwitchBLE.commandCharacteristicUUID,
          MagicSwitchBLE.responseCharacteristicUUID,
          MagicSwitchBLE.metadataCharacteristicUUID,
        ],
        for: service
      )
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard let characteristics = service.characteristics else { return }

    var commandChar: CBCharacteristic?
    var responseChar: CBCharacteristic?
    var metadataChar: CBCharacteristic?

    for char in characteristics {
      switch char.uuid {
      case MagicSwitchBLE.commandCharacteristicUUID: commandChar = char
      case MagicSwitchBLE.responseCharacteristicUUID: responseChar = char
      case MagicSwitchBLE.metadataCharacteristicUUID: metadataChar = char
      default: break
      }
    }

    // Subscribe to responses
    if let responseChar = responseChar {
      peripheral.setNotifyValue(true, for: responseChar)
    }

    // Read peer metadata to register in NetworkDeviceStore
    if let metadataChar = metadataChar {
      peripheral.readValue(for: metadataChar)
    }

    // If an outgoing connection is waiting for this peripheral to be ready
    if let commandChar = commandChar,
      let pending = pendingClientConnects.removeValue(forKey: peripheral.identifier)
    {
      let connection = BLETransportConnection(
        peripheral: peripheral,
        commandCharacteristic: commandChar,
        queue: centralQueue
      )
      activeClientConnections[peripheral.identifier] = connection
      pending(.success(connection))
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard error == nil, let data = characteristic.value else { return }

    if characteristic.uuid == MagicSwitchBLE.metadataCharacteristicUUID {
      // Decode and register peer in NetworkDeviceStore
      do {
        let metadata = try JSONDecoder().decode(BLEPeerMetadata.self, from: data)
        DispatchQueue.main.async {
          NetworkDeviceStore.shared.registerDiscoveredBluetoothPeer(
            identifier: peripheral.identifier,
            name: metadata.name,
            fingerprint: metadata.fingerprint
          )
        }
      } catch {
        Log.network.error("BLETransportManager: failed to decode peer metadata: \(error)")
      }
    } else if characteristic.uuid == MagicSwitchBLE.responseCharacteristicUUID {
      // Deliver response data to the active client connection
      if let connection = activeClientConnections[peripheral.identifier] {
        connection.ingestIncomingData(data)
      }
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let connection = activeClientConnections[peripheral.identifier] {
      connection.handleDidWriteValue(error: error)
    }
  }
}
