//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Swift
@_implementationOnly import _SwiftConcurrencyShims

// ==== Task -------------------------------------------------------------------

/// A unit of asynchronous work.
///
/// All asynchronous functions run as part of some task.
///
/// Only code that's running as part of the task can interact with that task,
/// by invoking the appropriate context-sensitive static functions which operate
/// on the current task.
///
/// A task's execution can be seen as a series of periods where the task was
/// running. Each such period ends at a suspension point or the
/// completion of the task.
///
/// These partial periods towards the task's completion are `PartialAsyncTask`.
/// Unless you're implementing a scheduler,
/// you don't generally interact with partial tasks directly.
/// ◊TODO: partial tasks might get replaced with jobs (see PR 36878)
///
/// Task Cancellation
/// =================
///
/// Tasks include a shared mechanism for indicating cancellation,
/// but not a shared implementation for how to handle cancellation.
/// Depending on the work you're doing in the task,
/// the correct way to stop that work varies.
/// Likewise,
/// it's the responsibility of the code running as part of the task
/// to check for cancellation at the appropriate points when stopping is possible.
/// In a long-running task, you might need to check for cancellation repeatedly,
/// and cancellation at different times
/// might require stopping different aspects of that work.
/// If you only need to throw an error to stop the work,
/// call the `Task.checkCancellation()` function to check for cancellation.
/// Other responses to cancellation include
/// returning the work completed so far, returning an empty result, or returning `nil`.
///
/// Cancellation is a purely Boolean state;
/// there's no way to include additional information
/// like the reason for cancellation.
/// This reflects the fact that a task can be canceled for many reasons,
/// and additional reasons can accrue during the cancellation process.
/// For example,
/// if it takes the task too long to exit after being canceled,
/// it could also miss a deadline.
/// ◊FIXME: Replace above example -- deadlines aren't part of the API yet
/// Cancellation is a lightweight way to stop a task before it completes,
/// not a general mechanism for inter-task communication.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public struct Task {
  internal let _task: Builtin.NativeObject

  // May only be created by the standard library.
  internal init(_ task: Builtin.NativeObject) {
    self._task = task
  }
}

// ==== Current Task -----------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task {

  /// Returns the task that this code is being run on,
  /// or `nil` if this property is accessed outside of any task.
  ///
  /// If you read this property from the context of an asynchronous function or closure,
  /// the current task is guaranteed to be non-nil.
  /// In a synchronous context,
  /// this property's value depends on whether the synchronous operation was
  /// itself called from an asynchronous context.
  /// For example:
  ///
  ///     func hello() {
  ///         if Task.current == nil { print("Nil") }
  ///         else { print("Not nil") }
  ///     }
  ///
  ///     func asynchronous() async { hello() }
  ///
  /// In the code above,
  /// because `hello()` is called by an asynchronous function,
  /// it prints "Not nil".
  ///
  public static var current: Task? {
    guard let _task = _getCurrentAsyncTask() else {
      return nil
    }

    // FIXME: This retain seems pretty wrong, however if we don't we WILL crash
    //        with "destroying a task that never completed" in the task's destroy.
    //        How do we solve this properly?
    Builtin.retain(_task)

    return Task(_task)
  }

}

