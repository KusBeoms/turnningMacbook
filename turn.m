// turn — 맥 화면 회전 도구 (Apple Silicon / Intel, 비공개 MonitorPanel 프레임워크 사용)
//
// 사용법:
//   turn               내장 화면을 90°씩 반시계방향으로 돌림
//   turn 0|90|180|270  지정한 각도로 설정
//   turn reset         0°로 복구
//   turn list          연결된 디스플레이 목록
//   turn auto          맥북을 돌리면 내장 가속도계로 감지해서 자동 회전
//   옵션: -d <displayID>  대상 디스플레이 지정 (기본: 내장 화면, 없으면 메인 화면)
//
// 화면이 돌아가 있는 동안에는 백그라운드 프로세스(turn --track)가 이벤트 탭으로
// 포인터 이동, 두 손가락 스크롤, 세 손가락 스와이프 방향을 화면 각도에 맞게 돌려 줍니다.
// (손쉬운 사용 권한 필요)

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDDevice.h>
#import <AppKit/AppKit.h>
#include <signal.h>
#include <spawn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>

extern char **environ;

@interface MPDisplay : NSObject
- (int)displayID;
- (NSString *)displayName;
- (BOOL)isBuiltIn;
- (BOOL)canChangeOrientation;
- (int)orientation;
- (void)setOrientation:(int)orientation;
@end

@interface MPDisplayMgr : NSObject
- (NSArray<MPDisplay *> *)displays;
@end

#pragma mark - 입력 회전 (백그라운드)

// 트랙패드와 커서의 연결을 끊고(CGAssociateMouseAndMouseCursorPosition), 순수한 이동량만 받아
// 회전시킨 뒤 커서를 직접 옮긴다. 이벤트를 다시 보내면 macOS가 옮긴 거리를 다음 delta에
// 더해 버려서 커서가 나선형으로 튀기 때문.

// 트랙패드 제스처 관련 비공개 이벤트 타입/필드 (디버그 로그로 확인한 값)
static const CGEventType kTurnEventGesture = (CGEventType)29;
static const CGEventType kTurnEventDockGesture = (CGEventType)30;
static const CGEventField kGestureHIDType = (CGEventField)110;
static const int64_t kGestureHIDTypeDockSwipe = 23;
static const CGEventField kGestureSwipeAxis = (CGEventField)123;
static const CGEventField kGestureSwipeProgress = (CGEventField)124;
static const CGEventField kGestureSwipeProgressBits = (CGEventField)135;
static const CGEventField kGestureSwipeMask = (CGEventField)115;
static const CGEventField kGestureSwipePositionX = (CGEventField)125;
static const CGEventField kGestureSwipePositionY = (CGEventField)126;
static const CGEventField kGestureSwipeVelocityX = (CGEventField)129;
static const CGEventField kGestureSwipeVelocityY = (CGEventField)130;
static const CGEventField kGesturePhase = (CGEventField)132;
static const int64_t kGesturePhaseEnded = 4;
static const int64_t kGesturePhaseCancelled = 8;
static const CGEventField kScrollPhase = (CGEventField)99;
static const CGEventField kScrollMomentumPhase = (CGEventField)123;

// 우리가 새로 만들어 보낸 이벤트 표식 (탭이 다시 처리하지 않도록)
static const int64_t kTurnEventTag = 0x7475726E; // 'turn'
static CGEventSourceRef gSource;
static BOOL gDockSwipeActive;  // 회전해서 다시 보내는 중인 Dock 스와이프가 진행 중인지

#pragma mark - macOS 27 Dock 스와이프 원본 데이터
//
// macOS 27부터 Dock은 합성 스와이프 이벤트에 직렬화된 IOHID 큐 데이터(CGEvent 필드 4205)가
// 붙어 있는지 검사하고, 없으면 조용히 무시한다. 일반 필드 설정 함수로는 이 필드를 쓸 수 없어서
// 이벤트를 직렬화한 뒤 데이터를 덧붙이고 다시 이벤트로 만든다.
// 바이트 레이아웃은 joshuarli/iss 가 역공학한 것을 따름.

static const uint16_t kRawIOHIDPayloadField = 4205;

static BOOL needsSwipePayload(void) {
    static int cached = -1;
    if (cached < 0) {
        char version[32];
        size_t size = sizeof(version);
        int major = 0;
        if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) == 0) {
            sscanf(version, "%d", &major);
        }
        cached = major >= 27;
    }
    return cached;
}

static int32_t fixed1616(double v) {
    int32_t f = (int32_t)(v * 65536.0);
    if (f == 0 && v != 0) return v > 0 ? 1 : -1;
    return f;
}

