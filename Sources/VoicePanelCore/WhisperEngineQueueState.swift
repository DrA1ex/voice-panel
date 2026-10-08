public struct WhisperEnginePendingQueue<Element: Sendable>: Sendable {
    private var elements: [Element] = []
    private var isFinishing = false

    public init() {}

    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }
    public var shouldFinalize: Bool { isFinishing && elements.isEmpty }

    @discardableResult
    public mutating func append(_ element: Element) -> Bool {
        guard !isFinishing else { return false }
        elements.append(element)
        return true
    }

    public mutating func removeFirst() -> Element? {
        guard !elements.isEmpty else { return nil }
        return elements.removeFirst()
    }

    public mutating func finish() {
        isFinishing = true
    }

    public mutating func reset() {
        elements.removeAll(keepingCapacity: true)
        isFinishing = false
    }
}
