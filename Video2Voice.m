#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "SKP_Silk_SDK_API.h"

// ==========================================
// 1. 强置顶悬浮提示 HUD（防止被微信窗口遮挡）
// ==========================================
static UILabel *gToastLabel = nil;

static UIWindow *V2V_GetMainWindow(void) {
    UIWindow *targetWin = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (!w.hidden && w.alpha > 0.01 && w.windowLevel == UIWindowLevelNormal) {
                    targetWin = w;
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    if (!targetWin && [[UIApplication sharedApplication].delegate respondsToSelector:@selector(window)]) {
        targetWin = [[UIApplication sharedApplication].delegate window];
    }
    if (!targetWin) {
        targetWin = [UIApplication sharedApplication].windows.firstObject;
    }
    return targetWin;
}

static void V2V_ShowToast(NSString *text, NSTimeInterval duration) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = V2V_GetMainWindow();
        if (!win) return;

        if (!gToastLabel) {
            gToastLabel = [[UILabel alloc] init];
            gToastLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.86];
            gToastLabel.textColor = [UIColor whiteColor];
            gToastLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
            gToastLabel.textAlignment = NSTextAlignmentCenter;
            gToastLabel.numberOfLines = 0;
            gToastLabel.layer.cornerRadius = 10.0;
            gToastLabel.layer.masksToBounds = YES;
            gToastLabel.layer.zPosition = 999999;
        }

        gToastLabel.text = text;
        CGSize maxSize = CGSizeMake(win.bounds.size.width - 72.0, 140.0);
        CGSize textSize = [gToastLabel sizeThatFits:maxSize];
        CGFloat w = textSize.width + 36.0;
        CGFloat h = textSize.height + 22.0;
        gToastLabel.frame = CGRectMake((win.bounds.size.width - w) * 0.5, (win.bounds.size.height - h) * 0.45, w, h);

        [win addSubview:gToastLabel];
        [win bringSubviewToFront:gToastLabel];
        gToastLabel.alpha = 1.0;

        if (duration > 0) {
            NSString *snapshotText = [text copy];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if ([gToastLabel.text isEqualToString:snapshotText]) {
                    [UIView animateWithDuration:0.25 animations:^{
                        gToastLabel.alpha = 0.0;
                    } completion:^(BOOL finished) {
                        if (gToastLabel.alpha == 0.0) {
                            [gToastLabel removeFromSuperview];
                        }
                    }];
                }
            });
        }
    });
}

// ==========================================
// 2. 零滤波提取视频音轨 + 防混响抵消单声道混缩（24kHz 16-bit PCM）
// ==========================================
static NSData *V2V_Extract24kMonoPCMFromVideo(NSString *videoPath, NSError **outError) {
    NSURL *url = [NSURL fileURLWithPath:videoPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES }];

    NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"WeChatVideo2Voice" code:-1 userInfo:@{ NSLocalizedDescriptionKey: @"该视频不包含音轨" }];
        }
        return nil;
    }

    NSError *readerErr = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerErr];
    if (!reader || readerErr) {
        if (outError) *outError = readerErr;
        return nil;
    }

    NSDictionary *outputSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(24000.0),
        AVNumberOfChannelsKey: @(2),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsFloatKey: @(NO),
        AVLinearPCMIsBigEndianKey: @(NO),
        AVLinearPCMIsNonInterleaved: @(NO)
    };

    AVAssetReaderTrackOutput *trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTracks.firstObject outputSettings:outputSettings];
    trackOutput.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:trackOutput]) return nil;
    [reader addOutput:trackOutput];

    if (![reader startReading]) {
        if (outError) *outError = reader.error;
        return nil;
    }

    NSMutableData *stereoData = [NSMutableData data];
    while (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sampleBuffer = [trackOutput copyNextSampleBuffer];
        if (!sampleBuffer) break;

        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
        if (blockBuffer) {
            size_t totalLen = 0;
            char *dataPtr = NULL;
            if (CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLen, &dataPtr) == kCMBlockBufferNoErr && dataPtr && totalLen > 0) {
                [stereoData appendBytes:dataPtr length:totalLen];
            }
        }
        CFRelease(sampleBuffer);
    }

    if (reader.status == AVAssetReaderStatusFailed) {
        if (outError) *outError = reader.error;
        return nil;
    }

    NSUInteger frameCount = stereoData.length / (sizeof(int16_t) * 2);
    if (frameCount == 0) return nil;

    const int16_t *stereoSamples = (const int16_t *)stereoData.bytes;
    float *monoFloat = (float *)malloc(frameCount * sizeof(float));
    if (!monoFloat) return nil;

    // 防相位抵消混缩（完整保留左右声道混响尾音）
    float maxPeak = 0.0001f;
    for (NSUInteger i = 0; i < frameCount; i++) {
        float L = (float)stereoSamples[i * 2];
        float R = (float)stereoSamples[i * 2 + 1];
        float mixed = 0.62f * L + 0.48f * R;
        monoFloat[i] = mixed;
        float absVal = fabsf(mixed);
        if (absVal > maxPeak) maxPeak = absVal;
    }

    float scale = (maxPeak > 30900.0f) ? (30900.0f / maxPeak) : 1.0f;

    NSMutableData *monoPCMData = [NSMutableData dataWithLength:frameCount * sizeof(int16_t)];
    int16_t *monoOut = (int16_t *)monoPCMData.mutableBytes;
    for (NSUInteger i = 0; i < frameCount; i++) {
        float v = monoFloat[i] * scale;
        if (v > 32767.0f) v = 32767.0f;
        if (v < -32768.0f) v = -32768.0f;
        monoOut[i] = (int16_t)v;
    }

    free(monoFloat);
    return monoPCMData;
}

