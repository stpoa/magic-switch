import CoreBluetooth
import Foundation

/// Errors specific to BLE transport connections.
enum BLETransportError: Error {
  case disconnected
  case notConnected
  case writeFailed(String)
  case characteristicNotFound
  case timeout
}

/// A `TransportConnection` operating over CoreBluetooth.
/// Bridges a Bluetooth Low Energy link into a reliable stream for `SecureChannel`.
final class BLETransportConnection: NSObject, TransportConnection {
  // MARK: - Properties

  private let byteStreamBuffer: ByteStreamBuffer
  private let queue: DispatchQueue
  private var isCancelled = false

  // Central-side properties
  private weak var peripheral: CBPeripheral?
  private var commandCharacteristic: CBCharacteristic?

  // Peripheral-side properties
  private weak var central: CBCentral?
  private weak var peripheralManager: CBPeripheralManager?
  private var responseCharacteristic: CBMutableCharacteristic?

  // Send queue state for Central writes
  private var sendCompletion: ((Error?) -> Void)?
  private var pendingChunks: [Data] = []

  var isConnected: Bool {
    if isCancelled { return false }
    if let peripheral = peripheral {
      return peripheral.state == .connected
    }
    return central != nil && peripheralManager != nil
  }

  // MARK: - Initialization (Central / Outgoing Role)

  init(
    peripheral: CBPeripheral,
    commandCharacteristic: CBCharacteristic,
    queue: DispatchQueue = DispatchQueue(label: "com.magicswitch.ble.conn.central")
  ) {
    self.peripheral = peripheral
    self.commandCharacteristic = commandCharacteristic
    self.queue = queue
    self.byteStreamBuffer = ByteStreamBuffer(queue: queue)
    super.init()
  }

  // MARK: - Initialization (Peripheral / Incoming Role)

  init(
    central: CBCentral,
    peripheralManager: CBPeripheralManager,
    responseCharacteristic: CBMutableCharacteristic,
    queue: DispatchQueue = DispatchQueue(label: "com.magicswitch.ble.conn.peripheral")
  ) {
    self.central = central
    self.peripheralManager = peripheralManager
    self.responseCharacteristic = responseCharacteristic
    self.queue = queue
    self.byteStreamBuffer = ByteStreamBuffer(queue: queue)
    super.init()
  }

  // MARK: - Incoming Byte Ingestion

  /// Called when new raw bytes arrive over the BLE link.
  func ingestIncomingData(_ data: Data) {
    byteStreamBuffer.append(data)
  }

  // MARK: - TransportConnection Implementation

  func send(data: Data, completion: @escaping (Error?) -> Void) {
    queue.async {
      guard self.isConnected else {
        completion(BLETransportError.notConnected)
        return
      }

      if let peripheral = self.peripheral, let char = self.commandCharacteristic {
        self.sendAsCentral(
          data: data, peripheral: peripheral, characteristic: char, completion: completion)
      } else if let central = self.central, let manager = self.peripheralManager,
        let char = self.responseCharacteristic
      {
        self.sendAsPeripheral(
          data: data, central: central, manager: manager, characteristic: char,
          completion: completion)
      } else {
        completion(BLETransportError.notConnected)
      }
    }
  }

  func receive(exactByteCount count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
    byteStreamBuffer.read(exact: count, completion: completion)
  }

  func cancel() {
    queue.async {
      guard !self.isCancelled else { return }
      self.isCancelled = true
      self.byteStreamBuffer.fail(error: SecureChannelError.connectionClosed)
      if let sendComp = self.sendCompletion {
        self.sendCompletion = nil
        sendComp(BLETransportError.disconnected)
      }
    }
  }

  // MARK: - Central Sending (Chunked Write with Response)

  private func sendAsCentral(
    data: Data,
    peripheral: CBPeripheral,
    characteristic: CBCharacteristic,
    completion: @escaping (Error?) -> Void
  ) {
    let maxChunk = max(
      20, min(MagicSwitchBLE.maxChunkSize, peripheral.maximumWriteValueLength(for: .withResponse)))
    var chunks: [Data] = []
    var offset = 0
    while offset < data.count {
      let length = min(maxChunk, data.count - offset)
      chunks.append(data.subdata(in: offset..<(offset + length)))
      offset += length
    }

    self.pendingChunks = chunks
    self.sendCompletion = completion
    self.sendNextCentralChunk()
  }

  private func sendNextCentralChunk() {
    guard let peripheral = peripheral, let char = commandCharacteristic else {
      let comp = sendCompletion
      sendCompletion = nil
      comp?(BLETransportError.disconnected)
      return
    }

    guard !pendingChunks.isEmpty else {
      let comp = sendCompletion
      sendCompletion = nil
      comp?(nil)
      return
    }

    let chunk = pendingChunks.removeFirst()
    peripheral.writeValue(chunk, for: char, type: .withResponse)
  }

  /// Called by the peripheral delegate when a chunk write completes.
  func handleDidWriteValue(error: Error?) {
    queue.async {
      if let error = error {
        let comp = self.sendCompletion
        self.sendCompletion = nil
        self.pendingChunks.removeAll()
        comp?(error)
        return
      }
      self.sendNextCentralChunk()
    }
  }

  // MARK: - Peripheral Sending (Chunked Notification)

  private func sendAsPeripheral(
    data: Data,
    central: CBCentral,
    manager: CBPeripheralManager,
    characteristic: CBMutableCharacteristic,
    completion: @escaping (Error?) -> Void
  ) {
    let maxChunk = MagicSwitchBLE.maxChunkSize
    var offset = 0
    var success = true

    while offset < data.count {
      let length = min(maxChunk, data.count - offset)
      let chunk = data.subdata(in: offset..<(offset + length))
      let didSend = manager.updateValue(chunk, for: characteristic, onSubscribedCentrals: [central])
      if !didSend {
        // If the transmit queue is full, yield a small slice then retry
        usleep(5000)  // 5ms
        let retrySend = manager.updateValue(
          chunk, for: characteristic, onSubscribedCentrals: [central])
        if !retrySend {
          success = false
          break
        }
      }
      offset += length
    }

    if success {
      completion(nil)
    } else {
      completion(BLETransportError.writeFailed("Peripheral transmit buffer overflow"))
    }
  }
}
