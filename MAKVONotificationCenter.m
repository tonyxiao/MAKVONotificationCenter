//
//  MAKVONotificationCenter.m
//  MAKVONotificationCenter
//
//  Created by Michael Ash on 10/15/08.
//

#import "MAKVONotificationCenter.h"
#import <objc/message.h>
#import <objc/runtime.h>

/******************************************************************************/
#if !__has_feature(objc_arc)	// Foundation already predefines __has_feature()
#error "MAKVONotificationCenter is designed to be built with ARC and will not work otherwise. Clients of it do not have to use ARC."
#endif

/******************************************************************************/
static const char			* const MAKVONotificationCenter_HelpersKey = "MAKVONotificationCenter_helpers";

static NSMutableSet			*MAKVONotificationCenter_swizzledClasses = nil;

/******************************************************************************/
@implementation NSObject (MAWeakReference)

static NSSet *weakRefUnavailableClasses = nil;

+ (void)load {
    // https://developer.apple.com/library/mac/#releasenotes/ObjectiveC/RN-TransitioningToARC/_index.html
    weakRefUnavailableClasses = [NSSet setWithObjects:
                                 // Classes that don't support zeroing-weak references
                                 @"NSATSTypesetter",
                                 @"NSColorSpace",
                                 @"NSFont",
                                 @"NSFontManager",
                                 @"NSFontPanel",
                                 @"NSImage",
                                 @"NSMenuView",
                                 @"NSParagraphStyle",
                                 @"NSSimpleHorizontalTypesetter",
                                 @"NSTableCellView",
                                 @"NSTextView",
                                 @"NSViewController",
                                 @"NSWindow",
                                 @"NSWindowController",
                                 // In addition
                                 @"NSHashTable",
                                 @"NSMapTable",
                                 @"NSPointerArray",
                                 // TODO: need to add all the classes in AV Foundation
                                 nil];
}

- (BOOL)ma_supportsWeakPointers {
    if ([self respondsToSelector:@selector(supportsWeakPointers)])
        return [[self performSelector:@selector(supportsWeakPointers)] boolValue];
    
    // NOTE: Also test for overriden implementation of allowsWeakReference in NSObject subclass.
    // We must use a bit of hackery here because by default NSObject's allowsWeakReference causes
    // assertion failure and program crash if it is not called by the runtime
    Method defaultMethod = class_getInstanceMethod([NSObject class], @selector(allowsWeakReference));
    Method overridenMethod = class_getInstanceMethod([self class], @selector(allowsWeakReference));
    if (overridenMethod != defaultMethod)
        return [[self performSelector:@selector(allowsWeakReference)] boolValue];
    
    // Make sure we are not one of classes that do not support weak references according to docs
    for (NSString *className in weakRefUnavailableClasses)
        if ([self isKindOfClass:NSClassFromString(className)])
            return NO;
    
    // Finally, all tests pass, by default objects support weak pointers
    return YES;
}

@end

/******************************************************************************/
@interface _MAKVONotificationHelper : NSObject <MAKVOObservation>
{
  @public		// for MAKVONotificationCenter
	id __unsafe_unretained	   _observer;
	id __unsafe_unretained	   _target;
	id __weak				   _weakObserver;
	id __weak				   _weakTarget;
	BOOL					   _observerIsWeak;
	BOOL					   _targetIsWeak;
	NSSet					  *_keyPaths;
	NSKeyValueObservingOptions _options;
	SEL						   _selector;		// NULL for block-based
	id						   _userInfo;		// block for block-based
}

- (id)initWithObserver:(id)observer object:(id)target keyPaths:(NSSet *)keyPaths
              selector:(SEL)selector userInfo:(id)userInfo options:(NSKeyValueObservingOptions)options;
- (void)deregister;

@end

/******************************************************************************/
@interface MAKVONotification ()
{
	id __unsafe_unretained _observer;
	id __unsafe_unretained _target;
	id __weak			   _weakObserver;
	id __weak			   _weakTarget;
}

- (id)initWithObserver:(id)observer_ object:(id)target_ keyPath:(NSString *)keyPath_ change:(NSDictionary *)change_;
- (id)initWithNotificationHelper:(_MAKVONotificationHelper *)helper_ keyPath:(NSString *)keyPath_ change:(NSDictionary *)change_;


