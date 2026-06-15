import AppKit

struct SplitTree<ViewType: NSView & Identifiable> {
  let root: Node?
  let zoomed: Node?

  struct Split: Equatable {
    let direction: Direction
    let ratio: Double
    let left: Node
    let right: Node
  }

  indirect enum Node: Equatable {
    case leaf(view: ViewType)
    case split(Split)
  }

  enum Direction: Equatable {
    case horizontal
    case vertical
  }

  enum PathComponent: Equatable {
    case left
    case right
  }

  struct Path: Equatable {
    let path: [PathComponent]

    var isEmpty: Bool { path.isEmpty }

  }

  struct SpatialSlot {
    let node: Node
    let bounds: CGRect
  }

  enum SpatialDirection {
    case left
    case right
    case top
    case down
  }

  struct Spatial {
    let slots: [SpatialSlot]
  }

  enum SplitError: Error {
    case viewNotFound
  }

  enum NewDirection {
    case left
    case right
    case down
    case top
  }

  enum FocusDirection {
    case previous
    case next
    case spatial(SpatialDirection)
  }

  var isEmpty: Bool {
    root == nil
  }

  var isSplit: Bool {
    if case .split = root { true } else { false }
  }

  var visibleNode: Node? {
    zoomed ?? root
  }

  init() {
    self.init(root: nil, zoomed: nil)
  }

  init(view: ViewType) {
    self.init(root: .leaf(view: view), zoomed: nil)
  }

  func contains(_ view: ViewType) -> Bool {
    root?.node(view: view) != nil
  }

  func contains(_ node: Node) -> Bool {
    root?.path(to: node) != nil
  }

  func find(id: ViewType.ID) -> Node? {
    root?.find(id: id)
  }

  func inserting(view: ViewType, at anchor: ViewType, direction: NewDirection, ratio: Double = 0.5) throws -> Self {
    guard let root else { throw SplitError.viewNotFound }
    return .init(
      root: try root.inserting(view: view, at: anchor, direction: direction, ratio: ratio),
      zoomed: nil
    )
  }

  func removing(_ target: Node) -> Self {
    guard let root else { return self }
    if root == target {
      return .init(root: nil, zoomed: nil)
    }
    let newRoot = root.remove(target)
    let newZoomed = (zoomed == target) ? nil : zoomed
    return .init(root: newRoot, zoomed: newZoomed)
  }

  func replacing(node: Node, with newNode: Node) throws -> Self {
    guard let root else { throw SplitError.viewNotFound }
    guard let path = root.path(to: node) else { throw SplitError.viewNotFound }
    let newRoot = try root.replacingNode(at: path, with: newNode)
    let newZoomed = (zoomed == node) ? newNode : zoomed
    return .init(root: newRoot, zoomed: newZoomed)
  }

  func focusTarget(for direction: FocusDirection, from currentNode: Node) -> ViewType? {
    guard let root else { return nil }

    switch direction {
    case .previous:
      let allLeaves = root.leaves()
      let currentView = currentNode.leftmostLeaf()
      guard let currentIndex = allLeaves.firstIndex(where: { $0 === currentView }) else {
        return nil
      }
      let index = allLeaves.indexWrapping(before: currentIndex)
      return allLeaves[index]

    case .next:
      let allLeaves = root.leaves()
      let currentView = currentNode.rightmostLeaf()
      guard let currentIndex = allLeaves.firstIndex(where: { $0 === currentView }) else {
        return nil
      }
      let index = allLeaves.indexWrapping(after: currentIndex)
      return allLeaves[index]

    case .spatial(let spatialDirection):
      let spatial = root.spatial()
      let nodes = spatial.slots(in: spatialDirection, from: currentNode)
      if nodes.isEmpty { return nil }
      let bestNode =
        nodes.first(where: {
          if case .leaf = $0.node { return true }
          return false
        }) ?? nodes[0]
      switch bestNode.node {
      case .leaf(let view):
        return view

      case .split:
        return switch spatialDirection {
        case .top, .left: bestNode.node.leftmostLeaf()
        case .down, .right: bestNode.node.rightmostLeaf()
        }
      }
    }
  }

