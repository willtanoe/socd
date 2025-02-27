/*
Le NumPad handling
NumLock gets pressed and released before every key that's numlocked. it has LL_KF_EXTENDED flag
then, an actual key gets pressed and released, it doesn't have LL_KF_EXTENDED flag
Then, NumLock gets pressed and released AGAIN.

This is handled as a single logical key press (and release).

When a key is held down, we first get a numlock (scanCode == 69 or 0x40) press/release,
then actual key presses, while you're holding it.
Then a key release.
Then, numlock press and release.

If you interrupt a key that you hold by some other numpad key, you don't get an intermediate numlock press/release,
you just get keycodes for other key without an extended flag, and only then numlock press/release

If you interrupt a repeating numpad key with some key not on a numpad, they receive inputs in order. But numlock key only clears
after you release the numpad key. So you have to assume that initial numlock only applies to the key code that immediately follows it.
And any other key code is not numlocked. And non-numlocked key can have extended key flags on it.
*/
CURRENT_PLATFORM :: Platform.WINDOWS;

// TODO: input exposes the same names.
KEY_RESERVED : u32 : 0;
MAX_PATH_LENGTH :: MAX_PATH;
HIDDEN_WINDOW_CLASS := "HIDDEN_WINDOW_CLASS";
mapping_resolving_hook: HHOOK;
mapping_setting_hook: HHOOK;

// TODO: these buffers should probably be thread(context)-locals. Just in case...
key_name_buffer: [301]u16;
// 0xe1ff is the biggest theoretical key code with an extended byte set.
// GetAsyncKeyState is not available in low level keyboard procedures, so we need to maintain our own.
kb_real_state: [57856]bool; // whether the key is pressed on a physical keyboard

tray_info: NOTIFYICONDATAW;

scan_code_to_lparam :: (scan_code: u32) -> u32 {
    // Extended key is handled in keyboard hooks
    lparam := scan_code << 16;
    return lparam;
}

// Returns textual name of the key in UTF8
get_key_name :: (key_scan_code: u32) -> string {
    if key_scan_code == KEY_RESERVED return "...";
    cached := KEY_NAMES[key_scan_code];
    if cached {
        return cached;
    }

    lparam := scan_code_to_lparam(key_scan_code);
    length := GetKeyNameTextW(lparam, key_name_buffer.data, key_name_buffer.count);
    if length == 0 {
        error := GetLastError();
        log_error("Couldn't get the key name for the key with scancode %. Error is %\n", key_scan_code, error);
        return "KEY ERROR";
    }
    key_name, ok := wide_to_utf8(key_name_buffer.data, length);
    if !ok {
        error := GetLastError();
        log_error("Couldn't convert the key name to UTF8 for scancode %. Buffer content is %. Error is %\n", key_scan_code, key_name_buffer, error);
        return "KEY ERROR";
    }
    KEY_NAMES[key_scan_code] = key_name;
    return key_name;
}


start_logging_keys :: () {
    //
}


// TODO: Try to find a way to be more optimal (like bailing out earlier) on key repeats:
// https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc
low_level_keyboard_proc :: (n_code: s32, wparam: WPARAM, lparam: LPARAM) -> s64 #c_call {
    push_my_context();
    kb_input := cast(*KBDLLHOOKSTRUCT)lparam;

    // We ignore injected events so we don't mess with the inputs
    // we inject ourselves with SendInput.
    // TODO maybe it's better to set our own custom extended info and check it
    // instead of LLKHF_INJECTED so we know FOR SURE it's ours
    if n_code != HC_ACTION || kb_input.flags & LLKHF_INJECTED {
        return CallNextHookEx(null, n_code, wparam, lparam);
    }

    key_virtual_code := kb_input.vkCode;
    key_scan_code := kb_input.scanCode;

    // 69 is numlock, just swallow it. Depend on LLKF_EXTENDED instead,
    // because numlocked keys don't have it set...
    if key_scan_code == 69 {
        return CallNextHookEx(null, n_code, wparam, lparam);
    }
    is_down := ifx wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN then true else false;
    if kb_input.flags & .LLKHF_EXTENDED {
        // We're adding 0xE100 to the scancode to signify that it's "EXTENDED".
        // This lets procedures like GetKeyNameTextW to correctly distinguish between
        // arrows and numpad keys, for example. Becuase Windows is fucking dogshit ass garbage that decided
        // to reuse the same scancodes between those keys. Another W for Linux.
        key_scan_code |= 0xE100;
    }

    recorded_state := kb_real_state[key_scan_code];

