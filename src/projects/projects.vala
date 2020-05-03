

namespace Vls.Projects {

/**
 * Factory method for creating new prject
 */
Pair<Project, string?> get_project (GLib.File root_dir, Cancellable cancellable) {

    string root_path = Util.realpath ((!) root_dir.get_path ());
    debug (@"[initialize] root path is $root_path");

    var meson_file = root_dir.get_child ("meson.build");
    Gee.ArrayList<File> cc_files = new Gee.ArrayList<File> ();
    Project project = null;
    string message = null;
    try {
        cc_files = Util.find_files (root_dir, /compile_commands\.json/, 2);
    } catch (Error e) {
        warning ("could not enumerate root dir - %s", e.message);
    }
    // TODO: autotools, make(?), cmake(?)
    var is_meson_project = meson_file.query_exists (cancellable); 
    if (is_meson_project) {
        try {
            project = new MesonProject (root_path, cancellable);
        } catch (Error e) {
            if (!(e is ProjectError.VERSION_UNSUPPORTED)) {
                message = @"Failed to initialize Meson project - $(e.message)";
                // throw new ProjectError.FAILED (message);
                //  showMessage (client, , MessageType.Error);
            }
        }
    }
    // try compile_commands.json if Meson failed
    if (project == null && !cc_files.is_empty) {
        foreach (var cc_file in cc_files) {
            string cc_file_path = Util.realpath (cc_file.get_path ());
            try {
                project = new CcProject (root_path, cc_file_path, cancellable);
                debug ("[initialize] initialized CcProject with %s", cc_file_path);
                break;
            } catch (Error e) {
                debug ("[initialize] CcProject failed with %s - %s", cc_file_path, e.message);
                continue;
            }
        }
    }

    // use DefaultProject as a last resort
    if (project == null) {
        if (root_dir.get_child ("CMakeLists.txt").query_exists ()) {
            message = @"CMake build system is not currently supported. Only Meson is. See https://github.com/benwaffle/vala-language-server/issues/73";
        } else if (root_dir.get_child ("autogen.sh").query_exists ()) {
            message = @"Autotools build system is not currently supported. Consider switching to Meson.";
        } else {
            message = @"Unknown project type. Consider switching to Meson.";
        }
        project = new DefaultProject (root_dir);

    }
    return new Pair<Project, string> (project, message);
}

} // namespace