// ==== Task Priority ----------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task {

  /// The current task's priority.
  ///
  /// If you access this property outside of any task,
  /// its value is `Priority.default`.
  /// ◊FIXME: @ktoso said docs & implementation should use .unspecified
  ///
  /// - SeeAlso: `Task.priority`
  public static var currentPriority: Priority {
    withUnsafeCurrentTask { task in
      task?.priority ?? Priority.default
    }
  }

  /// The task's priority.
  ///
  /// - SeeAlso: `Task.currentPriority`
  @available(*, deprecated, message: "Storing `Task` instances has been deprecated, and as such instance functions on Task are deprecated and will be removed soon. Use the static 'Task.currentPriority' instead.")
  public var priority: Priority {
    getJobFlags(_task).priority
  }

  /// The priority of a task.
  ///
  /// The executor determines how priority information impacts the way tasks are scheduled.
  /// The behavior varies depending on the executor currently being used.
  /// Typically, executors attempt to run tasks with a higher priority
  /// before tasks with a lower priority.
  /// However, the exact semantics of how priority is treated are left up to each
  /// platform and `Executor` implementation.
  ///
  /// Child tasks automatically inherit their parent task's priority.
  ///
  /// Detached tasks created by `detach(priority:operation:)` don't inherit task priority
  /// because they aren't attached to the current task.
  ///
  /// In some situations the priority of a task is elevated ---
  /// that is, the task is treated as it if had a higher priority,
  /// without actually changing the priority of the task:
  ///
  /// - If a task running on behalf of an actor,
  ///   and a new higher-priority task is enqueued to the actor,
  ///   then the actor's current task is temporarily elevated
  ///   to the priority of the enqueued task.
  ///   This priority elevation allows the new task
  ///   to be processed at (effectively) the priority it was enqueued with.
  /// - If a task is created with a `Task.Handle`
  ///   and a higher-priority task calls the `await handle.get()` method,
  ///   then the priority of this task is increased until the task completes.
  ///
  /// In both cases, priority elevation helps you prevent a low-priority task
  /// blocking the execution of a high priority task,
  /// which is also known as *priority inversion*.
  /// ◊TR: Let's revisit the above
  public enum Priority: Int, Comparable {
    // Values must be same as defined by the internal `JobPriority`.
    case userInteractive = 0x21
    case userInitiated   = 0x19
    case `default`       = 0x15
    case utility         = 0x11
    case background      = 0x09
    case unspecified     = 0x00

    public static func < (lhs: Priority, rhs: Priority) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }
}

