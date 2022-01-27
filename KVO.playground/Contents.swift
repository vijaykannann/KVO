import Foundation

  // MARK: KVO Change set
  /// Represent a change for a KVO compliant property.
public struct KVOChange<O:AnyObject, T> {
  
    /// The associated object for this change.
  public let object: O?
  
    /// The keyPath the triggered this change.
  public let keyPath: String
  
    /// The new value (if applicable).
  public let new: T?
  
    /// The old value (if applicable).
  public let old: T?
}

enum KVObserverError: Error {
  
    /// This error is thrown when the object passed as argument for the observation
    /// doesn't respond to the keyPath selector.
  case unrecognizedKeyPathForObject(error: String)
}

  // MARK: Observer class
  /// A simple, efficient and thread-safe abstraction around Key-Value Observation.
  /// An instance of this class can register itself as an observer for several different objects
  /// (and for different keyPaths).
  /// The observation deregistration is not required since it automatically perfomed when this
  /// instance is deallocated.
final public class KVO {
  
    /// Initial|New|Old
  let lock = Lock()
  
  private let info: NSMapTable<AnyObject, AnyObject> = NSMapTable(
    keyOptions: NSPointerFunctions.Options().union(
      NSPointerFunctions.Options.objectPointerPersonality),
    valueOptions: NSPointerFunctions.Options().union(NSPointerFunctions.Options()),
    capacity: 0)
  
  public init() { }
  
  deinit {
    self.unobserveAll()
  }
  
    /// Register this object for observation of the given keyPath for the given object.
  public func onChange<O: AnyObject, T>(keyPath: String,
                                        object: O,
                                        options: NSKeyValueObservingOptions = [.new,.initial,.old],
                                        dispatchOnMainQueue: Bool = false,
                                        change: @escaping (KVOChange<O, T>) -> Void) throws {
    
    guard (object as! NSObject).responds(to: Selector(keyPath)) else {
      throw KVObserverError.unrecognizedKeyPathForObject(
        error: " \(object) doesn't respond to selector \(keyPath)")
    }
    
    let info = KVObservationInfo<O, T>(keyPath: keyPath,
                                       options: options,
                                       dispatchOnMainQueue: false,
                                       change: change)
    
    var shouldObserve = true
    
    lock.lock()
    
      // Tries to retrieve the set.
    var setForObject = self.info.object(forKey: object)
    
      // It allocates a new set if necessary.
    if setForObject == nil {
      setForObject = NSMutableSet()
      self.info.setObject(setForObject, forKey: object)
    }
    
      // If there's already an observation registered skips it, otherwise it adds the observation
      // info to the set.
    if setForObject?.member(info) != nil {
      shouldObserve = false
    } else {
      setForObject?.add(info)
    }
    
    lock.unlock()
    
      // Finally adds the observation info to the sharedMananger
    if shouldObserve {
      KVObserverManager.sharedManager.observe(object, info: info)
    }
  }
  
    /// Stops all the observation.
  public func unobserveAll() {
    
    lock.lock()
    
      // Creates a copy of the map and removes all the observation info from it.
    let copy = self.info.copy(with: nil) as! NSMapTable<AnyObject, AnyObject>
    self.info.removeAllObjects()
    lock.unlock()
    
      // Now remove the observations.
    let enumerator = copy.keyEnumerator()
    
    while let object = enumerator.nextObject() {
      
      guard let set = copy.object(forKey: object as AnyObject) as? NSSet else { continue }
      for obj in set {
        
          //removes the kvo info from the shared manager
        guard let info = obj as? KVOChangeFactoring else { continue }
        KVObserverManager.sharedManager.unobserve(object as AnyObject, info: info)
      }
    }
  }
}

  // MARK: - Private
private protocol KVOChangeFactoring {
  
    // Uniquing,
  var uniqueIdenfier: Int { get }
  var keyPath: String { get }
  
    // Creates and execute an observer change block with an associated KVOChange object.
  func kvoChange(keyPath: String?,
                 ofObject object: AnyObject?,
                 change: [NSKeyValueChangeKey : Any]?)
}

