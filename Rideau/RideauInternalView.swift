//
// Rideau
//
// Copyright © 2019 Hiroshi Kimura
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit

protocol RideauInternalViewDelegate: AnyObject {

  @available(iOS 11, *)
  func rideauView(_ rideauInternalView: RideauInternalView, animatorsAlongsideMovingIn range: ResolvedSnapPointRange) -> [UIViewPropertyAnimator]

  func rideauView(_ rideauInternalView: RideauInternalView, willMoveTo snapPoint: RideauSnapPoint)

  func rideauView(_ rideauInternalView: RideauInternalView, didMoveTo snapPoint: RideauSnapPoint)

}

final class RideauInternalView: RideauTouchThroughView {

  /// A set of closures that tell events that happen on RideauInternalView.
  struct Handlers {

    /// Tells the snap point will change to another snap point.
    ///
    /// - Warning: RideauInternalView will not always move to the destination snap point. If the user interrupted moving animation, didChangeSnapPoint brings another snap point up to you.
    var willChangeSnapPoint: (_ destination: RideauSnapPoint) -> Void = { _ in }

    /// Tells the new snap point that currently RidauView snaps.
    var didChangeSnapPoint: (_ destination: RideauSnapPoint) -> Void = { _ in }
  }

  // MARK: - Nested types

  private struct CachedValueSet: Equatable {

    var sizeThatLastUpdated: CGSize
    var offsetThatLastUpdated: CGFloat
    var usingConfiguration: RideauView.Configuration
  }

  // MARK: - Properties

  weak var delegate: RideauInternalViewDelegate?

  /// A set of handlers for inter-view communication.
  internal var handlers: Handlers = .init()

  internal let backdropView = RideauTouchThroughView()

  internal var trackingScrollViewOption: RideauView.TrackingScrollViewOption = .automatic

