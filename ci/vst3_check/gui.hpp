/*
 * Wolf Shaper CI checks: the platform side of the gui check (ci/vst3_check)
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Copyright (C) 2026 Sonic Weaponry
 */

#pragma once

#include <cstdint>
#include <string>
#include <vector>

// A picture as 8-bit RGBA, rows from top to bottom.
struct Image
{
    int width = 0;
    int height = 0;
    std::vector<uint8_t> rgba;
};

// "photos/x.png" with the suffix "-window" becomes "photos/x-window.png".
inline std::string withSuffix(const std::string& path, const std::string& suffix)
{
    const size_t dot = path.rfind('.');
    const size_t slash = path.find_last_of("/\\");
    if (dot == std::string::npos || (slash != std::string::npos && dot < slash))
        return path + suffix;
    return path.substr(0, dot) + suffix + path.substr(dot);
}

// macOS (gui_mac.mm). One window at a time, all on the main thread.

// Starts the application, as a regular app whose windows come to the front.
bool guiStart(std::string& error);

// Opens a window with a content area of this size in points, and returns that content area's NSView, the parent a
// host hands to IPlugView::attached.
void* guiOpenWindow(int width, int height, const std::string& title, std::string& error);

void guiContentSize(int& width, int& height);
bool guiResizeWindow(int width, int height);

// Runs the event loop, which lets the plugin draw and run its timers.
void guiRun(double seconds);

// What the editor drew: its OpenGL buffer, read with its own context (glReadPixels). The front buffer, or the back one
// when the front can't be read; buffer says which.
bool guiReadEditor(Image& image, std::string& buffer, std::string& error);

// Photographs the window as the screen shows it with Apple's screencapture tool, saves the photo as a PNG at path, and
// returns its content area, where the plugin draws.
bool guiCapture(const std::string& path, Image& area, std::string& error);

// The whole screen, to see what went wrong.
void guiCaptureScreen(const std::string& path);

bool guiWritePng(const std::string& path, const Image& image, std::string& error);

// Screen, window and OpenGL facts for the log, one "GUI ..." line each.
std::string guiDescribe();

void guiCloseWindow();

bool guiReadPng(const std::string& path, Image& image, std::string& error);