private final class KVObservationInfo<O:AnyObject, T>: NSObject, KVOChangeFactoring {
  
  let options: NSKeyValueObservingOptions
  let change: (KVOChange<O, T>) -> Void
  let dispatchOnMainQueue: Bool
  
    // Uniquing,
  let keyPath: String
  var uniqueIdenfier = UUID().uuidString.hash
  
  init(keyPath: String,
       options: NSKeyValueObservingOptions,
       dispatchOnMainQueue: Bool,
       change: @escaping (KVOChange<O, T>) -> Void) {
    
    self.keyPath = keyPath
    self.options = options
    self.change = change
    self.dispatchOnMainQueue = dispatchOnMainQueue
  }
  
  override func isEqual(_ object: Any?) -> Bool {
    let result = super.isEqual(object)
    if !result {
      return self.keyPath == (object as AnyObject).keyPath
    }
    return result
  }
  
  func kvoChange(keyPath: String?,
                 ofObject object: AnyObject?,
                 change: [NSKeyValueChangeKey : Any]?) {
    
    let new = change?[NSKeyValueChangeKey.newKey] as? T
    let old = change?[NSKeyValueChangeKey.oldKey] as? T
    let change = KVOChange<O, T>(object: object as? O, keyPath: keyPath!, new: new, old: old)
    
      // Runs the callback.
      // We're not on the mainthread and we're supposed to dispatch the change on the main thread.
    if !Thread.isMainThread && self.dispatchOnMainQueue {
      DispatchQueue.main.sync { [weak self] () -> Void in
        self?.change(change)
      }
      
        // or simply dispatch the change.
    } else {
      self.change(change)
    }
  }
  
}

private final class KVObserverManager: NSObject {
  
  static let sharedManager = KVObserverManager()
  
  private var lock = Lock()
  private var observers = [Int: KVOChangeFactoring]()
  
  func observe<O: AnyObject, T>(_ object: AnyObject, info: KVObservationInfo<O, T>) {
    
    lock.lock()
    self.observers[info.uniqueIdenfier] = info
    lock.unlock()
    
    let context = unsafeBitCast(info.uniqueIdenfier, to: UnsafeMutableRawPointer.self)
    (object as! NSObject).addObserver(self,
                                      forKeyPath: info.keyPath,
                                      options: info.options,
                                      context: context)
  }
  
  func unobserve(_ object: AnyObject, info: KVOChangeFactoring) {
    
    lock.lock()
    self.observers.removeValue(forKey: info.uniqueIdenfier)
    lock.unlock()
    
    let context = unsafeBitCast(info.uniqueIdenfier, to: UnsafeMutableRawPointer.self)
    (object as! NSObject).removeObserver(self, forKeyPath: info.keyPath, context: context)
  }
  
    /// This message is sent to the receiver when the value at the specified key path relative to
    /// the given object has changed.
    /// The key path, relative to object, to the value that has changed.
  override fileprivate func observeValue(forKeyPath keyPath: String?,
                                         of object: Any?,
                                         change: [NSKeyValueChangeKey : Any]?,
                                         context: UnsafeMutableRawPointer?) {
    if object == nil || context == nil {
      return
    }
    
    lock.lock()
    let info = self.observers[unsafeBitCast(context, to: Int.self)]
    lock.unlock()
    
    info?.kvoChange(keyPath: keyPath,
                    ofObject: object as AnyObject?,
                    change: change)
  }
}

final class Lock {
  
  private var spin = OS_SPINLOCK_INIT
  private var unfair = os_unfair_lock_s()
  
  func lock() {
    if #available(iOS 10, *) {
      os_unfair_lock_lock(&unfair)
    } else {
      OSSpinLockLock(&spin)
    }
  }
  
  func unlock() {
    if #available(iOS 10, *) {
      os_unfair_lock_unlock(&unfair)
    } else {
      OSSpinLockUnlock(&spin)
    }
  }
}