  func focusTargetAfterClosing(_ node: Node) -> ViewType? {
    guard let root else { return nil }

    // Match Ghostty's macOS controller: closing the leftmost leaf moves to the next
    // surface, otherwise we move to the previous one.
    if root.leftmostLeaf() === node.leftmostLeaf() {
      return focusTarget(for: .next, from: node)
    } else {
      return focusTarget(for: .previous, from: node)
    }
  }

  func equalized() -> Self {
    guard let root else { return self }
    let newRoot = root.equalize()
    return .init(root: newRoot, zoomed: zoomed)
  }

  func settingZoomed(_ node: Node?) -> Self {
    .init(root: root, zoomed: node)
  }

  func resizing(
    node: Node,
    by pixels: UInt16,
    in direction: SpatialDirection,
    with bounds: CGRect
  ) throws -> Self {
    guard let root else { throw SplitError.viewNotFound }
    guard let path = root.path(to: node) else { throw SplitError.viewNotFound }

    let targetSplitDirection: Direction =
      switch direction {
      case .top, .down: .vertical
      case .left, .right: .horizontal
      }

    var splitPath: Path?
    var splitNode: Node?

    if !path.path.isEmpty {
      for index in stride(from: path.path.count - 1, through: 0, by: -1) {
        let parentPath = Path(path: Array(path.path.prefix(index)))
        if let parent = root.node(at: parentPath), case .split(let split) = parent {
          if split.direction == targetSplitDirection {
            splitPath = parentPath
            splitNode = parent
            break
          }
        }
      }
    }

    guard let splitPath,
      let splitNode,
      case .split(let split) = splitNode
    else {
      throw SplitError.viewNotFound
    }

    let spatial = root.spatial(within: bounds.size)
    guard let splitSlot = spatial.slots.first(where: { $0.node == splitNode }) else {
      throw SplitError.viewNotFound
    }

    let pixelOffset = Double(pixels)
    let width = max(splitSlot.bounds.width, 1)
    let height = max(splitSlot.bounds.height, 1)
    let newRatio: Double

    switch (split.direction, direction) {
    case (.horizontal, .left):
      newRatio = split.ratio - (pixelOffset / width)
    case (.horizontal, .right):
      newRatio = split.ratio + (pixelOffset / width)
    case (.vertical, .top):
      newRatio = split.ratio - (pixelOffset / height)
    case (.vertical, .down):
      newRatio = split.ratio + (pixelOffset / height)
    default:
      throw SplitError.viewNotFound
    }

    let clamped = max(0.1, min(0.9, newRatio))
    let newSplit = Split(
      direction: split.direction,
      ratio: clamped,
      left: split.left,
      right: split.right
    )

    let newRoot = try root.replacingNode(at: splitPath, with: .split(newSplit))
    return .init(root: newRoot, zoomed: nil)
  }

  func viewBounds() -> CGSize {
    root?.viewBounds() ?? .zero
  }

  func leaves() -> [ViewType] {
    root?.leaves() ?? []
  }

  func visibleLeaves() -> [ViewType] {
    visibleNode?.leaves() ?? []
  }

  var structuralIdentity: StructuralIdentity {
    StructuralIdentity(self)
  }

  struct StructuralIdentity: Hashable {
    private let root: Node?
    private let zoomed: Node?

    init(_ tree: SplitTree) {
      self.root = tree.root
      self.zoomed = tree.zoomed
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      areNodesStructurallyEqual(lhs.root, rhs.root)
        && areNodesStructurallyEqual(lhs.zoomed, rhs.zoomed)
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(0)
      if let root {
        root.hashStructure(into: &hasher)
      }
      hasher.combine(1)
      if let zoomed {
        zoomed.hashStructure(into: &hasher)
      }
    }

    private static func areNodesStructurallyEqual(_ lhs: Node?, _ rhs: Node?) -> Bool {
      switch (lhs, rhs) {
      case (nil, nil):
        return true
      case (let node1?, let node2?):
        return node1.isStructurallyEqual(to: node2)
      default:
        return false
      }
    }
  }

  private init(root: Node?, zoomed: Node?) {
    self.root = root
    self.zoomed = zoomed
  }
}

