import Foundation
import ReactiveSwift
import enum Result.NoError

extension Reactive where Base: NSObject {
	/// Create a signal which sends a `next` event at the end of every invocation
	/// of `selector` on the object.
	///
	/// It completes when the object deinitializes.
	///
	/// - note: Observers to the resulting signal should not call the method
	///         specified by the selector.
	///
	/// - parameters:
	///   - selector: The selector to observe.
	///
	/// - returns:
	///   A trigger signal.
	public func trigger(for selector: Selector) -> Signal<(), NoError> {
		return setupInterception(base, for: selector).map { _ in }
	}

	/// Create a signal which sends a `next` event, containing an array of bridged
	/// arguments, at the end of every invocation of `selector` on the object.
	///
	/// It completes when the object deinitializes.
	///
	/// - note: Observers to the resulting signal should not call the method
	///         specified by the selector.
	///
	/// - parameters:
	///   - selector: The selector to observe.
	///
	/// - returns:
	///   A signal that sends an array of bridged arguments.
	public func signal(for selector: Selector) -> Signal<[Any?], NoError> {
		return setupInterception(base, for: selector, packsArguments: true).map { $0! }
	}
}

/// Setup the method interception.
///
/// - parameters:
///   - object: The object to be intercepted.
///   - selector: The selector of the method to be intercepted.
///
/// - returns:
///   A signal that sends the corresponding `NSInvocation` after every
///   invocation of the method.
private func setupInterception(_ object: NSObject, for selector: Selector, packsArguments: Bool = false) -> Signal<[Any?]?, NoError> {
	let alias = selector.alias
	let interopAlias = selector.interopAlias

	guard let method = class_getInstanceMethod(object.objcClass, selector) else {
		fatalError("Selector `\(selector)` does not exist in class `\(String(describing: object.objcClass))`.")
	}

	let typeEncoding = method_getTypeEncoding(method)!
	assert(checkTypeEncoding(typeEncoding))

	return object.synchronized {
		if let state = object.value(forAssociatedKey: alias.utf8Start) as! InterceptingState? {
			if packsArguments {
				state.wantsArguments()
			}
			return state.signal
		}

		let subclass: AnyClass = swizzleClass(object)

		synchronized(subclass) {
			let isSwizzled = objc_getAssociatedObject(subclass, &isSwizzledKey) as! Bool? ?? false

			let signatureCache: Atomic<[Selector: AnyObject]>

			if isSwizzled {
				signatureCache = objc_getAssociatedObject(subclass, &interceptedSelectorsKey) as! Atomic<[Selector: AnyObject]>
			} else {
				signatureCache = Atomic([:])

				objc_setAssociatedObject(subclass, &interceptedSelectorsKey, signatureCache, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
				objc_setAssociatedObject(subclass, &isSwizzledKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

				enableMessageForwarding(subclass)
				setupMethodSignatureCaching(subclass, signatureCache)
			}

			signatureCache.modify { signatures in
				if signatures[selector] == nil {
					signatures[selector] = NSMethodSignature.signature(withObjCTypes: typeEncoding)
				}
			}

			if !class_respondsToSelector(subclass, interopAlias) {
				let immediateMethod = class_getImmediateMethod(subclass, selector)
				let generatedImpl = objc_getAssociatedObject(subclass, interopAlias.utf8Start) as! IMP?

				let immediateImpl: IMP? = immediateMethod.flatMap {
					let immediateImpl = method_getImplementation($0)
					return immediateImpl.flatMap { $0 != _rac_objc_msgForward && $0 != generatedImpl ? $0 : nil }
				}

				if let impl = immediateImpl {
					// If an immediate implementation of the selector is found in the
					// runtime subclass the first time the selector is intercepted,
					// preserve the implementation.
					//
					// Example: KVO setters if the instance is swizzled by KVO before RAC
					//          does.

					class_addMethod(subclass, interopAlias, impl, typeEncoding)
				}
			}
		}

		let state = InterceptingState(lifetime: object.reactive.lifetime)
		if packsArguments {
			state.wantsArguments()
		}
		object.setValue(state, forAssociatedKey: alias.utf8Start)

		if let template = InterceptionTemplates.template(forTypeEncoding: typeEncoding) {
			var impl = objc_getAssociatedObject(subclass, interopAlias.utf8Start) as! IMP?

			if impl == nil {
				impl = template(subclass.objcClass, subclass, selector)
				objc_setAssociatedObject(subclass, interopAlias.utf8Start, impl!, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
			}

			_ = class_replaceMethod(subclass, selector, impl!, typeEncoding)
		} else {
			// Start forwarding the messages of the selector.
			_ = class_replaceMethod(subclass, selector, _rac_objc_msgForward, typeEncoding)
		}

		return state.signal
	}
}

/// Swizzle `realClass` to enable message forwarding for method interception.
///
/// - parameters:
///   - realClass: The runtime subclass to be swizzled.
private func enableMessageForwarding(_ realClass: AnyClass) {
	let perceivedClass: AnyClass = class_getSuperclass(realClass)

	typealias ForwardInvocationImpl = @convention(block) (NSObject, AnyObject) -> Void
	let newForwardInvocation: ForwardInvocationImpl = { object, invocation in
		let selector = invocation.selector!
		let alias = selector.alias
		let interopAlias = selector.interopAlias

		defer {
			if let state = object.value(forAssociatedKey: alias.utf8Start) as! InterceptingState? {
				state.send(invocation: invocation)
			}
		}

		let method = class_getInstanceMethod(perceivedClass, selector)!
		let typeEncoding = method_getTypeEncoding(method)

		if class_respondsToSelector(realClass, interopAlias) {
			// RAC has preserved an immediate implementation found in the runtime
			// subclass that was supplied by an external party.
			//
			// As the KVO setter relies on the selector to work, it has to be invoked
			// by swapping in the preserved implementation and restore to the message
			// forwarder afterwards.
			//
			// However, the IMP cache would be thrashed due to the swapping.

			let interopImpl = class_getMethodImplementation(realClass, interopAlias)
			let previousImpl = class_replaceMethod(realClass, selector, interopImpl, typeEncoding)
			invocation.invoke()
			_ = class_replaceMethod(realClass, selector, previousImpl, typeEncoding)

			return
		}

		if let impl = method_getImplementation(method), impl != _rac_objc_msgForward {
			// The perceived class, or its ancestors, responds to the selector.
			//
			// The implementation is invoked through the selector alias, which
			// reflects the latest implementation of the selector in the perceived
			// class.

			let method = class_getImmediateMethod(realClass, alias)

			if method == nil || method_getImplementation(method!) != impl {
				// Update the alias if and only if the implementation has changed, so as
				// to avoid thrashing the IMP cache.
				_ = class_replaceMethod(realClass, alias, impl, typeEncoding)
			}

			invocation.setSelector(alias)
			invocation.invoke()

			return
		}

		// Forward the invocation to the closest `forwardInvocation(_:)` in the
		// inheritance hierarchy, or the default handler returned by the runtime
		// if it finds no implementation.
		typealias SuperForwardInvocation = @convention(c) (AnyObject, Selector, AnyObject) -> Void
		let impl = class_getMethodImplementation(perceivedClass, ObjCSelector.forwardInvocation)
		let forwardInvocation = unsafeBitCast(impl, to: SuperForwardInvocation.self)
		forwardInvocation(object, ObjCSelector.forwardInvocation, invocation)
	}

	_ = class_replaceMethod(realClass,
	                        ObjCSelector.forwardInvocation,
	                        imp_implementationWithBlock(newForwardInvocation as Any),
	                        ObjCMethodEncoding.forwardInvocation)
}

/// Swizzle `realClass` to accelerate the method signature retrieval, using a
/// signature cache that covers all known intercepted selectors of `realClass`.
///
/// - parameters:
///   - realClass: The runtime subclass to be swizzled.
///   - signatureCache: The method signature cache.
private func setupMethodSignatureCaching(_ realClass: AnyClass, _ signatureCache: Atomic<[Selector: AnyObject]>) {
	let perceivedClass: AnyClass = class_getSuperclass(realClass)

	let newMethodSignatureForSelector: @convention(block) (NSObject, Selector) -> AnyObject? = { object, selector in
		if let signature = signatureCache.withValue({ $0[selector] }) {
			return signature
		}

		typealias SuperMethodSignatureForSelector = @convention(c) (AnyObject, Selector, Selector) -> AnyObject?
		let impl = class_getMethodImplementation(perceivedClass, ObjCSelector.methodSignatureForSelector)
		let methodSignatureForSelector = unsafeBitCast(impl, to: SuperMethodSignatureForSelector.self)
		return methodSignatureForSelector(object, ObjCSelector.methodSignatureForSelector, selector)
	}

	_ = class_replaceMethod(realClass,
	                        ObjCSelector.methodSignatureForSelector,
	                        imp_implementationWithBlock(newMethodSignatureForSelector as Any),
	                        ObjCMethodEncoding.methodSignatureForSelector)
}

/// The state of an intercepted method specific to an instance.
internal final class InterceptingState {
	fileprivate let signal: Signal<[Any?]?, NoError>
	private let observer: Signal<[Any?]?, NoError>.Observer
	private var packsArguments = false

	/// Initialize a state specific to an instance.
	///
	/// - parameters:
	///   - lifetime: The lifetime of the instance.
	init(lifetime: Lifetime) {
		(signal, observer) = Signal<[Any?]?, NoError>.pipe()
		lifetime.ended.observeCompleted(observer.sendCompleted)
	}

	func wantsArguments() {
		packsArguments = true
	}

	func send(invocation: AnyObject) {
		observer.send(value: packsArguments ? unpackInvocation(invocation) : nil)
	}

	func send(packIfNeeded action: () -> [Any?]) {
		observer.send(value: packsArguments ? action() : nil)
	}
}

private var isSwizzledKey = 0
private var interceptedSelectorsKey = 0

/// Assert that the method does not contain types that cannot be intercepted.
///
/// - parameters:
///   - types: The type encoding C string of the method.
///
/// - returns:
///   `true`.
private func checkTypeEncoding(_ types: UnsafePointer<CChar>) -> Bool {
	// Some types, including vector types, are not encoded. In these cases the
	// signature starts with the size of the argument frame.
	assert(types.pointee < Int8(UInt8(ascii: "1")) || types.pointee > Int8(UInt8(ascii: "9")),
	       "unknown method return type not supported in type encoding: \(String(cString: types))")

	assert(types.pointee != Int8(UInt8(ascii: "(")), "union method return type not supported")
	assert(types.pointee != Int8(UInt8(ascii: "{")), "struct method return type not supported")
	assert(types.pointee != Int8(UInt8(ascii: "[")), "array method return type not supported")

	assert(types.pointee != Int8(UInt8(ascii: "j")), "complex method return type not supported")

	return true
}

/// Extract the arguments of an `NSInvocation` as an array of objects.
///
/// - parameters:
///   - invocation: The `NSInvocation` to unpack.
///
/// - returns:
///   An array of objects.
private func unpackInvocation(_ invocation: AnyObject) -> [Any?] {
	let invocation = invocation as AnyObject
	let methodSignature = invocation.objcMethodSignature!
	let count = UInt(methodSignature.numberOfArguments!)

	var bridged = [Any]()
	bridged.reserveCapacity(Int(count - 2))

	// Ignore `self` and `_cmd` at index 0 and 1.
	for position in 2 ..< count {
		let rawEncoding = methodSignature.argumentType(at: position)
		let encoding = ObjCTypeEncoding(rawValue: rawEncoding.pointee) ?? .undefined

		func extract<U>(_ type: U.Type) -> U {
			let pointer = UnsafeMutableRawPointer.allocate(bytes: MemoryLayout<U>.size,
			                                               alignedTo: MemoryLayout<U>.alignment)
			defer {
				pointer.deallocate(bytes: MemoryLayout<U>.size,
				                   alignedTo: MemoryLayout<U>.alignment)
			}

			invocation.copy(to: pointer, forArgumentAt: Int(position))
			return pointer.assumingMemoryBound(to: type).pointee
		}

		switch encoding {
		case .char:
			bridged.append(NSNumber(value: extract(CChar.self)))
		case .int:
			bridged.append(NSNumber(value: extract(CInt.self)))
		case .short:
			bridged.append(NSNumber(value: extract(CShort.self)))
		case .long:
			bridged.append(NSNumber(value: extract(CLong.self)))
		case .longLong:
			bridged.append(NSNumber(value: extract(CLongLong.self)))
		case .unsignedChar:
			bridged.append(NSNumber(value: extract(CUnsignedChar.self)))
		case .unsignedInt:
			bridged.append(NSNumber(value: extract(CUnsignedInt.self)))
		case .unsignedShort:
			bridged.append(NSNumber(value: extract(CUnsignedShort.self)))
		case .unsignedLong:
			bridged.append(NSNumber(value: extract(CUnsignedLong.self)))
		case .unsignedLongLong:
			bridged.append(NSNumber(value: extract(CUnsignedLongLong.self)))
		case .float:
			bridged.append(NSNumber(value: extract(CFloat.self)))
		case .double:
			bridged.append(NSNumber(value: extract(CDouble.self)))
		case .bool:
			bridged.append(NSNumber(value: extract(CBool.self)))
		case .object:
			bridged.append(extract((AnyObject?).self) as Any)
		case .type:
			bridged.append(extract((AnyClass?).self) as Any)
		case .selector:
			bridged.append(extract((Selector?).self) as Any)
		case .undefined:
			var size = 0, alignment = 0
			NSGetSizeAndAlignment(rawEncoding, &size, &alignment)
			let buffer = UnsafeMutableRawPointer.allocate(bytes: size, alignedTo: alignment)
			defer { buffer.deallocate(bytes: size, alignedTo: alignment) }

			invocation.copy(to: buffer, forArgumentAt: Int(position))
			bridged.append(NSValue(bytes: buffer, objCType: rawEncoding))
		}
	}

	return bridged
}