static void appendLE16(NSMutableData *d, uint16_t v) { v = OSSwapHostToLittleInt16(v); [d appendBytes:&v length:2]; }
static void appendLE32(NSMutableData *d, uint32_t v) { v = OSSwapHostToLittleInt32(v); [d appendBytes:&v length:4]; }
static void appendLE64(NSMutableData *d, uint64_t v) { v = OSSwapHostToLittleInt64(v); [d appendBytes:&v length:8]; }

// 반환값은 호출한 쪽이 CFRelease 해야 함. 실패하면 NULL
static CGEventRef attachSwipePayload(CGEventRef ev) {
    CFDataRef serialized = CGEventCreateData(kCFAllocatorDefault, ev);
    if (!serialized) return NULL;
    NSMutableData *bytes = [(__bridge_transfer NSData *)serialized mutableCopy];
    const uint8_t *head = bytes.bytes;
    // 직렬화 형식 버전 2 (00 00 00 02) 에서만 레이아웃이 확인됨
    if (bytes.length < 4 || head[0] != 0 || head[1] != 0 || head[2] != 0 || head[3] != 2) return NULL;

    int64_t phase = CGEventGetIntegerValueField(ev, kGesturePhase);
    double velX = CGEventGetDoubleValueField(ev, kGestureSwipeVelocityX);
    double velY = CGEventGetDoubleValueField(ev, kGestureSwipeVelocityY);
    // 끝 단계에서는 속도가 0이어도 속도 기록이 있어야 전환이 확정됨
    BOOL includeVelocity = velX != 0 || velY != 0 || phase == kGesturePhaseEnded;

    NSMutableData *payload = [NSMutableData data];
    // IOHIDSystemQueueElementHeader (28바이트)
    uint64_t timestamp = CGEventGetTimestamp(ev);
    appendLE64(payload, timestamp ? timestamp : mach_absolute_time());
    appendLE64(payload, 0);                           // sender_id
    appendLE32(payload, 0);                           // options
    appendLE32(payload, 0);                           // attribute_length
    appendLE32(payload, includeVelocity ? 2 : 1);     // event_count
    // IOHIDFluidTouchGestureData (40바이트)
    appendLE32(payload, 40);                          // base.size
    appendLE32(payload, 23);                          // base.type = fluid touch gesture
    appendLE32(payload, (uint32_t)((phase & 0xFF) << 24)); // base.options
    appendLE32(payload, 0);                           // base.depth + reserved
    appendLE32(payload, (uint32_t)fixed1616(CGEventGetDoubleValueField(ev, kGestureSwipePositionX)));
    appendLE32(payload, (uint32_t)fixed1616(CGEventGetDoubleValueField(ev, kGestureSwipePositionY)));
    appendLE32(payload, 0);                           // position_z
    appendLE32(payload, (uint32_t)CGEventGetIntegerValueField(ev, kGestureSwipeMask));
    appendLE16(payload, (uint16_t)CGEventGetIntegerValueField(ev, kGestureSwipeAxis));
    appendLE16(payload, 3);                           // gesture_flavor = Dock primary
    appendLE32(payload, (uint32_t)fixed1616(CGEventGetDoubleValueField(ev, kGestureSwipeProgress)));
    if (includeVelocity) {
        // IOHIDVelocityEventData (28바이트)
        appendLE32(payload, 28);                      // base.size
        appendLE32(payload, 9);                       // base.type = velocity
        appendLE32(payload, 0);                       // base.options
        appendLE32(payload, 1);                       // base.depth = 1 + reserved
        appendLE32(payload, (uint32_t)fixed1616(velX));
        appendLE32(payload, (uint32_t)fixed1616(velY));
        appendLE32(payload, 0);                       // velocity_z
    }

    // 필드 레코드: 길이(2바이트, 빅엔디언) + 필드 번호(2바이트, 빅엔디언) + 데이터
    uint8_t record[4] = {
        (uint8_t)(payload.length >> 8), (uint8_t)payload.length,
        (uint8_t)(kRawIOHIDPayloadField >> 8), (uint8_t)kRawIOHIDPayloadField,
    };
    [bytes appendBytes:record length:sizeof(record)];
    [bytes appendData:payload];
    return CGEventCreateFromData(kCFAllocatorDefault, (__bridge CFDataRef)bytes);
}

static CGDirectDisplayID gDisplay;
static int gOrientation;   // MPDisplay 기준 (반시계방향) 각도
static CGPoint gCursor;
static CGPoint gLastWarp;  // 직전 워프로 옮긴 거리
static CFMachPortRef gTap;

