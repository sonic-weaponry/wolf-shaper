/*
 * Wolf Shaper CI checks: the macOS side of the gui check (ci/vst3_check)
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Copyright (C) 2026 Sonic Weaponry
 */

// The window a host gives a plugin's editor, the event loop that lets the editor draw, and the pictures: what the editor
// drew into its OpenGL buffer, and a photo of the window as the screen shows it. The photo comes from Apple's
// screencapture tool: GitHub's macOS runners allow the tools a job runs to record the screen, while
// CGWindowListCreateImage returns no picture on macOS 26. Built with ARC.

#define GL_SILENCE_DEPRECATION 1

#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <QuartzCore/QuartzCore.h>

#include "gui.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>

static NSWindow* gWindow = nil;

static NSString* toNSString(const std::string& text)
{
    return [NSString stringWithUTF8String:text.c_str()];
}

static NSString* yesNo(bool value)
{
    return value ? @"yes" : @"no";
}

bool guiStart(std::string& error)
{
    NSApplication* app = [NSApplication sharedApplication];
    if (app == nil)
    {
        error = "no NSApplication";
        return false;
    }
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app finishLaunching];
    return true;
}

void* guiOpenWindow(int width, int height, const std::string& title, std::string& error)
{
    NSScreen* screen = [NSScreen mainScreen];
    if (screen == nil)
    {
        error = "no screen to open a window on";
        return nullptr;
    }
    const NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    const NSRect visible = [screen visibleFrame];
    NSRect frame = [NSWindow frameRectForContentRect:NSMakeRect(0, 0, width, height) styleMask:style];

    // Top left of the screen, or top right when the mouse pointer is there: a pointer over the editor lights up what it
    // hovers.
    frame.origin = NSMakePoint(NSMinX(visible) + 40, NSMaxY(visible) - NSHeight(frame) - 40);
    if (NSPointInRect([NSEvent mouseLocation], frame))
        frame.origin.x = NSMaxX(visible) - NSWidth(frame) - 40;

    gWindow = [[NSWindow alloc] initWithContentRect:[NSWindow contentRectForFrameRect:frame styleMask:style]
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    if (gWindow == nil)
    {
        error = "could not create a window";
        return nullptr;
    }
    [gWindow setReleasedWhenClosed:NO];
    [gWindow setTitle:toNSString(title)];
    [gWindow makeKeyAndOrderFront:nil];
    [gWindow orderFrontRegardless];
    if (@available(macOS 14.0, *))
        [NSApp activate];
    return (__bridge void*)[gWindow contentView];
}

void guiContentSize(int& width, int& height)
{
    const NSSize size = gWindow != nil ? [[gWindow contentView] frame].size : NSZeroSize;
    width = static_cast<int>(std::lround(size.width));
    height = static_cast<int>(std::lround(size.height));
}

bool guiResizeWindow(int width, int height)
{
    if (gWindow == nil)
        return false;
    [gWindow setContentSize:NSMakeSize(width, height)];
    return true;
}

void guiRun(double seconds)
{
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
    {
        @autoreleasepool
        {
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:until
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event != nil)
                [NSApp sendEvent:event];
            [NSApp updateWindows];
        }
    }
}

// Runs a tool to its end. The event loop keeps going meanwhile: waitUntilExit runs this thread's run loop.
static bool runTool(NSString* tool, NSArray<NSString*>* arguments, std::string& error)
{
    NSError* launchError = nil;
    NSTask* task = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:tool]
                                               arguments:arguments
                                                   error:&launchError
                                      terminationHandler:nil];
    if (task == nil)
    {
        error = std::string("could not start ") + [tool UTF8String] + ": " +
                (launchError != nil ? [[launchError localizedDescription] UTF8String] : "no reason given");
        return false;
    }
    [task waitUntilExit];
    if ([task terminationStatus] != 0)
    {
        error = std::string([tool UTF8String]) + " exited with code " + std::to_string([task terminationStatus]);
        return false;
    }
    return true;
}

