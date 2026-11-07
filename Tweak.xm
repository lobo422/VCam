#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "MediaManager.h"

// ============================================================================
// MARK: - Global State
// ============================================================================

static BOOL g_vcamEnabled = YES;
static UIWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;
static const char *kVCamOverlayLayerKey = "VCamOverlayLayerKey";

// ============================================================================
// MARK: - Preview Layer Manager (Overlays Real-Time Video on Camera Viewfinder)
// ============================================================================

@interface VCamPreviewManager : NSObject
+ (void)registerPreviewLayer:(AVCaptureVideoPreviewLayer *)layer;
+ (void)updateWithCGImage:(CGImageRef)cgImage;
@end

static NSHashTable *g_activePreviewLayers = nil;

@implementation VCamPreviewManager

+ (void)registerPreviewLayer:(AVCaptureVideoPreviewLayer *)layer {
    if (!layer) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_activePreviewLayers = [NSHashTable weakObjectsHashTable];
    });
    @synchronized (g_activePreviewLayers) {
        [g_activePreviewLayers addObject:layer];
    }
}

+ (void)updateWithCGImage:(CGImageRef)cgImage {
    if (!cgImage || !g_vcamEnabled) return;
    CGImageRetain(cgImage);
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (g_activePreviewLayers) {
            for (AVCaptureVideoPreviewLayer *previewLayer in g_activePreviewLayers) {
                if (!previewLayer) continue;
                
                CALayer *overlay = objc_getAssociatedObject(previewLayer, kVCamOverlayLayerKey);
                if (!overlay) {
                    overlay = [CALayer layer];
                    overlay.contentsGravity = kCAGravityResizeAspectFill;
                    overlay.frame = previewLayer.bounds;
                    overlay.zPosition = 999;
                    [previewLayer addSublayer:overlay];
                    objc_setAssociatedObject(previewLayer, kVCamOverlayLayerKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                overlay.frame = previewLayer.bounds;
                overlay.contents = (__bridge id)cgImage;
                overlay.hidden = !g_vcamEnabled;
                [CATransaction commit];
            }
        }
        CGImageRelease(cgImage);
    });
}

@end

// ============================================================================
// MARK: - Floating Button UI (Touch-Through Transparent Window)
// ============================================================================

@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter;
@end

@implementation VCamFloatButton
@end

@interface VCamOverlayWindow : UIWindow
@end

@implementation VCamOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil;
    }
    return hitView;
}
@end

static void setupFloatButton(void);
static void handlePanGesture(UIPanGestureRecognizer *gesture);
static void handleTapGesture(UITapGestureRecognizer *gesture);

static void setupFloatButton() {
    if (g_floatButton) return;
    
    UIWindowScene *activeScene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
    }
    
    CGFloat btnSize = 50;
    CGRect screen = [UIScreen mainScreen].bounds;
    
    g_floatButton = [VCamFloatButton buttonWithType:UIButtonTypeSystem];
    g_floatButton.frame = CGRectMake(screen.size.width - btnSize - 15, 100, btnSize, btnSize);
    g_floatButton.layer.cornerRadius = btnSize / 2.0;
    g_floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    g_floatButton.layer.shadowOpacity = 0.3;
    g_floatButton.layer.shadowRadius = 4;
    g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
    
    [g_floatButton setTitle:@"📷" forState:UIControlStateNormal];
    g_floatButton.titleLabel.font = [UIFont systemFontOfSize:24];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] 
        initWithTarget:g_floatButton action:@selector(handlePan:)];
    [g_floatButton addGestureRecognizer:pan];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] 
        initWithTarget:g_floatButton action:@selector(handleTap:)];
    [g_floatButton addGestureRecognizer:tap];
    
    if (activeScene) {
        g_overlayWindow = [[VCamOverlayWindow alloc] initWithWindowScene:activeScene];
    } else {
        g_overlayWindow = [[VCamOverlayWindow alloc] initWithFrame:screen];
    }
    g_overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    g_overlayWindow.hidden = NO;
    g_overlayWindow.backgroundColor = [UIColor clearColor];
    
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    [rootVC.view addSubview:g_floatButton];
    g_overlayWindow.rootViewController = rootVC;
    
    class_addMethod([g_floatButton class], @selector(handlePan:), 
                    (IMP)handlePanGesture, "v@:@");
    class_addMethod([g_floatButton class], @selector(handleTap:), 
                    (IMP)handleTapGesture, "v@:@");
}

static void handlePanGesture(UIPanGestureRecognizer *gesture) {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
    
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat x = btn.center.x < screen.size.width / 2 ? 35 : screen.size.width - 35;
        [UIView animateWithDuration:0.2 animations:^{
            btn.center = CGPointMake(x, btn.center.y);
        }];
    }
}

