// sa2_ios_ingame.mm: the in-game menu and debug overlay (sa2_ios_ingame.h).
#import <UIKit/UIKit.h>

#include "sa2_ios_ingame.h"
#include "sa2_ios_session.h"

#include <SDL3/SDL.h>

#include <cstdio>
#include <string>

namespace {
Sa2IosIngame g_info;
}  // namespace

@interface Sa2Ingame : NSObject
@property(nonatomic, strong) NSTimer* timer;
@property(nonatomic, weak) UIView* host;               // SDL's view
@property(nonatomic, strong) UIButton* menu;
@property(nonatomic, strong) UILabel* hud;
@property(nonatomic, strong) UITapGestureRecognizer* tap;
@property(nonatomic) BOOL hudOn;
@property(nonatomic) BOOL presenting;
@end

@implementation Sa2Ingame

- (void)start {
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick)
                                                userInfo:nil repeats:YES];
    // SDL pumps the run loop in its default mode alone; a timer in the common modes fires there too.
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    self.hudOn = g_info.hud;
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    [self.menu removeFromSuperview];
    [self.hud removeFromSuperview];
    if (self.tap) [self.tap.view removeGestureRecognizer:self.tap];
    self.menu = nil;
    self.hud = nil;
    self.tap = nil;
}

// SDL's view, once the player has made its window.
- (UIView*)findHost {
    int count = 0;
    SDL_Window** windows = SDL_GetWindows(&count);
    UIView* view = nil;
    if (windows && count > 0) {
        UIWindow* w = (__bridge UIWindow*)SDL_GetPointerProperty(SDL_GetWindowProperties(windows[0]),
                                                                 SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
        view = w.rootViewController.view;
    }
    SDL_free(windows);
    return view;
}

- (void)attachTo:(UIView*)view {
    self.host = view;
    // The menu's button: below the touch overlay's START (its centre at 7.5% of the short side, its
    // half height 3.5%: host/player/touch_overlay.cpp layout), at the top's centre.
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage* icon = [UIImage systemImageNamed:@"ellipsis.circle.fill"];
    [b setImage:icon forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    b.alpha = 0.35;
    b.accessibilityLabel = @"Game menu";
    [b addTarget:self action:@selector(openMenu) forControlEvents:UIControlEventTouchUpInside];
    b.hidden = !g_info.menu_button;
    [view addSubview:b];
    self.menu = b;
    // Three fingers at once, anywhere: the menu without the button. The touches still reach SDL.
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openMenu)];
    tap.numberOfTouchesRequired = 3;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    [view addGestureRecognizer:tap];
    self.tap = tap;
    UILabel* hud = [[UILabel alloc] init];
    hud.numberOfLines = 0;
    hud.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    hud.textColor = [UIColor colorWithWhite:1 alpha:0.92];
    hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    hud.userInteractionEnabled = NO;            // the touch controls under it still work
    hud.lineBreakMode = NSLineBreakByTruncatingTail;
    hud.hidden = !self.hudOn;
    [view addSubview:hud];
    self.hud = hud;
    [self layout];
}

- (void)layout {
    UIView* v = self.host;
    if (!v) return;
    const CGSize s = v.bounds.size;
    const CGFloat shortSide = MIN(s.width, s.height);
    const CGFloat side = 34;
    self.menu.frame = CGRectMake((s.width - side) / 2, 0.12 * shortSide + 4, side, side);
    self.hud.frame = CGRectMake(0.18 * s.width, 0.12 * shortSide + side + 12, 0.64 * s.width, 0.42 * s.height);
}

// The last `lines` lines of the console log.
- (NSString*)tail:(int)lines {
    FILE* f = std::fopen(g_info.console_path.c_str(), "rb");
    if (!f) return @"";
    std::fseek(f, 0, SEEK_END);
    const long size = std::ftell(f);
    const long from = size > 6000 ? size - 6000 : 0;
    std::fseek(f, from, SEEK_SET);
    std::string text(size_t(size - from), '\0');
    const size_t got = std::fread(text.data(), 1, text.size(), f);
    std::fclose(f);
    text.resize(got);
    size_t at = text.size();
    int n = 0;
    while (at > 0 && n <= lines) {
        at = text.rfind('\n', at - 1);
        if (at == std::string::npos) {
            at = 0;
            break;
        }
        n++;
    }
    NSString* s = [[NSString alloc] initWithBytes:text.data() + at length:text.size() - at
                                         encoding:NSUTF8StringEncoding];
    return s ?: @"";
}

- (void)tick {
    if (!self.host) {
        UIView* v = [self findHost];
        if (v) [self attachTo:v];
        return;
    }
    [self layout];
    [self.host bringSubviewToFront:self.menu];
    [self.host bringSubviewToFront:self.hud];
    if (self.hudOn) {
        const std::string status = g_info.status ? g_info.status() : std::string();
        self.hud.text = [NSString stringWithFormat:@" %s\n%@", status.c_str(), [self tail:24]];
    }
}

- (void)openMenu {
    if (self.presenting || !self.host) return;
    UIViewController* vc = self.host.window.rootViewController;
    if (!vc || vc.presentedViewController) return;
    self.presenting = YES;
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"SA2 Recompiled"
        message:@"The game keeps running behind this menu: pause it with START first." preferredStyle:UIAlertControllerStyleAlert];
    __weak Sa2Ingame* me = self;
    [a addAction:[UIAlertAction actionWithTitle:self.hudOn ? @"Hide debug overlay" : @"Show debug overlay"
                                          style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
        me.hudOn = !me.hudOn;
        me.hud.hidden = !me.hudOn;
        me.presenting = NO;
        [me tick];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Copy session folder" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction*) {
        UIPasteboard.generalPasteboard.string = [NSString stringWithUTF8String:g_info.session.c_str()];
        me.presenting = NO;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"End session" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction*) {
        UIAlertController* c = [UIAlertController alertControllerWithTitle:@"End the session?"
            message:@"Progress since your last save is lost. To play again afterwards, the app is quit and opened again."
            preferredStyle:UIAlertControllerStyleAlert];
        [c addAction:[UIAlertAction actionWithTitle:@"End session" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction*) {
            me.presenting = NO;
            sa2ios_request_end();
        }]];
        [c addAction:[UIAlertAction actionWithTitle:@"Keep playing" style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction*) { me.presenting = NO; }]];
        [vc presentViewController:c animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Resume" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction*) { me.presenting = NO; }]];
    [vc presentViewController:a animated:YES completion:nil];
}

@end

static Sa2Ingame* g_ingame;

void sa2ios_ingame_begin(const Sa2IosIngame& info) {
    g_info = info;
    g_ingame = [[Sa2Ingame alloc] init];
    [g_ingame start];
}

void sa2ios_ingame_end() {
    [g_ingame stop];
    g_ingame = nil;
    g_info = Sa2IosIngame{};
}