// ==== Task Handle ------------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task {
  /// An affordance to interact with an active task.
  ///
  /// You can use a task's handle to wait for its result or cancel the task.
  ///
  /// It's not a programming error to discard a task's handle without awaiting or canceling the task.
  /// A task runs whether or not you still have its handle stored somewhere.
  /// However, if you discard a task's handle, you give up the ability
  /// to wait for that task's result or cancel the task.
  public struct Handle<Success, Failure: Error>: Sendable {
    internal let _task: Builtin.NativeObject

    internal init(_ task: Builtin.NativeObject) {
      self._task = task
    }

    /// The task that this handle refers to.
    @available(*, deprecated, message: "Storing `Task` instances has been deprecated and will be removed soon.")
    public var task: Task {
      Task(_task)
    }

    /// Wait for the task to complete, returning its result or throw an error.
    ///
    /// If the task hasn't completed yet, its priority is elevated to the
    /// priority of the current task. Note that this may not be as effective as
    /// creating the task with the right priority to in the first place.
    ///
    /// If the task throws an error, this method propogates that error.
    /// Tasks that respond to cancellation by throwing `Task.CancellationError`
    /// have that error propogated here upon cancellation.
    /// ◊TR: I think this is the underlying explanation?
    /// ◊TR: That is, we don't specifically throw the cancellation error if a task is canceled,
    /// ◊TR: but rather most tasks will handle cancellation by throwing that error,
    /// ◊TR: which we propogate here.
    ///
    /// - Returns: The task's result.
    public func get() async throws -> Success {
      return try await _taskFutureGetThrowing(_task)
    }

    /// Wait for the task to complete, returning its result or its error.
    ///
    /// If the task hasn't completed yet, its priority is elevated to the
    /// priority of the current task. Note that this may not be as effective as
    /// creating the task with the right priority to in the first place.
    ///
    /// If the task throws an error, this method propogates that error.
    /// Tasks that respond to cancellation by throwing `Task.CancellationError`
    /// have that error propogated here upon cancellation.
    /// ◊TR: I think this is the underlying explanation?
    /// ◊TR: That is, we don't specifically throw the cancellation error if a task is canceled,
    /// ◊TR: but rather most tasks will handle cancellation by throwing that error,
    /// ◊TR: which we propogate here.
    ///
    /// - Returns: If the task suceeded, `.success`
    /// with the task's result as the associated value;
    /// otherwise, `.failure` with the error as the associated value.
    public func getResult() async -> Result<Success, Failure> {
      do {
        return .success(try await get())
      } catch {
        return .failure(error as! Failure) // as!-safe, guaranteed to be Failure
      }
    }

    /// Attempt to cancel the task.
    ///
    /// Whether this function has any effect is task-dependent.
    ///
    /// For a task to respect cancellation it must cooperatively check for it
    /// while running. Many tasks will check for cancellation before beginning
    /// their "actual work", however this is not a requirement nor is it guaranteed
    /// how and when tasks check for cancellation in general.
    public func cancel() {
      Builtin.cancelAsyncTask(_task)
    }
  }
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task.Handle where Failure == Never {

  /// Wait for the task to complete, returning its result.
  ///
  /// If the task hasn't completed,
  /// its priority is elevated to the priority of the current task.
  /// Note that this may not be as effective as
  /// creating the task with the right priority in the first place.
  ///
  /// The task that this handle refers to might check for cancellation ---
  /// however, since this method is nonthrowing,
  /// the task can't throw `CancellationError` and needs to use another method
  /// like returning `nil` instead.
  public func get() async -> Success {
    return await _taskFutureGet(_task)
  }
  
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task.Handle: Hashable {
  public func hash(into hasher: inout Hasher) {
    UnsafeRawPointer(Builtin.bridgeToRawPointer(_task)).hash(into: &hasher)
  }
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task.Handle: Equatable {
  public static func ==(lhs: Self, rhs: Self) -> Bool {
    UnsafeRawPointer(Builtin.bridgeToRawPointer(lhs._task)) ==
      UnsafeRawPointer(Builtin.bridgeToRawPointer(rhs._task))
  }
}

// ==== Conformances -----------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task: Hashable {
  public func hash(into hasher: inout Hasher) {
    UnsafeRawPointer(Builtin.bridgeToRawPointer(_task)).hash(into: &hasher)
  }
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task: Equatable {
  public static func ==(lhs: Self, rhs: Self) -> Bool {
    UnsafeRawPointer(Builtin.bridgeToRawPointer(lhs._task)) ==
      UnsafeRawPointer(Builtin.bridgeToRawPointer(rhs._task))
  }
}

// ==== Job Flags --------------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task {
  /// Flags for schedulable jobs.
  struct JobFlags {
    /// Kinds of schedulable jobs.
    enum Kind: Int {
      case task = 0
    }

    /// The actual bit representation of these flags.
    var bits: Int = 0

    /// The kind of job described by these flags.
    var kind: Kind {
      get {
        Kind(rawValue: bits & 0xFF)!
      }

      set {
        bits = (bits & ~0xFF) | newValue.rawValue
      }
    }

    /// Whether this is an asynchronous task.
    var isAsyncTask: Bool { kind == .task }

    /// The priority given to the job.
    var priority: Priority {
      get {
        Priority(rawValue: (bits & 0xFF00) >> 8)!
      }

      set {
        bits = (bits & ~0xFF00) | (newValue.rawValue << 8)
      }
    }

    /// Whether this is a child task.
    var isChildTask: Bool {
      get {
        (bits & (1 << 24)) != 0
      }

      set {
        if newValue {
          bits = bits | 1 << 24
        } else {
          bits = (bits & ~(1 << 24))
        }
      }
    }

    /// Whether this is a future.
    var isFuture: Bool {
      get {
        (bits & (1 << 25)) != 0
      }

      set {
        if newValue {
          bits = bits | 1 << 25
        } else {
          bits = (bits & ~(1 << 25))
        }
      }
    }

    /// Whether this is a group child.
    var isGroupChildTask: Bool {
      get {
        (bits & (1 << 26)) != 0
      }

      set {
        if newValue {
          bits = bits | 1 << 26
        } else {
          bits = (bits & ~(1 << 26))
        }
      }
    }

  }
}

// ==== Detached Tasks ---------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task {

  @discardableResult
  @available(*, deprecated, message: "`Task.runDetached` was replaced by `detach` and will be removed shortly.")
  public static func runDetached<T>(
    priority: Task.Priority = .unspecified,
    operation: __owned @Sendable @escaping () async throws -> T
  ) -> Task.Handle<T, Error> {
    detach(priority: priority, operation: operation)
  }

}