// 손가락 방향 벡터를 회전된 화면 좌표계의 벡터로 변환
static void rotateVector(double *x, double *y) {
    double dx = *x, dy = *y;
    switch (gOrientation) {
        case 90:  *x = -dy; *y = dx;  break;
        case 180: *x = -dx; *y = -dy; break;
        case 270: *x = dy;  *y = -dx; break;
    }
}

static BOOL pointOnAnyDisplay(CGPoint p) {
    uint32_t count = 0;
    CGGetDisplaysWithPoint(p, 0, NULL, &count);
    return count > 0;
}

static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(gTap, true);
        CGEventRef e = CGEventCreate(NULL);
        gCursor = CGEventGetLocation(e);
        CFRelease(e);
        return event;
    }

    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kTurnEventTag) return event;

    CGRect bounds = CGDisplayBounds(gDisplay);

    // 회전한 Dock 스와이프를 보내는 동안에는 원래 짝 이벤트를 막음 (우리가 짝을 따로 보냄)
    if (type == kTurnEventGesture) return gDockSwipeActive ? NULL : event;

    // 0°(자동 회전 모드에서 똑바로 놓인 상태)에서는 입력을 건드리지 않음
    if (gOrientation == 0) {
        gCursor = CGEventGetLocation(event);
        return event;
    }

    if (type == kCGEventScrollWheel) {
        CGEventRef e = CGEventCreate(NULL);
        BOOL onTarget = CGRectContainsPoint(bounds, CGEventGetLocation(e));
        CFRelease(e);
        if (!onTarget || gOrientation == 0) return event;

        // 실제 트랙패드 스크롤에는 원본 IOHID 데이터가 붙어 있어서 앱은 필드를 바꿔도 그걸 읽음.
        // 그래서 원래 이벤트는 버리고 원본 데이터가 없는 새 이벤트를 회전한 값으로 만들어 보냄
        double dh = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
        double dv = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
        double fh = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2);
        double fv = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1);
        double ph = CGEventGetDoubleValueField(event, kCGScrollWheelEventPointDeltaAxis2);
        double pv = CGEventGetDoubleValueField(event, kCGScrollWheelEventPointDeltaAxis1);
        rotateVector(&dh, &dv);
        rotateVector(&fh, &fv);
        rotateVector(&ph, &pv);

        CGEventRef out = CGEventCreateScrollWheelEvent2(gSource, kCGScrollEventUnitPixel, 2, 0, 0, 0);
        CGEventSetLocation(out, CGEventGetLocation(event));
        CGEventSetFlags(out, CGEventGetFlags(event));
        CGEventSetTimestamp(out, CGEventGetTimestamp(event));
        const CGEventField keep[] = {kCGScrollWheelEventIsContinuous, kScrollPhase, kScrollMomentumPhase};
        for (int i = 0; i < 3; i++) {
            CGEventSetIntegerValueField(out, keep[i], CGEventGetIntegerValueField(event, keep[i]));
        }
        // 정수 delta를 설정하면 fixed/point 값이 다시 계산돼 덮어써지므로 정수 → 고정소수점 → 픽셀 순서
        CGEventSetIntegerValueField(out, kCGScrollWheelEventDeltaAxis2, llround(dh));
        CGEventSetIntegerValueField(out, kCGScrollWheelEventDeltaAxis1, llround(dv));
        CGEventSetDoubleValueField(out, kCGScrollWheelEventFixedPtDeltaAxis2, fh);
        CGEventSetDoubleValueField(out, kCGScrollWheelEventFixedPtDeltaAxis1, fv);
        CGEventSetDoubleValueField(out, kCGScrollWheelEventPointDeltaAxis2, ph);
        CGEventSetDoubleValueField(out, kCGScrollWheelEventPointDeltaAxis1, pv);
        CGEventPost(kCGHIDEventTap, out);
        CFRelease(out);
        return NULL;
    }

    // 세 손가락 스와이프(Dock 스와이프: 데스크톱 전환, Mission Control)
    // 필드 110=23 이면 Dock 스와이프, 123=축(1 가로, 2 세로), 124=누적 진행량,
    // 125=이번 이동량, 129/130=끝날 때 속도
    if (type == kTurnEventDockGesture) {
        if (CGEventGetIntegerValueField(event, kGestureHIDType) != kGestureHIDTypeDockSwipe) return event;
        CGEventRef e = CGEventCreate(NULL);
        BOOL onTarget = CGRectContainsPoint(bounds, CGEventGetLocation(e));
        CFRelease(e);
        if (!onTarget || gOrientation == 0) return event;

        int64_t axis = CGEventGetIntegerValueField(event, kGestureSwipeAxis);
        if (axis != 1 && axis != 2) return event;

        // 스와이프가 끝날 때까지 원래 짝 이벤트(type 29)는 막아야 함
        int64_t phase = CGEventGetIntegerValueField(event, kGesturePhase);
        gDockSwipeActive = phase != kGesturePhaseEnded && phase != kGesturePhaseCancelled;

        // 손가락이 움직인 축을 단위 벡터로 두고 회전해서 새 축과 부호를 구함
        double x = axis == 1 ? 1 : 0, y = axis == 2 ? 1 : 0;
        rotateVector(&x, &y);
        int64_t newAxis = fabs(x) > 0.5 ? 1 : 2;
        double sign = newAxis == 1 ? x : y;

        // 스크롤과 마찬가지로 원본 IOHID 데이터가 없는 새 이벤트로 다시 보냄
        CGEventRef out = CGEventCreate(gSource);
        CGEventSetType(out, type);
        CGEventSetLocation(out, CGEventGetLocation(event));
        CGEventSetFlags(out, CGEventGetFlags(event));
        CGEventSetTimestamp(out, CGEventGetTimestamp(event));
        CGEventSetIntegerValueField(out, (CGEventField)55, type);
        for (int f = 100; f < 256; f++) {
            double v = CGEventGetDoubleValueField(event, (CGEventField)f);
            if (v != 0) CGEventSetDoubleValueField(out, (CGEventField)f, v);
        }
        CGEventSetIntegerValueField(out, kGestureSwipeAxis, newAxis);
        const CGEventField signedFields[] = {124, 125, 129, 130};
        for (int i = 0; i < 4; i++) {
            double v = CGEventGetDoubleValueField(event, signedFields[i]);
            CGEventSetDoubleValueField(out, signedFields[i], v * sign);
        }
        // 135번은 진행량(124)을 float 비트 그대로 담은 값이라 함께 맞춰야 함
        float progress = (float)CGEventGetDoubleValueField(out, kGestureSwipeProgress);
        uint32_t bits;
        memcpy(&bits, &progress, sizeof(bits));
        CGEventSetIntegerValueField(out, kGestureSwipeProgressBits, bits);

        // Dock 스와이프 뒤에는 항상 같은 시각의 빈 제스처(type 29) 이벤트가 짝으로 따라와야 함
        CGEventRef companion = CGEventCreate(gSource);
        CGEventSetType(companion, kTurnEventGesture);
        CGEventSetLocation(companion, CGEventGetLocation(event));
        CGEventSetTimestamp(companion, CGEventGetTimestamp(event));
        CGEventSetIntegerValueField(companion, (CGEventField)55, kTurnEventGesture);
        CGEventSetIntegerValueField(companion, (CGEventField)101, CGEventGetIntegerValueField(event, (CGEventField)101));

        // macOS 27부터는 IOHID 원본 데이터(필드 4205)가 붙어 있어야 Dock이 받아들임.
        // 직렬화를 거치면 표식이 사라지지만, 세션 단계로 보내므로 HID 단계인 이 탭을 다시 거치지 않음
        if (needsSwipePayload()) {
            CGEventRef augmented = attachSwipePayload(out);
            if (augmented) {
                CFRelease(out);
                out = augmented;
            }
        }

        CGEventPost(kCGSessionEventTap, out);
        CGEventPost(kCGSessionEventTap, companion);
        CFRelease(out);
        CFRelease(companion);
        return NULL;
    }

    BOOL isMove = type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged ||
                  type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged;

    CGPoint actual = CGEventGetLocation(event);
    double dx = isMove ? CGEventGetDoubleValueField(event, kCGMouseEventDeltaX) : 0;
    double dy = isMove ? CGEventGetDoubleValueField(event, kCGMouseEventDeltaY) : 0;

    if (!isMove) {
        // 클릭도 우리가 옮긴 커서 위치에서 일어나도록
        CGEventSetLocation(event, gCursor);
        return event;
    }

    // 워프로 옮긴 거리가 다음 이벤트 delta에 섞여 들어오므로 빼서 순수한 손가락 이동만 남김
    dx -= gLastWarp.x;
    dy -= gLastWarp.y;
    gLastWarp = CGPointZero;

    // 다른 앱 때문에 연결이 되살아나 macOS가 커서를 직접 움직였다면 다시 끊고 위치를 맞춤
    if (fabs(actual.x - gCursor.x) > 2 || fabs(actual.y - gCursor.y) > 2) {
        CGAssociateMouseAndMouseCursorPosition(false);
        gCursor = actual;
    }

    // 회전된 화면 위에서만 방향을 돌림 (다른 모니터에서는 그대로)
    if (CGRectContainsPoint(bounds, gCursor)) rotateVector(&dx, &dy);

    CGPoint next = CGPointMake(gCursor.x + dx, gCursor.y + dy);
    if (!pointOnAnyDisplay(next)) {
        CGRect current = bounds;
        CGDirectDisplayID ids[1];
        uint32_t count = 0;
        if (CGGetDisplaysWithPoint(gCursor, 1, ids, &count) == kCGErrorSuccess && count > 0) {
            current = CGDisplayBounds(ids[0]);
        }
        next.x = MIN(MAX(next.x, CGRectGetMinX(current)), CGRectGetMaxX(current) - 1);
        next.y = MIN(MAX(next.y, CGRectGetMinY(current)), CGRectGetMaxY(current) - 1);
    }
    gLastWarp = CGPointMake(next.x - gCursor.x, next.y - gCursor.y);
    gCursor = next;

    CGWarpMouseCursorPosition(gCursor);
    CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, dx);
    CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, dy);
    CGEventSetLocation(event, gCursor);
    return event;
}

