/*!
 * iOS SDK
 *
 * Tencent is pleased to support the open source community by making
 * Hippy available.
 *
 * Copyright (C) 2019 THL A29 Limited, a Tencent company.
 * All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <UIKit/UIKit.h>
#import "HippyDefaultImageProvider.h"
#import "NSData+DataType.h"
#import <CoreServices/CoreServices.h>
#import "HippyUtils.h"
#import <os/lock.h>

@interface HippyDefaultImageProvider () {
    NSData *_data;
    UIImage *_image;
    CGImageSourceRef _imageSourceRef;
    os_unfair_lock _imageSourceLock;
}

@end

@implementation HippyDefaultImageProvider

HIPPY_EXPORT_MODULE(defaultImageProvider)

+ (BOOL)canHandleData:(NSData *)data {
    return YES;
}

+ (BOOL)isAnimatedImage:(NSData *)data {
    BOOL ret = [data hippy_isAnimatedImage];
    return ret;
}

+ (NSUInteger)priorityForData:(NSData *)data {
    return 0;
}

+ (instancetype)imageProviderInstanceForData:(NSData *)data {
    return [[[self class] alloc] initWithData:data];
}

- (instancetype)initWithData:(NSData *)data {
    self = [super init];
    if (self) {
        _imageSourceLock = OS_UNFAIR_LOCK_INIT; // Initialize the lock unconditionally
        if ([[self class] isAnimatedImage:data]) {
            _imageSourceRef = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        } else {
            _data = data;
        }
    }
    return self;
}

- (UIImage *)image {
    if (nil == _image) {
        if (_data) {
            CGFloat view_width = _imageViewSize.width;
            CGFloat view_height = _imageViewSize.height;
            if (_downSample && view_width > 0 && view_height > 0) {
                CGFloat scale = HippyScreenScale();
                NSDictionary *options = @{ (NSString *)kCGImageSourceShouldCache: @(NO) };
                CGImageSourceRef ref = CGImageSourceCreateWithData((__bridge CFDataRef)_data, (__bridge CFDictionaryRef)options);
                if (ref) {
                    NSInteger width = 0, height = 0;
                    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(ref, 0, NULL);
                    if (properties) {
                        CFTypeRef val = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
                        if (val)
                            CFNumberGetValue(val, kCFNumberLongType, &height);
                        val = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
                        if (val)
                            CFNumberGetValue(val, kCFNumberLongType, &width);
                        if (width > (view_width * scale) || height > (view_height * scale)) {
                            NSInteger maxDimensionInPixels = MAX(view_width, view_height) * scale;
                            NSDictionary *downsampleOptions = @{
                                (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @(YES),
                                (NSString *)kCGImageSourceShouldCacheImmediately: @(YES),
                                (NSString *)kCGImageSourceCreateThumbnailWithTransform: @(YES),
                                (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxDimensionInPixels)
                            };
                            CGImageRef downsampleImageRef = CGImageSourceCreateThumbnailAtIndex(ref, 0, (__bridge CFDictionaryRef)downsampleOptions);
                            _image = [UIImage imageWithCGImage:downsampleImageRef];
                            CGImageRelease(downsampleImageRef);
                        }
                        CFRelease(properties);
                    }
                    CFRelease(ref);
                }
            }
        } else {
            _image = [self imageAtFrame:0];
        }
    }
    if (!_image) {
        _image = [UIImage imageWithData:_data];
    }
    return _image;
}

- (UIImage *)imageAtFrame:(NSUInteger)index {
    if (_imageSourceRef) {
        os_unfair_lock_lock(&_imageSourceLock);
        if (!_imageSourceRef) {
            os_unfair_lock_unlock(&_imageSourceLock);
            return nil;
        }
        CGImageRef imageRef = CGImageSourceCreateImageAtIndex(_imageSourceRef, index, NULL);
        os_unfair_lock_unlock(&_imageSourceLock);
        if (!imageRef) return nil;
        UIImage *image = [UIImage imageWithCGImage:imageRef];
        CGImageRelease(imageRef);
        return image;
    } else if (_data) {
        return [self image];
    }
    return nil;
}

- (NSUInteger)imageCount {
    os_unfair_lock_lock(&_imageSourceLock);
    if (!_imageSourceRef) {
        os_unfair_lock_unlock(&_imageSourceLock);
        return 0;
    }
    size_t count = CGImageSourceGetCount(_imageSourceRef);
    os_unfair_lock_unlock(&_imageSourceLock);
    return count;
}

- (NSUInteger)loopCount {
    os_unfair_lock_lock(&_imageSourceLock);
    if (!_imageSourceRef) {
        os_unfair_lock_unlock(&_imageSourceLock);
        return 0;
    }
    
    CFStringRef imageSourceContainerType = CGImageSourceGetType(_imageSourceRef);
    NSDictionary *imageProperties = CFBridgingRelease(CGImageSourceCopyProperties(_imageSourceRef, NULL));
    os_unfair_lock_unlock(&_imageSourceLock);
    
    NSString *imagePropertyKey = (NSString *)kCGImagePropertyGIFDictionary;
    NSString *loopCountKey = (NSString *)kCGImagePropertyGIFLoopCount;
    if (UTTypeConformsTo(imageSourceContainerType, kUTTypePNG)) {
        imagePropertyKey = (NSString *)kCGImagePropertyPNGDictionary;
        loopCountKey = (NSString *)kCGImagePropertyAPNGLoopCount;
    }
    
    id loopCountObject = [[imageProperties objectForKey:imagePropertyKey] objectForKey:loopCountKey];
    if (loopCountObject) {
        NSUInteger loopCount = [loopCountObject unsignedIntegerValue];
        return 0 == loopCount ? NSUIntegerMax : loopCount;
    } else {
        return NSUIntegerMax;
    }
}

- (NSTimeInterval)delayTimeAtFrame:(NSUInteger)frame {
    const NSTimeInterval kDelayTimeIntervalDefault = 0.1;
    
    os_unfair_lock_lock(&_imageSourceLock);
    if (!_imageSourceRef) {
        os_unfair_lock_unlock(&_imageSourceLock);
        return kDelayTimeIntervalDefault;
    }
    
    NSDictionary *frameProperties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(_imageSourceRef, frame, NULL));
    CFStringRef _Nullable utType = CGImageSourceGetType(_imageSourceRef);
    os_unfair_lock_unlock(&_imageSourceLock);
    
    NSString *imagePropertyKey = (NSString *)kCGImagePropertyGIFDictionary;
    NSString *delayTimeKey = (NSString *)kCGImagePropertyGIFDelayTime;
    NSString *unclampedDelayTime = (NSString *)kCGImagePropertyGIFUnclampedDelayTime;
    
    if (UTTypeConformsTo(utType, kUTTypePNG)) {
        imagePropertyKey = (NSString *)kCGImagePropertyPNGDictionary;
        delayTimeKey = (NSString *)kCGImagePropertyAPNGDelayTime;
        unclampedDelayTime = (NSString *)kCGImagePropertyAPNGUnclampedDelayTime;
    }
    
    NSDictionary *framePropertiesAni = [frameProperties objectForKey:imagePropertyKey];
    NSNumber *delayTime = [framePropertiesAni objectForKey:unclampedDelayTime];
    if (!delayTime) {
        delayTime = [framePropertiesAni objectForKey:delayTimeKey];
    }
    if (!delayTime) {
        delayTime = @(kDelayTimeIntervalDefault);
    }
    return [delayTime doubleValue];
}

- (void)dealloc {
    os_unfair_lock_lock(&_imageSourceLock);
    if (_imageSourceRef) {
        CFRelease(_imageSourceRef);
        _imageSourceRef = NULL;
    }
    os_unfair_lock_unlock(&_imageSourceLock);
    _data = nil;
}

@end
