#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>

static NSDictionary *BuildInfo(id response) {
    if (!response) return nil;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSNumber *rate = [response valueForKey:@"playbackRate"];
    if (rate) info[@"playbackRate"] = rate;
    id queue = [response valueForKey:@"playbackQueue"];
    if (!queue) return info.count ? info : nil;
    NSArray *items = [queue valueForKey:@"contentItems"];
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return info.count ? info : nil;
    NSNumber *location = [queue valueForKey:@"location"];
    NSInteger index = location.integerValue;
    id item = (index >= 0 && index < (NSInteger)items.count) ? items[(NSUInteger)index] : items.firstObject;
    id meta = [item valueForKey:@"metadata"];
    if (!meta) return info.count ? info : nil;
    void (^add)(NSString *, NSString *) = ^(NSString *source, NSString *key) {
        id value = [meta valueForKey:source];
        if (value && value != [NSNull null]) info[key] = value;
    };
    add(@"title", @"title");
    add(@"trackArtistName", @"artist");
    add(@"albumName", @"album");
    add(@"duration", @"duration");
    add(@"elapsedTime", @"elapsedTime");
    NSNumber *state = [response valueForKey:@"playbackState"];
    if (state) info[@"isPlaying"] = @(state.unsignedIntegerValue == 1);
    return info.count ? info : nil;
}

static NSDictionary *Query(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW | RTLD_GLOBAL);
    if (!handle) return nil;
    Class destClass = NSClassFromString(@"MRDestination");
    Class configClass = NSClassFromString(@"MRNowPlayingControllerConfiguration");
    Class controllerClass = NSClassFromString(@"MRNowPlayingController");
    if (!destClass || !configClass || !controllerClass) return nil;
    id destination = [destClass performSelector:NSSelectorFromString(@"userSelectedDestination")];
    id config = [[configClass alloc] performSelector:NSSelectorFromString(@"initWithDestination:") withObject:destination];
    [config setValue:@NO forKey:@"singleShot"];
    [config setValue:@YES forKey:@"requestPlaybackState"];
    [config setValue:@YES forKey:@"requestPlaybackQueue"];
    id controller = [[controllerClass alloc] performSelector:NSSelectorFromString(@"initWithConfiguration:") withObject:config];
    [controller performSelector:NSSelectorFromString(@"beginLoadingUpdates")];
    NSDictionary *result = nil;
    for (int i = 0; i < 24; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        result = BuildInfo([controller valueForKey:@"response"]);
        if (result) break;
    }
    [controller performSelector:NSSelectorFromString(@"endLoadingUpdates")];
    return result;
}

static void SendCommand(long command) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!handle) return;
    typedef Boolean (*SendFn)(long, NSDictionary *);
    SendFn send = (SendFn)dlsym(handle, "MRMediaRemoteSendCommand");
    if (send) send(command, nil);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        if (argc < 2) { printf("{}\n"); return 0; }
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        if ([command isEqualToString:@"play"]) { SendCommand(0); return 0; }
        if ([command isEqualToString:@"pause"]) { SendCommand(1); return 0; }
        if ([command isEqualToString:@"next"]) { SendCommand(4); return 0; }
        if ([command isEqualToString:@"previous"]) { SendCommand(5); return 0; }
        NSDictionary *info = Query();
        NSData *data = [NSJSONSerialization dataWithJSONObject:info ?: @{} options:0 error:nil];
        if (data) fwrite(data.bytes, 1, data.length, stdout);
        printf("\n");
    }
    return 0;
}