// ==========================================
// 3. 内置 SILK v3 满血编码器（24kHz / 40kbps / 关闭 DTX 保留尾音）
// ==========================================
static NSData *V2V_EncodePCMToMaxSilk(const int16_t *samples, NSUInteger sampleCount) {
    if (!samples || sampleCount == 0) return nil;

    SKP_int32 encSizeBytes = 0;
    if (SKP_Silk_SDK_Get_Encoder_Size(&encSizeBytes) != 0 || encSizeBytes <= 0) {
        return nil;
    }

    void *psEnc = malloc((size_t)encSizeBytes);
    if (!psEnc) return nil;

    SKP_SILK_SDK_EncControlStruct encStatus;
    memset(&encStatus, 0, sizeof(encStatus));
    if (SKP_Silk_SDK_InitEncoder(psEnc, &encStatus) != 0) {
        free(psEnc);
        return nil;
    }

    SKP_SILK_SDK_EncControlStruct encControl;
    memset(&encControl, 0, sizeof(encControl));
    encControl.API_sampleRate = 24000;
    encControl.maxInternalSampleRate = 24000;
    encControl.packetSize = 480;
    encControl.bitRate = 40000;
    encControl.packetLossPercentage = 0;
    encControl.complexity = 2;
    encControl.useInBandFEC = 0;
    encControl.useDTX = 0;

    NSMutableData *silkOut = [NSMutableData data];
    const uint8_t header[10] = { 0x02, '#', '!', 'S', 'I', 'L', 'K', '_', 'V', '3' };
    [silkOut appendBytes:header length:sizeof(header)];

    const NSUInteger frameSize = 480;
    int16_t frameBuffer[480];
    uint8_t encodedFrame[1024];

    for (NSUInteger offset = 0; offset < sampleCount; offset += frameSize) {
        NSUInteger remaining = sampleCount - offset;
        if (remaining >= frameSize) {
            memcpy(frameBuffer, samples + offset, frameSize * sizeof(int16_t));
        } else {
            memset(frameBuffer, 0, sizeof(frameBuffer));
            memcpy(frameBuffer, samples + offset, remaining * sizeof(int16_t));
        }

        SKP_int16 nBytesOut = sizeof(encodedFrame);
        SKP_int ret = SKP_Silk_SDK_Encode(psEnc, &encControl, frameBuffer, (SKP_int)frameSize, encodedFrame, &nBytesOut);
        if (ret == 0 && nBytesOut > 0) {
            int16_t leLen = CFSwapInt16HostToLittle((uint16_t)nBytesOut);
            [silkOut appendBytes:&leLen length:sizeof(int16_t)];
            [silkOut appendBytes:encodedFrame length:(NSUInteger)nBytesOut];
        }
    }

    free(psEnc);
    return silkOut;
}

