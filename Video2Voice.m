#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "SKP_Silk_SDK_API.h"

// ==========================================
// 1. 悬浮提示 HUD（实时反馈提取与发送进度）
// ==========================================
static UILabel *gToastLabel = nil;

static UIWindow *V2V_GetKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

static void V2V_ShowToast(NSString *text, NSTimeInterval duration) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = V2V_GetKeyWindow();
        if (!win) return;

        if (!gToastLabel) {
            gToastLabel = [[UILabel alloc] init];
            gToastLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
            gToastLabel.textColor = [UIColor whiteColor];
            gToastLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
            gToastLabel.textAlignment = NSTextAlignmentCenter;
            gToastLabel.numberOfLines = 0;
            gToastLabel.layer.cornerRadius = 10.0;
            gToastLabel.layer.masksToBounds = YES;
        }

        gToastLabel.text = text;
        CGSize maxSize = CGSizeMake(win.bounds.size.width - 80.0, 120.0);
        CGSize textSize = [gToastLabel sizeThatFits:maxSize];
        CGFloat w = textSize.width + 36.0;
        CGFloat h = textSize.height + 22.0;
        gToastLabel.frame = CGRectMake((win.bounds.size.width - w) * 0.5, (win.bounds.size.height - h) * 0.5, w, h);

        if (!gToastLabel.superview) {
            [win addSubview:gToastLabel];
        }
        gToastLabel.alpha = 1.0;

        [NSObject cancelPreviousPerformRequestsWithTarget:gToastLabel];
        if (duration > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{
                    gToastLabel.alpha = 0.0;
                } completion:^(BOOL finished) {
                    if (gToastLabel.alpha == 0.0) {
                        [gToastLabel removeFromSuperview];
                    }
                }];
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

    // 先解码为 24000Hz 双声道 16-bit PCM，保留完整左右声道混响能量
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

    // 1) 防相位抵消单声道混缩（避免左右声道混响直接相减丢失空间感）
    float maxPeak = 0.0001f;
    for (NSUInteger i = 0; i < frameCount; i++) {
        float L = (float)stereoSamples[i * 2];
        float R = (float)stereoSamples[i * 2 + 1];
        float mixed = 0.62f * L + 0.48f * R;
        monoFloat[i] = mixed;
        float absVal = fabsf(mixed);
        if (absVal > maxPeak) maxPeak = absVal;
    }

    // 2) 安全峰值归一化（仅当混缩后超过 -0.5dB 上限时等比例压回，不破坏原声动态）
    float scale = 1.0f;
    if (maxPeak > 30900.0f) {
        scale = 30900.0f / maxPeak;
    }

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

    // 锁定微信语音条协议上限参数
    SKP_SILK_SDK_EncControlStruct encControl;
    memset(&encControl, 0, sizeof(encControl));
    encControl.API_sampleRate = 24000;
    encControl.maxInternalSampleRate = 24000;
    encControl.packetSize = 480;         // 20ms 一帧 @ 24kHz
    encControl.bitRate = 40000;          // 40kbps 最高码率
    encControl.packetLossPercentage = 0;
    encControl.complexity = 2;           // 最高编码精度
    encControl.useInBandFEC = 0;         // 关闭纠错冗余，码率全留给音质
    encControl.useDTX = 0;               // 关闭静音压缩，完整保留混响与气音尾音

    NSMutableData *silkOut = [NSMutableData data];
    // 写入微信标准 SILK_V3 头部（0x02 + "#!SILK_V3"）
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
// 4. 构造微信语音消息并发送（支持超 60 秒自动切片）
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
    NSString *fromUsr = [origMsgWrap valueForKey:@"m_nsFromUsr"];
    NSString *toUsr = [origMsgWrap valueForKey:@"m_nsToUsr"];

    if ([fromUsr hasSuffix:@"@chatroom"]) return fromUsr;
    if ([toUsr hasSuffix:@"@chatroom"]) return toUsr;
    if (selfUsrName.length > 0 && [fromUsr isEqualToString:selfUsrName]) {
        return toUsr;
    }
    return fromUsr.length > 0 ? fromUsr : toUsr;
}

