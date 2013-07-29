//
//  NTracker.m
//  BaiduMobStatSample
//
//  Created by Miller on 13-7-8.
//
//
#import "NTracker.h"
#import "NSession.h"
#import "NLogConfig.h"
#import "NStringExtension.h"
#import "OpenUDID.h"

static NSMutableDictionary * trackers = nil;

@implementation NTracker

@synthesize name;

- (id)initWithId:(NSString *)trackerId{
    self = [super init];
    
    if (self) {
        self.name = [trackerId retain];
        
        isHit = NO;
        needCalc = YES;
        
        [self start];
        
        sampleRate = [[NLogConfig get:@"sampleRate" subkey:trackerId] doubleValue];
        
        fields = [[[NSMutableDictionary alloc] init] retain];
        
        // 设置默认服务器路径
        [fields setValue:[NLogConfig get:@"receiverUrl"] forKey:@"receiverUrl"];
        
        /*默认GET字段*/
        
        // 数据版本
        [fields setValue:[NSNumber numberWithInt:LOG_FORMAT_VERSION] forKey:@"v"];
        
        // 分辨率
        [fields setValue:@"TODO" forKey:@"s"];
        
        // 机器类别
        [fields setValue:@"TODO" forKey:@"mc"];
        
        // 网络类型
        [fields setValue:@"TODO" forKey:@"l"];
        
        // 运营商
        [fields setValue:@"TODO" forKey:@"op"];
        
        // 系统版本
        [fields setValue:@"TODO" forKey:@"sv"];
        
        durations = [[NSMutableDictionary alloc] init];
    }
    
    return self;
}

- (void)start{
    running = YES;
}

- (void)stop{
    running = NO;
}

- (void) send:(NSString *)hitType params:(NSDictionary *)params{
    [self send:hitType params:params immediately:NO];
}

- (void) send:(NSString *)hitType params:(NSDictionary *)params immediately:(BOOL)now{
    if (running == NO || ![self isHitRate]) {
        NSLog(@"MAC Address not hit the rate, so no data sent.");
        return;
    }
    
    params = [self applyFieldsProtocol:params];
        
    NSMutableDictionary* mutableParams = [NSMutableDictionary dictionaryWithDictionary:params];
    
    /*增加保留字段*/
    
    // session id
    [mutableParams setValue:[NSession getId] forKey:@"sid"];
    
    // session序号
    [mutableParams setValue:[NSNumber numberWithInt:[NSession getSeq]] forKey:@"seq"];
    
    // 时间戳
    [mutableParams setValue:[NSNumber numberWithLongLong:CurrentTimeMillis] forKey:@"t"];
    
    // 类型
    [mutableParams setValue:hitType forKey:@"ht"];
    
    // PASSPORT ID
    [mutableParams setValue:@"TODO" forKey:@"paid"];
    
    [[NSNotificationCenter defaultCenter]
     postNotificationName:@"NLOG_TRACKER_SEND"
     object:nil
     userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
            mutableParams,@"params",
            [self applyFieldsProtocol:fields],@"fields",
            name,@"name",
            [NSNumber numberWithBool:now],@"sendNow",
                nil]];

}

- (void) sendEvent:(NSString *)category
            action:(NSString *)action
             label:(NSString *)label
             value:(NSNumber *)value{
    
    NSString *hitType = @"event";
    
    NSMutableDictionary* params = [[NSMutableDictionary alloc] init];
    [params setValue:category forKey:@"eventCategory"];
    [params setValue:action forKey:@"eventAction"];
    [params setValue:label forKey:@"eventLabel"];
    [params setValue:value forKey:@"eventValue"];
    
    [self send:hitType params:params];
}

- (void) sendException:(NSString *)description
               isFatal:(Boolean)isFatal
                params:(NSDictionary *)params{
    
    NSString *hitType = @"exception";
    
    if (params == nil) {
        params = [[NSMutableDictionary alloc] init];
    }
    else {
        params = [NSMutableDictionary dictionaryWithDictionary:params];
    }
    
    [params setValue:description forKey:@"exDescription"];
    [params setValue:[NSNumber numberWithBool:isFatal] forKey:@"exFatal"];

    [self send:hitType params:params];
}

- (void) sendTiming:(NSString *)category
          interval:(NSTimeInterval)interval
              name:(NSString *)logName
             label:(NSString *)label{
    
    NSString *hitType = @"timing";
    
    NSMutableDictionary* params = [[NSMutableDictionary alloc] init];
    [params setValue:category forKey:@"tmCategory"];
    [params setValue:[NSNumber numberWithInt:(int)interval] forKey:@"tmInterval"];
    [params setValue:logName forKey:@"tmName"];
    [params setValue:label forKey:@"tmLabel"];
    
    [self send:hitType params:params];
}