  private var actualTopMargin: CGFloat {
    switch configuration.topMarginOption {
    case .fromTop(let value):
      return value
    case .fromSafeArea(let value):
      let offset: CGFloat
      if #available(iOS 11.0, *) {
        offset = safeAreaInsets.top + value
      } else {
        offset = 20 + value
      }
      return offset
    }
  }

  /**
   A height constraints for RideauContentContainerView.
   the constant would be set as maximum expandable size.
   */
  private var containerViewHeightConstraint: NSLayoutConstraint!

  /**
   A bottom constraints to hide the container view by offset
   */
  private var containerViewBottomConstraint: NSLayoutConstraint!

  /**
   A view that hosts a content and sliding by dragging and programaticaly.
   */
  public let containerView = RideauContentContainerView()

  private(set) public var configuration: RideauView.Configuration

  /**
   It would be set on layoutSubviews.
   */
  private var resolvedState: ResolvedState?

  private var containerDraggingAnimator: UIViewPropertyAnimator?

  private var animatorStore: AnimatorStore = .init()

  private var currentSnapPoint: ResolvedSnapPoint?

  /// a latest value that has been delivered over the delegate
  private var propagatedSnapPoint: ResolvedSnapPoint?

  private var isInteracting: Bool = false

  private var shouldUpdate: Bool = false

  private var oldValueSet: CachedValueSet?

  private let scrollController: ScrollController = .init()

  private struct TrackingState {
    // To tracking pan gesture
    var lastOffset: CGPoint!
    var shouldKillDecelerate: Bool = false
    var initialLocation: ResolvedState.Location?
    var hasReachedMostTop: Bool = false
    var initialShowsVerticalScrollIndicator: Bool = false
    var beganPoint: CGPoint = .zero
    var _isPanGestureTracking = false
  }

  private var trackingState: TrackingState = .init()

  private var hasTakenAlongsideAnimators: Bool = false

  private let panGesture = RideauViewDragGestureRecognizer()

  // MARK: - Initializers

  init(
    frame: CGRect,
    configuration: RideauView.Configuration
  ) {

    self.configuration = configuration
    super.init(frame: .zero)

  }

  // MARK: - Functions

  func setup() {

    callback: do {

      containerView.didChangeContent = { [weak self] in
        guard let self = self else { return }
        guard self.isInteracting == false else { return }
        // It needs to update update resolvedState
        self.shouldUpdate = true
        self.setNeedsLayout()
        self.layoutIfNeeded()
      }
    }

    view: do {

      containerView.translatesAutoresizingMaskIntoConstraints = false

      addSubview(backdropView)
      backdropView.frame = bounds
      backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

      addSubview(containerView)
      containerView.setOwner(self)

      containerViewHeightConstraint = containerView.heightAnchor.constraint(equalToConstant: 0).setIdentifier("maximum-height")
      containerViewHeightConstraint.priority = .defaultHigh

      containerViewBottomConstraint = containerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0).setIdentifier("hiding-offset")

      NSLayoutConstraint.activate([
        containerViewBottomConstraint,
        containerViewHeightConstraint,
        containerView.rightAnchor.constraint(equalTo: rightAnchor, constant: 0),
        containerView.leftAnchor.constraint(equalTo: leftAnchor, constant: 0),
      ])

    }

    gesture: do {

      panGesture.addTarget(self, action: #selector(handlePan))
      panGesture.delegate = self
      containerView.addGestureRecognizer(panGesture)
    }

  }

  @available(*, unavailable)
  required init?(
    coder aDecoder: NSCoder
  ) {
    fatalError()
  }

  deinit {

    animatorStore
      .allAnimators()
      .forEach {
        $0.stopAnimation(true)
      }
  }

  // MARK: - Functions

  func update(configuration: RideauView.Configuration) {
    self.configuration = configuration
    setNeedsLayout()
    layoutIfNeeded()
  }

  /**
   Registers other panGesture to enable dragging outside view.
   */
  func register(other panGesture: UIPanGestureRecognizer) {
    panGesture.addTarget(self, action: #selector(handlePan))
  }

  private func resolve(configuration: RideauView.Configuration) -> ResolvedState {

    let maxHeight = self.bounds.height - actualTopMargin

    let points = configuration.snapPoints.map { snapPoint -> ResolvedSnapPoint in
      switch snapPoint {
      case .hidden:
        return .init(pointsFromTop: round(maxHeight - -8), source: snapPoint)
      case .fraction(let fraction):
        return .init(pointsFromTop: round(maxHeight - maxHeight * fraction), source: snapPoint)
      case .pointsFromTop(let points):
        return .init(pointsFromTop: points, source: snapPoint)
      case .pointsFromBottom(let points):
        return .init(pointsFromTop: round(maxHeight - points), source: snapPoint)
      case .autoPointsFromBottom:

        guard let view = containerView.currentBodyView else {
          return .init(pointsFromTop: 0, source: snapPoint)
        }

        let size: CGSize = {

          let targetSize = CGSize(
            width: bounds.width,
            height: UIView.layoutFittingCompressedSize.height
          )

          let horizontalPriority: UILayoutPriority = .required
          let verticalPriority: UILayoutPriority = .fittingSizeLevel

          return view.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalPriority,
            verticalFittingPriority: verticalPriority
          )
        }()

        return .init(
          pointsFromTop: min(maxHeight, max(0, maxHeight - size.height)),
          source: snapPoint
        )
      }
    }

    let configuration = ResolvedState(
      snapPoints: points,
      maximumContainerViewHeight: maxHeight
    )

    containerViewHeightConstraint.constant = maxHeight

    return configuration
  }

  override func layoutSubviews() {

    super.layoutSubviews()

    let valueSet = CachedValueSet(
      sizeThatLastUpdated: bounds.size,
      offsetThatLastUpdated: actualTopMargin,
      usingConfiguration: configuration
    )

    guard oldValueSet != nil else {

      // First time layout

      oldValueSet = valueSet

      shouldUpdate = false

      let newresolvedState = resolve(configuration: self.configuration)
      resolvedState = newresolvedState

      if let initial = newresolvedState.resolvedSnapPoints.last {
        updateLayout(target: initial, resolvedState: newresolvedState)
      } else {
        assertionFailure()
      }

      return
    }

    guard shouldUpdate || oldValueSet != valueSet, let currentSnapPoint = currentSnapPoint else {
      // No needs to update layout
      return
    }

    oldValueSet = valueSet
    shouldUpdate = false

    let newresolvedState = resolve(configuration: configuration)

    guard resolvedState != newresolvedState else {
      // It had to update layout, but configuration for layot does not have changes.
      return
    }
    resolvedState = newresolvedState

    guard
      let snapPoint = newresolvedState.resolvedSnapPoint(by: currentSnapPoint.source) ?? newresolvedState.resolvedSnapPoints.first
    else {
      // ??? probably, not need to update current layout
      return
    }

    updateLayout(target: snapPoint, resolvedState: newresolvedState)

  }

  func move(to snapPoint: RideauSnapPoint, animated: Bool, completion: @escaping () -> Void) {

    guard let resolvedState = resolvedState else {
      assertionFailure()
      return
    }

    preventCurrentAnimations: do {

      if #available(iOS 11, *) {
        prepareAlongsideAnimators()
      }

      animatorStore.allAnimators()
        .forEach {
          $0.pauseAnimation()
        }

      containerDraggingAnimator?.stopAnimation(true)
    }

    guard let target = resolvedState.resolvedSnapPoints.first(where: { $0.source == snapPoint }) else {
      assertionFailure("No such snap point")
      return
    }

    if animated {
      continueInteractiveTransition(
        target: target,
        velocity: .zero,
        resolvedState: resolvedState,
        completion: completion
      )
    } else {
      UIView.performWithoutAnimation {
        continueInteractiveTransition(
          target: target,
          velocity: .zero,
          resolvedState: resolvedState,
          completion: completion
        )
      }
    }

  }

  func isReachedMostTop(location: ResolvedState.Location) -> Bool {
    let result: Bool
    switch location {
    case .between:
      result = false
    case .exact(let point),
      .outOfEnd(let point),
      .outOfStart(let point):
      result = resolvedState!.isReachedMostTop(point)
    }
    return result
  }

  @available(iOS 11, *)
  private func prepareAlongsideAnimators() {

    if !hasTakenAlongsideAnimators {

      hasTakenAlongsideAnimators = true

      resolvedState?
        .ranges()
        .forEach { range in
          delegate?.rideauView(self, animatorsAlongsideMovingIn: range).forEach { animator in
            animator.pausesOnCompletion = true
            animator.pauseAnimation()
            animatorStore.set(animator: animator, for: range)
          }
        }
    }

  }

  @objc private dynamic func handlePan(gesture: UIPanGestureRecognizer) {

    func currentHidingOffset(translation: CGPoint) -> CGFloat {

      let offset = actualTopMargin

      var nextValue: CGFloat
      if let v = containerView.layer.presentation().map({ $0.frame.origin.y }) {
        nextValue = v
      } else {
        nextValue = containerView.frame.origin.y
      }

      nextValue -= offset
      nextValue += translation.y

      return nextValue
    }

    guard let resolvedState = resolvedState else {
      assertionFailure()
      return
    }

    let targetScrollView: UIScrollView? = {

      guard let gesture = gesture as? RideauViewDragGestureRecognizer else {
        // it's possible when touched outside of Rideau.
        return nil
      }

      switch trackingScrollViewOption {
      case .noTracking: return nil
      case .automatic: return gesture.trackingScrollView
      case .specific(let scrollView): return scrollView
      }
    }()

    let translation = gesture.translation(in: gesture.view!)

    defer {
      gesture.setTranslation(.zero, in: gesture.view!)
    }

    let nextOffset = currentHidingOffset(translation: translation)
    let currentOffset = currentHidingOffset(translation: .zero)
    let nextLocation = resolvedState.currentLocation(from: nextOffset)
    let currentLocation = resolvedState.currentLocation(from: currentOffset)

    switch gesture.state {
    case .began:

      throttlingGesture_preparation: do {
        trackingState._isPanGestureTracking = false
        trackingState.beganPoint = gesture.location(in: gesture.view?.window)
      }

      trackingState.initialLocation = currentLocation
      trackingState.shouldKillDecelerate = false
      trackingState.hasReachedMostTop = false

      isInteracting = true

      containerDraggingAnimator?.pauseAnimation()
      containerDraggingAnimator?.stopAnimation(true)

      if #available(iOS 11, *) {
        prepareAlongsideAnimators()
      }

      if let scrollView = targetScrollView {
        scrollController.startTracking(scrollView: scrollView)
        scrollController.lockScrolling()
        trackingState.lastOffset = scrollView.contentOffset
        trackingState.initialShowsVerticalScrollIndicator = scrollView.showsVerticalScrollIndicator
      }

      fallthrough
    case .changed:

      throttlingGesture_run: do {
        let locationInWindow = gesture.location(in: gesture.view?.window)
        if trackingState._isPanGestureTracking == false, abs(trackingState.beganPoint.y - locationInWindow.y) < 15 {
          return
        } else {
          trackingState._isPanGestureTracking = true
        }
      }

      let isCurrentReachedMostTop = isReachedMostTop(location: currentLocation)

      trackingState.hasReachedMostTop = trackingState.hasReachedMostTop ? trackingState.hasReachedMostTop : isCurrentReachedMostTop

      var skipsDragging = false

      if let scrollView = targetScrollView {

        let isInitialReachedMostTop = isReachedMostTop(location: trackingState.initialLocation!)

        let isScrollingDown = gesture.velocity(in: gesture.view).y > 0
        let isScrollViewOnTop = scrollView.contentOffset.y <= -_getActualContentInset(from: scrollView).top

        skipsDragging = !isScrollViewOnTop

        assert(trackingState.lastOffset != nil)

        if isScrollingDown {

          switch (isScrollViewOnTop, isInitialReachedMostTop, isCurrentReachedMostTop, trackingState.hasReachedMostTop) {
          case (false, false, false, true):
            scrollController.unlockScrolling()
            trackingState.shouldKillDecelerate = true
            trackingState.lastOffset = scrollView.contentOffset
            return
          case (false, false, false, false):
            scrollController.unlockScrolling()
            trackingState.shouldKillDecelerate = true
            scrollView.contentOffset = trackingState.lastOffset!
            skipsDragging = false
          case (true, true, false, _):
            trackingState.shouldKillDecelerate = true
            scrollController.lockScrolling()
            trackingState.lastOffset = scrollView.contentOffset
          case (false, true, true, _):
            scrollController.unlockScrolling()
            trackingState.shouldKillDecelerate = false
            trackingState.lastOffset = scrollView.contentOffset
            return
          case (false, true, false, _):
            scrollController.unlockScrolling()
            trackingState.shouldKillDecelerate = true
            trackingState.lastOffset = scrollView.contentOffset
            return
          case (true, false, false, _):
            trackingState.shouldKillDecelerate = true
            scrollController.lockScrolling()
            trackingState.lastOffset = scrollView.contentOffset
          case (false, false, true, _):
            scrollController.unlockScrolling()
            trackingState.shouldKillDecelerate = false
            trackingState.lastOffset = scrollView.contentOffset
            return
          default:
            scrollController.unlockScrolling()
            trackingState.shouldKillDecelerate = false
            trackingState.lastOffset = scrollView.contentOffset
            break
          }

        } else {

          if isCurrentReachedMostTop {
            trackingState.shouldKillDecelerate = false
            trackingState.lastOffset = scrollView.contentOffset
            scrollController.unlockScrolling()
          } else {
            skipsDragging = false
            scrollView.contentOffset = trackingState.lastOffset!
            scrollController.lockScrolling()
            trackingState.shouldKillDecelerate = true
          }
        }

        if trackingState.initialShowsVerticalScrollIndicator {
          scrollView.showsVerticalScrollIndicator = !trackingState.shouldKillDecelerate
        }

      }

      guard !skipsDragging else {

        return
      }

      switch nextLocation {
      case .exact:

        containerViewBottomConstraint.constant = nextOffset
        containerViewHeightConstraint.constant = resolvedState.maximumContainerViewHeight

      case .between(let range):

        let bottomOffset: CGFloat
        if resolvedState.smallestVisibleSnappoint().hidingOffset < nextOffset {
          bottomOffset = nextOffset - resolvedState.smallestVisibleSnappoint().hidingOffset
        } else {
          bottomOffset = 0
        }

        containerView.updateLayoutGuideBottomOffset(bottomOffset)

        containerViewBottomConstraint.constant = nextOffset
        containerViewHeightConstraint.constant = resolvedState.maximumContainerViewHeight

        if #available(iOS 11, *) {

          let fractionCompleteInRange = ValuePatch.init(nextOffset)
            .progress(
              start: range.start.hidingOffset,
              end: range.end.hidingOffset
            )
            .clip(min: 0, max: 1)
            .reverse()
            .fractionCompleted

          animatorStore[range]?.forEach {
            $0.isReversed = false
            $0.pauseAnimation()
            $0.fractionComplete = fractionCompleteInRange
          }

          animatorStore
            .filter { $0.start > range.start }
            .forEach {
              $0.isReversed = false
              $0.pauseAnimation()
              $0.fractionComplete = 1
            }

          animatorStore
            .filter { $0.end < range.start }
            .forEach {
              $0.isReversed = false
              $0.pauseAnimation()
              $0.fractionComplete = 0
            }

        }

      case .outOfStart(let point):
        containerViewBottomConstraint.constant = point.hidingOffset
        let offset = translation.y * 0.1
        /** rubber-banding */
        containerViewHeightConstraint.constant -= offset
      case .outOfEnd(let point):
        containerViewBottomConstraint.constant = point.hidingOffset
        if targetScrollView == nil {
          let offset = translation.y * 0.1
          /** rubber-banding */
          containerViewHeightConstraint.constant -= offset
        }
      }

      if let scrollView = targetScrollView {
        trackingState.lastOffset = scrollView.contentOffset
      }

    case .ended, .cancelled, .failed:

      scrollController.endTracking()

      if let scrollView = targetScrollView, trackingState.shouldKillDecelerate {
        // To perform task next event loop.
        DispatchQueue.main.async { [self] in

          var targetOffset = trackingState.lastOffset!
          let insetTop = _getActualContentInset(from: scrollView).top
          if targetOffset.y < -insetTop {
            // Workaround: sometimes, scrolling-lock may be failed. ContentOffset has a little bit negative offset.
            targetOffset.y = -insetTop
          }
          scrollView.setContentOffset(targetOffset, animated: false)
          scrollView.showsVerticalScrollIndicator = trackingState.initialShowsVerticalScrollIndicator
        }
      }

      let gestureVelocity = gesture.velocity(in: gesture.view!)
      let gestureVelocityY = gestureVelocity.y
      let gestureVelocityX = gestureVelocity.x

      let target: ResolvedSnapPoint = {
        switch nextLocation {
        case .between(let range):

          guard let pointCloser = range.pointCloser(by: nextOffset) else {
            fatalError()
          }

          let threshold: CGFloat = 400

          guard abs(gestureVelocityY) > abs(gestureVelocityX) else {
            return pointCloser
          }

          switch gestureVelocityY {
          case -threshold...threshold:
            // stay in current snappoint
            return pointCloser
          case ...(-threshold):
            return range.start
          case threshold...:
            return range.end
          default:
            fatalError()
          }

        case .exact(let point),
          .outOfEnd(let point),
          .outOfStart(let point):
          return point
        }
      }()

      let targetTranslateY = target.hidingOffset

      let proposedVelocity: CGVector = {

        var initialVelocity = CGVector(
          dx: 0,
          dy: abs(abs(gestureVelocityY) / (targetTranslateY - nextOffset))
        )

        if initialVelocity.dy.isInfinite || initialVelocity.dy.isNaN {
          initialVelocity.dy = 0
        }

        if case .outOfStart = nextLocation {
          return .zero
        }

        if case .outOfEnd = nextLocation {
          return .zero
        }

        return initialVelocity
      }()

      continueInteractiveTransition(
        target: target,
        velocity: proposedVelocity,
        resolvedState: resolvedState,
        completion: {

        }
      )

      isInteracting = false
    default:
      break
    }

  }

  /// Update the current layout with updating the constant value of constraints.
  /// - Parameter target:
  private func updateLayout(target: ResolvedSnapPoint, resolvedState: ResolvedState) {

    currentSnapPoint = target

    containerViewBottomConstraint.constant = target.hidingOffset
    containerViewHeightConstraint.constant = resolvedState.maximumContainerViewHeight

    if target.source == .hidden {
      containerView.updateLayoutGuideBottomOffset(target.hidingOffset - resolvedState.smallestVisibleSnappoint().hidingOffset)
    } else {
      containerView.updateLayoutGuideBottomOffset(0)
    }
  }

  private func continueInteractiveTransition(
    target: ResolvedSnapPoint,
    velocity: CGVector,
    resolvedState: ResolvedState,
    completion: @escaping () -> Void
  ) {

    propagate: do {
      handlers.willChangeSnapPoint(target.source)
      delegate?.rideauView(self, willMoveTo: target.source)
    }

    assert(currentSnapPoint != nil)

    debugLog("Velocity", velocity)

    let topAnimator: UIViewPropertyAnimator

    switch containerView.currentResizingOption {
    case .noResize?:

      topAnimator = UIViewPropertyAnimator(
        duration: 0,
        timingParameters: UISpringTimingParameters(
          damping: 0.95,
          response: 0.4,
          initialVelocity: CGVector(dx: 0, dy: velocity.dy)
        )
      )
    case .resizeToVisibleArea?, .none:

      let damping = ValuePatch(velocity.dy)
        .progress(start: 0, end: 20)
        .clip(min: 0, max: 1)
        .transition(start: 1, end: 0.7)
        .value

      topAnimator = UIViewPropertyAnimator(
        duration: 0,
        timingParameters: UISpringTimingParameters(
          damping: damping,  // Workaround : Can't use initialVelocity, initialVelocity cause strange animation that will shrink and expand subviews"
          response: 0.3,
          initialVelocity: .zero
        )
      )
    }

    // flush pending updates

    layoutIfNeeded()

    if #available(iOS 11, *) {

      animatorStore
        .filter { range in
          range.start >= target
        }
        .forEach {
          $0.isReversed = false
          $0.pauseAnimation()
          if $0.fractionComplete < 1 {
            $0.continueAnimation(withTimingParameters: nil, durationFactor: 1)
          }
        }

      animatorStore
        .filter { range in
          range.end <= target
        }
        .forEach {
          $0.isReversed = true
          $0.pauseAnimation()
          if $0.fractionComplete < 1 {
            $0.continueAnimation(withTimingParameters: nil, durationFactor: 1)
          }
        }

    }

    topAnimator
      .addAnimations {
        self.updateLayout(target: target, resolvedState: resolvedState)
        self.layoutIfNeeded()
      }

    topAnimator.addCompletion { _ in

      // WARN: If topAnimator is stopped as force, this completion block will not be called.

      completion()
      propagate: do {
        if self.propagatedSnapPoint?.source != target.source {
          self.delegate?.rideauView(self, didMoveTo: target.source)
          self.handlers.didChangeSnapPoint(target.source)
          self.propagatedSnapPoint = target
        }
      }
    }

    topAnimator.startAnimation()

    containerDraggingAnimator = topAnimator

  }

}