#if DEBUG {
    key_name := get_key_name(key_scan_code);
    if is_down {
        log("Pressed: %\n", key_name);
    } else {
        log("Released: %\n", key_name);
    }
}

    is_repeat := recorded_state && is_down;

    kb_real_state[key_scan_code] = is_down;

    bind := get_key_mapping(key_scan_code);
    if bind == dummy_bind {
        return CallNextHookEx(null, n_code, wparam, lparam);
    }

    extended := bind.code & 0xE100;
    bind_scan := bind.code & 0x00FF;

    if bind.mode == .REMAP {
        flags : KEYBDINPUT_Flags = ifx is_down then xx 0 else .KEYEVENTF_KEYUP;
        flags |= ifx extended then .KEYEVENTF_EXTENDEDKEY else xx 0;
        flags |= .KEYEVENTF_SCANCODE;

        input: INPUT;
        input.type = .INPUT_KEYBOARD;
        input.ki = KEYBDINPUT.{0, cast(u16)bind_scan, flags, 0, null};
        events_count := SendInput(1, *input, size_of(INPUT));
        if events_count == 0 {
            error := GetLastError();
            log_error("SendInput failed with error: %\n", error);
        }
        // Returning non-zero means that we don't want the original key to get propagated
        return 1;
    }
    if bind.mode == .OPPOSITE || bind.mode == .NEUTRAL {
        // Get the state of the opposite key
        opposite_is_down := kb_real_state[bind.code];

        if is_down {
            if opposite_is_down {
                if !is_repeat {
#if DEBUG {
                    log("Releasing opposite: %\n", get_key_name(bind_scan));
}
                    flags : KEYBDINPUT_Flags = .KEYEVENTF_KEYUP;
                    flags |= ifx extended then .KEYEVENTF_EXTENDEDKEY else xx 0;
                    flags |= .KEYEVENTF_SCANCODE;

                    input: INPUT;
                    input.type = .INPUT_KEYBOARD;
                    input.ki = KEYBDINPUT.{0, cast(u16)bind_scan, flags, 0, null};
                    events_count := SendInput(1, *input, size_of(INPUT));

                    if events_count == 0 {
                        error := GetLastError();
                        log_error("SendInput failed with error: %\n", error);
                    }
                } else {
#if DEBUG {
                    log("Detected repeat event for %\n", key_name);
}
                }

                if bind.mode == .NEUTRAL {
                    // Do not propagate the original key if it's meant to cancel out
                    return 1;
                }

            }
        } else {
            if opposite_is_down {
#if DEBUG {
                log("Pressing opposite: %\n", get_key_name(bind_scan));
}
                flags : KEYBDINPUT_Flags = 0;
                flags |= ifx extended then .KEYEVENTF_EXTENDEDKEY else xx 0;
                flags |= .KEYEVENTF_SCANCODE;

                input: INPUT;
                input.type = .INPUT_KEYBOARD;
                input.ki = KEYBDINPUT.{0, cast(u16)bind_scan, flags, 0, null};
                events_count := SendInput(1, *input, size_of(INPUT));

                if events_count == 0 {
                    error := GetLastError();
                    log_error("SendInput failed with error: %\n", error);
                }
            }
        }
    }
    return CallNextHookEx(null, n_code, wparam, lparam);
}