- (void) sendView:(NSString *)viewName params:(NSDictionary *)params{
    
    NSString *hitType = @"appview";
    
    if (params == nil) {
        params = [[NSMutableDictionary alloc] init];
    }
    else {
        params = [NSMutableDictionary dictionaryWithDictionary:params];
    }
    
    [params setValue:viewName forKey:@"appScreen"];
    
    [self send:hitType params:params];

}

- (void) setSampleRate:(double) rate{
    sampleRate = rate;
    needCalc = YES;
}

- (void) set:(NSDictionary *)params{
    if (params == nil) {
        return;
    }
    
    for(id key in params){
        [self set:key value:[params objectForKey:key]];
//        [fields setValue:[params objectForKey:key] forKey:key];
    }
}

- (void) set:(NSString *)key value:(id)val{
    @synchronized(self) {
        if ([key isEqualToString:@"protocolParameter"] && [val isKindOfClass:[NSDictionary class]]) {
            [self setFieldsProtocol:val];
            return;
        }
        [fields setValue:val forKey:key];
    }
}

- (void) setFieldsProtocol:(NSDictionary *)map{
    fieldsProtocol = [map retain];
}

- (NSDictionary *) applyFieldsProtocol:(NSDictionary *) params{
    if (!fieldsProtocol) {
        return params;
    }
    
    NSMutableDictionary* result = [[NSMutableDictionary alloc] init];
    
    for( id key in params) {
        NSString* mappedField = [fieldsProtocol objectForKey:key];
        
        if (mappedField) {
            [result setObject:[params objectForKey:key] forKey:mappedField];
        }
        else {
            [result setObject:[params objectForKey:key] forKey:key];
        }
    }
    
    return [NSDictionary dictionaryWithDictionary:result];
}

/**
 * 思路：根据MAC地址获得最后两位16进制数字，转10进制（范围0-255）
 * 根据命中率计算尾数命中范围( 1 <= (x + 1) <= round(命中率 * 256) )
 * 例如：如果命中率为 0.1，则MAC地址最后数字为 0 - 25的会命中
        如果命中率为 1，则MAC地址最后数字为 0 - 255的会命中
        如果命中率为 0，则无MAC地址会命中
 */
- (BOOL) isHitRate{
        
    if (!needCalc) {
        return isHit;
    }
    
    needCalc = NO;
    
    NSString* openuuid = [OpenUDID value];
    NSString* lastDigital = [openuuid substringFromIndex:[openuuid length] - 2];
    
    unsigned hitTail = 0;
    NSScanner *scanner = [NSScanner scannerWithString:lastDigital];
    [scanner scanHexInt: &hitTail];
    
    double rate = sampleRate;
    double max = round(rate * 256) * 1.0;
    
    /*
    NSLog(@"Mac Address:%@", macAddr);
    NSLog(@"Hit tail:%u", hitTail);
    NSLog(@"Rate:%f", rate);
    NSLog(@"Max:%f", max);
    */
    
    hitTail++;
    
    return isHit = ( hitTail >= 1 && hitTail <= max );
}

- (void) logDurationStart:(NSString *)label{
    if (!label) {
        return;
    }
    [durations setValue:[NSNumber numberWithLongLong:CurrentTimeMillis] forKey:label];
}

- (void) logDurationEnd:(NSString *)label{
    long long start;
    
    if (!label || !(start = [[durations valueForKey:label] longLongValue])) {
        return;
    }
    
    long long now = CurrentTimeMillis;
    double duration = (double)(now - start);
    
    [self sendTiming:nil interval:duration name:nil label:label];
}

+ (NTracker *) getTracker:(NSString *)trackerId{
    NTracker* tracker = nil;
    
    if (trackers != nil) {
        tracker = [trackers objectForKey:trackerId];
    }
    else {
        trackers = [[NSMutableDictionary alloc] init];
    }
    
    if (tracker == nil) {
        tracker = [[NTracker alloc] initWithId:trackerId];
        [trackers setValue:tracker forKey:trackerId];
    }
    
    return tracker;
}

- (void) dealloc{
    [fields release];
    [durations release];
    
    if (fieldsProtocol) {
        [fieldsProtocol release];
    }
    [super dealloc];
}

@end