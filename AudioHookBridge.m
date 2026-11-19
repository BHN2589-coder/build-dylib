#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <string.h>

struct dyld_interpose_tuple {
    const void *replacement;
    const void *replacee;
};

static void *g_dzbAudioUnitRender = NULL;
static void *g_dzbAudioUnitGetProperty = NULL;
static void *g_origAudioUnitRender = NULL;
static void *g_origAudioUnitGetProperty = NULL;
static char g_appBundleDir[1024] = {0};

// --- PHẦN 1: XÁC ĐỊNH PHẠM VI APP & ĐỊA CHỈ HÀM GỐC ---

static void init_app_bundle_prefix(void) {
    if (g_appBundleDir[0] != '\0') return;
    const char *mainExec = _dyld_get_image_name(0);
    if (!mainExec) return;
    const char *appMarker = strstr(mainExec, ".app/");
    if (appMarker) {
        size_t len = (size_t)((appMarker - mainExec) + 5);
        if (len < sizeof(g_appBundleDir)) {
            memcpy(g_appBundleDir, mainExec, len);
            g_appBundleDir[len] = '\0';
        }
    }
}

static bool is_tweak_or_bridge_image(const char *path) {
    if (!path) return false;
    return (strstr(path, "DzbTweak") != NULL ||
            strstr(path, "thanhdoigiong") != NULL ||
            strstr(path, "AudioHookBridge") != NULL ||
            strstr(path, "LoadControl") != NULL);
}

static bool is_target_app_image(const char *path) {
    if (!path || is_tweak_or_bridge_image(path)) return false;
    init_app_bundle_prefix();
    if (g_appBundleDir[0] != '\0') {
        return strncmp(path, g_appBundleDir, strlen(g_appBundleDir)) == 0;
    }
    // Dự phòng nếu không lấy được prefix: loại trừ thư viện hệ thống
    return (strncmp(path, "/System/", 8) != 0 && strncmp(path, "/usr/lib/", 9) != 0);
}

static void resolve_dzb_interpose_pointers(void) {
    if (!g_origAudioUnitRender || !g_origAudioUnitGetProperty) {
        void *atHandle = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
        if (atHandle) {
            if (!g_origAudioUnitRender) g_origAudioUnitRender = dlsym(atHandle, "AudioUnitRender");
            if (!g_origAudioUnitGetProperty) g_origAudioUnitGetProperty = dlsym(atHandle, "AudioUnitGetProperty");
        }
        if (!g_origAudioUnitRender) g_origAudioUnitRender = dlsym(RTLD_DEFAULT, "AudioUnitRender");
        if (!g_origAudioUnitGetProperty) g_origAudioUnitGetProperty = dlsym(RTLD_DEFAULT, "AudioUnitGetProperty");
    }

    if (g_dzbAudioUnitRender && g_dzbAudioUnitGetProperty) return;

    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "DzbTweak") || strstr(name, "thanhdoigiong"))) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            if (!header || header->magic != MH_MAGIC_64) break;

            const char *segs[] = {"__DATA", "__DATA_CONST"};
            for (int s = 0; s < 2; s++) {
                unsigned long size = 0;
                struct dyld_interpose_tuple *tuples =
                    (struct dyld_interpose_tuple *)getsectiondata(header, segs[s], "__interpose", &size);

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
            }
            break;
        }
    }
}

// --- PHẦN 2: GHI ĐÈ CON TRỎ AN TOÀN (HỖ TRỢ CẢ LAZY BINDING & CHAINED FIXUPS) ---

static void patch_pointer_slot(void **slot, void *new_func, bool is_const_seg) {
    if (!slot || !new_func || *slot == new_func) return;

    uintptr_t addr = (uintptr_t)slot;
    uintptr_t page_start = addr & ~(uintptr_t)(vm_page_size - 1);

    kern_return_t kr = vm_protect(mach_task_self(),
                                  (vm_address_t)page_start,
                                  vm_page_size,
                                  false,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(),
                        (vm_address_t)page_start,
                        vm_page_size,
                        false,
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    }

    if (kr == KERN_SUCCESS) {
        *slot = new_func;
        vm_prot_t restore_prot = is_const_seg ? VM_PROT_READ : (VM_PROT_READ | VM_PROT_WRITE);
        vm_protect(mach_task_self(),
                   (vm_address_t)page_start,
                   vm_page_size,
                   false,
                   restore_prot);
    }
}

