#import "VT100Output.h"

#import "DebugLogging.h"
#import "iTermAdvancedSettingsModel.h"

#include <term.h>

#define MEDIAN(min_, mid_, max_) MAX(MIN(mid_, max_), min_)

// Indexes into _keyStrings.
typedef enum {
    TERMINFO_KEY_LEFT, TERMINFO_KEY_RIGHT, TERMINFO_KEY_UP, TERMINFO_KEY_DOWN,
    TERMINFO_KEY_HOME, TERMINFO_KEY_END, TERMINFO_KEY_PAGEDOWN,
    TERMINFO_KEY_PAGEUP, TERMINFO_KEY_F0, TERMINFO_KEY_F1, TERMINFO_KEY_F2,
    TERMINFO_KEY_F3, TERMINFO_KEY_F4, TERMINFO_KEY_F5, TERMINFO_KEY_F6,
    TERMINFO_KEY_F7, TERMINFO_KEY_F8, TERMINFO_KEY_F9, TERMINFO_KEY_F10,
    TERMINFO_KEY_F11, TERMINFO_KEY_F12, TERMINFO_KEY_F13, TERMINFO_KEY_F14,
    TERMINFO_KEY_F15, TERMINFO_KEY_F16, TERMINFO_KEY_F17, TERMINFO_KEY_F18,
    TERMINFO_KEY_F19, TERMINFO_KEY_F20, TERMINFO_KEY_F21, TERMINFO_KEY_F22,
    TERMINFO_KEY_F23, TERMINFO_KEY_F24, TERMINFO_KEY_F25, TERMINFO_KEY_F26,
    TERMINFO_KEY_F27, TERMINFO_KEY_F28, TERMINFO_KEY_F29, TERMINFO_KEY_F30,
    TERMINFO_KEY_F31, TERMINFO_KEY_F32, TERMINFO_KEY_F33, TERMINFO_KEY_F34,
    TERMINFO_KEY_F35, TERMINFO_KEY_BACKSPACE, TERMINFO_KEY_BACK_TAB,
    TERMINFO_KEY_TAB, TERMINFO_KEY_DEL, TERMINFO_KEY_INS, TERMINFO_KEY_HELP,
    TERMINFO_KEYS
} VT100TerminalTerminfoKeys;

typedef enum {
    // Keyboard modifier flags
    MOUSE_BUTTON_SHIFT_FLAG = 4,
    MOUSE_BUTTON_META_FLAG = 8,
    MOUSE_BUTTON_CTRL_FLAG = 16,

    // scroll flag
    MOUSE_BUTTON_SCROLL_FLAG = 64,  // this is a scroll event

    // for SGR 1006 style, internal use only
    MOUSE_BUTTON_SGR_RELEASE_FLAG = 128  // mouse button was released

} MouseButtonModifierFlag;

#define ESC  0x1b

// Codes to send for keypresses
#define CURSOR_SET_DOWN      "\033OB"
#define CURSOR_SET_UP        "\033OA"
#define CURSOR_SET_RIGHT     "\033OC"
#define CURSOR_SET_LEFT      "\033OD"
#define CURSOR_SET_HOME      "\033OH"
#define CURSOR_SET_END       "\033OF"
#define CURSOR_RESET_DOWN    "\033[B"
#define CURSOR_RESET_UP      "\033[A"
#define CURSOR_RESET_RIGHT   "\033[C"
#define CURSOR_RESET_LEFT    "\033[D"
#define CURSOR_RESET_HOME    "\033[H"
#define CURSOR_RESET_END     "\033[F"
#define CURSOR_MOD_DOWN      "\033[1;%dB"
#define CURSOR_MOD_UP        "\033[1;%dA"
#define CURSOR_MOD_RIGHT     "\033[1;%dC"
#define CURSOR_MOD_LEFT      "\033[1;%dD"
#define CURSOR_MOD_HOME      "\033[1;%dH"
#define CURSOR_MOD_END       "\033[1;%dF"

#define KEY_INSERT           "\033[2~"
#define KEY_PAGE_UP          "\033[5~"
#define KEY_PAGE_DOWN        "\033[6~"
#define KEY_DEL              "\033[3~"
#define KEY_BACKSPACE        "\010"

#define ALT_KP_0        "\033Op"
#define ALT_KP_1        "\033Oq"
#define ALT_KP_2        "\033Or"
#define ALT_KP_3        "\033Os"
#define ALT_KP_4        "\033Ot"
#define ALT_KP_5        "\033Ou"
#define ALT_KP_6        "\033Ov"
#define ALT_KP_7        "\033Ow"
#define ALT_KP_8        "\033Ox"
#define ALT_KP_9        "\033Oy"
#define ALT_KP_MINUS    "\033Om"
#define ALT_KP_PLUS     "\033Ok"
#define ALT_KP_PERIOD   "\033On"
#define ALT_KP_SLASH    "\033Oo"
#define ALT_KP_STAR     "\033Oj"
#define ALT_KP_EQUALS   "\033OX"
#define ALT_KP_ENTER    "\033OM"

// Reporting formats
#define KEY_FUNCTION_FORMAT  "\033[%d~"