// ==========================================
// 4. 构造微信 8.0.75 语音消息并发送（含 m_dtVoice 内存数据赋值）
// ==========================================
static NSString *V2V_GetSelfUserName(void) {
    Class settingUtil = objc_getClass("SettingUtil");
    if (settingUtil && [settingUtil respondsToSelector:@selector(getLocalUsrName:)]) {
        NSString *name = ((NSString * (*)(id, SEL, unsigned int))objc_msgSend)(settingUtil, @selector(getLocalUsrName:), 0);
        if (name.length > 0) return name;
    }

    Class centerCls = objc_getClass("MMServiceCenter");
    Class contactMgrCls = objc_getClass("CContactMgr");
    if (centerCls && contactMgrCls) {
        id center = ((id (*)(id, SEL))objc_msgSend)(centerCls, @selector(defaultCenter));
        id mgr = ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), contactMgrCls);
        if (mgr && [mgr respondsToSelector:@selector(getSelfContact)]) {
            id selfContact = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(getSelfContact));
            NSString *usrName = [selfContact valueForKey:@"m_nsUsrName"];
            if (usrName.length > 0) return usrName;
        }
    }
    return nil;
}

static NSString *V2V_ResolveTargetChatUserName(id origMsgWrap, NSString *selfUsrName) {
    NSString *fromUsr = nil;
    NSString *toUsr = nil;
    @try {
        fromUsr = [origMsgWrap valueForKey:@"m_nsFromUsr"];
        toUsr = [origMsgWrap valueForKey:@"m_nsToUsr"];
    } @catch (NSException *e) {}

    if ([fromUsr hasSuffix:@"@chatroom"]) return fromUsr;
    if ([toUsr hasSuffix:@"@chatroom"]) return toUsr;
    if (selfUsrName.length > 0 && [fromUsr isEqualToString:selfUsrName]) {
        return toUsr;
    }
    return fromUsr.length > 0 ? fromUsr : toUsr;
}