// Cách 1: Rebind theo tên symbol (bắt được cả __la_symbol_ptr trước khi app bật mic)
static void rebind_indirect_symbols(const struct mach_header_64 *header, intptr_t slide) {
    const struct segment_command_64 *linkedit_seg = NULL;
    const struct symtab_command *symtab_cmd = NULL;
    const struct dysymtab_command *dysymtab_cmd = NULL;

    uintptr_t cur = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cur;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cur;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkedit_seg = seg;
            }
        } else if (cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)cur;
        } else if (cmd->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (const struct dysymtab_command *)cur;
        }
        cur += cmd->cmdsize;
    }

    if (!linkedit_seg || !symtab_cmd || !dysymtab_cmd || dysymtab_cmd->nindirectsyms == 0) return;

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_seg->vmaddr - linkedit_seg->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);
    const uint32_t *indirect_symtab = (const uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cur;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cur;
            bool is_data = (strcmp(seg->segname, SEG_DATA) == 0);
            bool is_const = (strcmp(seg->segname, "__DATA_CONST") == 0);
            if (is_data || is_const) {
                const struct section_64 *sects = (const struct section_64 *)(cur + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    uint32_t sect_type = sects[j].flags & SECTION_TYPE;
                    if (sect_type != S_LAZY_SYMBOL_POINTERS && sect_type != S_NON_LAZY_SYMBOL_POINTERS) continue;

                    uint32_t ind_offset = sects[j].reserved1;
                    size_t count = (size_t)(sects[j].size / sizeof(void *));
                    if ((uint64_t)ind_offset + count > dysymtab_cmd->nindirectsyms) continue;

                    void **bindings = (void **)((uintptr_t)slide + sects[j].addr);
                    for (size_t k = 0; k < count; k++) {
                        uint32_t sym_idx = indirect_symtab[ind_offset + k];
                        if (sym_idx == INDIRECT_SYMBOL_ABS ||
                            sym_idx == INDIRECT_SYMBOL_LOCAL ||
                            sym_idx == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
                            continue;
                        }
                        if (sym_idx >= symtab_cmd->nsyms) continue;
                        uint32_t str_off = symtab[sym_idx].n_un.n_strx;
                        if (str_off >= symtab_cmd->strsize) continue;

                        const char *sym_name = strtab + str_off;
                        if (g_dzbAudioUnitRender && strcmp(sym_name, "_AudioUnitRender") == 0) {
                            patch_pointer_slot(&bindings[k], g_dzbAudioUnitRender, is_const);
                        } else if (g_dzbAudioUnitGetProperty && strcmp(sym_name, "_AudioUnitGetProperty") == 0) {
                            patch_pointer_slot(&bindings[k], g_dzbAudioUnitGetProperty, is_const);
                        }
                    }
                }
            }
        }
        cur += cmd->cmdsize;
    }
}

// Cách 2: Quét trực tiếp con trỏ đã bind sẵn (hỗ trợ Chained Fixups)
static void scan_direct_pointers(const struct mach_header_64 *header) {
    const char *segments[] = {"__DATA_CONST", "__DATA"};
    const char *sections[] = {"__got", "__la_symbol_ptr", "__nl_symbol_ptr"};

    for (int s = 0; s < 2; s++) {
        bool is_const = (s == 0);
        for (int c = 0; c < 3; c++) {
            unsigned long size = 0;
            void **section_ptr = (void **)getsectiondata(header, segments[s], sections[c], &size);
            if (!section_ptr || size == 0) continue;

            size_t count = size / sizeof(void *);
            for (size_t i = 0; i < count; i++) {
                if (g_dzbAudioUnitRender && g_origAudioUnitRender && section_ptr[i] == g_origAudioUnitRender) {
                    patch_pointer_slot(&section_ptr[i], g_dzbAudioUnitRender, is_const);
                } else if (g_dzbAudioUnitGetProperty && g_origAudioUnitGetProperty && section_ptr[i] == g_origAudioUnitGetProperty) {
                    patch_pointer_slot(&section_ptr[i], g_dzbAudioUnitGetProperty, is_const);
                }
            }
        }
    }
}

static void hook_single_image(const struct mach_header_64 *header64, intptr_t slide, const char *imagePath) {
    if (!header64 || header64->magic != MH_MAGIC_64) return;
    if (!is_target_app_image(imagePath)) return;

    resolve_dzb_interpose_pointers();
    if (!g_dzbAudioUnitRender && !g_dzbAudioUnitGetProperty) return;

    rebind_indirect_symbols(header64, slide);
    scan_direct_pointers(header64);
}

static void sweep_app_images(void) {
    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!is_target_app_image(name)) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        hook_single_image(header, slide, name);
    }
}

// --- PHẦN 3: KHÓA HƯỚNG XOAY ĐỒNG BỘ VỚI ỨNG DỤNG CHÍNH ---