#define REPORT_POSITION      "\033[%d;%dR"
#define REPORT_POSITION_Q    "\033[?%d;%dR"
#define REPORT_STATUS        "\033[0n"

// Secondary Device Attribute: VT100

#define STATIC_STRLEN(n)   ((sizeof(n)) - 1)

@implementation VT100Output {
    // Indexed by values in VT100TerminalTerminfoKeys.
    // Gives strings to send for various special keys.
    char *_keyStrings[TERMINFO_KEYS];

    // If $TERM is something normalish then we can do fancier key reporting
    // (e.g., modifier + forwards delete). When false, rely on terminfo's definition.
    BOOL _standard;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _optionIsMetaForSpecialKeys = YES;
        self.termType = @"dumb";
    }
    return self;
}

- (void)dealloc {
    for (int i = 0; i < TERMINFO_KEYS; i ++) {
        if (_keyStrings[i]) {
            free(_keyStrings[i]);
        }
    }
}

+ (NSSet<NSString *> *)standardTerminals {
    static NSSet<NSString *> *terms;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        terms = [NSSet setWithArray:@[ @"xterm",
                                       @"xterm-new",
                                       @"xterm-256color",
                                       @"xterm+256color",
                                       @"xterm-kitty",
                                       @"iterm",
                                       @"iterm2" ]];
    });
    return terms;
}

- (void)setTermType:(NSString *)term {
    _standard = [[VT100Output standardTerminals] containsObject:term];
    _termType = [term copy];
    int r = 0;
    setupterm((char *)[_termType UTF8String], fileno(stdout), &r);
    const BOOL termTypeIsValid = (r == 1);

    DLog(@"setTermTypeIsValid:%@ cur_term=%p", @(termTypeIsValid), cur_term);
    if (termTypeIsValid && cur_term) {
        char *key_names[] = {
            key_left, key_right, key_up, key_down,
            key_home, key_end, key_npage, key_ppage,
            key_f0, key_f1, key_f2, key_f3, key_f4,
            key_f5, key_f6, key_f7, key_f8, key_f9,
            key_f10, key_f11, key_f12, key_f13, key_f14,
            key_f15, key_f16, key_f17, key_f18, key_f19,
            key_f20, key_f21, key_f22, key_f23, key_f24,
            key_f25, key_f26, key_f27, key_f28, key_f29,
            key_f30, key_f31, key_f32, key_f33, key_f34,
            key_f35,
            key_backspace, key_btab,
            tab,
            key_dc, key_ic,
            key_help,
        };

        for (int i = 0; i < TERMINFO_KEYS; i ++) {
            if (_keyStrings[i]) {
                free(_keyStrings[i]);
            }
            _keyStrings[i] = key_names[i] ? strdup(key_names[i]) : NULL;
            DLog(@"Set key string %d (%s) to %s", i, key_names[i], _keyStrings[i]);
        }
    } else {
        for (int i = 0; i < TERMINFO_KEYS; i ++) {
            if (_keyStrings[i]) {
                free(_keyStrings[i]);
            }
            _keyStrings[i] = NULL;
        }
    }
}

- (NSData *)keyArrowUp:(unsigned int)modflag {
    return [self specialKey:TERMINFO_KEY_UP
                  cursorMod:CURSOR_MOD_UP
                  cursorSet:CURSOR_SET_UP
                cursorReset:CURSOR_RESET_UP
                    modflag:modflag
                   isCursor:YES];
}

- (NSData *)keyArrowDown:(unsigned int)modflag {
    return [self specialKey:TERMINFO_KEY_DOWN
                  cursorMod:CURSOR_MOD_DOWN
                  cursorSet:CURSOR_SET_DOWN
                cursorReset:CURSOR_RESET_DOWN
                    modflag:modflag
                   isCursor:YES];
}

- (NSData *)keyArrowLeft:(unsigned int)modflag {
    return [self specialKey:TERMINFO_KEY_LEFT
                  cursorMod:CURSOR_MOD_LEFT
                  cursorSet:CURSOR_SET_LEFT
                cursorReset:CURSOR_RESET_LEFT
                    modflag:modflag
                   isCursor:YES];
}

- (NSData *)keyArrowRight:(unsigned int)modflag {
    return [self specialKey:TERMINFO_KEY_RIGHT
                  cursorMod:CURSOR_MOD_RIGHT
                  cursorSet:CURSOR_SET_RIGHT
                cursorReset:CURSOR_RESET_RIGHT
                    modflag:modflag
                   isCursor:YES];
}

- (NSData *)keyHome:(unsigned int)modflag screenlikeTerminal:(BOOL)screenlike {
    if (screenlike) {
        const char *bytes = "\033[1~";
        return [NSData dataWithBytes:bytes length:strlen(bytes)];
    }
    return [self specialKey:TERMINFO_KEY_HOME
                  cursorMod:CURSOR_MOD_HOME
                  cursorSet:CURSOR_SET_HOME
                cursorReset:CURSOR_RESET_HOME
                    modflag:modflag
                   isCursor:NO];
}

