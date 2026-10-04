// Harness only: Combine does not exist on Linux. Same names, no publishing: enough to compile and run the logic.
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