/// Run the given non-throwing operation as part of a new top-level task.
///
/// Avoid using a detached task unless it isn't possible
/// to model the operation using structured concurrency features like child tasks.
/// Child tasks inherit the parent task's priority and task-local storage,
/// and canceling a parent task automatically cancels all of its child tasks.
/// You need to handle these considerations manually with a detached task.
///
/// You need to keep a reference to the task's handle
/// if you need to cancel it by calling the `Task.Handle.cancel()` method.
/// Discarding a detached task's handle doesn't implicitly cancel that task,
/// it only makes it impossible for you to explicitly cancel the task.
///
/// - Parameters:
///   - priority: The priority of the task.
///   - executor: The executor that the detached closure should start executing on.
///   - operation: The operation to perform.
///
/// - Returns: A handle to the task.
@discardableResult
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public func detach<T>(
  priority: Task.Priority = .unspecified,
  operation: __owned @Sendable @escaping () async -> T
) -> Task.Handle<T, Never> {
  // Set up the job flags for a new task.
  var flags = Task.JobFlags()
  flags.kind = .task
  flags.priority = priority
  flags.isFuture = true

  // Create the asynchronous task future.
  let (task, _) = Builtin.createAsyncTaskFuture(flags.bits, operation)

  // Enqueue the resulting job.
  _enqueueJobGlobal(Builtin.convertTaskToJob(task))

  return Task.Handle<T, Never>(task)
}

/// Run given throwing `operation` as part of a new top-level task.
///
/// If the operation throws an error, this method propogates that error.
///
/// Avoid using a detached task unless it isn't possible
/// to model the operation using structured concurrency features like child tasks.
/// Child tasks inherit the parent task's priority and task-local storage,
/// and canceling a parent task automatically cancels all of its child tasks.
/// You need to handle these considerations manually with a detached task.
///
/// A detached task runs to completion
/// unless it is explicitly canceled by calling the `Task.Handle.cancel()` method.
/// Specifically, dropping a detached task's handle
/// doesn't cancel that task.
///
/// - Parameters:
///   - priority: The priority of the task.
///   - executor: The executor that the detached closure should start executing on.
///   - operation: The operation to perform.
///
/// - Returns: A handle to the task.
@discardableResult
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public func detach<T>(
  priority: Task.Priority = .unspecified,
  operation: __owned @Sendable @escaping () async throws -> T
) -> Task.Handle<T, Error> {
  // Set up the job flags for a new task.
  var flags = Task.JobFlags()
  flags.kind = .task
  flags.priority = priority
  flags.isFuture = true

  // Create the asynchronous task future.
  let (task, _) = Builtin.createAsyncTaskFuture(flags.bits, operation)

  // Enqueue the resulting job.
  _enqueueJobGlobal(Builtin.convertTaskToJob(task))

  return Task.Handle<T, Error>(task)
}