// 연결을 실제로 끊은 뒤에만 되돌림 (그래픽 연결 준비 전에 CG 함수를 부르면 강제 종료됨)
static volatile sig_atomic_t gDisassociated;

static void restoreAndExit(int sig) {
    if (gDisassociated) CGAssociateMouseAndMouseCursorPosition(true);
    _exit(0);
}

// 회전 중에만 트랙패드와 커서 연결을 끊음
static void setPointerDetached(BOOL detached) {
    CGAssociateMouseAndMouseCursorPosition(!detached);
    gDisassociated = detached;
}

#pragma mark - 자동 회전 (내장 가속도계)
//
// Apple Silicon 맥북의 IMU(Bosch BMI286)는 공개 API가 없고 AppleSPUHIDDevice
// (usage page 0xFF00, usage 3)로 노출된다. AppleSPUHIDDriver 속성으로 센서를 깨운 뒤
// 22바이트 리포트의 6/10/14 바이트에 있는 int32(Q16.16, 단위 g)를 읽는다.
// 방법: olvvier/apple-silicon-accelerometer, taigrr/apple-silicon-accelerometer

static MPDisplay *gAutoDisplay;
static uint8_t gAccelReport[4096];
static double gGravity[3];
static BOOL gGravityReady;
static long gAccelSamples;
static int gCandidate = -1;
static CFAbsoluteTime gCandidateSince;