@property(copy,readwrite)	NSString			*keyPath;
@property(strong,readwrite) NSDictionary        *change;
@property(assign,readwrite)	BOOL				observerIsWeak, targetIsWeak;

@end

/******************************************************************************/
@implementation MAKVONotification

@synthesize keyPath, observerIsWeak, targetIsWeak, change;

- (id)initWithObserver:(id)observer_ object:(id)target_ keyPath:(NSString *)keyPath_ change:(NSDictionary *)change_
{
    if ((self = [super init]))
    {
        _observer = observer_;
        _target = target_;
        self.change = change_;
        self.keyPath = keyPath_;
    }
    return self;
}

- (id)initWithNotificationHelper:(_MAKVONotificationHelper *)helper_ keyPath:(NSString *)keyPath_ change:(NSDictionary *)change_ {
    self = [super init];
    if (self) {
		_observer			= helper_->_observer;
		_target				= helper_->_target;
		_weakObserver		= helper_->_weakObserver;
		_weakTarget			= helper_->_weakTarget;
		self.observerIsWeak = helper_->_observerIsWeak;
		self.targetIsWeak	= helper_->_targetIsWeak;
        self.keyPath        = keyPath_;
        self.change         = change_;
    }
    return self;
    
}


- (id)observer { return self.observerIsWeak ? _weakObserver : _observer; }
- (id)target { return self.targetIsWeak ? _weakTarget : _target; }
- (NSKeyValueChange)kind { return [[change objectForKey:NSKeyValueChangeKindKey] unsignedIntegerValue]; }
- (id)oldValue { return [change objectForKey:NSKeyValueChangeOldKey]; }
- (id)newValue { return [change objectForKey:NSKeyValueChangeNewKey]; }
- (NSIndexSet *)indexes { return [change objectForKey:NSKeyValueChangeIndexesKey]; }
- (BOOL)isPrior { return [[change objectForKey:NSKeyValueChangeNotificationIsPriorKey] boolValue]; }

@end

/******************************************************************************/
@implementation _MAKVONotificationHelper

static char MAKVONotificationHelperMagicContext = 0;