- (NSData *)keyEnd:(unsigned int)modflag screenlikeTerminal:(BOOL)screenlike {
    if (screenlike) {
        const char *bytes = "\033[4~";
        return [NSData dataWithBytes:bytes length:strlen(bytes)];
    }
    return [self specialKey:TERMINFO_KEY_END
                  cursorMod:CURSOR_MOD_END
                  cursorSet:CURSOR_SET_END
                cursorReset:CURSOR_RESET_END
                    modflag:modflag
                   isCursor:NO];
}

- (NSData *)keyInsert {
    if (_keyStrings[TERMINFO_KEY_INS]) {
        return [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_INS]
                              length:strlen(_keyStrings[TERMINFO_KEY_INS])];
    } else {
        return [NSData dataWithBytes:KEY_INSERT length:STATIC_STRLEN(KEY_INSERT)];
    }
}

- (NSData *)standardDataForKeyWithCode:(int)code flags:(NSEventModifierFlags)flags {
    if (!_standard) {
        return nil;
    }
    const int mod = [self cursorModifierParamForEventModifierFlags:flags];
    if (mod) {
        return [[NSString stringWithFormat:@"\e[%d;%d~", code, mod] dataUsingEncoding:NSUTF8StringEncoding];
    }
    return [[NSString stringWithFormat:@"\e[%d~", code] dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)keyDelete:(NSEventModifierFlags)flags {
    NSData *standard = [self standardDataForKeyWithCode:3 flags:flags];
    if (standard) {
        return standard;
    }
    if (_keyStrings[TERMINFO_KEY_DEL]) {
        return [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_DEL]
                              length:strlen(_keyStrings[TERMINFO_KEY_DEL])];
    } else {
        return [NSData dataWithBytes:KEY_DEL length:STATIC_STRLEN(KEY_DEL)];
    }
}

- (NSData *)keyBackspace {
    if (_keyStrings[TERMINFO_KEY_BACKSPACE]) {
        return [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_BACKSPACE]
                              length:strlen(_keyStrings[TERMINFO_KEY_BACKSPACE])];
    } else {
        return [NSData dataWithBytes:KEY_BACKSPACE length:STATIC_STRLEN(KEY_BACKSPACE)];
    }
}

- (NSData *)keyPageUp:(unsigned int)modflag {
    NSData *standard = [self standardDataForKeyWithCode:5 flags:modflag];
    if (standard) {
        return standard;
    }
    NSData* theSuffix;
    if (_keyStrings[TERMINFO_KEY_PAGEUP]) {
        theSuffix = [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_PAGEUP]
                                   length:strlen(_keyStrings[TERMINFO_KEY_PAGEUP])];
    } else {
        theSuffix = [NSData dataWithBytes:KEY_PAGE_UP
                                   length:STATIC_STRLEN(KEY_PAGE_UP)];
    }
    NSMutableData* data = [NSMutableData data];
    if (modflag & NSEventModifierFlagOption) {
        char esc = ESC;
        [data appendData:[NSData dataWithBytes:&esc length:1]];
    }
    [data appendData:theSuffix];
    return data;
}

- (NSData *)keyPageDown:(unsigned int)modflag
{
    NSData *standard = [self standardDataForKeyWithCode:6 flags:modflag];
    if (standard) {
        return standard;
    }
    NSData* theSuffix;
    if (_keyStrings[TERMINFO_KEY_PAGEDOWN]) {
        theSuffix = [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_PAGEDOWN]
                                   length:strlen(_keyStrings[TERMINFO_KEY_PAGEDOWN])];
    } else {
        theSuffix = [NSData dataWithBytes:KEY_PAGE_DOWN
                                   length:STATIC_STRLEN(KEY_PAGE_DOWN)];
    }
    NSMutableData* data = [NSMutableData data];
    if (modflag & NSEventModifierFlagOption) {
        char esc = ESC;
        [data appendData:[NSData dataWithBytes:&esc length:1]];
    }
    [data appendData:theSuffix];
    return data;
}

- (BOOL)isLikeXterm {
    return [_termType hasPrefix:@"xterm"];
}