static const double kAutoRotateHoldSeconds = 0.8;  // 같은 방향이 이만큼 유지돼야 회전

static uint8_t gLidReport[4096];
static double gLidAngle = 110;  // 화면이 열린 각도(도). lid 센서를 못 읽으면 흔한 값으로 가정

static void onLidReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                        uint32_t reportID, uint8_t *report, CFIndex length) {
    if (length < 3 || report[0] != 1) return;
    int angle = (report[1] | report[2] << 8) & 0x1FF;
    if (angle > 0 && angle <= 360) gLidAngle = angle;
}

// 중력 벡터(센서 좌표, g)로부터 화면 방향(MPDisplay 각도)을 구함. 판단할 수 없으면 -1
//
// 센서 축(본체 기준, NSEvent/tilt-sim-experiment 문서): x=오른쪽, y=힌지 쪽, z=키보드 위쪽.
// 값은 중력이 향하는 방향이라 평평하게 두면 (0, 0, -1g).
// 화면은 힌지에서 L도 열려 있으므로 화면 평면의 중력은
//   오른쪽 성분 = x,  화면 위쪽 성분 = -y·cos L + z·sin L
// 이 벡터가 화면 아래쪽이면 0°, 오른쪽이면 90°(맥북 오른쪽이 바닥), 위쪽이면 180°, 왼쪽이면 270°.
static int orientationFromGravity(double x, double y, double z) {
    double lid = gLidAngle * M_PI / 180;
    double right = x;
    double up = -y * cos(lid) + z * sin(lid);
    // 맥북을 눕혀서 화면이 거의 수평이면 방향을 판단하지 않음
    if (sqrt(right * right + up * up) < 0.5) return -1;

    double angle = atan2(right, -up) * 180 / M_PI;  // 0=평소, +90=오른쪽 아래, ±180=거꾸로, -90=왼쪽 아래
    if (angle < 0) angle += 360;
    int nearest = ((int)lround(angle / 90) % 4) * 90;
    double diff = fabs(angle - nearest);
    if (diff > 180) diff = 360 - diff;
    // 경계에서 왔다갔다하지 않도록 기준 방향 ±30° 안에 들어올 때만 인정
    return diff <= 30 ? nearest : -1;
}

