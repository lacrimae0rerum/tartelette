/// A fixed-capacity ring buffer of samples; appending beyond capacity drops the oldest sample.
public struct MetricsHistory<Sample> {
  public let capacity: Int
  private var storage: [Sample] = []
  private var head = 0

  public init(capacity: Int) {
    precondition(capacity > 0, "MetricsHistory needs a positive capacity")
    self.capacity = capacity
    storage.reserveCapacity(capacity)
  }

  public var count: Int { storage.count }
  public var isEmpty: Bool { storage.isEmpty }

  /// Samples in chronological order (oldest first).
  public var samples: [Sample] {
    guard storage.count == capacity, head != 0 else { return storage }
    return Array(storage[head...] + storage[..<head])
  }

  public var latest: Sample? {
    guard !storage.isEmpty else { return nil }
    return storage.count < capacity ? storage.last : storage[(head + capacity - 1) % capacity]
  }

  public mutating func append(_ sample: Sample) {
    if storage.count < capacity {
      storage.append(sample)
    } else {
      storage[head] = sample
      head = (head + 1) % capacity
    }
  }

  public mutating func removeAll() {
    storage.removeAll(keepingCapacity: true)
    head = 0
  }
}

extension MetricsHistory: Sendable where Sample: Sendable {}

extension MetricsHistory: Equatable where Sample: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.capacity == rhs.capacity && lhs.samples == rhs.samples
  }
}