// https://invisible-island.net/xterm/xterm-function-keys.html hints at this but is incomplete.
// Much of this was determined by experimentation with xterm, TERM=xterm.
- (NSString *)xtermKeyFunction:(int)no modifiers:(NSEventModifierFlags)modifiers {
    // Modifiers remap function keys into higher number function keys, some of which probably
    // don't exist on any earthly keyboard.
    // regular f1 = f1          (+0)
    // meta f1 = f49            (+48)
    // control f1 = f25         (+24)
    // meta ctrl f1 = f75       (+74)
    // shift f1 = f13           (+12)
    // meta shift f1 = f61      (+60)
    // shift control f1 = f37   (+36)
    // meta shift ctrl f1 = f87 (+86)

    const BOOL shift = !!(modifiers & NSEventModifierFlagShift);
    const BOOL ctrl = !!(modifiers & NSEventModifierFlagControl);
    const BOOL meta = !!(modifiers & NSEventModifierFlagOption);

    const int offsets[] = {
             // Shift Control Meta
        0,   // no    no      no
        12,  // yes   no      no
        24,  // no    yes     no
        36,  // yes   yes     no
        48,  // no    no      yes
        60,  // yes   no      yes
        74,  // no    yes     yes
        86,  // yes   yes     yes
    };
    int i = 0;
    if (shift) {
        i += 1;
    }
    if (ctrl) {
        i += 2;
    }
    if (meta) {
        i += 4;
    }
    const int offset = offsets[i];

    switch (MEDIAN(1, no + offset, 98)) {
            // Regular
        case 1:
            return @"\eOP";
        case 2:
            return @"\eOQ";
        case 3:
            return @"\eOR";
        case 4:
            return @"\eOS";
        case 5:
            return @"\e[15~";
        case 6:
            return @"\e[17~";
        case 7:
            return @"\e[18~";
        case 8:
            return @"\e[19~";
        case 9:
            return @"\e[20~";
        case 10:
            return @"\e[21~";
        case 11:
            return @"\e[23~";
        case 12:
            return @"\e[24~";

            // shift
        case 13:
            return @"\e[1;2P";
        case 14:
            return @"\e[1;2Q";
        case 15:
            return @"\e[1;2R";
        case 16:
            return @"\e[1;2S";
        case 17:
            return @"\e[15;2~";
        case 18:
            return @"\e[17;2~";
        case 19:
            return @"\e[18;2~";
        case 20:
            return @"\e[19;2~";
        case 21:
            return @"\e[20;2~";
        case 22:
            return @"\e[21;2~";
        case 23:
            return @"\e[23;2~";
        case 24:
            return @"\e[24;2~";

            // control
        case 25:
            return @"\e[1;5P";
        case 26:
            return @"\e[1;5Q";
        case 27:
            return @"\e[1;5R";
        case 28:
            return @"\e[1;5S";
        case 29:
            return @"\e[15;5~";
        case 30:
            return @"\e[17;5~";
        case 31:
            return @"\e[18;5~";
        case 32:
            return @"\e[19;5~";
        case 33:
            return @"\e[20;5~";
        case 34:
            return @"\e[21;5~";
        case 35:
            return @"\e[23;5~";
        case 36:
            return @"\e[24;5~";

            // shift-control
        case 37:
            return @"\e[1;6P";
        case 38:
            return @"\e[1;6Q";
        case 39:
            return @"\e[1;6R";
        case 40:
            return @"\e[1;6S";
        case 41:
            return @"\e[15;6~";
        case 42:
            return @"\e[17;6~";
        case 43:
            return @"\e[18;6~";
        case 44:
            return @"\e[19;6~";
        case 45:
            return @"\e[20;6~";
        case 46:
            return @"\e[21;6~";
        case 47:
            return @"\e[23;6~";
        case 48:
            return @"\e[24;6~";

            // meta
        case 49:
            return _optionIsMetaForSpecialKeys ? @"\e[1;9P" : @"\e[1;3P";
        case 50:
            return _optionIsMetaForSpecialKeys ? @"\e[1;9Q" : @"\e[1;3Q";
        case 51:
            return _optionIsMetaForSpecialKeys ? @"\e[1;9R" : @"\e[1;3R";
        case 52:
            return _optionIsMetaForSpecialKeys ? @"\e[1;9S" : @"\e[1;3S";
        case 53:
            return _optionIsMetaForSpecialKeys ? @"\e[15;9~" : @"\e[15;3~";
        case 54:
            return _optionIsMetaForSpecialKeys ? @"\e[17;9~" : @"\e[17;3~";
        case 55:
            return _optionIsMetaForSpecialKeys ? @"\e[18;9~" : @"\e[18;3~";
        case 56:
            return _optionIsMetaForSpecialKeys ? @"\e[19;9~" : @"\e[19;3~";
        case 57:
            return _optionIsMetaForSpecialKeys ? @"\e[20;9~" : @"\e[20;3~";
        case 58:
            return _optionIsMetaForSpecialKeys ? @"\e[21;9~" : @"\e[21;3~";
        case 59:
            return _optionIsMetaForSpecialKeys ? @"\e[23;9~" : @"\e[23;3~";
        case 60:
            return _optionIsMetaForSpecialKeys ? @"\e[24;9~" : @"\e[24;3~";

            // shift-meta
        case 61:
            return _optionIsMetaForSpecialKeys ? @"\e[1;10P" : @"\e[1;4P";
        case 62:
            return _optionIsMetaForSpecialKeys ? @"\e[1;10Q" : @"\e[1;4Q";
        case 63:
            return _optionIsMetaForSpecialKeys ? @"\e[1;10R" : @"\e[1;4R";
        case 64:
            return _optionIsMetaForSpecialKeys ? @"\e[1;10S" : @"\e[1;4S";
        case 65:
            return _optionIsMetaForSpecialKeys ? @"\e[15;10~" : @"\e[15;4~";
        case 66:
            return _optionIsMetaForSpecialKeys ? @"\e[15;10~" : @"\e[15;4~";
        case 67:
            return _optionIsMetaForSpecialKeys ? @"\e[17;10~" : @"\e[17;4~";
        case 68:
            return _optionIsMetaForSpecialKeys ? @"\e[18;10~" : @"\e[18;4~";
        case 69:
            return _optionIsMetaForSpecialKeys ? @"\e[19;10~" : @"\e[19;4~";
        case 70:
            return _optionIsMetaForSpecialKeys ? @"\e[20;10~" : @"\e[20;4~";
        case 71:
            return _optionIsMetaForSpecialKeys ? @"\e[21;10~" : @"\e[21;4~";
        case 72:
            return _optionIsMetaForSpecialKeys ? @"\e[22;10~" : @"\e[22;4~";
        case 73:
            return _optionIsMetaForSpecialKeys ? @"\e[23;10~" : @"\e[23;4~";
        case 74:
            return _optionIsMetaForSpecialKeys ? @"\e[24;10~" : @"\e[24;4~";

            // control-meta
        case 75:
            return _optionIsMetaForSpecialKeys ? @"\e[1;13P" : @"\e[1;7P";
        case 76:
            return _optionIsMetaForSpecialKeys ? @"\e[1;13Q" : @"\e[1;7Q";
        case 77:
            return _optionIsMetaForSpecialKeys ? @"\e[1;13R" : @"\e[1;7R";
        case 78:
            return _optionIsMetaForSpecialKeys ? @"\e[1;13S" : @"\e[1;7S";
        case 79:
            return _optionIsMetaForSpecialKeys ? @"\e[15;13~" : @"\e[15;7~";
        case 80:
            return _optionIsMetaForSpecialKeys ? @"\e[17;13~" : @"\e[17;7~";
        case 81:
            return _optionIsMetaForSpecialKeys ? @"\e[18;13~" : @"\e[18;7~";
        case 82:
            return _optionIsMetaForSpecialKeys ? @"\e[19;13~" : @"\e[19;7~";
        case 83:
            return _optionIsMetaForSpecialKeys ? @"\e[20;13~" : @"\e[20;7~";
        case 84:
            return _optionIsMetaForSpecialKeys ? @"\e[21;13~" : @"\e[21;7~";
        case 85:
            return _optionIsMetaForSpecialKeys ? @"\e[23;13~" : @"\e[23;7~";
        case 86:
            return _optionIsMetaForSpecialKeys ? @"\e[24;13~" : @"\e[24;7~";

            // shift-control-meta
        case 87:
            return _optionIsMetaForSpecialKeys ? @"\e[1;14P" : @"\e[1;8P";
        case 88:
            return _optionIsMetaForSpecialKeys ? @"\e[1;14Q" : @"\e[1;8Q";
        case 89:
            return _optionIsMetaForSpecialKeys ? @"\e[1;14R" : @"\e[1;8R";
        case 90:
            return _optionIsMetaForSpecialKeys ? @"\e[1;14S" : @"\e[1;8S";
        case 91:
            return _optionIsMetaForSpecialKeys ? @"\e[15;14~" : @"\e[15;8~";
        case 92:
            return _optionIsMetaForSpecialKeys ? @"\e[17;14~" : @"\e[17;8~";
        case 93:
            return _optionIsMetaForSpecialKeys ? @"\e[18;14~" : @"\e[18;8~";
        case 94:
            return _optionIsMetaForSpecialKeys ? @"\e[19;14~" : @"\e[19;8~";
        case 95:
            return _optionIsMetaForSpecialKeys ? @"\e[20;14~" : @"\e[20;8~";
        case 96:
            return _optionIsMetaForSpecialKeys ? @"\e[21;14~" : @"\e[21;8~";
        case 97:
            return _optionIsMetaForSpecialKeys ? @"\e[23;14~" : @"\e[23;8~";
        case 98:
            return _optionIsMetaForSpecialKeys ? @"\e[24;14~" : @"\e[24;8~";
    }
    return nil;
}