mapping_setting_hook_proc :: (n_code: s32, wparam: WPARAM, lparam: LPARAM) -> s64 #c_call {
    using current_program_state;
    push_my_context();
    key_virtual_code := wparam;
    // How to interpret lparam: https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input
    hiword := (lparam >> 16) & 0xffff;
    // Scan code is bits 16-23, so byte 3, or the low byte of the hiword. It's a bit confusing...
    raw_scan_code := cast(u32)hiword & 0xff;
    key_scan_code : u32 = 0;

    // Extended bit is 24th. TODO: Use it, or we get confused with numlock is enabled vs when it's not
    // Something like:
    is_extended := cast(u32)(hiword & KF_EXTENDED) == KF_EXTENDED;

    if is_extended {
        // log("We are extended\n");
        key_scan_code = (0xe1 << 8) | raw_scan_code;
    } else {
        key_scan_code = raw_scan_code;
    }

    // Transition state flag is bit 31. Transition means whether key is pressed or released!
    is_down := hiword & KF_UP == 0;

    // Numlock is extended here, so 0xe100 + 0x0045 is numlock, we just ignore it.
    if key_scan_code == 0xe145 return CallNextHookEx(null, n_code, wparam, lparam);

    key_name := get_key_name(key_scan_code);
    if active_state == .SETTING_SOURCE || active_state == .SETTING_DESTINATION {
        // next_state := Mapping_State.NOTHING;
        if is_down {
            if active_state == .SETTING_SOURCE {
                old_source_code := active_mapping.source.code;
                current_destination_code := active_mapping.destination.code;

                // We ban setting the key to itself.
                if key_scan_code == current_destination_code {
                    return CallNextHookEx(null, n_code, wparam, lparam);
                }

                active_mapping.*.source.code = key_scan_code;
                table_set(*active_profile_in_ui.mappings, active_mapping.source.code, active_mapping.destination);

                if active_mapping.mode == .OPPOSITE || active_mapping.mode == .NEUTRAL {
                    table_remove(*active_profile_in_ui.mappings, active_mapping.destination.code);
                    table_set(*active_profile_in_ui.mappings, active_mapping.destination.code, active_mapping.source);
                }
                // We don't want to delete a mapping if the new code is the same as the old one. For example,
                // if the user reconsidered the change
                if key_scan_code != old_source_code {
                    table_remove(*active_profile_in_ui.mappings, old_source_code);
                }

            } else if active_state == .SETTING_DESTINATION {
                current_source_code := active_mapping.source.code;
                old_destination_code := active_mapping.destination.code;

                // We ban setting the key to itself.
                if key_scan_code == current_source_code {
                    return CallNextHookEx(null, n_code, wparam, lparam);
                }

                next_state = .NOTHING;

                active_mapping.*.destination.code = key_scan_code;

                table_set(*active_profile_in_ui.mappings, active_mapping.source.code, active_mapping.destination);
                if active_mapping.mode == .OPPOSITE || active_mapping.mode == .NEUTRAL {
                    table_remove(*active_profile_in_ui.mappings, old_destination_code);
                    table_set(*active_profile_in_ui.mappings, active_mapping.destination.code, active_mapping.source);
                }
            }

            if next_state == .NOTHING {
                finalize_state();
            } else {
                active_state = next_state;
            }
        }
    }
    return CallNextHookEx(null, n_code, wparam, lparam);
}

detect_focused_program :: (
    win_event_hook_handle: *void,
    // TODO: This is enum of "event constants":
    // https://learn.microsoft.com/en-us/windows/win32/winauto/event-constants
    event: u32,
    window: HWND,
    id_object: u32,
    id_child: u32,
    id_event_thread: u32,
    dwms_event_time: u32
) #c_call {
    push_my_context();
    using current_program_state;
    inspected_window := GetForegroundWindow();
    process_id: u32 = 0;
    GetWindowThreadProcessId(inspected_window, *process_id);
    unset_mapping_resolving_hook();

    if !process_id {
        // Sometimes when you minimize a window nothing is focused for a brief moment,
        // in this case windows sends "System Idle Process" as currently focused window
        // for some reason. Just ignore it.
        return;
    }
    focused_program_buffer: [MAX_PATH]u16;
    foreground_process := OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id);
    if !foreground_process {
        // Sometimes we can't open a process (#5 "access denied"). Ignore it I guess.
        if (GetLastError() == 5) {
            return;
        }
        log_error("Couldn't open the foreground process, error code is %\n", GetLastError());
    }

    filename_size : u32 = MAX_PATH;
    // This function API is so fucking weird. Read its docs extremely carefully
    QueryFullProcessImageNameW(foreground_process, 0, focused_program_buffer.data, *filename_size);
    CloseHandle(foreground_process);
    PathStripPathW(focused_program_buffer.data);
    focused_program_name, ok := wide_to_utf8(focused_program_buffer.data);
#if DEBUG {
        log("Window activated: %\n", focused_program_name);
}

    program_handle := GetModuleHandleW(null);

    for profile: profiles {
        if profile.program == focused_program_name && profile.platform == CURRENT_PLATFORM {
            active_profile = *profile;
            set_mapping_resolving_hook(program_handle);
            return;
        }
    }
    if profiles[0].mappings_array.count > 0 {
        active_profile = *profiles[0];

        set_mapping_resolving_hook(program_handle);
        return;
    }
}

_list_of_process_ids: [..]u32;
_opened_programs: Table(string, bool);