static BOOL V2V_SendSingleSilkChunk(NSData *silkData, uint32_t durationMs, NSString *selfUsr, NSString *targetUsr) {
    Class msgWrapCls = objc_getClass("CMessageWrap");
    Class centerCls = objc_getClass("MMServiceCenter");
    Class msgMgrCls = objc_getClass("CMessageMgr");
    if (!msgWrapCls || !centerCls || !msgMgrCls || !silkData || targetUsr.length == 0) return NO;

    id voiceWrap = ((id (*)(id, SEL))objc_msgSend)(msgWrapCls, @selector(alloc));
    voiceWrap = ((id (*)(id, SEL, unsigned int))objc_msgSend)(voiceWrap, @selector(initWithMsgType:), 34);
    if (!voiceWrap) return NO;

    @try {
        if (selfUsr.length > 0) [voiceWrap setValue:selfUsr forKey:@"m_nsFromUsr"];
        [voiceWrap setValue:targetUsr forKey:@"m_nsToUsr"];
        [voiceWrap setValue:@(34) forKey:@"m_uiMessageType"];
        [voiceWrap setValue:@(4) forKey:@"m_uiVoiceFormat"]; // 4 = SILK_V3
        [voiceWrap setValue:@(durationMs) forKey:@"m_uiVoiceTime"];
        [voiceWrap setValue:silkData forKey:@"m_dtVoice"];    // 关键修复：微信发送语音依赖内存字节流
        [voiceWrap setValue:@((uint32_t)[[NSDate date] timeIntervalSince1970]) forKey:@"m_uiCreateTime"];
        [voiceWrap setValue:@(1) forKey:@"m_uiStatus"];
    } @catch (NSException *e) {}

    // 同步写入本地缓存路径，确保本地自己点开也能秒播放
    if ([msgWrapCls respondsToSelector:@selector(GetPathOfAudio:)]) {
        NSString *audioPath = ((NSString * (*)(id, SEL, id))objc_msgSend)(msgWrapCls, @selector(GetPathOfAudio:), voiceWrap);
        if (audioPath.length > 0) {
            NSString *dir = [audioPath stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [silkData writeToFile:audioPath atomically:YES];
        }
    }

    id center = ((id (*)(id, SEL))objc_msgSend)(centerCls, @selector(defaultCenter));
    id msgMgr = ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), msgMgrCls);
    if (!msgMgr) return NO;

    if ([msgMgr respondsToSelector:@selector(AddAudioMsg:MsgWrap:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(msgMgr, @selector(AddAudioMsg:MsgWrap:), targetUsr, voiceWrap);
        return YES;
    } else if ([msgMgr respondsToSelector:@selector(AddMsg:MsgWrap:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(msgMgr, @selector(AddMsg:MsgWrap:), targetUsr, voiceWrap);
        return YES;
    }
    return NO;
}

static NSString *V2V_ResolveVideoFilePath(id videoMsgWrap) {
    Class msgWrapCls = objc_getClass("CMessageWrap");
    if (!msgWrapCls) return nil;

    SEL selectors[] = {
        NSSelectorFromString(@"GetPathOfMesVideo:"),
        NSSelectorFromString(@"GetTempPathOfMesVideo:")
    };

    for (int i = 0; i < 2; i++) {
        if ([msgWrapCls respondsToSelector:selectors[i]]) {
            NSString *path = ((NSString * (*)(id, SEL, id))objc_msgSend)(msgWrapCls, selectors[i], videoMsgWrap);
            if (path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
                return path;
            }
        }
    }
    return nil;
}

static void V2V_ProcessAndSendVideoWrap(id videoMsgWrap) {
    if (!videoMsgWrap) {
        V2V_ShowToast(@"未获取到视频消息数据", 2.0);
        return;
    }

    NSString *videoPath = V2V_ResolveVideoFilePath(videoMsgWrap);
    if (videoPath.length == 0) {
        V2V_ShowToast(@"请先点开播放一下该视频，加载完再转语音条", 2.5);
        return;
    }

    NSString *selfUsr = V2V_GetSelfUserName();
    NSString *targetUsr = V2V_ResolveTargetChatUserName(videoMsgWrap, selfUsr);
    if (targetUsr.length == 0) {
        V2V_ShowToast(@"无法识别当前聊天窗口对象", 2.0);
        return;
    }

    V2V_ShowToast(@"正在提取无损音轨并编码...", 0);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSError *err = nil;
        NSData *pcmData = V2V_Extract24kMonoPCMFromVideo(videoPath, &err);
        if (!pcmData || pcmData.length < 960) {
            V2V_ShowToast(err.localizedDescription ?: @"视频音轨提取失败", 2.2);
            return;
        }

        const int16_t *allSamples = (const int16_t *)pcmData.bytes;
        NSUInteger totalSamples = pcmData.length / sizeof(int16_t);

        const NSUInteger maxSamplesPerChunk = 24000 * 59;
        NSMutableArray<NSData *> *silkChunks = [NSMutableArray array];
        NSMutableArray<NSNumber *> *chunkDurations = [NSMutableArray array];

        for (NSUInteger offset = 0; offset < totalSamples; offset += maxSamplesPerChunk) {
            NSUInteger count = MIN(maxSamplesPerChunk, totalSamples - offset);
            NSData *silkData = V2V_EncodePCMToMaxSilk(allSamples + offset, count);
            if (silkData.length > 10) {
                uint32_t ms = (uint32_t)((count * 1000ULL) / 24000ULL);
                if (ms < 1000) ms = 1000;
                [silkChunks addObject:silkData];
                [chunkDurations addObject:@(ms)];
            }
        }

        if (silkChunks.count == 0) {
            V2V_ShowToast(@"SILK 编码失败", 2.0);
            return;
        }

        for (NSUInteger i = 0; i < silkChunks.count; i++) {
            NSData *chunk = silkChunks[i];
            uint32_t ms = [chunkDurations[i] unsignedIntValue];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BOOL ok = V2V_SendSingleSilkChunk(chunk, ms, selfUsr, targetUsr);
                if (!ok) {
                    V2V_ShowToast(@"发送失败：未匹配到微信 8.0.75 语音发送接口", 2.5);
                } else if (i == silkChunks.count - 1) {
                    NSString *tip = (silkChunks.count > 1)
                        ? [NSString stringWithFormat:@"已发送 %lu 条高清语音 (24kHz/40kbps)", (unsigned long)silkChunks.count]
                        : @"已发送高清语音条 (24kHz/40kbps)";
                    V2V_ShowToast(tip, 1.8);
                }
            });
        }
    });
}