extension RideauInternalView {

  private struct AnimatorStore {

    private var backingStore: [ResolvedSnapPointRange: [UIViewPropertyAnimator]] = [:]

    subscript(_ range: ResolvedSnapPointRange) -> [UIViewPropertyAnimator]? {
      get {
        return backingStore[range]
      }
      set {
        backingStore[range] = newValue
      }
    }

    mutating func set(animator: UIViewPropertyAnimator, for key: ResolvedSnapPointRange) {

      var array = self[key]

      if array != nil {
        array?.append(animator)
        self[key] = array
      } else {
        let array = [animator]
        self[key] = array
      }

    }

    func filter(_ condition: (ResolvedSnapPointRange) -> Bool) -> [UIViewPropertyAnimator] {
      return
        backingStore
        .filter { condition($0.key) }
        .reduce(into: [UIViewPropertyAnimator]()) { (result, args) in
          result += args.value
        }
    }

    func allAnimators() -> [UIViewPropertyAnimator] {

      return
        backingStore.reduce(into: [UIViewPropertyAnimator]()) { (result, args) in
          result += args.value
        }

    }

    mutating func removeAllAnimations() {
      backingStore.removeAll()
    }

  }

  struct ResolvedState: Equatable {

    // MARK: - Nested types

    enum Location {
      case between(ResolvedSnapPointRange)
      case exact(ResolvedSnapPoint)
      case outOfEnd(ResolvedSnapPoint)
      case outOfStart(ResolvedSnapPoint)
    }