get_list_of_programs :: () -> [..]string {
    using current_program_state;
    defer table_reset(*_opened_programs);

    result: [..]string;
    result.allocator = temp;
    enum_processes();
    for process_id: _list_of_process_ids {
        if process_id == 0 continue;
        focused_program_buffer: [MAX_PATH]u16;
        foreground_process := OpenProcess(PROCESS_QUERY_INFORMATION, 0, process_id);
        if !foreground_process {
            continue;
        }

        filename_size : u32 = MAX_PATH;
        // This function API is so fucking weird. Read its docs extremely carefully
        QueryFullProcessImageNameW(foreground_process, 0, focused_program_buffer.data, *filename_size);
        CloseHandle(foreground_process);
        PathStripPathW(focused_program_buffer.data);
        name, ok := wide_to_utf8(focused_program_buffer.data,, temp);

        // Idk if this ever happens
        if !ok {
            continue;
        }

        name_lower := to_lower_copy(name,, temp);
        search_lower := to_lower_copy(active_search.text,, temp);
        if (active_search.text.count && contains(name_lower, search_lower)) || !active_search.text.count {
            _, found := table_find(*_opened_programs, name);
            if !found {
                copied_string := copy_string(name,, temp);
                table_set(*_opened_programs, copied_string, true);
                array_add(*result, copied_string);
            }
        }
    }

    array_reset_keeping_memory(*_list_of_process_ids);
    return result;
}

enum_processes :: () {
    new_count_in_bytes: s64;
    enum_success := K32EnumProcesses(_list_of_process_ids.data, xx (_list_of_process_ids.count*size_of(u32)), xx *new_count_in_bytes);
    if !enum_success {
        #import "System";
        error_code, error_string := get_error_value_and_string();
        log_error("Couldn't get list of running programs. Error code: %, message: %\n", error_code, error_string);
    }

    if new_count_in_bytes/size_of(u32) < _list_of_process_ids.count {
        _list_of_process_ids.count = new_count_in_bytes/size_of(u32);
        return;
    }

    while new_count_in_bytes/size_of(u32) >= _list_of_process_ids.count {
        // Guarding against the infinite loop when new count is equal to count and doesn't change between iterations.
        prev_new_count_in_bytes := new_count_in_bytes;

        array_reserve(*_list_of_process_ids, new_count_in_bytes/size_of(u32) + 100);
        _list_of_process_ids.count = new_count_in_bytes/size_of(u32) + 100;

        enum_success := K32EnumProcesses(_list_of_process_ids.data, xx (_list_of_process_ids.count*size_of(u32)), xx *new_count_in_bytes);
        if !enum_success {
            #import "System";
            error_code, error_string := get_error_value_and_string();
            log_error("Couldn't get list of running programs. Error code: %, message: %\n", error_code, error_string);
        }
        if prev_new_count_in_bytes == new_count_in_bytes {
            break;
        }
    }
}

start_detecting_focused_program :: () {
    SetWinEventHook(
        EVENT_OBJECT_FOCUS,
        EVENT_OBJECT_FOCUS,
        null,
        cast(*void)detect_focused_program,
        0,
        0,
        WINEVENT_OUTOFCONTEXT,
    );
}

set_mapping_resolving_hook :: (instance: HINSTANCE) {
    if !mapping_resolving_hook_is_installed {
        log("Installing the mapping resolving hook\n");
        mapping_resolving_hook = SetWindowsHookExW(WH_KEYBOARD_LL, cast(HOOKPROC)low_level_keyboard_proc, instance, 0);
        if (mapping_resolving_hook != null) {
            mapping_resolving_hook_is_installed = true;
        } else {
            log_error("Failed to set mapping resolving hook\n");
        }
    }
}

set_key_mapping_hook :: (window: Window_Type) {
    using current_program_state;

    if !mapping_setting_hook_is_installed {
        memset(kb_real_state.data, 0, kb_real_state.count);
        // null as instance and GetCurrentThreadId() instead of zero to hook into inputs when focusing this program.
        // Otherwise, the hook will only listen to keyboard from all other programs except this one!
        mapping_setting_hook = SetWindowsHookExW(WH_KEYBOARD, cast(HOOKPROC)mapping_setting_hook_proc, null, GetCurrentThreadId());
        if (mapping_setting_hook != null) {
            mapping_setting_hook_is_installed = true;
            log("Listening for new mapping: %\n", active_state);
        } else {
            error := GetLastError();
            log_error("Mapping setting hook initialization failed: %\n", error);
        }
    }
}