// ==========================================
// 5. Hook 微信 8.0.75 消息气泡长按菜单
// ==========================================
static void V2V_SwizzleMethod(Class cls, SEL origSel, SEL newSel) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method newMethod = class_getInstanceMethod(cls, newSel);
    if (!origMethod || !newMethod) return;

    if (class_addMethod(cls, origSel, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(cls, newSel, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

static id V2V_CreateMenuItem(id target, SEL action) {
    Class menuItemCls = objc_getClass("MMMenuItem");
    if (!menuItemCls) return nil;

    id item = ((id (*)(id, SEL))objc_msgSend)(menuItemCls, @selector(alloc));
    SEL sel2 = NSSelectorFromString(@"initWithTitle:target:action:");
    SEL sel4 = NSSelectorFromString(@"initWithTitle:svgName:target:action:");

    if ([menuItemCls instancesRespondToSelector:sel2]) {
        return ((id (*)(id, SEL, id, id, SEL))objc_msgSend)(item, sel2, @"转语音条", target, action);
    } else if ([menuItemCls instancesRespondToSelector:sel4]) {
        return ((id (*)(id, SEL, id, id, id, SEL))objc_msgSend)(item, sel4, @"转语音条", @"icons_outlined_voice", target, action);
    }
    return nil;
}

static id V2V_ExtractMsgWrapFromCellView(id cellView) {
    if (!cellView) return nil;
    id viewModel = nil;
    if ([cellView respondsToSelector:@selector(viewModel)]) {
        viewModel = ((id (*)(id, SEL))objc_msgSend)(cellView, @selector(viewModel));
    }
    if (viewModel && [viewModel respondsToSelector:@selector(messageWrap)]) {
        return ((id (*)(id, SEL))objc_msgSend)(viewModel, @selector(messageWrap));
    }
    @try {
        return [cellView valueForKeyPath:@"viewModel.messageWrap"];
    } @catch (NSException *e) {}

    // 兜底遍历实例变量提取 CMessageWrap
    Class msgWrapCls = objc_getClass("CMessageWrap");
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([cellView class], &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *enc = ivar_getTypeEncoding(ivars[i]);
        if (enc && enc[0] == '@') {
            id obj = object_getIvar(cellView, ivars[i]);
            if (msgWrapCls && [obj isKindOfClass:msgWrapCls]) {
                free(ivars);
                return obj;
            }
        }
    }
    if (ivars) free(ivars);
    return nil;
}

@implementation NSObject (V2VVideoCellMenuHook)

- (id)v2v_operationMenuItems {
    id origItems = [self v2v_operationMenuItems];
    id msgWrap = V2V_ExtractMsgWrapFromCellView(self);
    if (!msgWrap) return origItems;

    NSInteger msgType = 0;
    @try {
        msgType = [[msgWrap valueForKey:@"m_uiMessageType"] integerValue];
    } @catch (NSException *e) {}

    // 43 = 聊天视频消息，62 = 小视频消息
    if (msgType == 43 || msgType == 62) {
        id menuItem = V2V_CreateMenuItem(self, @selector(v2v_onTapConvertVideoToVoice));
        if (menuItem) {
            NSMutableArray *items = [origItems isKindOfClass:[NSArray class]]
                ? [origItems mutableCopy]
                : [NSMutableArray array];
            [items addObject:menuItem];
            return items;
        }
    }
    return origItems;
}

- (void)v2v_onTapConvertVideoToVoice {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    id msgWrap = V2V_ExtractMsgWrapFromCellView(self);
    V2V_ProcessAndSendVideoWrap(msgWrap);
}

@end

// ==========================================
// 6. 动态库入口
// ==========================================
__attribute__((constructor))
static void V2VPluginInit(void) {
    @autoreleasepool {
        Class commonCellCls = objc_getClass("CommonMessageCellView");
        SEL menuSel = NSSelectorFromString(@"operationMenuItems");

        if (commonCellCls && class_getInstanceMethod(commonCellCls, menuSel)) {
            V2V_SwizzleMethod(commonCellCls, menuSel, @selector(v2v_operationMenuItems));
        }
    }
}