    // MARK: - Properties

    /**
     first is most expanded snappoint
     */
    let resolvedSnapPoints: [ResolvedSnapPoint]
    let maximumContainerViewHeight: CGFloat

    // MARK: - Initializers

    init(
      snapPoints: [ResolvedSnapPoint],
      maximumContainerViewHeight: CGFloat
    ) {
      self.maximumContainerViewHeight = maximumContainerViewHeight
      self.resolvedSnapPoints = Set(snapPoints).sorted(by: <)
    }

    // MARK: - Functions

    func ranges() -> [ResolvedSnapPointRange] {

      guard resolvedSnapPoints.count >= 2 else {
        assertionFailure("")
        return []
      }

      var ranges: [ResolvedSnapPointRange] = []
      var before: ResolvedSnapPoint = resolvedSnapPoints.first!
      for point in resolvedSnapPoints.dropFirst() {
        let range = ResolvedSnapPointRange(before, point)
        ranges.append(range)
        before = point
      }

      return ranges

    }

    func isReachedMostTop(_ resolvedSnapPoint: ResolvedSnapPoint) -> Bool {
      return resolvedSnapPoints.first?.hidingOffset == resolvedSnapPoint.hidingOffset
    }

    func resolvedSnapPoint(by snapPoint: RideauSnapPoint) -> ResolvedSnapPoint? {
      return resolvedSnapPoints.first { $0.source == snapPoint }
    }

