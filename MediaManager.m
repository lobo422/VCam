#import "MediaManager.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface MediaManager () {
    CVPixelBufferRef _streamPixelBuffer;
    int _socketFd;
}
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, assign) int64_t frameIndex;
@property (nonatomic, strong) NSThread *networkThread;
@end

@implementation MediaManager

+ (instancetype)sharedManager {
    static MediaManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MediaManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = VCamModeStream; // Default to Stream mode from PC!
        _loopPlayback = YES;
        _isRunning = NO;
        _isNetworkStreamActive = NO;
        _videoSize = CGSizeMake(1080, 1920);
        _decodeQueue = dispatch_queue_create("com.vcam.decode", DISPATCH_QUEUE_SERIAL);
        _startTime = kCMTimeZero;
        _frameIndex = 0;
        _streamPixelBuffer = NULL;
        _socketFd = -1;
    }
    return self;
}

#pragma mark - Live Network Stream (PC to iPhone over USB)

static CVPixelBufferRef pixelBufferFromJPEGData(NSData *data) {
    if (!data || data.length == 0) return NULL;
    
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!cgImage) return NULL;
    
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    
    CVPixelBufferRef pxbuffer = NULL;
    NSDictionary *options = @{
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @(YES),
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @(YES),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)options,
                                          &pxbuffer);
    if (status != kCVReturnSuccess || !pxbuffer) {
        CGImageRelease(cgImage);
        return NULL;
    }
    
    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pxbuffer);
    
    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, width, height, 8, bytesPerRow, rgbColorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);
    
    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    CGImageRelease(cgImage);
    return pxbuffer;
}

- (void)startNetworkStreamWithHost:(NSString *)host port:(int)port {
    if (self.isNetworkStreamActive) return;
    self.isNetworkStreamActive = YES;
    self.mode = VCamModeStream;
    
    // TCP Server listening on 0.0.0.0:port (Enables USB usbmux forward & direct Wi-Fi streaming)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int server_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (server_fd < 0) return;
        
        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        
        struct sockaddr_in serv_addr;
        memset(&serv_addr, 0, sizeof(serv_addr));
        serv_addr.sin_family = AF_INET;
        serv_addr.sin_addr.s_addr = INADDR_ANY;
        serv_addr.sin_port = htons(port);
        
        if (bind(server_fd, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
            close(server_fd);
            return;
        }
        
        if (listen(server_fd, 5) < 0) {
            close(server_fd);
            return;
        }
        
        NSLog(@"[VCam] Stream Server listening on 0.0.0.0:%d", port);
        
        while (self.isNetworkStreamActive) {
            struct sockaddr_in client_addr;
            socklen_t addrlen = sizeof(client_addr);
            int client_sock = accept(server_fd, (struct sockaddr *)&client_addr, &addrlen);
            if (client_sock < 0) {
                [NSThread sleepForTimeInterval:0.5];
                continue;
            }
            
            NSLog(@"[VCam] Stream Client connected!");
            
            while (self.isNetworkStreamActive) {
                uint8_t header[9];
                ssize_t n = recv(client_sock, header, 9, MSG_WAITALL);
                if (n != 9) break;
                if (memcmp(header, "LIVE", 4) != 0) break;
                
                uint8_t type = header[4];
                uint32_t length = (header[5] << 24) | (header[6] << 16) | (header[7] << 8) | header[8];
                if (length > 10 * 1024 * 1024) break;
                
                NSMutableData *payload = [NSMutableData dataWithLength:length];
                n = recv(client_sock, [payload mutableBytes], length, MSG_WAITALL);
                if (n != length) break;
                
                if (type == 0x01) {
                    CVPixelBufferRef newBuf = pixelBufferFromJPEGData(payload);
                    if (newBuf) {
                        @synchronized (self) {
                            if (self->_streamPixelBuffer) {
                                CVPixelBufferRelease(self->_streamPixelBuffer);
                            }
                            self->_streamPixelBuffer = newBuf;
                        }
                    }
                }
            }
            close(client_sock);
        }
        close(server_fd);
    });
}

- (void)stopNetworkStream {
    self.isNetworkStreamActive = NO;
}

#pragma mark - Media Loading (Fallback local file)