/// Run given `operation` as asynchronously in its own top-level task.
///
/// The `async` function should be used when creating asynchronous work
/// that operates on behalf of the synchronous function that calls it.
/// Like `detach`, the async function creates a separate, top-level task.
/// Unlike `detach`, the task creating by `async` inherits the priority and
/// actor context of the caller, so the `operation` is treated more like an
/// asynchronous extension to the synchronous operation. Additionally, `async`
/// does not return a handle to refer to the task.
///
/// - Parameters:
///   - priority: priority of the task. If unspecified, the priority will
///               be inherited from the task that is currently executing
///               or, if there is none, from the platform's understanding of
///               which thread is executing.
///   - operation: the operation to execute
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public func async(
  priority: Task.Priority = .unspecified,
  @_inheritActorContext @_implicitSelfCapture operation: __owned @Sendable @escaping () async -> Void
) {
  // Determine the priority at which we should create this task
  let actualPriority: Task.Priority
  if priority == .unspecified {
    actualPriority = withUnsafeCurrentTask { task in
      // If we are running on behalf of a task,
      if let task = task {
        return task.priority
      }

      return Task.Priority(rawValue: _getCurrentThreadPriority()) ?? .unspecified
    }
  } else {
    actualPriority = priority
  }

  // Set up the job flags for a new task.
  var flags = Task.JobFlags()
  flags.kind = .task
  flags.priority = actualPriority
  flags.isFuture = true

  // Create the asynchronous task future.
  let (task, _) = Builtin.createAsyncTaskFuture(flags.bits, operation)

  // Enqueue the resulting job.
  _enqueueJobGlobal(Builtin.convertTaskToJob(task))
}

// ==== Async Handler ----------------------------------------------------------

// TODO: remove this?
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
func _runAsyncHandler(operation: @escaping () async -> ()) {
  typealias ConcurrentFunctionType = @Sendable () async -> ()
  detach(
    operation: unsafeBitCast(operation, to: ConcurrentFunctionType.self)
  )
}

// ==== Async Sleep ------------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task {
  /// Suspends the current task,
  /// and waits for at least the given duration before resuming it.
  ///
  /// This method doesn't make guarantee how long the task is suspended.
  /// Depending on a variety of factors,
  /// it could be suspended for exactly the given duration,
  /// or for a much longer duration.
  ///
  /// Calling this method doesn't block the underlying thread.
  ///
  /// - Parameters:
  ///   - duration: The time to sleep, in nanoseconds.
  public static func sleep(_ duration: UInt64) async {
    // Set up the job flags for a new task.
    var flags = Task.JobFlags()
    flags.kind = .task
    flags.priority = .default
    flags.isFuture = true

    // Create the asynchronous task future.
    let (task, _) = Builtin.createAsyncTaskFuture(flags.bits, {})

    // Enqueue the resulting job.
    _enqueueJobGlobalWithDelay(duration, Builtin.convertTaskToJob(task))

    await Handle<Void, Never>(task).get()
  }
}

// ==== Voluntary Suspension -----------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task {

  /// Suspends the current task and allows other tasks to execute.
  ///
  /// A task can voluntarily suspend itself
  /// in the middle of a long-running operation
  /// that doesn't contain any suspension points,
  /// to let other tasks run for a while
  /// before execution returns back to this task.
  ///
  /// Note that if this task is the highest-priority task in the system,
  /// the executor immediately resumes execution of the same task.
  /// As such,
  /// this method isn't necessarily a way to avoid resource starvation.
  public static func yield() async {
    // Prepare the job flags
    var flags = JobFlags()
    flags.kind = .task
    flags.priority = .default
    flags.isFuture = true

    // Create the asynchronous task future, it will do nothing, but simply serves
    // as a way for us to yield our execution until the executor gets to it and
    // resumes us.
    // TODO: consider if it would be useful for this task to be a child task
    let (task, _) = Builtin.createAsyncTaskFuture(flags.bits, {})

    // Enqueue the resulting job.
    _enqueueJobGlobal(Builtin.convertTaskToJob(task))

    let _ = await Handle<Void, Never>(task).get()
  }
}

// ==== UnsafeCurrentTask ------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension Task {

  @available(*, deprecated, message: "`Task.unsafeCurrent` was replaced by `withUnsafeCurrentTask { task in ... }`, and will be removed soon.")
  public static var unsafeCurrent: UnsafeCurrentTask? {
    guard let _task = _getCurrentAsyncTask() else {
      return nil
    }
    // FIXME: This retain seems pretty wrong, however if we don't we WILL crash
    //        with "destroying a task that never completed" in the task's destroy.
    //        How do we solve this properly?
    Builtin.retain(_task)
    return UnsafeCurrentTask(_task)
  }
}