    func currentLocation(from hidingOffset: CGFloat) -> Location {

      if let point = resolvedSnapPoints.first(where: { $0.hidingOffset == hidingOffset }) {
        return .exact(point)
      }

      precondition(!resolvedSnapPoints.isEmpty)

      let firstHalf = resolvedSnapPoints.lazy.filter { $0.hidingOffset <= hidingOffset }
      let secondHalf = resolvedSnapPoints.lazy.filter { $0.hidingOffset >= hidingOffset }

      if !firstHalf.isEmpty && !secondHalf.isEmpty {

        return .between(ResolvedSnapPointRange(firstHalf.last!, secondHalf.first!))
      }

      if firstHalf.isEmpty {
        return .outOfEnd(secondHalf.first!)
      }

      if secondHalf.isEmpty {
        return .outOfStart(firstHalf.last!)
      }

      fatalError()

    }

    func smallestVisibleSnappoint() -> ResolvedSnapPoint {
      resolvedSnapPoints.filter { $0.source != .hidden }.last!
    }

  }
}

extension RideauInternalView: UIGestureRecognizerDelegate {

  @objc
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {

    guard let _gestureRecognizer = gestureRecognizer as? RideauViewDragGestureRecognizer else {
      assertionFailure("\(gestureRecognizer)")
      return false
    }

    switch trackingScrollViewOption {
    case .noTracking:
      return false
    case .automatic:
      let result = _gestureRecognizer.trackingScrollView == otherGestureRecognizer.view
      return result
    case .specific(let scrollView):
      return otherGestureRecognizer.view == scrollView
    }

  }
}

extension UISpringTimingParameters {
  convenience init(
    damping: CGFloat,
    response: CGFloat,
    initialVelocity: CGVector = .zero
  ) {
    let stiffness = pow(2 * .pi / response, 2)
    let damp = 4 * .pi * damping / response
    self.init(mass: 1, stiffness: stiffness, damping: damp, initialVelocity: initialVelocity)
  }

  public convenience init(
    decelerationRate: CGFloat,
    frequencyResponse: CGFloat,
    initialVelocity: CGVector = .zero
  ) {
    let dampingRatio = CoreGraphics.log(decelerationRate) / (-4 * .pi * 0.001)
    self.init(damping: dampingRatio, response: frequencyResponse, initialVelocity: initialVelocity)
  }

}