- (id)initWithObserver:(id)observer object:(id)target keyPaths:(NSSet *)keyPaths
              selector:(SEL)selector userInfo:(id)userInfo options:(NSKeyValueObservingOptions)options
{
    if ((self = [super init]))
    {
        _observerIsWeak = [observer ma_supportsWeakPointers]; // This will be NO if observer is nil
        _targetIsWeak = [target ma_supportsWeakPointers];
        _observer = observer;
        _target = target;
        _weakObserver = _observerIsWeak ? observer : nil;
        _weakTarget = _targetIsWeak ? target : nil;
        _selector = selector;
        _userInfo = userInfo;
        _keyPaths = keyPaths;
        _options = options;
        
        
        // Pass only Apple's options to Apple's code.
        options &= ~(MAKeyValueObservingOptionUnregisterManually | MAKeyValueObservingOptionNoInformation);
        
        for (NSString *keyPath in _keyPaths)
        {
            if ([target isKindOfClass:[NSArray class]])
            {
                [target addObserver:self toObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [target count])]
                         forKeyPath:keyPath options:options context:&MAKVONotificationHelperMagicContext];
            }
            else
                [target addObserver:self forKeyPath:keyPath options:options context:&MAKVONotificationHelperMagicContext];
        }
        
        NSMutableSet				*observerHelpers = nil, *targetHelpers = nil;
        
        if (observer) // Observer can be nil if using block observation
        {
            @synchronized (observer)
            {
                if (!(observerHelpers = objc_getAssociatedObject(observer, &MAKVONotificationCenter_HelpersKey)))
                    objc_setAssociatedObject(observer, &MAKVONotificationCenter_HelpersKey, observerHelpers = [NSMutableSet set], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            @synchronized (observerHelpers) { [observerHelpers addObject:self]; }
        }
        
        @synchronized (target)
        {
            if (!(targetHelpers = objc_getAssociatedObject(target, &MAKVONotificationCenter_HelpersKey)))
                objc_setAssociatedObject(target, &MAKVONotificationCenter_HelpersKey, targetHelpers = [NSMutableSet set], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        @synchronized (targetHelpers) { [targetHelpers addObject:self]; }
    }
    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == &MAKVONotificationHelperMagicContext)
    {
        if ((_observerIsWeak && !_weakObserver) || (_targetIsWeak && !_weakTarget))	// weak reference got nilled
        {
            [self remove];
            return;
        }
        
#if NS_BLOCKS_AVAILABLE
        if (_selector)
#endif
            ((void (*)(id, SEL, NSString *, id, NSDictionary *, id))objc_msgSend)(_observer, _selector, keyPath, object, change, _userInfo);
#if NS_BLOCKS_AVAILABLE
        else
        {
            MAKVONotification		*notification = nil;

            // Pass object instead of _target as the notification object so that
            //	array observations will work as expected.
            if (!(_options & MAKeyValueObservingOptionNoInformation))
                notification = [[MAKVONotification alloc] initWithNotificationHelper:self keyPath:keyPath change:change];
            ((void (^)(MAKVONotification *))_userInfo)(notification);
        }
#endif
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)deregister
{
    // For auto-unregistered observations, the unsafe target is always
    //	guaranteed to be valid. However, for manually unregistered ones, the
    //	unsafe target can become invalid without warning, and we can only trust
    //	the zeroing weak reference. If the ZWR is nil at this point, it's
    //	impossible to remove the observation anyway; the target is already gone
    //	and KVO has already thrown its own error. This is the behavior we want.
    id __unsafe_unretained checkedTarget = (_targetIsWeak ? _weakTarget : _target);

//NSLog(@"deregistering observer %@ target %@/%@ observation %@", _observer, _target, _unsafeTarget, self);
    if ([checkedTarget isKindOfClass:[NSArray class]])
    {
        NSIndexSet		*idxSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [checkedTarget count])];
        
        for (NSString *keyPath in _keyPaths)
            [checkedTarget removeObserver:self fromObjectsAtIndexes:idxSet forKeyPath:keyPath context:&MAKVONotificationHelperMagicContext];
    }
    else
    {
        for (NSString *keyPath in _keyPaths)
            [checkedTarget removeObserver:self forKeyPath:keyPath context:&MAKVONotificationHelperMagicContext];
    }
    
    if ((_observerIsWeak && _weakObserver) || (!_observerIsWeak && _observer)) {        
        NSMutableSet			*observerHelpers = objc_getAssociatedObject(_observer, &MAKVONotificationCenter_HelpersKey);
        @synchronized (observerHelpers) { [observerHelpers removeObject:self]; }
    }
    
    if ((_targetIsWeak && _weakTarget) || (!_targetIsWeak && _target)) {
        NSMutableSet			*targetHelpers = objc_getAssociatedObject(_target, &MAKVONotificationCenter_HelpersKey);
        @synchronized (targetHelpers) { [targetHelpers removeObject:self]; } // if during dealloc, this will happen momentarily anyway
    }
    
    // Protect against multiple invocations
    _observer = nil;
    _target = nil;
    _weakTarget = nil;
    _weakObserver = nil;
    _keyPaths = nil;
}

- (BOOL)isValid	// the observation is invalid if and only if it has been deregistered
{
    return _target != nil;
}

- (void)remove
{
    [self deregister];
}

- (void)dealloc
{
    [self deregister];
}

@end

/******************************************************************************/
@interface MAKVONotificationCenter ()

- (void)_swizzleObjectClassIfNeeded:(id)object;

@end

@implementation MAKVONotificationCenter

+ (void)initialize
{
    static dispatch_once_t				onceToken = 0;
    
    dispatch_once(&onceToken, ^ { MAKVONotificationCenter_swizzledClasses = [NSMutableSet set]; });
}

+ (id)defaultCenter
{
    static MAKVONotificationCenter		*center = nil;
    static dispatch_once_t				onceToken = 0;
    
    // I really wanted to keep Mike's old way of doing this with
    //	OSAtomicCompareAndSwapPtrBarrier(); that was just cool! Unfortunately,
    //	pragmatism says always hand thread-safety off to the OS when possible as
    //	a matter of prudence, not that I can imagine the old way ever breaking.
    //	Also, this way is, while much less cool, a bit more readable.
    dispatch_once(&onceToken, ^ {
        center = [[MAKVONotificationCenter alloc] init];
    });
    return center;
}

#if NS_BLOCKS_AVAILABLE