static void applyOrientation(int orientation) {
    [gAutoDisplay setOrientation:orientation];
    gOrientation = orientation;
    gDockSwipeActive = NO;
    gLastWarp = CGPointZero;
    CGEventRef e = CGEventCreate(NULL);
    gCursor = CGEventGetLocation(e);
    CFRelease(e);
    setPointerDetached(orientation != 0);
}

#pragma mark - 자동 회전 애니메이션
//
// 모든 창 위에 검은 오버레이를 서서히 띄우고(페이드 인), 가려진 상태에서 실제 방향을 바꾼 뒤
// 서서히 걷어낸다(페이드 아웃). 방향 전환 때 생기는 깜빡임과 창 재배치가 보이지 않는다.

static BOOL gRotating;
static NSWindow *gOverlay;
static const NSTimeInterval kFadeInSeconds = 0.2;
static const NSTimeInterval kFadeOutSeconds = 0.3;

// CG 전역 좌표(주 화면 왼쪽 위 원점) → Cocoa 화면 좌표(주 화면 왼쪽 아래 원점)
static NSRect cocoaFrameForDisplay(CGDirectDisplayID display) {
    CGRect b = CGDisplayBounds(display);
    CGFloat primaryHeight = CGDisplayBounds(CGMainDisplayID()).size.height;
    return NSMakeRect(b.origin.x, primaryHeight - b.origin.y - b.size.height, b.size.width, b.size.height);
}

static NSWindow *makeOverlayWindow(NSRect frame) {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed = NO;
    w.level = NSScreenSaverWindowLevel;
    w.backgroundColor = NSColor.blackColor;
    w.opaque = YES;
    w.hasShadow = NO;
    w.ignoresMouseEvents = YES;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                           NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    w.contentView.wantsLayer = YES;
    w.contentView.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    return w;
}

static void finishRotation(void) {
    [gOverlay orderOut:nil];
    gOverlay = nil;
    gRotating = NO;
}

static void fadeOutOverlay(void) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kFadeOutSeconds;
        gOverlay.animator.alphaValue = 0;
    } completionHandler:^{
        finishRotation();
    }];
}

// 방향을 바꾼 뒤 디스플레이 크기가 새 방향으로 바뀔 때까지 기다림 (최대 약 1.5초)
static void waitForDisplaySize(CGSize expected, int triesLeft, void (^done)(void)) {
    CGSize now = CGDisplayBounds(gDisplay).size;
    if (CGSizeEqualToSize(now, expected) || triesLeft <= 0) {
        done();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        waitForDisplaySize(expected, triesLeft - 1, done);
    });
}

static void rotateWithAnimation(int to) {
    gRotating = YES;
    CGSize oldSize = CGDisplayBounds(gDisplay).size;
    CGSize newSize = (to - gOrientation) % 180 ? CGSizeMake(oldSize.height, oldSize.width) : oldSize;

    gOverlay = makeOverlayWindow(cocoaFrameForDisplay(gDisplay));
    gOverlay.alphaValue = 0;
    [gOverlay orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kFadeInSeconds;
        gOverlay.animator.alphaValue = 1;
    } completionHandler:^{
        applyOrientation(to);
        waitForDisplaySize(newSize, 75, ^{
            // 새 방향의 화면 크기에 맞춰 오버레이를 다시 덮은 뒤 걷어냄
            [gOverlay setFrame:cocoaFrameForDisplay(gDisplay) display:YES];
            fadeOutOverlay();
        });
    }];
}

