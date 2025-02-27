#load "modules/Control_Flow/or_return_build.jai";

build :: () {
    w := compiler_create_workspace("Target Program");
    if !w {
        print("Workspace creation failed\n");
        return;
    }
    optimized := false;

    target_options := get_build_options(w);
    target_options.output_executable_name = "hitboxer";
    target_options.arithmetic_overflow_check = .FATAL;
    set_optimization(*target_options, .DEBUG);

    args := target_options.compile_time_command_line;

    set_build_options_dc(.{do_output=false});
    modules_dir := join(#filepath, "modules/Input");

    for arg: args {
        if arg == {
            case "release";
            optimized = true;
            set_optimization(*target_options, .VERY_OPTIMIZED);
        }
    }

    remap_import(w, "", "Input", "");
    set_build_options(target_options, w);

    #if OS == .WINDOWS {
        if optimized {
            // This disables runtime console
            set_build_options_dc(.{append_linker_arguments=.["/SUBSYSTEM:windows", "/ENTRY:mainCRTStartup"]}, w);
        }
    }

    compiler_begin_intercept(w);
    add_build_file("./main.jai", w);

    add_build_string(tprint("DEBUG :: %;", ifx !optimized then "true" else "false"), w);
    or_return_add_source(w);

    while true {
        message := compiler_wait_for_message();
        if message.kind == {
            case .FAILED_IMPORT;
            m := cast(*Message_Failed_Import) message;
            if m.target_module_name == {
                case "Input";
                provide_import(message.workspace, m, .PATH_TO_DIRECTORY, modules_dir);
            }
            case .TYPECHECKED;
            typechecked := cast(*Message_Typechecked) message;
            or_return_handle_typechecked(typechecked);

            case .COMPLETE;
            break;
        }
    }

    compiler_end_intercept(w);

    #if OS == .WINDOWS {
        #import "Windows_Resources";
        exe_name := sprint("%.exe", target_options.output_executable_name);
        defer free(exe_name);

        success := set_icon_by_filename(exe_name, "icon.ico");
        if !success {
            log_error(
                "Failed to set the icon for exe '%' to filename '%'.\n",
                exe_name, "icon.ico",
            );
        }
        manifest_options: Manifest_Options;
        success = add_manifest_to_executable(exe_name, manifest_options);
        if !success {
            log_error("Couldn't add the manifest to the executable %\n", exe_name);
        }
    }
}

#run build();

#import "Basic";
#import "Compiler";
