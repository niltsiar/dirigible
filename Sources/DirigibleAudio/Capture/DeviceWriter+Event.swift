extension DeviceWriter {
    /// What a listener posts to the writer queue (decision 0013).
    enum Event: Sendable {
        case rate(Double)
        /// The channel count of each input buffer.
        case layout([Int])
        case alive(Bool)
        case devicesChanged
    }
}