// Reference: http://www.utexas.edu/cc/faqs/unix/VT200-function-keys.html
// http://www.cs.utk.edu/~shuford/terminal/misc_old_terminals_news.txt
- (NSData *)keyFunction:(int)no modifiers:(NSEventModifierFlags)modifiers {
    DLog(@"keyFunction:%@", @(no));
    char str[256];
    int len;

    if ([self isLikeXterm]) {
        return [[self xtermKeyFunction:no modifiers:modifiers] dataUsingEncoding:NSISOLatin1StringEncoding];
    }

    if (no <= 5) {
        if (_keyStrings[TERMINFO_KEY_F0+no]) {
            return [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_F0+no]
                                  length:strlen(_keyStrings[TERMINFO_KEY_F0+no])];
        } else {
            sprintf(str, KEY_FUNCTION_FORMAT, no + 10);
        }
    } else if (no <= 10) {
        if (_keyStrings[TERMINFO_KEY_F0+no]) {
            return [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_F0+no]
                                  length:strlen(_keyStrings[TERMINFO_KEY_F0+no])];
        } else {
            sprintf(str, KEY_FUNCTION_FORMAT, no + 11);
        }
    } else if (no <= 14) {
        if (_keyStrings[TERMINFO_KEY_F0+no]) {
            return [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_F0+no]
                                  length:strlen(_keyStrings[TERMINFO_KEY_F0+no])];
        } else {
            sprintf(str, KEY_FUNCTION_FORMAT, no + 12);
        }
    } else if (no <= 16) {
        if (_keyStrings[TERMINFO_KEY_F0+no]) {
            return [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_F0+no]
                                  length:strlen(_keyStrings[TERMINFO_KEY_F0+no])];
        } else {
            sprintf(str, KEY_FUNCTION_FORMAT, no + 13);
        }
    } else if (no <= 20) {
        if (_keyStrings[TERMINFO_KEY_F0+no]) {
            return [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_F0+no]
                                  length:strlen(_keyStrings[TERMINFO_KEY_F0+no])];
        } else {
            sprintf(str, KEY_FUNCTION_FORMAT, no + 14);
        }
    } else if (no <= 35) {
        if (_keyStrings[TERMINFO_KEY_F0+no]) {
            return [NSData dataWithBytes:_keyStrings[TERMINFO_KEY_F0+no]
                                  length:strlen(_keyStrings[TERMINFO_KEY_F0+no])];
        } else {
            str[0] = 0;
        }
    } else {
        str[0] = 0;
    }
    len = strlen(str);
    return [NSData dataWithBytes:str length:len];
}