/// Calls a closure with an unsafe handle to current task.
///
/// If you call this function from the body of an asynchronous function,
/// the unsafe task handle passed to the closure is always be non-nil
/// because an asynchronous function always runs in the context of a task.
/// However if you call this function from the body of a synchronous function,
/// and that function isn't executing in the context of any task,
/// the unsafe task handle is `nil`.
///
/// Don't try to store an unsafe task handle
/// for use outside this method's closure.
/// Storing an unsafe task handle has no impact on the task's actual lifecycle,
/// and the behavior of accessing an unsafe task handle
/// outside of the `withUnsafeCurrentTask(body:)` method's closure isn't defined.
/// Instead, use the `task` property of `UnsafeCurrentTask`
/// to access an instance of `Task` that you can store long-term
/// and interact with outside of the closure body.
///
/// - Parameters:
///   - body: A closure that takes an `UnsafeCurrentTask` parameter.
///     If `body` has a return value,
///     that value is also used as the return value
///     for the `withUnsafeCurrentTask(body:)` function.
///
/// - Returns: The return value, if any, of the `body` closure.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public func withUnsafeCurrentTask<T>(body: (UnsafeCurrentTask?) throws -> T) rethrows -> T {
  guard let _task = _getCurrentAsyncTask() else {
    return try body(nil)
  }

  // FIXME: This retain seems pretty wrong, however if we don't we WILL crash
  //        with "destroying a task that never completed" in the task's destroy.
  //        How do we solve this properly?
  Builtin.retain(_task)

  return try body(UnsafeCurrentTask(_task))
}