unset_mapping_resolving_hook :: () {
    if !mapping_resolving_hook_is_installed return;

    log("Unhooking mapping resolving hook\n");
    UnhookWindowsHookEx(mapping_resolving_hook);
    // Forget buttons that are pressed before unhooking from the keyboard
    // So that when we hook again we don't end up in a dirty state where one
    // of the buttons is being stuck from the previous hook
    memset(kb_real_state.data, 0, kb_real_state.count);
    mapping_resolving_hook_is_installed = false;
}

unset_mapping_setting_hook :: () {
    if !mapping_setting_hook_is_installed return;
    log("Unhooking mapping setting hook\n");
    UnhookWindowsHookEx(mapping_setting_hook);
    mapping_setting_hook_is_installed = false;
}

get_dpi_scale :: (window: Window_Type) -> float {
    // TODO: Return 1.0 for Windows7, if we will ever support that.
    dpi := cast(float32) GetDpiForWindow(window);
    return dpi / 96.0;
}


create_window :: () -> Window_Type {
    // Windows is very bad at thread-switching by default unless you do this. Sad.
    timeBeginPeriod(1);
    the_window := create_window(window_width, window_height, "Hitboxer v0.12");
    // We can't specify style in create_window, so change it afterwards.
    // TLDR is that we want a regular window but without an ability to maximize and resize it.
    // SetWindowLongPtrW(the_window, GWL_STYLE, WS_VISIBLE | WS_OVERLAPPED | WS_CAPTION | WS_MINIMIZEBOX | WS_SYSMENU);

    return the_window;
}


platform_hide_to_tray :: (window: HWND) {
    ShowWindow(window, SW_HIDE);
    the_window_hidden = true;
}

tray_proc :: (hwnd: HWND, message: u32, wParam: WPARAM, lParam: LPARAM) -> s64 #c_call {

    exit_menu : u64 = 100;
    push_my_context();
    if message == {
        case WM_APP + 1; {
            if lParam == {
                case WM_LBUTTONDOWN; {
                    if the_window_hidden {
                        ShowWindow(the_window, SW_SHOW);
                    } else {
                        ShowWindow(the_window, SW_HIDE);
                    }
                    the_window_hidden = !the_window_hidden;
                }
                case WM_RBUTTONDOWN; {
                    pt: POINT;
                    GetCursorPos(*pt);
                    // From TrackPopupMenuEx remarks
                    // To display a context menu for a notification icon, the current window must be the foreground
                    // window before the application calls TrackPopupMenu or TrackPopupMenuEx.
                    // Otherwise, the menu will not disappear when the user clicks outside of the menu
                    SetForegroundWindow(hwnd);

                    hmenu := CreatePopupMenu();
                    InsertMenuW(hmenu, 0, .MF_BYPOSITION | .MF_STRING, xx exit_menu, utf8_to_wide("Exit the program",, temp));
                    // result will hold 0 or the id of the menu item because of .TPM_RETURNCMD passed
                    result := TrackPopupMenuEx(hmenu, .TPM_LEFTALIGN | .TPM_LEFTBUTTON | .TPM_BOTTOMALIGN | .TPM_RETURNCMD , pt.x, pt.y, hwnd, null);
                    PostMessageW(hwnd, WM_COMMAND, xx result, 0);
                    // MSDN says that I MUST call DestroyMenu, or they'll put me to Guantanamo Bay :(
                    DestroyMenu(hmenu);
                }
            }
        }
        case WM_COMMAND; {
            if wParam == exit_menu PostMessageW(the_window, WM_QUIT, 0, 0);
        }
    }

    return DefWindowProcW(hwnd, message, wParam, lParam);
}


// A hidden window we use specifically to handle tray events
create_hidden_window :: (window_name: string, parent: Window_Type = null) -> HWND {
    hInstance := GetModuleHandleW(null);

    wc: WNDCLASSEXW;
    wc.cbSize = size_of(WNDCLASSEXW);
    wc.hInstance            = hInstance;
    wc.lpszClassName        = utf8_to_wide(HIDDEN_WINDOW_CLASS,, temp);


    wc.lpfnWndProc = xx tray_proc;

    if RegisterClassExW(*wc) == 0 {
        log_error("RegisterClassExW returned 0.\n");
        return null;
    }

    hwnd := CreateWindowExW(
        0,
        utf8_to_wide(HIDDEN_WINDOW_CLASS,, temp),
        utf8_to_wide(window_name,, temp),
        0,
        xx CW_USEDEFAULT, xx CW_USEDEFAULT,
        xx CW_USEDEFAULT,
        xx CW_USEDEFAULT,
        null,
        null,
        cast (HINSTANCE) 0,
        null,
    );

    if hwnd == null {
        log_error("CreateWindowExW returned 0.\n");
        return null;
    }

    return hwnd;
}