- (id<MAKVOObservation>)addObserver:(id)observer
                             object:(id)target
                            keyPath:(id<MAKVOKeyPathSet>)keyPath
                            options:(NSKeyValueObservingOptions)options
                              block:(void (^)(MAKVONotification *notification))block
{
    return [self addObserver:observer object:target keyPath:keyPath selector:NULL userInfo:[block copy] options:options];
}

#endif

- (id<MAKVOObservation>)addObserver:(id)observer
                             object:(id)target
                            keyPath:(id<MAKVOKeyPathSet>)keyPath
                           selector:(SEL)selector
                           userInfo:(id)userInfo
                            options:(NSKeyValueObservingOptions)options;
{
    if (!(options & MAKeyValueObservingOptionUnregisterManually))
    {
        [self _swizzleObjectClassIfNeeded:observer];
        [self _swizzleObjectClassIfNeeded:target];
    }
    
    NSMutableSet				*keyPaths = [NSMutableSet set];
    
    for (NSString *path in [keyPath ma_keyPathsAsSetOfStrings])
        [keyPaths addObject:path];
    
    _MAKVONotificationHelper	*helper = [[_MAKVONotificationHelper alloc] initWithObserver:observer object:target keyPaths:keyPaths
                                                                                    selector:selector userInfo:userInfo options:options];
    
    // RAIAIROFT: Resource Acquisition Is Allocation, Initialization, Registration, and Other Fun Tricks.
    return helper;
}

- (void)removeObserver:(id)observer object:(id)target keyPath:(id<MAKVOKeyPathSet>)keyPath selector:(SEL)selector
{
    NSParameterAssert(observer || target);	// at least one of observer or target must be non-nil
    
    @autoreleasepool
    {
        NSMutableSet				*observerHelpers = objc_getAssociatedObject(observer, &MAKVONotificationCenter_HelpersKey) ?: [NSMutableSet set],
                                    *targetHelpers = objc_getAssociatedObject(target, &MAKVONotificationCenter_HelpersKey) ?: [NSMutableSet set],
                                    *allHelpers = [NSMutableSet set],
                                    *keyPaths = [NSMutableSet set];
    
        for (NSString *path in [keyPath ma_keyPathsAsSetOfStrings])
            [keyPaths addObject:path];
        @synchronized (observerHelpers) { [allHelpers unionSet:observerHelpers]; }
        @synchronized (targetHelpers) { [allHelpers unionSet:targetHelpers]; }
        
        for (_MAKVONotificationHelper *helper in allHelpers)
        {
            if ((!observer || helper->_observer == observer) &&
                (!target || helper->_target == target) &&
                (!keyPath || [helper->_keyPaths isEqualToSet:keyPaths]) &&
                (!selector || helper->_selector == selector))
            {
                [helper deregister];
            }
        }
    }
}

- (void)removeObservation:(id<MAKVOObservation>)observation
{
    [observation remove];
}

- (void)_swizzleObjectClassIfNeeded:(id)object
{
    if (!object)
        return;
    @synchronized (MAKVONotificationCenter_swizzledClasses)
    {
        Class			class = [object class];//object_getClass(object);

        if ([MAKVONotificationCenter_swizzledClasses containsObject:class])
            return;
//NSLog(@"Swizzling class %@", class);
        SEL				deallocSel = NSSelectorFromString(@"dealloc");/*@selector(dealloc)*/
        Method			dealloc = class_getInstanceMethod(class, deallocSel);
        IMP				origImpl = method_getImplementation(dealloc),
                        newImpl = imp_implementationWithBlock((__bridge void *)^ (void *obj)
        {
//NSLog(@"Auto-deregistering any helpers (%@) on object %@ of class %@", objc_getAssociatedObject((__bridge id)obj, &MAKVONotificationCenter_HelpersKey), obj, class);
            @autoreleasepool
            {
                for (_MAKVONotificationHelper *observation in [objc_getAssociatedObject((__bridge id)obj, &MAKVONotificationCenter_HelpersKey) copy])
                {
                    // It's necessary to check the option here, as a particular
                    //	observation may want manual deregistration while others
                    //	on objects of the same class (or even the same object)
                    //	don't.
                    if (!(observation->_options & MAKeyValueObservingOptionUnregisterManually))
                        [observation deregister];
                }
            }
            ((void (*)(void *, SEL))origImpl)(obj, deallocSel);
        });
        
        class_replaceMethod(class, deallocSel, newImpl, method_getTypeEncoding(dealloc));
        
        [MAKVONotificationCenter_swizzledClasses addObject:class];
    }
}

