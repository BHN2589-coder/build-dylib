#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <objc/message.h>
#import <objc/runtime.h>

struct dyld_interpose_tuple {
    const void *replacement;
    const void *replacee;
};

static void *g_dzbAudioUnitRender = NULL;
static void *g_dzbAudioUnitGetProperty = NULL;
static void *g_origAudioUnitRender = NULL;
static void *g_origAudioUnitGetProperty = NULL;

static void resolve_dzb_interpose_pointers(void) {
    if (!g_origAudioUnitRender) {
        g_origAudioUnitRender = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    }
    if (!g_origAudioUnitGetProperty) {
        g_origAudioUnitGetProperty = dlsym(RTLD_DEFAULT, "AudioUnitGetProperty");
    }

    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "DzbTweak") || strstr(name, "thanhdoigiong"))) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            if (!header || header->magic != MH_MAGIC_64) break;

            unsigned long size = 0;
            struct dyld_interpose_tuple *tuples =
                (struct dyld_interpose_tuple *)getsectiondata(header, "__DATA", "__interpose", &size);

            if (tuples && size >= sizeof(struct dyld_interpose_tuple)) {
                size_t count = size / sizeof(struct dyld_interpose_tuple);
                for (size_t j = 0; j < count; j++) {
                    if (tuples[j].replacee == g_origAudioUnitRender && tuples[j].replacement) {
                        g_dzbAudioUnitRender = (void *)tuples[j].replacement;
                    } else if (tuples[j].replacee == g_origAudioUnitGetProperty && tuples[j].replacement) {
                        g_dzbAudioUnitGetProperty = (void *)tuples[j].replacement;
                    }
                }
            }
            break;
        }
    }
}

static void replace_pointers_in_section(const struct mach_header_64 *header,
                                        const char *segname,
                                        const char *sectname,
                                        void *orig_func,
                                        void *new_func) {
    if (!orig_func || !new_func || !header) return;

    unsigned long size = 0;
    void **section_ptr = (void **)getsectiondata(header, segname, sectname, &size);
    if (!section_ptr || size == 0) return;

    size_t count = size / sizeof(void *);
    for (size_t i = 0; i < count; i++) {
        if (section_ptr[i] == orig_func) {
            uintptr_t addr = (uintptr_t)&section_ptr[i];
            uintptr_t page_start = addr & ~(PAGE_SIZE - 1);

            kern_return_t kr = vm_protect(mach_task_self(),
                                          (vm_address_t)page_start,
                                          PAGE_SIZE,
                                          false,
                                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            if (kr == KERN_SUCCESS) {
                section_ptr[i] = new_func;
                vm_protect(mach_task_self(),
                           (vm_address_t)page_start,
                           PAGE_SIZE,
                           false,
                           VM_PROT_READ | VM_PROT_DEFAULT);
            }
        }
    }
}

static void hook_single_image_header(const struct mach_header_64 *header64, const char *imagePath) {
    if (!header64 || header64->magic != MH_MAGIC_64) return;
    if (imagePath && (strstr(imagePath, "DzbTweak") || strstr(imagePath, "thanhdoigiong") || strstr(imagePath, "AudioHookBridge"))) {
        return;
    }

    resolve_dzb_interpose_pointers();
    if (!g_dzbAudioUnitRender && !g_dzbAudioUnitGetProperty) return;

    const char *segments[] = {"__DATA_CONST", "__DATA", "__AUTH_CONST", "__AUTH"};
    const char *sections[] = {"__got", "__la_symbol_ptr", "__nl_symbol_ptr", "__const"};

    for (int s = 0; s < 4; s++) {
        for (int c = 0; c < 4; c++) {
            if (g_dzbAudioUnitRender && g_origAudioUnitRender) {
                replace_pointers_in_section(header64, segments[s], sections[c], g_origAudioUnitRender, g_dzbAudioUnitRender);
            }
            if (g_dzbAudioUnitGetProperty && g_origAudioUnitGetProperty) {
                replace_pointers_in_section(header64, segments[s], sections[c], g_origAudioUnitGetProperty, g_dzbAudioUnitGetProperty);
            }
        }
    }
}

static void sweep_all_loaded_images(void) {
    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        hook_single_image_header(header, name);
    }
}

static void on_image_loaded(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    const char *fname = (dladdr(mh, &info) && info.dli_fname) ? info.dli_fname : NULL;
    hook_single_image_header((const struct mach_header_64 *)mh, fname);
}

static UIInterfaceOrientationMask fixed_supportedInterfaceOrientations(id self, SEL _cmd) {
    UIInterfaceOrientationMask appMask = [[UIApplication sharedApplication] supportedInterfaceOrientationsForWindow:nil];
    if (appMask != 0) {
        return appMask;
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIInterfaceOrientation orientation = ((UIWindowScene *)scene).interfaceOrientation;
            if (UIInterfaceOrientationIsLandscape(orientation)) {
                return UIInterfaceOrientationMaskLandscape;
            }
        }
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

static BOOL fixed_shouldAutorotate(id self, SEL _cmd) {
    return NO;
}

static void fixed_makeKeyAndVisible(id self, SEL _cmd) {
    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setHidden:), NO);
}

static void patchDzbOrientationBehavior(void) {
    NSArray *vcClasses = @[@"DzbOverlayVC", @"DzbCallPanel", @"DzbSettingsVC", @"DzbNav"];
    for (NSString *clsName in vcClasses) {
        Class cls = NSClassFromString(clsName);
        if (cls) {
            class_replaceMethod(cls,
                                @selector(supportedInterfaceOrientations),
                                (IMP)fixed_supportedInterfaceOrientations,
                                "Q@:");
            class_replaceMethod(cls,
                                @selector(shouldAutorotate),
                                (IMP)fixed_shouldAutorotate,
                                "B@:");
        }
    }

    Class winCls = NSClassFromString(@"DzbPassthroughWindow");
    if (winCls) {
        class_replaceMethod(winCls,
                            @selector(makeKeyAndVisible),
                            (IMP)fixed_makeKeyAndVisible,
                            "v@:");
        class_replaceMethod(winCls,
                            @selector(makeKeyWindow),
                            (IMP)fixed_makeKeyAndVisible,
                            "v@:");
    }
}

static void ensureVoiceChangerState(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"Dzb_VoiceChangerEnabled"];
    if ([defaults integerForKey:@"Dzb_VoiceType"] == 0) {
        [defaults setInteger:1 forKey:@"Dzb_VoiceType"];
    }
    if ([defaults objectForKey:@"Dzb_VirtualCamEnabled"] == nil) {
        [defaults setBool:NO forKey:@"Dzb_VirtualCamEnabled"];
    }
    [defaults synchronize];

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                       error:&err];
    }
    [session setActive:YES error:&err];
}

__attribute__((constructor))
static void init_AudioHookBridge(void) {
    resolve_dzb_interpose_pointers();
    sweep_all_loaded_images();
    _dyld_register_func_for_add_image(on_image_loaded);
    ensureVoiceChangerState();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolve_dzb_interpose_pointers();
        sweep_all_loaded_images();
        ensureVoiceChangerState();
        patchDzbOrientationBehavior();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolve_dzb_interpose_pointers();
        sweep_all_loaded_images();
        patchDzbOrientationBehavior();
    });
}