platform_after_window_created :: (window: HWND) -> success: bool #must {
    tray_window := create_hidden_window("hidden_tray_window", window);
    if !tray_window {
        log_error("Failed to create a base window for the tray icon: %\n", GetLastError());
    }

    process_handle := GetModuleHandleW(null);
    tray_info.cbSize = size_of(NOTIFYICONDATAW);
    tray_info.uID = 1231234545;
    tray_info.uFlags = .NIF_ICON | .NIF_MESSAGE | .NIF_TIP;
    tray_info.hIcon = LoadIconW(process_handle, MAKEINTRESOURCE(2));

    tray_info.hWnd = tray_window;
    tray_info.uCallbackMessage = WM_APP + 1;

    result := Shell_NotifyIconW(.NIM_ADD, *tray_info);
    if result != 1 {
        log_error("Failed to create a tray icon: %\n", GetLastError());
    }
    return true;
}


platform_init :: () -> success: bool #must, reason: string {
    array_reserve(*_list_of_process_ids, 1000);
    _list_of_process_ids.count = 1000;
    // TODO: come up with better window class to distinguish us
    the_window = FindWindowW(utf8_to_wide("Default Window Class",, temp), utf8_to_wide("Hitboxer v0.12",, temp));
    if the_window {
        ShowWindow(the_window, SW_SHOW);
        SetForegroundWindow(the_window);
        return false, "Another instance of the app is already running, trying to put it to the foreground\n";
    }
    return true, "";
}


platform_wait_for_message :: inline () {
    WaitMessage();
}


platform_wake_up_main_thread :: () {
    PostMessageW(the_window, WM_USER, 0, 0);
}


platform_deinit :: (window: HWND) {
    result := Shell_NotifyIconW(.NIM_DELETE, *tray_info);
    if !result {
        #import "System";
        error_code, error_string := get_error_value_and_string();
        log_error("Coulnd't clean up the tray icon. Error code: %, message: %\n", error_code, error_string);
    }
}


MAKEINTRESOURCE :: (x: s32) -> *u16 {
    return cast(*u16) x;  // Sigh.
}


HHOOK :: *void;
HOOKPROC :: *void;
WH_KEYBOARD :: 2;
WH_KEYBOARD_LL :: 13;


KBD_Flags :: enum_flags u32 {
    LLKHF_EXTENDED :: KF_EXTENDED >> 8;
    LLKHF_LOWER_IL_INJECTED :: 0x00000002;
    LLKHF_INJECTED :: 0x00000010;
    LLKHF_ALTDOWN :: KF_ALTDOWN >> 8;
    LLKHF_UP :: KF_UP >> 8;
}


KBDLLHOOKSTRUCT :: struct {
   vkCode: u32;
   scanCode: u32;
   flags: KBD_Flags;
   time: u32;
   dwExtraInfo: u32;
}


INPUT_Type :: enum u32 {
    INPUT_MOUSE :: 0;
    INPUT_KEYBOARD :: 1;
    INPUT_HARDWARE :: 2;
}


INPUT :: struct {
    type: INPUT_Type;
    mi: MOUSEINPUT;
    #place mi;
    ki: KEYBDINPUT;
    #place mi;
    hi: HARDWAREINPUT;
}


KEYEVENTF_KEYUP : u32 : 0x0002;
KEYEVENTF_SCANCODE : u32 : 0x0008;


KEYBDINPUT_Flags :: enum_flags u32 {
    KEYEVENTF_EXTENDEDKEY :: 0x0001;
    KEYEVENTF_KEYUP :: 0x0002;
    KEYEVENTF_SCANCODE :: 0x0008;
    KEYEVENTF_UNICODE :: 0x0004;
}


KEYBDINPUT :: struct {
    wVk: u16;
    wScan: u16;
    dwFlags: KEYBDINPUT_Flags;
    time: u32;
    dwExtraInfo: *u32;
}


MOUSEINPUT :: struct {
    dx: s32;
    dy: s32;
    mouseData: u32;
    dwFlags: u32;
    time: u32;
    dwExtraInfo: *u32;
}


HARDWAREINPUT :: struct {
    uMsg: u32;
    wParamL: u16;
    wParamH: u16;
}


