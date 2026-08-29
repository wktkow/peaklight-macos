#import "PeaklightObjCShim.h"

id _Nullable PeaklightTryCreateCAFilter(NSString *filterType) {
    @try {
        Class filterClass = NSClassFromString(@"CAFilter");
        SEL selector = NSSelectorFromString(@"filterWithType:");
        if (filterClass == Nil || ![filterClass respondsToSelector:selector]) {
            return nil;
        }

        typedef id _Nullable (*FilterFactoryImplementation)(id, SEL, NSString *);
        FilterFactoryImplementation implementation =
            (FilterFactoryImplementation)[filterClass methodForSelector:selector];
        if (implementation == NULL) {
            return nil;
        }
        return implementation(filterClass, selector, filterType);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

id _Nullable PeaklightTryValueForKey(id object, NSString *key) {
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

BOOL PeaklightTrySetValueForKey(
    id object,
    id _Nullable value,
    NSString *key
) {
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}