static CGImageRef loadImage(const std::string& path, std::string& error)
{
    NSURL* url = [NSURL fileURLWithPath:toNSString(path)];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (source == nullptr)
    {
        error = "could not open " + path;
        return nullptr;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (image == nullptr)
        error = "could not read a picture from " + path;
    return image;
}

static bool savePng(CGImageRef image, const std::string& path, std::string& error)
{
    NSURL* url = [NSURL fileURLWithPath:toNSString(path)];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
    if (destination == nullptr)
    {
        error = "could not create " + path;
        return false;
    }
    CGImageDestinationAddImage(destination, image, nullptr);
    const bool saved = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    if (!saved)
        error = "could not write " + path;
    return saved;
}

// The picture's pixels as 8-bit RGBA, in the picture's own color space when it has an RGB one, so that nothing gets
// converted.
static bool toRgba(CGImageRef picture, Image& image, std::string& error)
{
    const size_t width = CGImageGetWidth(picture);
    const size_t height = CGImageGetHeight(picture);
    const CGBitmapInfo layout =
        static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big);
    image.width = static_cast<int>(width);
    image.height = static_cast<int>(height);
    image.rgba.assign(width * height * 4, 0);

    CGColorSpaceRef own = CGImageGetColorSpace(picture);
    CGContextRef context = nullptr;
    if (own != nullptr && CGColorSpaceGetModel(own) == kCGColorSpaceModelRGB)
        context = CGBitmapContextCreate(image.rgba.data(), width, height, 8, width * 4, own, layout);
    if (context == nullptr)
    {
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        context = CGBitmapContextCreate(image.rgba.data(), width, height, 8, width * 4, srgb, layout);
        CGColorSpaceRelease(srgb);
    }
    if (context == nullptr)
    {
        error = "could not read the picture's pixels";
        return false;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), picture);
    CGContextRelease(context);
    return true;
}

bool guiCapture(const std::string& path, Image& area, std::string& error)
{
    if (gWindow == nil)
    {
        error = "no window to photograph";
        return false;
    }
    // -l: only this window, -o: without its shadow, -x: without the camera sound.
    NSArray<NSString*>* arguments = @[
        [NSString stringWithFormat:@"-l%ld", static_cast<long>([gWindow windowNumber])], @"-o", @"-x", @"-tpng",
        toNSString(path)
    ];
    if (!runTool(@"/usr/sbin/screencapture", arguments, error))
        return false;
    CGImageRef window = loadImage(path, error);
    if (window == nullptr)
        return false;

    // The photo holds the whole window, title bar included. The content area is where the plugin draws.
    const NSRect frame = [gWindow frame];
    const NSRect content = [gWindow contentRectForFrameRect:frame];
    const double scaleX = static_cast<double>(CGImageGetWidth(window)) / NSWidth(frame);
    const double scaleY = static_cast<double>(CGImageGetHeight(window)) / NSHeight(frame);
    std::printf("GUI window photo: %zux%zu px for a %gx%g point window (scale %g x %g)\n", CGImageGetWidth(window),
                CGImageGetHeight(window), NSWidth(frame), NSHeight(frame), scaleX, scaleY);
    if (std::fabs(scaleX - scaleY) > 0.01 || scaleX < 0.99)
    {
        CGImageRelease(window);
        error = "the window photo has an unexpected size";
        return false;
    }
    const CGRect contentArea = CGRectMake(std::round((NSMinX(content) - NSMinX(frame)) * scaleX),
                                          std::round((NSMaxY(frame) - NSMaxY(content)) * scaleY),
                                          std::round(NSWidth(content) * scaleX), std::round(NSHeight(content) * scaleY));
    CGImageRef cropped = CGImageCreateWithImageInRect(window, contentArea);
    CGImageRelease(window);
    if (cropped == nullptr)
    {
        error = "could not cut the content area out of the window photo";
        return false;
    }
    const bool ok = toRgba(cropped, area, error);
    CGImageRelease(cropped);
    return ok;
}

void guiCaptureScreen(const std::string& path)
{
    std::string error;
    if (runTool(@"/usr/sbin/screencapture", @[ @"-x", @"-tpng", toNSString(path) ], error))
        std::printf("GUI saved a photo of the whole screen: %s\n", path.c_str());
    else
        std::printf("GUI no photo of the whole screen: %s\n", error.c_str());
}

static NSOpenGLView* findOpenGLView(NSView* view)
{
    if ([view isKindOfClass:[NSOpenGLView class]])
        return (NSOpenGLView*)view;
    for (NSView* child in [view subviews])
        if (NSOpenGLView* found = findOpenGLView(child))
            return found;
    return nil;
}

