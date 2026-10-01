/// Stack of recently closed tabs, for "Reopen Closed Tab" (⌘⇧T).
public struct RecentlyClosed<Item> {
    public private(set) var items: [Item] = []
    public let capacity: Int

    public init(capacity: Int = 20) { self.capacity = max(1, capacity) }

    public mutating func push(_ item: Item) {
        items.append(item)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }

    public mutating func pop() -> Item? { items.popLast() }

    public var isEmpty: Bool { items.isEmpty }
}