- (NSData*)keypadData:(unichar)unicode keystr:(NSString*)keystr {
    NSData *theData = nil;

    // numeric keypad mode
    if (!self.keypadMode) {
        return ([keystr dataUsingEncoding:NSUTF8StringEncoding]);
    }
    // alternate keypad mode
    switch (unicode) {
        case '0':
            theData = [NSData dataWithBytes:ALT_KP_0 length:STATIC_STRLEN(ALT_KP_0)];
            break;
        case '1':
            theData = [NSData dataWithBytes:ALT_KP_1 length:STATIC_STRLEN(ALT_KP_1)];
            break;
        case '2':
            theData = [NSData dataWithBytes:ALT_KP_2 length:STATIC_STRLEN(ALT_KP_2)];
            break;
        case '3':
            theData = [NSData dataWithBytes:ALT_KP_3 length:STATIC_STRLEN(ALT_KP_3)];
            break;
        case '4':
            theData = [NSData dataWithBytes:ALT_KP_4 length:STATIC_STRLEN(ALT_KP_4)];
            break;
        case '5':
            theData = [NSData dataWithBytes:ALT_KP_5 length:STATIC_STRLEN(ALT_KP_5)];
            break;
        case '6':
            theData = [NSData dataWithBytes:ALT_KP_6 length:STATIC_STRLEN(ALT_KP_6)];
            break;
        case '7':
            theData = [NSData dataWithBytes:ALT_KP_7 length:STATIC_STRLEN(ALT_KP_7)];
            break;
        case '8':
            theData = [NSData dataWithBytes:ALT_KP_8 length:STATIC_STRLEN(ALT_KP_8)];
            break;
        case '9':
            theData = [NSData dataWithBytes:ALT_KP_9 length:STATIC_STRLEN(ALT_KP_9)];
            break;
        case '-':
            theData = [NSData dataWithBytes:ALT_KP_MINUS length:STATIC_STRLEN(ALT_KP_MINUS)];
            break;
        case '+':
            theData = [NSData dataWithBytes:ALT_KP_PLUS length:STATIC_STRLEN(ALT_KP_PLUS)];
            break;
        case '.':
            theData = [NSData dataWithBytes:ALT_KP_PERIOD length:STATIC_STRLEN(ALT_KP_PERIOD)];
            break;
        case '/':
            theData = [NSData dataWithBytes:ALT_KP_SLASH length:STATIC_STRLEN(ALT_KP_SLASH)];
            break;
        case '*':
            theData = [NSData dataWithBytes:ALT_KP_STAR length:STATIC_STRLEN(ALT_KP_STAR)];
            break;
        case '=':
            theData = [NSData dataWithBytes:ALT_KP_EQUALS length:STATIC_STRLEN(ALT_KP_EQUALS)];
            break;
        case 0x03:
            theData = [NSData dataWithBytes:ALT_KP_ENTER length:STATIC_STRLEN(ALT_KP_ENTER)];
            break;
        default:
            theData = [keystr dataUsingEncoding:NSUTF8StringEncoding];
            break;
    }

    return (theData);
}

- (char *)mouseReport:(int)button atX:(int)x Y:(int)y {
    static char buf[64]; // This should be enough for all formats.
    switch (self.mouseFormat) {
        case MOUSE_FORMAT_XTERM_EXT:
            // TODO: This doesn' thandle positions greater than 223 correctly. It should use UTF-8.
            snprintf(buf, sizeof(buf), "\033[M%c%lc%lc",
                     (wint_t) (32 + button),
                     (wint_t) (32 + x),
                     (wint_t) (32 + y));
            break;
        case MOUSE_FORMAT_URXVT:
            snprintf(buf, sizeof(buf), "\033[%d;%d;%dM", 32 + button, x, y);
            break;
        case MOUSE_FORMAT_SGR:
            if (button & MOUSE_BUTTON_SGR_RELEASE_FLAG) {
                // for mouse release event
                snprintf(buf, sizeof(buf), "\033[<%d;%d;%dm",
                         button ^ MOUSE_BUTTON_SGR_RELEASE_FLAG,
                         x,
                         y);
            } else {
                // for mouse press/motion event
                snprintf(buf, sizeof(buf), "\033[<%d;%d;%dM", button, x, y);
            }
            break;
        case MOUSE_FORMAT_XTERM:
        default:
            snprintf(buf, sizeof(buf), "\033[M%c%c%c", 32 + button, MIN(255, 32 + x), MIN(255, 32 + y));
            break;
    }
    return buf;
}