static void onAccelReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                          uint32_t reportID, uint8_t *report, CFIndex length) {
    if (length != 22) return;
    int32_t raw[3];
    memcpy(raw, report + 6, sizeof(raw));
    for (int i = 0; i < 3; i++) {
        // OSSwapLittleToHostInt32 는 부호 없는 값을 돌려주므로 int32_t 로 되돌려야 음수가 보존됨
        double g = (int32_t)OSSwapLittleToHostInt32(raw[i]) / 65536.0;
        gGravity[i] = gGravityReady ? gGravity[i] * 0.98 + g * 0.02 : g;  // 흔들림 제거용 저역 통과
    }
    gGravityReady = YES;

    // 약 800Hz로 들어오므로 20번에 한 번(약 25ms마다)만 판단
    if (++gAccelSamples % 20) return;
    if (gRotating) return;  // 애니메이션 중에는 판단하지 않음
    int orientation = orientationFromGravity(gGravity[0], gGravity[1], gGravity[2]);
    if (orientation < 0 || orientation == gOrientation) {
        gCandidate = -1;
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (orientation != gCandidate) {
        gCandidate = orientation;
        gCandidateSince = now;
    } else if (now - gCandidateSince >= kAutoRotateHoldSeconds) {
        gCandidate = -1;
        rotateWithAnimation(orientation);
    }
}

static long registryInt(io_service_t svc, CFStringRef key) {
    CFTypeRef ref = IORegistryEntryCreateCFProperty(svc, key, NULL, 0);
    long v = 0;
    if (ref && CFGetTypeID(ref) == CFNumberGetTypeID()) CFNumberGetValue(ref, kCFNumberLongType, &v);
    if (ref) CFRelease(ref);
    return v;
}

static BOOL startAutoRotate(CGDirectDisplayID displayID) {
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MonitorPanel.framework"] load];
    MPDisplayMgr *mgr = [[NSClassFromString(@"MPDisplayMgr") alloc] init];
    for (MPDisplay *d in [mgr displays]) {
        if ([d displayID] == (int)displayID) gAutoDisplay = d;
    }
    if (!gAutoDisplay) return NO;

    io_iterator_t it;
    io_service_t svc;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS) {
        const char *keys[] = {"SensorPropertyReportingState", "SensorPropertyPowerState", "ReportInterval"};
        int32_t values[] = {1, 1, 1000};
        while ((svc = IOIteratorNext(it))) {
            for (int i = 0; i < 3; i++) {
                CFStringRef k = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
                CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &values[i]);
                IORegistryEntrySetCFProperty(svc, k, n);
                CFRelease(k);
                CFRelease(n);
            }
            IOObjectRelease(svc);
        }
        IOObjectRelease(it);
    }

    BOOL opened = NO;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &it) == KERN_SUCCESS) {
        while ((svc = IOIteratorNext(it))) {
            long page = registryInt(svc, CFSTR("PrimaryUsagePage"));
            long usage = registryInt(svc, CFSTR("PrimaryUsage"));
            BOOL isAccel = !opened && page == 0xFF00 && usage == 3;
            BOOL isLid = page == 0x20 && usage == 138;  // 화면 열림 각도 센서
            if (isAccel || isLid) {
                IOHIDDeviceRef dev = IOHIDDeviceCreate(kCFAllocatorDefault, svc);
                if (dev && IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone) == kIOReturnSuccess) {
                    IOHIDDeviceRegisterInputReportCallback(dev, isAccel ? gAccelReport : gLidReport, 4096,
                                                           isAccel ? onAccelReport : onLidReport, NULL);
                    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
                    if (isAccel) opened = YES;
                }
            }
            IOObjectRelease(svc);
        }
        IOObjectRelease(it);
    }
    return opened;
}

static int runTracker(CGDirectDisplayID display, int orientation, BOOL autoRotate) {
    // 종료될 때 트랙패드와 커서 연결을 반드시 되돌림 (시작 직후 종료돼도 처리되도록 가장 먼저 등록)
    signal(SIGTERM, restoreAndExit);
    signal(SIGINT, restoreAndExit);
    signal(SIGHUP, restoreAndExit);

    gDisplay = display;
    gOrientation = orientation;

    gSource = CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventSourceSetUserData(gSource, kTurnEventTag);

    CGEventRef e = CGEventCreate(NULL);
    gCursor = CGEventGetLocation(e);
    CFRelease(e);

    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged) |
        CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp) |
        CGEventMaskBit(kCGEventScrollWheel) | CGEventMaskBit(kTurnEventDockGesture) |
        CGEventMaskBit(kTurnEventGesture);

    gTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                            mask, tapCallback, NULL);
    if (!gTap) return 1;

    if (autoRotate) {
        // 회전 애니메이션 창을 띄우기 위해 Dock 아이콘 없는 앱으로 초기화
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        if (!startAutoRotate(display)) return 1;
    }
    setPointerDetached(gOrientation != 0);

    CFRunLoopSourceRef loopSource = CFMachPortCreateRunLoopSource(NULL, gTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), loopSource, kCFRunLoopCommonModes);
    CGEventTapEnable(gTap, true);
    if (autoRotate) {
        [NSApp run];
    } else {
        CFRunLoopRun();
    }
    return 0;
}

#pragma mark - 백그라운드 프로세스 관리

static NSString *pidFilePath(void) {
    return [NSString stringWithFormat:@"/tmp/turn-%d.pid", getuid()];
}

static void stopTracker(void) {
    NSString *s = [NSString stringWithContentsOfFile:pidFilePath() encoding:NSUTF8StringEncoding error:nil];
    pid_t pid = (pid_t)[s intValue];
    if (pid > 0) kill(pid, SIGTERM);
    [[NSFileManager defaultManager] removeItemAtPath:pidFilePath() error:nil];
}

