static void forceShowDzbUIForGames(void) {
    // Kiểm tra nếu là Liên Quân Mobile thì bỏ qua việc ép bật UI overlay để tránh lỗi xoay dọc
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.garena.game.kgvn"]) {
        return; 
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"Dzb_VoiceChangerEnabled"];
    [defaults setBool:YES forKey:@"Dzb_VirtualCamEnabled"];
    [defaults synchronize];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSArray *classNames = @[@"DzbOverlayVC", @"DzbCallPanel", @"Dzb"];
        for (NSString *className in classNames) {
            Class targetClass = NSClassFromString(className);
            if (targetClass) {
                id instance = nil;
                if ([targetClass respondsToSelector:@selector(shared)]) {
                    instance = ((id(*)(id, SEL))objc_msgSend)(targetClass, @selector(shared));
                } else if ([targetClass respondsToSelector:@selector(sharedInstance)]) {
                    instance = ((id(*)(id, SEL))objc_msgSend)(targetClass, @selector(sharedInstance));
                }
                if (instance) {
                    if ([instance respondsToSelector:@selector(ensureWindow)]) {
                        ((void(*)(id, SEL))objc_msgSend)(instance, @selector(ensureWindow));
                    }
                    if ([instance respondsToSelector:@selector(showForVideoCall:)]) {
                        ((void(*)(id, SEL, BOOL))objc_msgSend)(instance, @selector(showForVideoCall:), YES);
                    }
                    break;
                }
            }
        }
    });
}