extension SplitTree.Node {
  typealias Node = SplitTree.Node
  typealias NewDirection = SplitTree.NewDirection
  typealias SplitError = SplitTree.SplitError
  typealias Path = SplitTree.Path
  typealias PathComponent = SplitTree.PathComponent
  typealias Split = SplitTree.Split

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.leaf(let leftView), .leaf(let rightView)):
      return leftView === rightView

    case (.split(let split1), .split(let split2)):
      return split1 == split2

    default:
      return false
    }
  }

  func find(id: ViewType.ID) -> Node? {
    switch self {
    case .leaf(let view):
      return view.id == id ? self : nil
    case .split(let split):
      if let found = split.left.find(id: id) { return found }
      return split.right.find(id: id)
    }
  }

  func node(view: ViewType) -> Node? {
    switch self {
    case .leaf(let leafView):
      return leafView === view ? self : nil
    case .split(let split):
      if let result = split.left.node(view: view) { return result }
      if let result = split.right.node(view: view) { return result }
      return nil
    }
  }

  func path(to node: Self) -> Path? {
    var components: [PathComponent] = []
    func search(_ current: Self) -> Bool {
      if current == node { return true }
      switch current {
      case .leaf:
        return false
      case .split(let split):
        components.append(.left)
        if search(split.left) { return true }
        components.removeLast()
        components.append(.right)
        if search(split.right) { return true }
        components.removeLast()
        return false
      }
    }
    return search(self) ? Path(path: components) : nil
  }

  func node(at path: Path) -> Node? {
    if path.isEmpty { return self }
    guard case .split(let split) = self else { return nil }
    let component = path.path[0]
    let remainingPath = Path(path: Array(path.path.dropFirst()))
    switch component {
    case .left:
      return split.left.node(at: remainingPath)
    case .right:
      return split.right.node(at: remainingPath)
    }
  }

  func inserting(view: ViewType, at anchor: ViewType, direction: NewDirection, ratio: Double = 0.5) throws -> Self {
    guard let path = path(to: .leaf(view: anchor)) else {
      throw SplitError.viewNotFound
    }

    let splitDirection: SplitTree.Direction
    let newViewOnLeft: Bool
    switch direction {
    case .left:
      splitDirection = .horizontal
      newViewOnLeft = true
    case .right:
      splitDirection = .horizontal
      newViewOnLeft = false
    case .top:
      splitDirection = .vertical
      newViewOnLeft = true
    case .down:
      splitDirection = .vertical
      newViewOnLeft = false
    }

    let newNode: Node = .leaf(view: view)
    let existingNode: Node = .leaf(view: anchor)
    let newSplit: Node = .split(
      .init(
        direction: splitDirection,
        ratio: ratio,
        left: newViewOnLeft ? newNode : existingNode,
        right: newViewOnLeft ? existingNode : newNode
      ))

    return try replacingNode(at: path, with: newSplit)
  }

  func replacingNode(at path: Path, with newNode: Self) throws -> Self {
    if path.isEmpty { return newNode }

    func replaceInner(current: Node, pathOffset: Int) throws -> Node {
      if pathOffset >= path.path.count { return newNode }
      guard case .split(let split) = current else {
        throw SplitError.viewNotFound
      }
      let component = path.path[pathOffset]
      switch component {
      case .left:
        return .split(
          .init(
            direction: split.direction,
            ratio: split.ratio,
            left: try replaceInner(current: split.left, pathOffset: pathOffset + 1),
            right: split.right
          ))
      case .right:
        return .split(
          .init(
            direction: split.direction,
            ratio: split.ratio,
            left: split.left,
            right: try replaceInner(current: split.right, pathOffset: pathOffset + 1)
          ))
      }
    }

    return try replaceInner(current: self, pathOffset: 0)
  }

  func remove(_ target: Node) -> Node? {
    if self == target { return nil }
    switch self {
    case .leaf:
      return self
    case .split(let split):
      let newLeft = split.left.remove(target)
      let newRight = split.right.remove(target)
      if newLeft == nil && newRight == nil {
        return nil
      } else if newLeft == nil {
        return newRight
      } else if newRight == nil {
        return newLeft
      }
      return .split(
        .init(
          direction: split.direction,
          ratio: split.ratio,
          left: newLeft!,
          right: newRight!
        ))
    }
  }

  func resizing(to ratio: Double) -> Self {
    switch self {
    case .leaf:
      return self
    case .split(let split):
      return .split(
        .init(
          direction: split.direction,
          ratio: ratio,
          left: split.left,
          right: split.right
        ))
    }
  }

  func leftmostLeaf() -> ViewType {
    switch self {
    case .leaf(let view):
      return view
    case .split(let split):
      return split.left.leftmostLeaf()
    }
  }

  func rightmostLeaf() -> ViewType {
    switch self {
    case .leaf(let view):
      return view
    case .split(let split):
      return split.right.rightmostLeaf()
    }
  }

  func leaves() -> [ViewType] {
    switch self {
    case .leaf(let view):
      return [view]
    case .split(let split):
      return split.left.leaves() + split.right.leaves()
    }
  }

  func equalize() -> Node {
    let (equalizedNode, _) = equalizeWithWeight()
    return equalizedNode
  }

  private func equalizeWithWeight() -> (node: Node, weight: Int) {
    switch self {
    case .leaf:
      return (self, 1)
    case .split(let split):
      let leftWeight = split.left.weightForDirection(split.direction)
      let rightWeight = split.right.weightForDirection(split.direction)
      let totalWeight = leftWeight + rightWeight
      let newRatio = Double(leftWeight) / Double(totalWeight)
      let (leftNode, _) = split.left.equalizeWithWeight()
      let (rightNode, _) = split.right.equalizeWithWeight()
      let newSplit = Split(
        direction: split.direction,
        ratio: newRatio,
        left: leftNode,
        right: rightNode
      )
      return (.split(newSplit), totalWeight)
    }
  }

  private func weightForDirection(_ direction: SplitTree.Direction) -> Int {
    switch self {
    case .leaf:
      return 1
    case .split(let split):
      if split.direction == direction {
        return split.left.weightForDirection(direction) + split.right.weightForDirection(direction)
      }
      return 1
    }
  }

  func viewBounds() -> CGSize {
    switch self {
    case .leaf(let view):
      return view.bounds.size
    case .split(let split):
      let leftBounds = split.left.viewBounds()
      let rightBounds = split.right.viewBounds()
      switch split.direction {
      case .horizontal:
        return CGSize(
          width: leftBounds.width + rightBounds.width,
          height: max(leftBounds.height, rightBounds.height)
        )
      case .vertical:
        return CGSize(
          width: max(leftBounds.width, rightBounds.width),
          height: leftBounds.height + rightBounds.height
        )
      }
    }
  }

  func spatial(within bounds: CGSize? = nil) -> SplitTree.Spatial {
    let width: Double
    let height: Double
    if let bounds {
      width = bounds.width
      height = bounds.height
    } else {
      let (dimensionWidth, dimensionHeight) = dimensions()
      width = Double(dimensionWidth)
      height = Double(dimensionHeight)
    }

    let slots = spatialSlots(in: CGRect(x: 0, y: 0, width: width, height: height))
    return SplitTree.Spatial(slots: slots)
  }

  private func dimensions() -> (width: UInt, height: UInt) {
    switch self {
    case .leaf:
      return (1, 1)
    case .split(let split):
      let leftDimensions = split.left.dimensions()
      let rightDimensions = split.right.dimensions()
      switch split.direction {
      case .horizontal:
        return (
          width: leftDimensions.width + rightDimensions.width,
          height: max(leftDimensions.height, rightDimensions.height)
        )
      case .vertical:
        return (
          width: max(leftDimensions.width, rightDimensions.width),
          height: leftDimensions.height + rightDimensions.height
        )
      }
    }
  }

  private func spatialSlots(in bounds: CGRect) -> [SplitTree.SpatialSlot] {
    switch self {
    case .leaf:
      return [.init(node: self, bounds: bounds)]
    case .split(let split):
      let leftBounds: CGRect
      let rightBounds: CGRect
      switch split.direction {
      case .horizontal:
        let splitX = bounds.minX + bounds.width * split.ratio
        leftBounds = CGRect(
          x: bounds.minX,
          y: bounds.minY,
          width: bounds.width * split.ratio,
          height: bounds.height
        )
        rightBounds = CGRect(
          x: splitX,
          y: bounds.minY,
          width: bounds.width * (1 - split.ratio),
          height: bounds.height
        )
      case .vertical:
        let splitY = bounds.minY + bounds.height * split.ratio
        leftBounds = CGRect(
          x: bounds.minX,
          y: bounds.minY,
          width: bounds.width,
          height: bounds.height * split.ratio
        )
        rightBounds = CGRect(
          x: bounds.minX,
          y: splitY,
          width: bounds.width,
          height: bounds.height * (1 - split.ratio)
        )
      }
      var slots: [SplitTree.SpatialSlot] = [.init(node: self, bounds: bounds)]
      slots += split.left.spatialSlots(in: leftBounds)
      slots += split.right.spatialSlots(in: rightBounds)
      return slots
    }
  }

  var structuralIdentity: StructuralIdentity {
    StructuralIdentity(self)
  }

  struct StructuralIdentity: Hashable {
    private let node: SplitTree.Node

    init(_ node: SplitTree.Node) {
      self.node = node
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.node.isStructurallyEqual(to: rhs.node)
    }

    func hash(into hasher: inout Hasher) {
      node.hashStructure(into: &hasher)
    }
  }

  fileprivate func isStructurallyEqual(to other: Node) -> Bool {
    switch (self, other) {
    case (.leaf(let view1), .leaf(let view2)):
      return view1 === view2
    case (.split(let split1), .split(let split2)):
      return split1.direction == split2.direction
        && split1.left.isStructurallyEqual(to: split2.left)
        && split1.right.isStructurallyEqual(to: split2.right)
    default:
      return false
    }
  }

  fileprivate func hashStructure(into hasher: inout Hasher) {
    switch self {
    case .leaf(let view):
      hasher.combine(0)
      hasher.combine(ObjectIdentifier(view))
    case .split(let split):
      hasher.combine(1)
      hasher.combine(split.direction)
      split.left.hashStructure(into: &hasher)
      split.right.hashStructure(into: &hasher)
    }
  }
}