- (NSData *)mousePress:(int)button withModifiers:(unsigned int)modflag at:(VT100GridCoord)coord {
    int cb;

    cb = button;
    if (button == MOUSE_BUTTON_SCROLLDOWN || button == MOUSE_BUTTON_SCROLLUP) {
        // convert x11 scroll button number to terminal button code
        const int offset = MOUSE_BUTTON_SCROLLDOWN;
        cb -= offset;
        cb |= MOUSE_BUTTON_SCROLL_FLAG;
    }
    if (modflag & NSEventModifierFlagControl) {
        cb |= MOUSE_BUTTON_CTRL_FLAG;
    }
    if (modflag & NSEventModifierFlagShift) {
        cb |= MOUSE_BUTTON_SHIFT_FLAG;
    }
    if (modflag & NSEventModifierFlagCommand) {
        cb |= MOUSE_BUTTON_META_FLAG;
    }
    char *buf = [self mouseReport:cb atX:(coord.x + 1) Y:(coord.y + 1)];

    return [NSData dataWithBytes: buf length: strlen(buf)];
}

- (NSData *)mouseRelease:(int)button withModifiers:(unsigned int)modflag at:(VT100GridCoord)coord {
    int cb;

    if (self.mouseFormat == MOUSE_FORMAT_SGR) {
        // for SGR 1006 mode
        cb = button | MOUSE_BUTTON_SGR_RELEASE_FLAG;
    } else {
        // for 1000/1005/1015 mode
        // To quote the xterm docs:
        // The low two bits of C b encode button information:
        // 0=MB1 pressed, 1=MB2 pressed, 2=MB3 pressed, 3=release.
        cb = 3;
    }

    if (modflag & NSEventModifierFlagControl) {
        cb |= MOUSE_BUTTON_CTRL_FLAG;
    }
    if (modflag & NSEventModifierFlagShift) {
        cb |= MOUSE_BUTTON_SHIFT_FLAG;
    }
    if (modflag & NSEventModifierFlagCommand) {
        cb |= MOUSE_BUTTON_META_FLAG;
    }
    char *buf = [self mouseReport:cb atX:(coord.x + 1) Y:(coord.y + 1)];

    return [NSData dataWithBytes: buf length: strlen(buf)];
}

- (NSData *)mouseMotion:(int)button withModifiers:(unsigned int)modflag at:(VT100GridCoord)coord {
    int cb;

    if (button == MOUSE_BUTTON_NONE) {
        cb = button;
    } else {
        cb = button % 3;
    }
    if (button > 3) {
        cb |= MOUSE_BUTTON_SCROLL_FLAG;
    }
    if (modflag & NSEventModifierFlagControl) {
        cb |= MOUSE_BUTTON_CTRL_FLAG;
    }
    if (modflag & NSEventModifierFlagShift) {
        cb |= MOUSE_BUTTON_SHIFT_FLAG;
    }
    if (modflag & NSEventModifierFlagCommand) {
        cb |= MOUSE_BUTTON_META_FLAG;
    }
    char *buf = [self mouseReport:(32 + cb) atX:(coord.x + 1) Y:(coord.y + 1)];

    return [NSData dataWithBytes: buf length: strlen(buf)];
}