@end

/******************************************************************************/
@implementation NSObject (MAKVONotification)

- (id<MAKVOObservation>)addObserver:(id)observer keyPath:(id<MAKVOKeyPathSet>)keyPath selector:(SEL)selector userInfo:(id)userInfo
                            options:(NSKeyValueObservingOptions)options
{
    return [[MAKVONotificationCenter defaultCenter] addObserver:observer object:self keyPath:keyPath selector:selector userInfo:userInfo options:options];
}

- (id<MAKVOObservation>)observeTarget:(id)target keyPath:(id<MAKVOKeyPathSet>)keyPath selector:(SEL)selector userInfo:(id)userInfo
                              options:(NSKeyValueObservingOptions)options
{
    return [[MAKVONotificationCenter defaultCenter] addObserver:self object:target keyPath:keyPath selector:selector userInfo:userInfo options:options];
}

#if NS_BLOCKS_AVAILABLE

- (id<MAKVOObservation>)addObservationKeyPath:(id<MAKVOKeyPathSet>)keyPath
                                      options:(NSKeyValueObservingOptions)options
                                        block:(void (^)(MAKVONotification *notification))block
{
    return [[MAKVONotificationCenter defaultCenter] addObserver:nil object:self keyPath:keyPath options:options block:block];
}

- (id<MAKVOObservation>)addObserver:(id)observer keyPath:(id<MAKVOKeyPathSet>)keyPath options:(NSKeyValueObservingOptions)options
                              block:(void (^)(MAKVONotification *notification))block
{
    return [[MAKVONotificationCenter defaultCenter] addObserver:observer object:self keyPath:keyPath options:options block:block];
}

- (id<MAKVOObservation>)observeTarget:(id)target keyPath:(id<MAKVOKeyPathSet>)keyPath options:(NSKeyValueObservingOptions)options
                                block:(void (^)(MAKVONotification *notification))block
{
    return [[MAKVONotificationCenter defaultCenter] addObserver:self object:target keyPath:keyPath options:options block:block];
}

#endif

- (void)removeAllObservers
{
    [[MAKVONotificationCenter defaultCenter] removeObserver:nil object:self keyPath:nil selector:NULL];
}

- (void)stopObservingAllTargets
{
    [[MAKVONotificationCenter defaultCenter] removeObserver:self object:nil keyPath:nil selector:NULL];
}

- (void)removeObserver:(id)observer keyPath:(id<MAKVOKeyPathSet>)keyPath
{
    [[MAKVONotificationCenter defaultCenter] removeObserver:observer object:self keyPath:keyPath selector:NULL];
}

- (void)stopObserving:(id)target keyPath:(id<MAKVOKeyPathSet>)keyPath
{
    [[MAKVONotificationCenter defaultCenter] removeObserver:self object:target keyPath:keyPath selector:NULL];
}

- (void)removeObserver:(id)observer keyPath:(id<MAKVOKeyPathSet>)keyPath selector:(SEL)selector
{
    [[MAKVONotificationCenter defaultCenter] removeObserver:observer object:self keyPath:keyPath selector:selector];
}

- (void)stopObserving:(id)target keyPath:(id<MAKVOKeyPathSet>)keyPath selector:(SEL)selector
{
    [[MAKVONotificationCenter defaultCenter] removeObserver:self object:target keyPath:keyPath selector:selector];
}

@end

/******************************************************************************/
@implementation NSString (MAKeyPath)

- (id<NSFastEnumeration>)ma_keyPathsAsSetOfStrings
{
    return [NSSet setWithObject:self];
}

@end

@implementation NSArray (MAKeyPath)

- (id<NSFastEnumeration>)ma_keyPathsAsSetOfStrings
{
    return self;
}

@end

@implementation NSSet (MAKeyPath)

- (id<NSFastEnumeration>)ma_keyPathsAsSetOfStrings
{
    return self;
}

@end

@implementation NSOrderedSet (MAKeyPath)

- (id<NSFastEnumeration>)ma_keyPathsAsSetOfStrings
{
    return self;
}

@end