static UIWindow *find_main_app_window(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *winScene = (UIWindowScene *)scene;
        for (UIWindow *win in winScene.windows) {
            if (win.hidden) continue;
            NSString *winCls = NSStringFromClass([win class]);
            if ([winCls hasPrefix:@"Dzb"]) continue;
            if (win.rootViewController && ![NSStringFromClass([win.rootViewController class]) hasPrefix:@"Dzb"]) {
                return win;
            }
        }
    }
    return nil;
}

static UIInterfaceOrientation get_current_scene_orientation(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *winScene = (UIWindowScene *)scene;
            if (@available(iOS 26.0, *)) {
                return winScene.effectiveGeometry.interfaceOrientation;
            } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                return winScene.interfaceOrientation;
#pragma clang diagnostic pop
            }
        }
    }
    return UIInterfaceOrientationUnknown;
}

static UIInterfaceOrientationMask fixed_supportedInterfaceOrientations(id self, SEL _cmd) {
    UIWindow *mainWin = find_main_app_window();
    if (mainWin && mainWin.rootViewController && mainWin.rootViewController != self) {
        UIInterfaceOrientationMask mask = [mainWin.rootViewController supportedInterfaceOrientations];
        if (mask != 0) return mask;
    }

    UIInterfaceOrientation cur = get_current_scene_orientation();
    if (UIInterfaceOrientationIsLandscape(cur)) {
        return UIInterfaceOrientationMaskLandscape;
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

static BOOL fixed_shouldAutorotate(id self, SEL _cmd) {
    UIWindow *mainWin = find_main_app_window();
    if (mainWin && mainWin.rootViewController && mainWin.rootViewController != self) {
        return [mainWin.rootViewController shouldAutorotate];
    }
    return YES;
}

static UIInterfaceOrientation fixed_preferredInterfaceOrientationForPresentation(id self, SEL _cmd) {
    UIInterfaceOrientation cur = get_current_scene_orientation();
    if (cur != UIInterfaceOrientationUnknown) {
        return cur;
    }
    return UIInterfaceOrientationLandscapeRight;
}

static void fixed_makeKeyAndVisible(id self, SEL _cmd) {
    [(UIWindow *)self setHidden:NO];
}

static void patchDzbOrientationBehavior(void) {
    NSArray<NSString *> *vcClasses = @[@"DzbOverlayVC", @"DzbSettingsVC", @"DzbVCamPreview"];
    for (NSString *clsName in vcClasses) {
        Class cls = NSClassFromString(clsName);
        if (cls && [cls isSubclassOfClass:[UIViewController class]]) {
            class_replaceMethod(cls,
                                @selector(supportedInterfaceOrientations),
                                (IMP)fixed_supportedInterfaceOrientations,
                                "Q@:");
            class_replaceMethod(cls,
                                @selector(shouldAutorotate),
                                (IMP)fixed_shouldAutorotate,
                                "B@:");
            class_replaceMethod(cls,
                                @selector(preferredInterfaceOrientationForPresentation),
                                (IMP)fixed_preferredInterfaceOrientationForPresentation,
                                "q@:");
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

// --- PHẦN 4: ĐĂNG KÝ CALLBACK & KHỞI TẠO ---

static void on_image_loaded(const struct mach_header *mh, intptr_t slide) {
    @autoreleasepool {
        Dl_info info;
        const char *fname = (dladdr(mh, &info) && info.dli_fname) ? info.dli_fname : NULL;
        if (fname && (strstr(fname, "DzbTweak") || strstr(fname, "thanhdoigiong"))) {
            resolve_dzb_interpose_pointers();
            sweep_app_images();
            patchDzbOrientationBehavior();
            return;
        }
        hook_single_image((const struct mach_header_64 *)mh, slide, fname);
    }
}

static void ensureDefaultVoiceSettings(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"Dzb_VoiceChangerEnabled"] == nil) {
        [defaults setBool:YES forKey:@"Dzb_VoiceChangerEnabled"];
    }
    if ([defaults objectForKey:@"Dzb_VirtualCamEnabled"] == nil) {
        [defaults setBool:NO forKey:@"Dzb_VirtualCamEnabled"];
    }
    [defaults synchronize];
}

__attribute__((constructor))
static void init_AudioHookBridge(void) {
    @autoreleasepool {
        init_app_bundle_prefix();
        resolve_dzb_interpose_pointers();
        sweep_app_images();
        patchDzbOrientationBehavior();
        _dyld_register_func_for_add_image(on_image_loaded);
        ensureDefaultVoiceSettings();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            resolve_dzb_interpose_pointers();
            sweep_app_images();
            patchDzbOrientationBehavior();
        });
    }
}