// One of the editor's OpenGL buffers, read with its own context. Whatever was current before is current again
// afterwards, and the read buffer is restored.
static bool readOpenGL(NSOpenGLView* view, GLenum buffer, Image& image, std::string& error)
{
    const NSSize size = [view convertSizeToBacking:[view bounds].size];
    const int width = static_cast<int>(std::lround(size.width));
    const int height = static_cast<int>(std::lround(size.height));
    if (width <= 0 || height <= 0)
    {
        error = "the OpenGL view has no size";
        return false;
    }
    std::vector<uint8_t> rows(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);

    NSOpenGLContext* previous = [NSOpenGLContext currentContext];
    [[view openGLContext] makeCurrentContext];
    while (glGetError() != GL_NO_ERROR)
    {
    }
    GLint readBuffer = 0;
    glGetIntegerv(GL_READ_BUFFER, &readBuffer);
    glReadBuffer(buffer);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rows.data());
    const GLenum status = glGetError();
    glReadBuffer(static_cast<GLenum>(readBuffer));
    if (previous != nil)
        [previous makeCurrentContext];
    else
        [NSOpenGLContext clearCurrentContext];
    if (status != GL_NO_ERROR)
    {
        char text[80];
        std::snprintf(text, sizeof(text), "glReadPixels failed with OpenGL error 0x%X", static_cast<unsigned>(status));
        error = text;
        return false;
    }

    // OpenGL's rows run from the bottom up. Alpha is made opaque, so that the picture shows the colors as they are.
    const size_t row = static_cast<size_t>(width) * 4;
    image.width = width;
    image.height = height;
    image.rgba.resize(rows.size());
    for (int y = 0; y < height; ++y)
        std::memcpy(&image.rgba[static_cast<size_t>(y) * row], &rows[static_cast<size_t>(height - 1 - y) * row], row);
    for (size_t p = 3; p < image.rgba.size(); p += 4)
        image.rgba[p] = 255;
    return true;
}

// A single-buffered context (the software renderer's fallback on a runner) draws straight into the front buffer. With
// double buffering the front buffer holds the frame last shown, and the back one is the fallback.
bool guiReadEditor(Image& image, std::string& buffer, std::string& error)
{
    NSOpenGLView* view = gWindow != nil ? findOpenGLView([gWindow contentView]) : nil;
    if (view == nil)
    {
        error = "the editor has no OpenGL view";
        return false;
    }
    std::string frontError;
    if (readOpenGL(view, GL_FRONT, image, frontError))
    {
        buffer = "front";
        return true;
    }
    if (readOpenGL(view, GL_BACK, image, error))
    {
        buffer = "back";
        return true;
    }
    error = "front buffer: " + frontError + "; back buffer: " + error;
    return false;
}

bool guiWritePng(const std::string& path, const Image& image, std::string& error)
{
    const CGBitmapInfo layout =
        static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(const_cast<uint8_t*>(image.rgba.data()), static_cast<size_t>(image.width),
                                                 static_cast<size_t>(image.height), 8,
                                                 static_cast<size_t>(image.width) * 4, srgb, layout);
    CGColorSpaceRelease(srgb);
    if (context == nullptr)
    {
        error = "could not make a picture to save as " + path;
        return false;
    }
    CGImageRef picture = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (picture == nullptr)
    {
        error = "could not make a picture to save as " + path;
        return false;
    }
    const bool saved = savePng(picture, path, error);
    CGImageRelease(picture);
    return saved;
}