- (NSData *)reportiTerm2Version {
    // We uppercase the string to ensure it does not contain a "n".
    // The [ must never be followed by a 0 (see the isiterm2.sh script for justification).
    NSString *version = [NSString stringWithFormat:@"%c[ITERM2 %@n", ESC,
                         [[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] uppercaseString]];
    return [version dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)reportKeyReportingMode:(int)mode {
    return [[NSString stringWithFormat:@"%c[?%du", ESC, mode] dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)reportActivePositionWithX:(int)x Y:(int)y withQuestion:(BOOL)q
{
    char buf[64];

    snprintf(buf, sizeof(buf), q?REPORT_POSITION_Q:REPORT_POSITION, y, x);

    return [NSData dataWithBytes:buf length:strlen(buf)];
}

- (NSData *)reportStatus
{
    return [NSData dataWithBytes:REPORT_STATUS
                          length:STATIC_STRLEN(REPORT_STATUS)];
}

- (NSData *)reportDeviceAttribute {
    // VT220 + sixel
    // For a very long time we returned 1;2, like most other terms, but we need to advertise sixel
    // support. Let's see what happens! New in version 3.3.0.
    //
    // Update: Per issue 7803, VT200 must accept 8-bit CSI. Allow users to elect VT100 reporting by
    // setting $TERM to VT100.
    switch (_vtLevel) {
        case VT100EmulationLevel100:
            return [@"\033[?1;2c" dataUsingEncoding:NSUTF8StringEncoding];
        case VT100EmulationLevel200:
            return [@"\033[?62;4c" dataUsingEncoding:NSUTF8StringEncoding];
    }
}

- (NSData *)reportSecondaryDeviceAttribute {
    const int xtermVersion = [iTermAdvancedSettingsModel xtermVersion];
    int vt = 0;
    switch (_vtLevel) {
        case VT100EmulationLevel100:
            vt = 0;
            break;
        case VT100EmulationLevel200:
            vt = 1;
            break;
    }
    NSString *report = [NSString stringWithFormat:@"\033[>%d;%d;0c", vt, xtermVersion];
    return [report dataUsingEncoding:NSISOLatin1StringEncoding];
}

- (NSData *)reportExtendedDeviceAttribute {
    NSString *versionString = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    NSString *reportString = [NSString stringWithFormat:@"%cP>|iTerm2 %@%c\\", ESC, versionString, ESC];
    return [reportString dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)reportColor:(NSColor *)color atIndex:(int)index prefix:(NSString *)prefix {
    NSString *string = nil;
    if ([iTermAdvancedSettingsModel oscColorReport16Bits]) {
        string = [NSString stringWithFormat:@"%c]%@%d;rgb:%04x/%04x/%04x%c\\",
                  ESC,
                  prefix,
                  index,
                  (int) ([color redComponent] * 65535.0),
                  (int) ([color greenComponent] * 65535.0),
                  (int) ([color blueComponent] * 65535.0),
                  ESC];
    } else {
        string = [NSString stringWithFormat:@"%c]%@%d;rgb:%02x/%02x/%02x%c\\",
                  ESC,
                  prefix,
                  index,
                  (int) ([color redComponent] * 255.0),
                  (int) ([color greenComponent] * 255.0),
                  (int) ([color blueComponent] * 255.0),
                  ESC];
    }
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)reportChecksum:(int)checksum withIdentifier:(int)identifier {
    // DCS Pid ! ~ D..D ST
    NSString *string =
        [NSString stringWithFormat:@"%cP%d!~%04x%c\\", ESC, identifier, (short)checksum, ESC];
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)reportSGRCodes:(NSArray<NSString *> *)codes {
    NSString *string = [NSString stringWithFormat:@"%c[%@m", ESC, [codes componentsJoinedByString:@";"]];
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Private

- (int)cursorModifierParamForEventModifierFlags:(NSEventModifierFlags)modflag {
    // Normal mode
    static int metaModifierValues[] = {
        0,  // Nothing
        2,  // Shift
        5,  // Control
        6,  // Control Shift
        9,  // Meta
        10, // Meta Shift
        13, // Meta Control
        14  // Meta Control Shift
    };
    static int altModifierValues[] = {
        0,  // Nothing
        2,  // Shift
        5,  // Control
        6,  // Control Shift
        3,  // Alt
        4,  // Alt Shift
        7,  // Alt Control
        8   // Alt Control Shift
    };


    int theIndex = 0;
    if (modflag & NSEventModifierFlagOption) {
        theIndex |= 4;
    }
    if (modflag & NSEventModifierFlagControl) {
        theIndex |= 2;
    }
    if (modflag & NSEventModifierFlagShift) {
        theIndex |= 1;
    }
    int *modValues = _optionIsMetaForSpecialKeys ? metaModifierValues : altModifierValues;
    return modValues[theIndex];
}

- (NSData *)specialKey:(int)terminfo
             cursorMod:(char *)cursorMod
             cursorSet:(char *)cursorSet
           cursorReset:(char *)cursorReset
               modflag:(unsigned int)modflag
              isCursor:(BOOL)isCursor {
    NSData* prefix = nil;
    NSData* theSuffix;
    const int mod = [self cursorModifierParamForEventModifierFlags:modflag];
    if (_keyStrings[terminfo] && mod == 0 && !isCursor && self.keypadMode) {
        // Application keypad mode.
        theSuffix = [NSData dataWithBytes:_keyStrings[terminfo]
                                   length:strlen(_keyStrings[terminfo])];
    } else {
        if (mod) {
            char buf[20];
            sprintf(buf, cursorMod, mod);
            theSuffix = [NSData dataWithBytes:buf length:strlen(buf)];
        } else {
            if (self.cursorMode) {
                theSuffix = [NSData dataWithBytes:cursorSet
                                           length:strlen(cursorSet)];
            } else {
                theSuffix = [NSData dataWithBytes:cursorReset
                                           length:strlen(cursorReset)];
            }
        }
    }
    NSMutableData* data = [NSMutableData data];
    if (prefix) {
        [data appendData:prefix];
    }
    [data appendData:theSuffix];
    return data;
}

- (NSData *)reportFocusGained:(BOOL)gained {
    char flag = gained ? 'I' : 'O';
    NSString *message = [NSString stringWithFormat:@"%c[%c", 27, flag];
    return [message dataUsingEncoding:NSUTF8StringEncoding];
}


@end