/// An unsafe task handle for the current task.
///
/// To get an instance of `UnsafeCurrentTask` for the current task,
/// call the `withUnsafeCurrentTask(body:)` method.
/// Don't try to store an unsafe task handle
/// for use outside that method's closure.
/// Storing an unsafe task handle has no impact on the task's actual lifecycle,
/// and the behavior of accessing an unsafe task handle
/// outside of the `withUnsafeCurrentTask(body:)` method's closure isn't defined.
/// Instead, use the `task` property of `UnsafeCurrentTask`
/// to access an instance of `Task` that you can store long-term
/// and interact with outside of the closure body.
///
/// Only APIs on `UnsafeCurrentTask` that are also part of `Task`
/// are safe to invoke from another task
/// besides the one that this task handle represents.
/// Calling other APIs from another task is undefined behavior,
/// breaks invariants in other parts of the program running on this task,
/// and may lead to crashes or data loss.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public struct UnsafeCurrentTask {
  internal let _task: Builtin.NativeObject

  // May only be created by the standard library.
  internal init(_ task: Builtin.NativeObject) {
    self._task = task
  }

  /// The current task,
  /// represented in a way that's safe to store for later use.
  ///
  /// Operations on an instance of `Task` are safe to call from any other task,
  /// unlike `UnsafeCurrentTask`.
  ///
  /// ◊TR: Is this rewrite better?
  /// ◊TR: I'm rewriting your original abstract to remove code voice,
  /// ◊TR: which isn't allowed in abstracts.
  @available(*, deprecated, message: "Storing `Task` instances has been deprecated and will be removed soon.")
  public var task: Task {
    Task(_task)
  }

  /// A Boolean value that indicates whether the current task was canceled.
  ///
  /// After the value of this property is true, it will remain true indefinitely.
  /// There is no uncancellation operation.
  ///
  /// - SeeAlso: `checkCancellation()`
  public var isCancelled: Bool {
    _taskIsCancelled(_task)
  }

  /// The current task's priority.
  ///
  /// - SeeAlso: `Task.currentPriority`
  public var priority: Task.Priority {
    getJobFlags(_task).priority
  }

}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension UnsafeCurrentTask: Hashable {
  public func hash(into hasher: inout Hasher) {
    UnsafeRawPointer(Builtin.bridgeToRawPointer(_task)).hash(into: &hasher)
  }
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension UnsafeCurrentTask: Equatable {
  public static func ==(lhs: Self, rhs: Self) -> Bool {
    UnsafeRawPointer(Builtin.bridgeToRawPointer(lhs._task)) ==
      UnsafeRawPointer(Builtin.bridgeToRawPointer(rhs._task))
  }
}

// ==== Internal ---------------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_task_getCurrent")
func _getCurrentAsyncTask() -> Builtin.NativeObject?

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_task_getJobFlags")
func getJobFlags(_ task: Builtin.NativeObject) -> Task.JobFlags

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_task_enqueueGlobal")
@usableFromInline
func _enqueueJobGlobal(_ task: Builtin.Job)

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_task_enqueueGlobalWithDelay")
@usableFromInline
func _enqueueJobGlobalWithDelay(_ delay: UInt64, _ task: Builtin.Job)

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_task_asyncMainDrainQueue")
public func _asyncMainDrainQueue() -> Never

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public func _runAsyncMain(_ asyncFun: @escaping () async throws -> ()) {
#if os(Windows)
  detach {
    do {
      try await asyncFun()
      exit(0)
    } catch {
      _errorInMain(error)
    }
  }
#else
  @MainActor @Sendable
  func _doMain(_ asyncFun: @escaping () async throws -> ()) async {
    do {
      try await asyncFun()
    } catch {
      _errorInMain(error)
    }
  }

  detach {
    await _doMain(asyncFun)
    exit(0)
  }
#endif
  _asyncMainDrainQueue()
}

// FIXME: both of these ought to take their arguments _owned so that
// we can do a move out of the future in the common case where it's
// unreferenced
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_task_future_wait")
public func _taskFutureGet<T>(_ task: Builtin.NativeObject) async -> T

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_task_future_wait_throwing")
public func _taskFutureGetThrowing<T>(_ task: Builtin.NativeObject) async throws -> T

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public func _runChildTask<T>(
  operation: @Sendable @escaping () async throws -> T
) async -> Builtin.NativeObject {
  let currentTask = Builtin.getCurrentAsyncTask()

  // Set up the job flags for a new task.
  var flags = Task.JobFlags()
  flags.kind = .task
  flags.priority = getJobFlags(currentTask).priority
  flags.isFuture = true
  flags.isChildTask = true

  // Create the asynchronous task future.
  let (task, _) = Builtin.createAsyncTaskFuture(
      flags.bits, operation)

  // Enqueue the resulting job.
  _enqueueJobGlobal(Builtin.convertTaskToJob(task))

  return task
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_task_cancel")
func _taskCancel(_ task: Builtin.NativeObject)

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_task_isCancelled")
func _taskIsCancelled(_ task: Builtin.NativeObject) -> Bool

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@usableFromInline
@_silgen_name("swift_task_isCurrentExecutor")
func _taskIsCurrentExecutor(_ executor: Builtin.Executor) -> Bool

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@usableFromInline
@_silgen_name("swift_task_reportUnexpectedExecutor")
func _reportUnexpectedExecutor(_ _filenameStart: Builtin.RawPointer,
                               _ _filenameLength: Builtin.Word,
                               _ _filenameIsASCII: Builtin.Int1,
                               _ _line: Builtin.Word,
                               _ _executor: Builtin.Executor)

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_task_getCurrentThreadPriority")
func _getCurrentThreadPriority() -> Int

#if _runtime(_ObjC)

/// Intrinsic used by SILGen to launch a task for bridging a Swift async method
/// which was called through its ObjC-exported completion-handler-based API.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_alwaysEmitIntoClient
@usableFromInline
internal func _runTaskForBridgedAsyncMethod(_ body: @escaping () async -> Void) {
  // TODO: We can probably do better than detach
  // if we're already running on behalf of a task,
  // if the receiver of the method invocation is itself an Actor, or in other
  // situations.
#if compiler(>=5.5) && $Sendable
  detach { await body() }
#endif
}

#endif