static BOOL startTracker(int displayID, int angle, BOOL autoRotate) {
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts)) {
        fprintf(stderr,
            "트랙패드 방향을 맞추려면 손쉬운 사용 권한이 필요합니다.\n"
            "시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 이 명령을 실행한 앱(터미널 등)을 허용한 뒤 다시 실행하세요.\n");
        return NO;
    }

    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return NO;

    char idArg[16], angleArg[16];
    snprintf(idArg, sizeof(idArg), "%d", displayID);
    snprintf(angleArg, sizeof(angleArg), "%d", angle);
    char *args[] = {path, autoRotate ? "--auto" : "--track", idArg, angleArg, NULL};

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    pid_t pid;
    int err = posix_spawn(&pid, path, &actions, &attr, args, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (err != 0) return NO;

    // 탭 생성에 실패하면 자식이 곧바로 종료됨
    usleep(300 * 1000);
    if (kill(pid, 0) != 0) return NO;

    [[NSString stringWithFormat:@"%d", pid] writeToFile:pidFilePath() atomically:YES
                                               encoding:NSUTF8StringEncoding error:nil];
    return YES;
}

#pragma mark - main

static void usage(void) {
    fprintf(stderr,
        "사용법: turn [0|90|180|270|reset|list|auto] [-d displayID]\n"
        "  인자 없이 실행하면 90°씩 반시계방향으로 회전합니다.\n"
        "  auto: 맥북을 돌리면 내장 가속도계로 감지해서 화면을 자동으로 회전합니다.\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 4 && (strcmp(argv[1], "--track") == 0 || strcmp(argv[1], "--auto") == 0)) {
            return runTracker((CGDirectDisplayID)strtoul(argv[2], NULL, 10), atoi(argv[3]),
                              strcmp(argv[1], "--auto") == 0);
        }

        [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MonitorPanel.framework"] load];
        Class mgrClass = NSClassFromString(@"MPDisplayMgr");
        if (!mgrClass) {
            fprintf(stderr, "MonitorPanel 프레임워크를 불러올 수 없습니다.\n");
            return 1;
        }

        NSString *command = nil;
        long targetID = -1;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) {
                targetID = strtol(argv[++i], NULL, 10);
            } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
                usage();
                return 0;
            } else {
                command = @(argv[i]);
            }
        }

        MPDisplayMgr *mgr = [[mgrClass alloc] init];
        NSArray<MPDisplay *> *displays = [mgr displays];

        if ([command isEqualToString:@"list"]) {
            for (MPDisplay *d in displays) {
                printf("%d\t%s%s\t%d°%s\n", [d displayID], [[d displayName] UTF8String],
                       [d isBuiltIn] ? " (내장)" : "", [d orientation],
                       [d canChangeOrientation] ? "" : "\t[회전 불가]");
            }
            return 0;
        }

        MPDisplay *target = nil;
        for (MPDisplay *d in displays) {
            if (targetID >= 0 ? [d displayID] == targetID : [d isBuiltIn]) { target = d; break; }
        }
        if (!target && targetID < 0) {
            for (MPDisplay *d in displays) {
                if ([d displayID] == (int)CGMainDisplayID()) { target = d; break; }
            }
        }
        if (!target) {
            fprintf(stderr, "대상 디스플레이를 찾을 수 없습니다. `turn list`로 확인하세요.\n");
            return 1;
        }
        if (![target canChangeOrientation]) {
            fprintf(stderr, "%s 화면은 회전을 지원하지 않습니다.\n", [[target displayName] UTF8String]);
            return 1;
        }

        int current = [target orientation];

        if ([command isEqualToString:@"auto"]) {
            stopTracker();
            if (!startTracker([target displayID], current, YES)) {
                fprintf(stderr, "자동 회전을 시작하지 못했습니다.\n");
                return 1;
            }
            printf("자동 회전을 켰습니다. 끄려면 turn reset 또는 원하는 각도를 입력하세요.\n");
            return 0;
        }

        int angle;
        if (command == nil) {
            angle = (current + 90) % 360;
        } else if ([command isEqualToString:@"reset"]) {
            angle = 0;
        } else {
            if (![@[@"0", @"90", @"180", @"270"] containsObject:command]) {
                usage();
                return 1;
            }
            angle = [command intValue];
        }

        stopTracker();
        [target setOrientation:angle];
        printf("%s: %d° → %d°\n", [[target displayName] UTF8String], current, angle);

        if (angle != 0) {
            if (startTracker([target displayID], angle, NO)) {
                printf("트랙패드 방향도 %d°에 맞췄습니다.\n", angle);
            } else {
                fprintf(stderr, "트랙패드 방향 보정을 시작하지 못했습니다.\n");
            }
        }
    }
    return 0;
}