extension SplitTree.Spatial {
  func slots(
    in direction: SplitTree.SpatialDirection,
    from referenceNode: SplitTree.Node
  ) -> [SplitTree.SpatialSlot] {
    guard let refSlot = slots.first(where: { $0.node == referenceNode }) else { return [] }

    func distance(from rect1: CGRect, to rect2: CGRect) -> Double {
      let deltaX = rect2.minX - rect1.minX
      let deltaY = rect2.minY - rect1.minY
      return sqrt(deltaX * deltaX + deltaY * deltaY)
    }

    return switch direction {
    case .left:
      slots.filter {
        $0.node != referenceNode && $0.bounds.maxX <= refSlot.bounds.minX
      }.sorted {
        distance(from: refSlot.bounds, to: $0.bounds)
          < distance(from: refSlot.bounds, to: $1.bounds)
      }
    case .right:
      slots.filter {
        $0.node != referenceNode && $0.bounds.minX >= refSlot.bounds.maxX
      }.sorted {
        distance(from: refSlot.bounds, to: $0.bounds)
          < distance(from: refSlot.bounds, to: $1.bounds)
      }
    case .top:
      slots.filter {
        $0.node != referenceNode && $0.bounds.maxY <= refSlot.bounds.minY
      }.sorted {
        distance(from: refSlot.bounds, to: $0.bounds)
          < distance(from: refSlot.bounds, to: $1.bounds)
      }
    case .down:
      slots.filter {
        $0.node != referenceNode && $0.bounds.minY >= refSlot.bounds.maxY
      }.sorted {
        distance(from: refSlot.bounds, to: $0.bounds)
          < distance(from: refSlot.bounds, to: $1.bounds)
      }
    }
  }
}

extension BidirectionalCollection {
  func indexWrapping(before index: Index) -> Index {
    let previousIndex = self.index(before: index)
    if previousIndex < startIndex {
      return self.index(before: endIndex)
    }
    return previousIndex
  }

  func indexWrapping(after index: Index) -> Index {
    let nextIndex = self.index(after: index)
    if nextIndex == endIndex {
      return startIndex
    }
    return nextIndex
  }
}