static void V2V_SendSingleSilkChunk(NSData *silkData, uint32_t durationMs, NSString *selfUsr, NSString *targetUsr) {
    Class msgWrapCls = objc_getClass("CMessageWrap");
    Class centerCls = objc_getClass("MMServiceCenter");
    Class msgMgrCls = objc_getClass("CMessageMgr");
    if (!msgWrapCls || !centerCls || !msgMgrCls || !silkData || targetUsr.length == 0) return;

    id voiceWrap = ((id (*)(id, SEL))objc_msgSend)(msgWrapCls, @selector(alloc));
    voiceWrap = ((id (*)(id, SEL, unsigned int))objc_msgSend)(voiceWrap, @selector(initWithMsgType:), 34);
    if (!voiceWrap) return;

    @try {
        if (selfUsr.length > 0) [voiceWrap setValue:selfUsr forKey:@"m_nsFromUsr"];
        [voiceWrap setValue:targetUsr forKey:@"m_nsToUsr"];
        [voiceWrap setValue:@(34) forKey:@"m_uiMessageType"];
        [voiceWrap setValue:@(4) forKey:@"m_uiVoiceFormat"]; // 4 = SILK_V3
        [voiceWrap setValue:@(durationMs) forKey:@"m_uiVoiceTime"];
        [voiceWrap setValue:@((uint32_t)[[NSDate date] timeIntervalSince1970]) forKey:@"m_uiCreateTime"];
        [voiceWrap setValue:@(1) forKey:@"m_uiStatus"];
    } @catch (NSException *e) {}

    if (![msgWrapCls respondsToSelector:@selector(GetPathOfAudio:)]) return;
    NSString *audioPath = ((NSString * (*)(id, SEL, id))objc_msgSend)(msgWrapCls, @selector(GetPathOfAudio:), voiceWrap);
    if (audioPath.length == 0) return;

    NSString *dir = [audioPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    if (![silkData writeToFile:audioPath atomically:YES]) return;

    id center = ((id (*)(id, SEL))objc_msgSend)(centerCls, @selector(defaultCenter));
    id msgMgr = ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), msgMgrCls);
    if (!msgMgr) return;

    if ([msgMgr respondsToSelector:@selector(AddAudioMsg:MsgWrap:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(msgMgr, @selector(AddAudioMsg:MsgWrap:), targetUsr, voiceWrap);
    } else if ([msgMgr respondsToSelector:@selector(AddMsg:MsgWrap:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(msgMgr, @selector(AddMsg:MsgWrap:), targetUsr, voiceWrap);
    }
}

static void V2V_ProcessAndSendVideoWrap(id videoMsgWrap) {
    if (!videoMsgWrap) return;

    Class msgWrapCls = objc_getClass("CMessageWrap");
    if (!msgWrapCls || ![msgWrapCls respondsToSelector:@selector(GetPathOfMesVideo:)]) {
        V2V_ShowToast(@"未找到视频路径接口", 2.0);
        return;
    }

    NSString *videoPath = ((NSString * (*)(id, SEL, id))objc_msgSend)(msgWrapCls, @selector(GetPathOfMesVideo:), videoMsgWrap);
    if (videoPath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
        V2V_ShowToast(@"视频尚未加载完成，请先点开播放后再转语音条", 2.5);
        return;
    }

    NSString *selfUsr = V2V_GetSelfUserName();
    NSString *targetUsr = V2V_ResolveTargetChatUserName(videoMsgWrap, selfUsr);
    if (targetUsr.length == 0) {
        V2V_ShowToast(@"无法识别当前聊天对象", 2.0);
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

        // 微信语音条单条上限 60 秒，按 59 秒（24000 * 59 = 1416000 采样点）安全分段
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

        // 按顺序发送到当前聊天窗口（多段时间隔 0.35 秒防乱序）
        for (NSUInteger i = 0; i < silkChunks.count; i++) {
            NSData *chunk = silkChunks[i];
            uint32_t ms = [chunkDurations[i] unsignedIntValue];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                V2V_SendSingleSilkChunk(chunk, ms, selfUsr, targetUsr);
                if (i == silkChunks.count - 1) {
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
// 5. Hook 微信 8.0.75 视频气泡长按菜单
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
    id viewModel = nil;
    if ([cellView respondsToSelector:@selector(viewModel)]) {
        viewModel = ((id (*)(id, SEL))objc_msgSend)(cellView, @selector(viewModel));
    }
    if (viewModel && [viewModel respondsToSelector:@selector(messageWrap)]) {
        return ((id (*)(id, SEL))objc_msgSend)(viewModel, @selector(messageWrap));
    }
    @try {
        return [cellView valueForKeyPath:@"viewModel.messageWrap"];
    } @catch (NSException *e) {
        return nil;
    }
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
        Class videoCellCls = objc_getClass("VideoMessageCellView");
        Class commonCellCls = objc_getClass("CommonMessageCellView");
        SEL menuSel = NSSelectorFromString(@"operationMenuItems");

        if (videoCellCls && class_getInstanceMethod(videoCellCls, menuSel)) {
            V2V_SwizzleMethod(videoCellCls, menuSel, @selector(v2v_operationMenuItems));
        } else if (commonCellCls && class_getInstanceMethod(commonCellCls, menuSel)) {
            V2V_SwizzleMethod(commonCellCls, menuSel, @selector(v2v_operationMenuItems));
        }
    }
}
