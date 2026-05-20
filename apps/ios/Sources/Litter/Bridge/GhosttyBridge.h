#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LitterGhosttyInputHandler)(NSData *data);

@interface LitterGhosttyTerminal : NSObject

@property (nonatomic, copy, nullable) LitterGhosttyInputHandler inputHandler;

- (nullable instancetype)initWithView:(UIView *)view error:(NSError **)error;
- (void)resizeToWidth:(CGFloat)width height:(CGFloat)height scale:(CGFloat)scale;
- (void)writeOutput:(NSData *)data;
- (NSString *)visibleText;
- (void)draw;
- (void)requestRedraw;
- (void)setOcclusion:(BOOL)occluded;
- (void)setFocused:(BOOL)focused;
- (BOOL)applyConfigAtPath:(NSString *)path error:(NSError **)error;
- (BOOL)mouseCaptured;
- (void)mousePosX:(double)x y:(double)y mods:(int)mods;
- (BOOL)mouseButtonPressed:(BOOL)pressed button:(int)button mods:(int)mods;
- (void)mouseScrollX:(double)x y:(double)y precise:(BOOL)precise mods:(int)mods;

// Stable identifiers for the common Ghostty keys we pass through. The C
// enum these map to (`ghostty_input_key_e`) is internal to the bridge; the
// integer order may change when the upstream Ghostty header bumps. Use
// these constants instead of hardcoding raw enum values in Swift.
typedef NS_ENUM(int, LitterGhosttyKey) {
    LitterGhosttyKeyUnidentified = 0,
    LitterGhosttyKeyEnter,
    LitterGhosttyKeyTab,
    LitterGhosttyKeyBackspace,
    LitterGhosttyKeyEscape,
    LitterGhosttyKeySpace,
    LitterGhosttyKeyArrowUp,
    LitterGhosttyKeyArrowDown,
    LitterGhosttyKeyArrowLeft,
    LitterGhosttyKeyArrowRight,
    LitterGhosttyKeyPageUp,
    LitterGhosttyKeyPageDown,
    LitterGhosttyKeyHome,
    LitterGhosttyKeyEnd,
    LitterGhosttyKeyDelete,
    LitterGhosttyKeyInsert,
};

// Key dispatch. `action` 0=release, 1=press, 2=repeat.
// `key` is a `LitterGhosttyKey` from the table above; the bridge translates
// it to the real ghostty enum value before calling `ghostty_surface_key`.
// `text` is the platform-decoded character(s), nullable.
- (BOOL)dispatchKeyAction:(int)action
                      key:(LitterGhosttyKey)key
                     mods:(int)mods
                     text:(NSString *_Nullable)text
                composing:(BOOL)composing;
// Commit text (writes to terminal); preedit goes through `setPreeditText:`.
- (void)sendText:(NSString *)text;
- (void)setPreeditText:(NSString *_Nullable)text;
// Notify Ghostty that the platform keyboard configuration changed (layout, etc).
- (void)keyboardChanged;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