Notify_Icon_Flags :: enum_flags u32 {
    NIF_MESSAGE  :: 0x00000001;
    NIF_ICON     :: 0x00000002;
    NIF_TIP      :: 0x00000004;
    NIF_STATE    :: 0x00000008;
    NIF_INFO     :: 0x00000010;
    NIF_GUID     :: 0x00000020;
    NIF_REALTIME :: 0x00000040;
    NIF_SHOWTIP  :: 0x00000080;
}


Notify_Icon_State_Mask :: enum_flags u32 {
    NIS_HIDDEN     :: 0x00000001;
    NIS_SHAREDICON :: 0x00000002;
}


Notify_Icon_State :: Notify_Icon_State_Mask;


Notify_Icon_Info_Flags :: enum_flags u32 {
    NIIF_NONE               :: 0x00000000;
    NIIF_INFO               :: 0x00000001;
    NIIF_WARNING            :: 0x00000002;
    NIIF_ERROR              :: 0x00000003;
    NIIF_USER               :: 0x00000004;
    NIIF_NOSOUND            :: 0x00000010;
    NIIF_LARGE_ICON         :: 0x00000020;
    NIIF_RESPECT_QUIET_TIME :: 0x00000080;
    NIIF_ICON_MASK          :: 0x0000000F;
}


NOTIFYICONDATAW :: struct {
    cbSize: u32;
    hWnd: HWND;
    uID: u32;
    uFlags: Notify_Icon_Flags;
    uCallbackMessage: u32;
    hIcon: HICON;
    szTip: [128]u16;
    dwState: Notify_Icon_State;
    dwStateMask: Notify_Icon_State_Mask;
    szInfo: [256]u16;
    DUMMYUNIONNAME :: union {
        uTimeout: u32;
        uVersion: u32;
    };
    szInfoTitle: [64]u16;
    dwInfoFlags: Notify_Icon_Info_Flags;
    guidItem: GUID;
    hBalloonIcon: HICON ;
}


Notify_Icon_Message :: enum u32 {
    NIM_ADD        :: 0x00000000;
    NIM_MODIFY     :: 0x00000001;
    NIM_DELETE     :: 0x00000002;
    NIM_SETFOCUS   :: 0x00000003;
    NIM_SETVERSION :: 0x00000004;
}


Insert_Menu_Flags :: enum_flags u32 {
    MF_BYCOMMAND    :: 0x00000000;
    MF_BYPOSITION   :: 0x00000400;
    MF_BITMAP       :: 0x00000004;
    MF_CHECKED      :: 0x00000008;
    MF_DISABLED     :: 0x00000002;
    MF_ENABLED      :: 0x00000000;
    MF_GRAYED       :: 0x00000001;
    MF_MENUBARBREAK :: 0x00000020;
    MF_MENUBREAK    :: 0x00000040;
    MF_OWNERDRAW    :: 0x00000100;
    MF_POPUP        :: 0x00000010;
    MF_SEPARATOR    :: 0x00000800;
    MF_STRING       :: 0x00000000;
    MF_UNCHECKED    :: 0x00000000;
}


Track_Popup_Menu_Flags :: enum_flags u32 {
    TPM_CENTERALIGN     :: 0x0004;
    TPM_LEFTALIGN       :: 0x0000;
    TPM_RIGHTALIGN      :: 0x0008;

    TPM_BOTTOMALIGN     :: 0x0020;
    TPM_TOPALIGN        :: 0x0000;
    TPM_VCENTERALIGN    :: 0x0010;

    TPM_NONOTIFY        :: 0x0080;
    TPM_RETURNCMD       :: 0x0100;

    TPM_LEFTBUTTON      :: 0x0000;
    TPM_RIGHTBUTTON     :: 0x0002;

    TPM_HORNEGANIMATION :: 0x0800;
    TPM_HORPOSANIMATION :: 0x0400;
    TPM_NOANIMATION     :: 0x4000;
    TPM_VERNEGANIMATION :: 0x2000;
    TPM_VERPOSANIMATION :: 0x1000;

    TPM_HORIZONTAL      :: 0x0000;
    TPM_VERTICAL        :: 0x0040;
}


TPMPARAMS :: struct {
  cbSize: u32;
  rcExclude: RECT;
}


WM_USER :: 0x0400;
WM_APP :: 0x8000;

HC_ACTION :: 0; // The wParam and lParam parameters contain information about a keyboard message.

