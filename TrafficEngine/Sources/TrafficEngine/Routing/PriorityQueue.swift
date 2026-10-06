//
//  PriorityQueue.swift
//  TrafficEngine
//
//  A minimal binary min-heap used by the router.
//

struct PriorityQueue<Element> {
    private var heap: [Element] = []
    private let isHigherPriority: (Element, Element) -> Bool

    /// `areInIncreasingOrder(a, b)` should return true if `a` has higher
    /// priority (i.e. should be dequeued before `b`).
    init(_ areInIncreasingOrder: @escaping (Element, Element) -> Bool) {
        self.isHigherPriority = areInIncreasingOrder
    }

    var isEmpty: Bool { heap.isEmpty }
    var count: Int { heap.count }

    mutating func push(_ element: Element) {
        heap.append(element)
        siftUp(from: heap.count - 1)
    }

    mutating func pop() -> Element? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let element = heap.removeLast()
        if !heap.isEmpty { siftDown(from: 0) }
        return element
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        var parent = (child - 1) / 2
        while child > 0 && isHigherPriority(heap[child], heap[parent]) {
            heap.swapAt(child, parent)
            child = parent
            parent = (child - 1) / 2
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        let count = heap.count
        while true {
            let left = parent * 2 + 1
            let right = parent * 2 + 2
            var candidate = parent
            if left < count && isHigherPriority(heap[left], heap[candidate]) { candidate = left }
            if right < count && isHigherPriority(heap[right], heap[candidate]) { candidate = right }
            if candidate == parent { return }
            heap.swapAt(parent, candidate)
            parent = candidate
        }
    }
}
