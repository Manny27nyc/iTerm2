// -*- mode:objc -*-
/*
 **  TextViewWrapper.m
 **
 **  Copyright (c) 2010
 **
 **  Author: George Nachman
 **
 **  Project: iTerm2
 **
 **  Description: This wraps a textview and adds a border at the top of
 **  the visible area.
 **
 **  This program is free software; you can redistribute it and/or modify
 **  it under the terms of the GNU General Public License as published by
 **  the Free Software Foundation; either version 2 of the License, or
 **  (at your option) any later version.
 **
 **  This program is distributed in the hope that it will be useful,
 **  but WITHOUT ANY WARRANTY; without even the implied warranty of
 **  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 **  GNU General Public License for more details.
 **
 **  You should have received a copy of the GNU General Public License
 **  along with this program; if not, write to the Free Software
 **  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */


#import "TextViewWrapper.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermPreferences.h"
#import "NSObject+iTerm.h"
#import "NSView+iTerm.h"
#import "PTYTextView.h"

@implementation TextViewWrapper {
    PTYTextView *child_;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(scrollViewDidScroll:)
                                                     name:NSViewBoundsDidChangeNotification
                                                   object:nil];
    }
    return self;
}

// This is a hack to fix an apparent bug in macOS 10.14 beta 3. I would like to remove it when it's no longer needed.
// https://openradar.appspot.com/radar?id=6090021505335296
// rdar://42228044
- (void)scrollViewDidScroll:(NSNotification *)notification {
    if (notification.object != self.superview) {
        return;
    }
    [self setNeedsDisplay:YES];
}

// For some reason this view just doesn't work with layers when using the legacy renderer. When it
// has a layer it becomes opaque black, as of macOS 11.1.
- (void)drawRect:(NSRect)dirtyRect {
    NSColor *color = [self it_backgroundColorOfEnclosingTerminalIfBackgroundColorViewHidden];
    DLog(@"textViewWrapper: draw with color %@", color);
    [color ?: [NSColor clearColor] set];
    NSRectFill(dirtyRect);
}

- (void)addSubview:(NSView *)child {
    [super addSubview:child];
    if ([child isKindOfClass:[PTYTextView class]]) {
      child_ = (PTYTextView *)child;
      [self setFrame:NSMakeRect(0, 0, [child frame].size.width, [child frame].size.height)];
      [child setFrameOrigin:NSMakePoint(0, 0)];
      [self setPostsFrameChangedNotifications:YES];
      [self setPostsBoundsChangedNotifications:YES];
    }
}

- (void)willRemoveSubview:(NSView *)subview {
  if (subview == child_) {
    child_ = nil;
  }
  [super willRemoveSubview:subview];
}

- (NSRect)adjustScroll:(NSRect)proposedVisibleRect {
    return [child_ adjustScroll:proposedVisibleRect];
}

- (BOOL)isFlipped {
    return YES;
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    NSRect rect = self.bounds;
    rect.size.height -= [iTermPreferences intForKey:kPreferenceKeyTopBottomMargins];
    rect.origin.y = [iTermPreferences intForKey:kPreferenceKeyTopBottomMargins];
    if (!NSEqualRects(child_.frame, rect)) {
        child_.frame = rect;
    }
}

- (void)setUseMetal:(BOOL)useMetal {
    if (useMetal == _useMetal) {
        return;
    }
    _useMetal = useMetal;
    [self setNeedsDisplay:YES];
}

@end