- (void)loadMediaFromURL:(NSURL *)url {
    dispatch_async(_decodeQueue, ^{
        AVAsset *asset = [AVAsset assetWithURL:url];
        if (!asset) return;
        
        self.currentAsset = asset;
        self.videoDuration = asset.duration;
        
        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count > 0) {
            AVAssetTrack *track = tracks.firstObject;
            CGSize size = track.naturalSize;
            CGAffineTransform t = track.preferredTransform;
            size = CGSizeApplyAffineTransform(size, t);
            size.width = fabs(size.width);
            size.height = fabs(size.height);
            if (size.width > 0 && size.height > 0) {
                self.videoSize = size;
            }
        }
        
        [self resetReaders];
        self.mode = VCamModeVideo;
    });
}

- (void)resetReaders {
    NSError *error = nil;
    if (self.currentAsset) {
        self.videoReader = [AVAssetReader assetReaderWithAsset:self.currentAsset error:&error];
        NSArray<AVAssetTrack *> *videoTracks = [self.currentAsset tracksWithMediaType:AVMediaTypeVideo];
        if (videoTracks.count > 0) {
            NSDictionary *settings = @{
                (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            };
            self.videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTracks.firstObject
                                                                          outputSettings:settings];
            self.videoOutput.alwaysCopiesSampleData = NO;
            [self.videoReader addOutput:self.videoOutput];
        }
        [self.videoReader startReading];
    }
}

#pragma mark - Frame Generation

- (CMSampleBufferRef)nextVideoFrame {
    // 1. If in Live PC Stream mode:
    if (self.mode == VCamModeStream) {
        CVPixelBufferRef buf = NULL;
        @synchronized (self) {
            if (_streamPixelBuffer) {
                buf = CVPixelBufferRetain(_streamPixelBuffer);
            }
        }
        
        if (buf) {
            CMVideoFormatDescriptionRef formatDesc = NULL;
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buf, &formatDesc);
            
            CMTime pts = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
            CMSampleTimingInfo timing = {
                .duration = CMTimeMake(1, 30),
                .presentationTimeStamp = pts,
                .decodeTimeStamp = pts,
            };
            
            CMSampleBufferRef sample = NULL;
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                               buf,
                                               YES,
                                               NULL, NULL,
                                               formatDesc,
                                               &timing,
                                               &sample);
            if (formatDesc) CFRelease(formatDesc);
            CVPixelBufferRelease(buf);
            return sample;
        }
    }
    
    // 2. Fallback to Local Video mode
    if (self.mode == VCamModeVideo && self.videoOutput) {
        CMSampleBufferRef sample = [self.videoOutput copyNextSampleBuffer];
        if (!sample && self.loopPlayback) {
            [self resetReaders];
            sample = [self.videoOutput copyNextSampleBuffer];
        }
        if (sample) {
            CMTime now = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
            CMSampleBufferRef retimed = NULL;
            CMSampleBufferRef copy = NULL;
            CMSampleBufferCreateCopy(kCFAllocatorDefault, sample, &copy);
            if (copy) {
                CMSampleBufferSetOutputPresentationTimeStamp(copy, now);
                retimed = copy;
            }
            CFRelease(sample);
            return retimed;
        }
    }
    
    // 3. Fallback to black frame
    CMTime pts = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
    return [self generateBlackFrameWithSize:self.videoSize presentationTime:pts];
}

- (CMSampleBufferRef)nextAudioFrame {
    return NULL;
}

#pragma mark - Black Frame

- (CMSampleBufferRef)generateBlackFrameWithSize:(CGSize)size presentationTime:(CMTime)pts {
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          (size_t)size.width,
                                          (size_t)size.height,
                                          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                          (__bridge CFDictionaryRef)attrs,
                                          &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) return NULL;
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    size_t yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
    memset(yPlane, 16, yBytesPerRow * yHeight);
    
    void *uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    size_t uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    size_t uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
    memset(uvPlane, 128, uvBytesPerRow * uvHeight);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    CMVideoFormatDescriptionRef formatDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
    
    CMSampleBufferRef sampleBuffer = NULL;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = pts,
        .decodeTimeStamp = pts,
    };
    
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                       pixelBuffer,
                                       YES,
                                       NULL, NULL,
                                       formatDesc,
                                       &timing,
                                       &sampleBuffer);
    if (formatDesc) CFRelease(formatDesc);
    CVPixelBufferRelease(pixelBuffer);
    return sampleBuffer;
}

#pragma mark - Lifecycle

- (void)start {
    self.isRunning = YES;
    self.startTime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
}

- (void)stop {
    self.isRunning = NO;
}

@end