KF_EXTENDED :: 0x0100; //  	Manipulates the extended key flag.
KF_DLGMODE  :: 0x0800; //  	Manipulates the dialog mode flag, which indicates whether a dialog box is active.
KF_MENUMODE :: 0x1000; //  	Manipulates the menu mode flag, which indicates whether a menu is active.
KF_ALTDOWN  :: 0x2000; //  	Manipulates the context code flag.
KF_REPEAT   :: 0x4000; //  	Manipulates the previous key state flag.
KF_UP       :: 0x8000; //  	Manipulates the transition state flag.

LLKHF_EXTENDED :: 0x0100 >> 8; // Test the extended-key flag.
LLKHF_INJECTED :: 0x00000010; // Test the event-injected (from any process) flag.

EVENT_OBJECT_FOCUS :: 0x8005;
WINEVENT_OUTOFCONTEXT :: 0;
WINEVENT_INCONTEXT :: 4;

PROCESS_VM_READ :: 0x0010;
PROCESS_QUERY_INFORMATION :: 0x0400;
PROCESS_QUERY_LIMITED_INFORMATION :: 0x1000;

user32   :: #library,system "user32";
kernel32 :: #library,system "kernel32";
shlwapi  :: #library,system "shlwapi";
shell32  :: #library,system "shell32";

SetWindowsHookExW :: (idHook: s32, lpfn: HOOKPROC, hmod: HINSTANCE, dwThreadId: u32) -> HHOOK #foreign user32;
UnhookWindowsHookEx :: (hhk: HHOOK) -> s32 #foreign user32;
PostMessageW :: (hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) -> BOOL #foreign user32;
WaitMessage :: () -> BOOL #foreign user32;
FindWindowW :: (lpClassName: *u16, lpWindowName: *u16) -> HWND #foreign user32;
SetForegroundWindow :: (hWnd: HWND) -> BOOL #foreign user32;
CallNextHookEx :: (hhk: HHOOK, nCode: s32, wParam: WPARAM, lParam: LPARAM) -> s64 #foreign user32;
MapVirtualKeyW :: (uCode: u32, uMapType: u32) -> u32 #foreign user32;
GetKeyNameTextW :: (lparam: u32, lp_string: *u16, cch_size: s32) -> s32 #foreign user32;
// TODO: Make it a pointer to an array of INPUTs instead:
// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
SendInput :: (cInputs: u32, pInputs: *INPUT, cbSize: s32) -> u32 #foreign user32;
GetWindowThreadProcessId :: (hwnd: HWND, lpdwProcessId: *u32) -> u32 #foreign user32;
SetWinEventHook :: (eventMin: u32, eventMax: u32, hmodWinEventProc: HMODULE, pfnWinEventProc: *void, idProcess: u32, idThread: u32, dwFlags: u32) -> HANDLE #foreign user32;
GetDpiForWindow :: (hWnd: HWND) -> u32 #foreign user32;
OpenProcess :: (dwDesiredAccess: u32, bInheritHandle: s32, dwProcessId: u32) -> HANDLE #foreign kernel32;
QueryFullProcessImageNameW :: (hProcess: HANDLE, dwFlags: u32, lpExeName: *u16, lpdwSize: *u32) -> s32 #foreign kernel32;
PathStripPathW :: (pszPath: *u16) #foreign shlwapi;

K32EnumProcesses :: (lpidProcess: *u32, cb: u32, lpcbNeeded: *u32) -> BOOL #foreign kernel32;
// Icons
Shell_NotifyIconW :: (dwMessage: Notify_Icon_Message, lpData: *NOTIFYICONDATAW) -> BOOL #foreign shell32;
CreateDialogParamW :: (hInstance: HINSTANCE, lpTemplateName: *u16, hWndParent: HWND, lpDialogFunc: HOOKPROC, dwInitParam: LPARAM) -> HWND #foreign user32;

// Menus
CreatePopupMenu :: () -> HMENU #foreign user32;
DestroyMenu :: (hmenu: HMENU) -> BOOL #foreign user32;
InsertMenuW :: (hMenu: HMENU, uPosition: u32, uFlags: Insert_Menu_Flags, uIDNewItem: *u32, lpNewItem: *u16) -> BOOL #foreign user32;
TrackPopupMenuEx :: (hMenu: HMENU, uFlags: Track_Popup_Menu_Flags, x: s32, y: s32, hwnd: HWND, lptpm: *TPMPARAMS) -> BOOL #foreign user32;

#import "Windows";
#import "Windows_Utf8";
#import "Hash_Table";