static UIViewController *findTopViewController(void) {
    UIViewController *topVC = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow && w != g_overlayWindow) {
                        topVC = w.rootViewController;
                        break;
                    }
                }
            }
        }
    }
    if (!topVC) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow && w != g_overlayWindow) {
                topVC = w.rootViewController;
                break;
            }
        }
    }
    while (topVC && topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

@interface VCamImagePickerControllerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker 
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    
    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
    if (!videoURL) return;
    
    [[MediaManager sharedManager] loadMediaFromURL:videoURL];
    [[MediaManager sharedManager] start];
    if (g_floatButton) {
        g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

static VCamImagePickerControllerDelegate *g_pickerDelegate = nil;

static void handleTapGesture(UITapGestureRecognizer *gesture) {
    UIViewController *topVC = findTopViewController();
    if (!topVC) return;
    
    UIAlertController *alert = [UIAlertController 
        alertControllerWithTitle:@"Antigravity Camera Lab" 
        message:g_vcamEnabled ? @"Camera ảo: ĐANG BẬT" : @"Camera ảo: ĐÃ TẮT"
        preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Action 1: Connect to PC USB Stream
    [alert addAction:[UIAlertAction actionWithTitle:@"📡 Nhận Luồng Trực Tiếp Từ Máy Tính (Cáp USB)" 
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        g_vcamEnabled = YES;
        [[MediaManager sharedManager] startNetworkStreamWithHost:@"127.0.0.1" port:8080];
        [[MediaManager sharedManager] start];
        if (g_floatButton) {
            g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
        }
    }]];
    
    // Action 2: Choose local video
    [alert addAction:[UIAlertAction actionWithTitle:@"📁 Chọn Video Trong Máy" 
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeSavedPhotosAlbum]) {
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *currentTop = findTopViewController();
            UIImagePickerController *picker = [[UIImagePickerController alloc] init];
            picker.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
            picker.mediaTypes = @[@"public.movie"];
            picker.delegate = g_pickerDelegate;
            [currentTop presentViewController:picker animated:YES completion:nil];
        });
    }]];
    
    // Action 3: Toggle ON/OFF
    [alert addAction:[UIAlertAction actionWithTitle:g_vcamEnabled ? @"🔴 Tắt Camera Ảo (Về Camera Thật)" : @"🟢 Bật Camera Ảo" 
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        g_vcamEnabled = !g_vcamEnabled;
        if (g_floatButton) {
            g_floatButton.backgroundColor = g_vcamEnabled 
                ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
                : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        }
        if (g_vcamEnabled) {
            [[MediaManager sharedManager] start];
        } else {
            [[MediaManager sharedManager] stop];
        }
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = gesture.view;
        alert.popoverPresentationController.sourceRect = gesture.view.bounds;
    }
    
    [topVC presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// MARK: - Delegate Proxy Pattern (For any API reading raw sample buffers)
// ============================================================================

@interface VCamSampleBufferProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate;
@end

@implementation VCamSampleBufferProxy

- (void)captureOutput:(AVCaptureOutput *)output 
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer 
           fromConnection:(AVCaptureConnection *)connection {
    
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
        if (fakeFrame) {
            if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.originalDelegate captureOutput:output didOutputSampleBuffer:fakeFrame fromConnection:connection];
            }
            CFRelease(fakeFrame);
            return;
        }
    }
    
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output 
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer 
       fromConnection:(AVCaptureConnection *)connection {
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [self.originalDelegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) return YES;
    if (aSelector == @selector(captureOutput:didDropSampleBuffer:fromConnection:)) return YES;
    return [self.originalDelegate respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    return self.originalDelegate;
}

@end

// ============================================================================
// MARK: - Hooks (Targeting Native Camera App com.apple.camera)
// ============================================================================

%group VCamHooks

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!g_floatButton) {
        setupFloatButton();
    }
}
%end

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    [[MediaManager sharedManager] start];
}
- (void)stopRunning {
    %orig;
}
%end

%hook AVCaptureVideoPreviewLayer

- (id)initWithSession:(AVCaptureSession *)session {
    self = %orig;
    if (self) {
        [VCamPreviewManager registerPreviewLayer:self];
    }
    return self;
}

- (id)initWithSessionWithNoConnection:(AVCaptureSession *)session {
    self = %orig;
    if (self) {
        [VCamPreviewManager registerPreviewLayer:self];
    }
    return self;
}

- (id)init {
    self = %orig;
    if (self) {
        [VCamPreviewManager registerPreviewLayer:self];
    }
    return self;
}

- (void)setSession:(AVCaptureSession *)session {
    %orig;
    [VCamPreviewManager registerPreviewLayer:self];
}

- (void)layoutSublayers {
    %orig;
    [VCamPreviewManager registerPreviewLayer:self];
    CALayer *overlay = objc_getAssociatedObject(self, kVCamOverlayLayerKey);
    if (overlay) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlay.frame = self.bounds;
        [CATransaction commit];
    }
}

%end

%hook CALayer
- (void)addSublayer:(CALayer *)layer {
    %orig;
    if ([layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
        [VCamPreviewManager registerPreviewLayer:(AVCaptureVideoPreviewLayer *)layer];
    }
}
- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned)idx {
    %orig;
    if ([layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
        [VCamPreviewManager registerPreviewLayer:(AVCaptureVideoPreviewLayer *)layer];
    }
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate 
                          queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:[VCamSampleBufferProxy class]]) {
        VCamSampleBufferProxy *proxy = [[VCamSampleBufferProxy alloc] init];
        proxy.originalDelegate = delegate;
        objc_setAssociatedObject(self, "VCamSampleBufferProxyKey", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(proxy, queue);
        return;
    }
    %orig;
}
%end

%end // VCamHooks group

// ============================================================================
// MARK: - Constructor
// ============================================================================

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSLog(@"[VCam] Injecting into: %@", bundleID);
        
        // Strict scope: ONLY activate inside Apple's native Camera app
        if ([bundleID isEqualToString:@"com.apple.camera"]) {
            %init(VCamHooks);
            
            g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];
            
            [MediaManager sharedManager].onFrameReceived = ^(UIImage *img) {
                [VCamPreviewManager updateWithCGImage:img.CGImage];
            };
            
            // Start network stream server on port 8080 (USB port forward)
            [[MediaManager sharedManager] startNetworkStreamWithHost:@"127.0.0.1" port:8080];
            [[MediaManager sharedManager] start];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
                dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        setupFloatButton();
                    }
                });
        }
    }
}
