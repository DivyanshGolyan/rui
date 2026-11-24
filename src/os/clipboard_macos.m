#import <AppKit/NSPasteboard.h>
#import <Foundation/NSData.h>
#import <ImageIO/ImageIO.h>
#include <stdbool.h>
#include <stdint.h>

typedef bool (*ImageReceiver)(void *, const uint8_t *, size_t);

typedef struct {
    CFMutableDataRef data;
    size_t limit;
    bool overflow;
} PngOutput;

static size_t appendPng(void *context, const void *bytes, size_t count) {
    PngOutput *output = context;
    if (output->overflow || count > output->limit - (size_t)CFDataGetLength(output->data)) {
        output->overflow = true;
        return 0;
    }
    CFDataAppendBytes(output->data, bytes, (CFIndex)count);
    return count;
}

static bool boundedDimensions(size_t width, size_t height) {
    const size_t max_axis = 8192;
    const size_t max_pixels = 32 * 1024 * 1024;
    return width > 0 && width <= max_axis && height > 0 && height <= max_axis &&
           width * height <= max_pixels;
}

static CGImageRef decodeTiff(NSData *tiff) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)tiff, NULL);
    if (!source) return NULL;

    CGImageRef image = NULL;
    CFStringRef type = CGImageSourceGetType(source);
    if (type && CFEqual(type, CFSTR("public.tiff")) && CGImageSourceGetCount(source) > 0) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        size_t width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
        size_t height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
        if (boundedDimensions(width, height)) {
            image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
            if (image && !boundedDimensions(CGImageGetWidth(image), CGImageGetHeight(image))) {
                CGImageRelease(image);
                image = NULL;
            }
        }
    }
    CFRelease(source);
    return image;
}

static void receiveTiff(NSData *tiff, size_t limit, void *context, ImageReceiver receive) {
    CGImageRef image = decodeTiff(tiff);
    if (!image) return;

    PngOutput output = { .data = CFDataCreateMutable(NULL, 0), .limit = limit };
    if (output.data) {
        const CGDataConsumerCallbacks callbacks = { .putBytes = appendPng };
        CGDataConsumerRef consumer = CGDataConsumerCreate(&output, &callbacks);
        if (consumer) {
            CGImageDestinationRef png = CGImageDestinationCreateWithDataConsumer(consumer, CFSTR("public.png"), 1, NULL);
            if (png) {
                CGImageDestinationAddImage(png, image, NULL);
                if (CGImageDestinationFinalize(png) && !output.overflow) {
                    receive(context, CFDataGetBytePtr(output.data), (size_t)CFDataGetLength(output.data));
                }
                CFRelease(png);
            }
            CGDataConsumerRelease(consumer);
        }
        CFRelease(output.data);
    }
    CGImageRelease(image);
}

void rui_clipboard_macos_read(size_t limit, void *context, ImageReceiver receive) {
    @autoreleasepool {
        NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
        NSArray<NSPasteboardType> *formats = @[ NSPasteboardTypePNG, @"public.jpeg" ];
        for (NSPasteboardType format in formats) {
            NSData *data = [clipboard dataForType:format];
            if (data.length > 0 && data.length <= limit && receive(context, data.bytes, data.length)) return;
        }
        NSData *tiff = [clipboard dataForType:NSPasteboardTypeTIFF];
        if (tiff.length > 0 && tiff.length <= limit) receiveTiff(tiff, limit, context, receive);
    }
}
