#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <objc/message.h>

struct dyld_interpose_tuple {
    const void *replacement;
    const void *replacee;
};

static void *g_dzbAudioUnitRender = NULL;
static void *g_dzbAudioUnitGetProperty = NULL;

static void replace_pointers_in_section(const struct mach_header_64 *header,
                                        intptr_t slide,
                                        const char *segname,
                                        const char *sectname,
                                        void *orig_func,
                                        void *new_func) {
    if (!orig_func || !new_func) return;
    
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

static void on_image_loaded(const struct mach_header *mh, intptr_t slide) {
    if (mh->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *header64 = (const struct mach_header_64 *)mh;

    Dl_info info;
    if (dladdr(mh, &info) && info.dli_fname) {
        if (strstr(info.dli_fname, "DzbTweak") || strstr(info.dli_fname, "thanhdoigiong")) {
            return;
        }
    }

    void *origRender = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    void *origGetProp = dlsym(RTLD_DEFAULT, "AudioUnitGetProperty");

    const char *segments[] = {"__DATA_CONST", "__DATA"};
    const char *sections[] = {"__got", "__la_symbol_ptr", "__nl_symbol_ptr"};

    for (int s = 0; s < 2; s++) {
        for (int c = 0; c < 3; c++) {
            replace_pointers_in_section(header64, slide, segments[s], sections[c], origRender, g_dzbAudioUnitRender);
            replace_pointers_in_section(header64, slide, segments[s], sections[c], origGetProp, g_dzbAudioUnitGetProperty);
        }
    }
}

static void forceShowDzbUIForGames(void) {
    // Chặn ép bật UI overlay trên Liên Quân Mobile để tránh lỗi xoay dọc màn hình
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

__attribute__((constructor))
static void init_AudioHookBridge(void) {
    void *origRender = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    void *origGetProp = dlsym(RTLD_DEFAULT, "AudioUnitGetProperty");

    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "DzbTweak") || strstr(name, "thanhdoigiong"))) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            unsigned long size = 0;
            struct dyld_interpose_tuple *tuples = (struct dyld_interpose_tuple *)getsectiondata(header, "__DATA", "__interpose", &size);
            
            if (tuples && size >= sizeof(struct dyld_interpose_tuple)) {
                size_t count = size / sizeof(struct dyld_interpose_tuple);
                for (size_t j = 0; j < count; j++) {
                    if (tuples[j].replacee == origRender) {
                        g_dzbAudioUnitRender = (void *)tuples[j].replacement;
                    } else if (tuples[j].replacee == origGetProp) {
                        g_dzbAudioUnitGetProperty = (void *)tuples[j].replacement;
                    }
                }
            }
            break;
        }
    }

    if (g_dzbAudioUnitRender) {
        _dyld_register_func_for_add_image(on_image_loaded);
    }
    
    forceShowDzbUIForGames();
}