static void describeView(NSView* view, int depth, NSMutableString* out)
{
    [out appendFormat:@"GUI view %@%@ %gx%g%@\n", [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
                      NSStringFromClass([view class]), NSWidth([view frame]), NSHeight([view frame]),
                      [view wantsLayer] ? @", layer-backed" : @""];
    if ([view isKindOfClass:[NSOpenGLView class]])
    {
        NSOpenGLView* glView = (NSOpenGLView*)view;
        NSOpenGLPixelFormat* format = [glView pixelFormat];
        GLint accelerated = -1, doubleBuffer = -1, profile = -1, rendererId = -1;
        [format getValues:&accelerated forAttribute:NSOpenGLPFAAccelerated forVirtualScreen:0];
        [format getValues:&doubleBuffer forAttribute:NSOpenGLPFADoubleBuffer forVirtualScreen:0];
        [format getValues:&profile forAttribute:NSOpenGLPFAOpenGLProfile forVirtualScreen:0];
        [format getValues:&rendererId forAttribute:NSOpenGLPFARendererID forVirtualScreen:0];

        // Asked through the editor's own OpenGL context; whatever was current before is current again afterwards.
        NSOpenGLContext* previous = [NSOpenGLContext currentContext];
        [[glView openGLContext] makeCurrentContext];
        const GLubyte* renderer = glGetString(GL_RENDERER);
        const GLubyte* version = glGetString(GL_VERSION);
        const GLubyte* vendor = glGetString(GL_VENDOR);
        [out appendFormat:@"GUI opengl renderer \"%s\", version \"%s\", vendor \"%s\"\n",
                          renderer != nullptr ? reinterpret_cast<const char*>(renderer) : "(none)",
                          version != nullptr ? reinterpret_cast<const char*>(version) : "(none)",
                          vendor != nullptr ? reinterpret_cast<const char*>(vendor) : "(none)"];
        if (previous != nil)
            [previous makeCurrentContext];
        else
            [NSOpenGLContext clearCurrentContext];
        [out appendFormat:@"GUI opengl view pixel format %@ (%d virtual screens): accelerated %d, double buffer %d, "
                          @"profile 0x%X (legacy is 0x%X), renderer ID 0x%X, best resolution surface %@\n",
                          format != nil ? @"set" : @"nil", format != nil ? [format numberOfVirtualScreens] : 0,
                          accelerated, doubleBuffer, profile, static_cast<unsigned>(NSOpenGLProfileVersionLegacy),
                          rendererId, yesNo([glView wantsBestResolutionOpenGLSurface])];

        // The pixel format the context really uses, which can differ from the view's.
        CGLContextObj cgl = [[glView openGLContext] CGLContextObj];
        CGLPixelFormatObj pixelFormat = cgl != nullptr ? CGLGetPixelFormat(cgl) : nullptr;
        GLint cglAccelerated = -1, cglDoubleBuffer = -1, cglRenderer = -1, cglProfile = -1, current = -1;
        if (pixelFormat != nullptr)
        {
            CGLDescribePixelFormat(pixelFormat, 0, kCGLPFAAccelerated, &cglAccelerated);
            CGLDescribePixelFormat(pixelFormat, 0, kCGLPFADoubleBuffer, &cglDoubleBuffer);
            CGLDescribePixelFormat(pixelFormat, 0, kCGLPFARendererID, &cglRenderer);
            CGLDescribePixelFormat(pixelFormat, 0, kCGLPFAOpenGLProfile, &cglProfile);
        }
        if (cgl != nullptr)
            CGLGetParameter(cgl, kCGLCPCurrentRendererID, &current);
        CALayer* layer = [glView layer];
        [out appendFormat:@"GUI opengl context pixel format %@: accelerated %d, double buffer %d, renderer ID 0x%X, "
                          @"profile 0x%X; current renderer ID 0x%X; layer %@, %@\n",
                          pixelFormat != nullptr ? @"set" : @"nil", cglAccelerated, cglDoubleBuffer, cglRenderer,
                          cglProfile, current, layer != nil ? NSStringFromClass([layer class]) : @"none",
                          layer != nil && [layer contents] != nil ? @"with contents" : @"without contents"];
    }
    for (NSView* child in [view subviews])
        describeView(child, depth + 1, out);
}

std::string guiDescribe()
{
    if (gWindow == nil)
        return "GUI no window\n";
    NSMutableString* out = [NSMutableString string];
    NSScreen* screen = [gWindow screen] != nil ? [gWindow screen] : [NSScreen mainScreen];
    [out appendFormat:@"GUI macOS %@, screen %gx%g points, backing scale %g, %lu screen(s)\n",
                      [[NSProcessInfo processInfo] operatingSystemVersionString], NSWidth([screen frame]),
                      NSHeight([screen frame]), [screen backingScaleFactor],
                      static_cast<unsigned long>([[NSScreen screens] count])];
    [out appendFormat:@"GUI window %ld: frame %@, content %@, backing scale %g, visible to macOS %@, key %@, app active %@\n",
                      static_cast<long>([gWindow windowNumber]), NSStringFromRect([gWindow frame]),
                      NSStringFromRect([gWindow contentRectForFrameRect:[gWindow frame]]), [gWindow backingScaleFactor],
                      yesNo(([gWindow occlusionState] & NSWindowOcclusionStateVisible) != 0), yesNo([gWindow isKeyWindow]),
                      yesNo([NSApp isActive])];
    [out appendFormat:@"GUI mouse pointer at %@\n", NSStringFromPoint([NSEvent mouseLocation])];
    describeView([gWindow contentView], 0, out);
    return [out UTF8String];
}

void guiCloseWindow()
{
    [gWindow orderOut:nil];
    [gWindow close];
    gWindow = nil;
}

bool guiReadPng(const std::string& path, Image& image, std::string& error)
{
    CGImageRef picture = loadImage(path, error);
    if (picture == nullptr)
        return false;
    const bool ok = toRgba(picture, image, error);
    CGImageRelease(picture);
    return ok;
}
