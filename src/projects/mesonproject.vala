/* mesonproject.vala
 *
 * Copyright 2020-2022 Princeton Ferro <princetonferro@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Gee;

/**
 * A project with a Meson backend
 */
class Vls.MesonProject : Project {
    private bool build_files_have_changed = true;
    private HashMap<File, FileMonitor> meson_build_files = new HashMap<File, FileMonitor> (Util.file_hash, Util.file_equal);
    private string build_dir;
    private bool configured_once;
    private bool requires_general_build;
    private Scheduler _scheduler;

    public override bool reconfigure_if_stale (Cancellable? cancellable = null) throws Error {
        if (!build_files_have_changed) {
            return false;
        }

        var reconfigure_start = GLib.get_monotonic_time ();
        build_targets.clear ();
        build_files_have_changed = false;

        // 0. we support only Meson >= 0.50
        MesonIntrospection.check_meson_version (build_dir, _scheduler);

        // 1. configure new build directory
        var root_meson_build = File.new_build_filename (root_path, "meson.build");
        if (!meson_build_files.has_key (root_meson_build)) {
            Logger.debug ("compile", "obtaining a new file monitor for %s",
                           root_meson_build.get_path ());
            FileMonitor file_monitor = root_meson_build.monitor_file (FileMonitorFlags.NONE, cancellable);
            file_monitor.changed.connect (file_changed_event);
            meson_build_files[root_meson_build] = file_monitor;
        }

        string[] spawn_args = {"meson", "setup", ".", root_path};
        string proc_stdout = "";
        string proc_stderr = "";
        int proc_status = -1;
        Logger.info ("compile", "%sconfiguring build dir %s", configured_once ? "re" : "", build_dir);
        if (configured_once)
            spawn_args += "--reconfigure";

        _scheduler.run_sync<void> (() => {
            Process.spawn_sync (
                build_dir,
                spawn_args,
                null,
                SpawnFlags.SEARCH_PATH,
                null,
                out proc_stdout,
                out proc_stderr,
                out proc_status);
        });

        if (proc_status != 0) {
            Logger.warn ("compile", "configuration failed with exit code %d\n----stdout:\n%s\n----stderr:\n%s",
                          proc_status, proc_stdout, proc_stderr);
            throw new ProjectError.CONFIGURATION (@"meson configuration failed with exit code $proc_status");
        }

        // 2. load project dependencies, which may be of use to C build targets
        var raw_dependencies = new ArrayList<Meson.Dependency> ();
        var dependencies_parser = new Json.Parser.immutable_new ();
        MesonIntrospection.load_introspection_json (dependencies_parser, build_dir, "dependencies", _scheduler, cancellable);
        Json.Node? rd_json_root = dependencies_parser.get_root ();
        if (rd_json_root == null) {
            Logger.warn ("compile", "JSON root is null! C code targets may fail to build.");
        } else if (rd_json_root.get_node_type () != Json.NodeType.ARRAY) {
            Logger.warn ("compile", "JSON root is not an array! C code targets may fail to build.");
        } else {
            int elem_idx = -1;
            foreach (Json.Node elem_node in rd_json_root.get_array ().get_elements ()) {
                elem_idx++;
                var raw_dependency = Json.gobject_deserialize
                    (typeof (Meson.Dependency), elem_node) as Meson.Dependency?;
                if (raw_dependency == null) {
                    Logger.warn ("compile", "could not deserialize raw dependency/element #%d", elem_idx);
                    continue;
                }
                raw_dependencies.add (raw_dependency);
            }
        }

        // 3. create build targets
        var targets_parser = new Json.Parser.immutable_new ();
        MesonIntrospection.load_introspection_json(targets_parser, build_dir, "targets", _scheduler, cancellable);
        Json.Node? tg_json_root = targets_parser.get_root ();
        if (tg_json_root == null) {
            Logger.warn ("compile", "JSON root is null! Bailing out");
            throw new ProjectError.INTROSPECTION ("Meson targets: JSON root is null!");
        } else if (tg_json_root.get_node_type () != Json.NodeType.ARRAY) {
            Logger.warn ("compile", "JSON root is not an array! Bailing out");
            throw new ProjectError.INTROSPECTION ("Meson targets: JSON root is not an array!");
        }
        var target_builder = new MesonTargetBuilder (build_dir, root_path, file_cache, analysis_cache);
        target_builder.target_defined_in_file.connect (on_target_defined_in_file);
        target_builder.build_targets_from_json (tg_json_root.get_array (), raw_dependencies, cancellable);
        target_builder.augment_from_compile_commands (cancellable);
        build_targets.clear ();
        build_targets.add_all (target_builder.build_targets);

        // 5. look for more file monitors
        var bs_files_parser = new Json.Parser.immutable_new ();
        try {
            MesonIntrospection.load_introspection_json(bs_files_parser, build_dir, "buildsystem_files", _scheduler, cancellable);
            Json.Node? bsf_json_root = bs_files_parser.get_root ();
            if (bsf_json_root == null) {
                throw new ProjectError.INTROSPECTION ("Meson buildsystem files: JSON root is null!");
            } else if (bsf_json_root.get_node_type () != Json.NodeType.ARRAY) {
                throw new ProjectError.INTROSPECTION ("Meson buildsystem files: JSON root is not an array!");
            }

            foreach (Json.Node elem_node in bsf_json_root.get_array ().get_elements ()) {
                string? path = elem_node.get_string ();
                if (path != null && (path.has_suffix ("meson.build") || path.has_suffix ("meson_options.txt") || path.has_suffix ("meson.options"))) {
                    var build_file = File.new_for_path ((!) path);
                    if (!meson_build_files.has_key (build_file)) {
                        Logger.debug ("compile", "obtaining a new file monitor for %s",
                                       build_file.get_path ());
                        try {
                            FileMonitor file_monitor = build_file.monitor_file (FileMonitorFlags.NONE, cancellable);
                            file_monitor.changed.connect (file_changed_event);
                            meson_build_files[build_file] = file_monitor;
                        } catch (Error e) {
                            Logger.warn ("compile", "failed to monitor build file %s - %s",
                                          build_file.get_path (), e.message);
                        }
                    }
                }
            }
        } catch (Error e) {
            Logger.warn ("compile", "failed to load meson buildsystem files: %s", e.message);
        }

        // 6. perform final analysis and sanity checking
        analyze_build_targets (cancellable);
        if (target_builder.has_targets_executing_generated_programs ()) {
            requires_general_build = true;
            var dest = new HashMap<BuildTarget, File> ();
            target_builder.update_dependencies_for_targets_executing_generated_programs (dest);
            foreach (var entry in dest) {
                Logger.debug ("compile", "requires general build because target %s executes a file (%s) generated by another target %s",
                               entry.key.id, entry.value.get_path (), entry.key.dependencies[entry.value].id);
            }
        }

        configured_once = true;

        var reconfigure_elapsed = GLib.get_monotonic_time () - reconfigure_start;
        Logger.debug ("compile", "reconfigure completed in %.3fs", reconfigure_elapsed / 1000000.0);
        return true;
    }

    private void on_target_defined_in_file (string defined_in) {
        var defined_in_file = File.new_for_path (defined_in);
        if (!meson_build_files.has_key (defined_in_file)) {
            Logger.debug ("compile", "obtaining a new file monitor for %s",
                           defined_in_file.get_path ());
            try {
                FileMonitor file_monitor = defined_in_file.monitor_file (FileMonitorFlags.NONE);
                file_monitor.changed.connect (file_changed_event);
                meson_build_files[defined_in_file] = file_monitor;
            } catch (Error e) {
                Logger.warn ("compile", "failed to monitor %s - %s", defined_in, e.message);
            }
        }
    }

    public override void build_if_stale (GLib.Cancellable? cancellable = null) throws Error {
        if (requires_general_build) {
            int proc_status = -1;
            string proc_stdout = "";
            string proc_stderr = "";

            proc_stdout = _scheduler.run_sync<string> (() => {
                string stdout_str;
                Process.spawn_sync (
                    build_dir,
                    {"meson", "compile"},
                    null,
                    SpawnFlags.SEARCH_PATH,
                    null,
                    out stdout_str,
                    out proc_stderr,
                    out proc_status);
                return stdout_str;
            }, cancellable);

            if (proc_status != 0) {
                Logger.warn ("compile", "`meson compile' in %s failed with exit code %d\n----stdout:\n%s\n----stderr:\n%s",
                              build_dir, proc_status, proc_stdout, proc_stderr);
                throw new ProjectError.INTROSPECTION (@"`meson compile' failed with exit code $proc_status");
            }
        }

        base.build_if_stale (cancellable);
    }

    public MesonProject (string root_path, FileCache file_cache, Cancellable? cancellable = null) throws Error {
        base (root_path, file_cache);
        _scheduler = new Scheduler ();
        this.build_dir = DirUtils.make_tmp (@"vls-meson-$(str_hash (root_path))-XXXXXX");
        reconfigure_if_stale (cancellable);
    }

    ~MesonProject () {
        Util.remove_dir (build_dir);
    }

    private void file_changed_event (File src, File? dest, FileMonitorEvent event_type) {
        if (FileMonitorEvent.DELETED in event_type) {
            Logger.debug ("compile", "watched file %s was deleted", src.get_path ());
            // remove this file monitor since the file was deleted
            FileMonitor file_monitor;
            if (meson_build_files.unset (src, out file_monitor)) {
                file_monitor.cancel ();
                file_monitor.changed.disconnect (file_changed_event);
            }
            build_files_have_changed = true;
            changed ();
        } else if (FileMonitorEvent.CHANGED in event_type) {
            Logger.debug ("compile", "watched file %s was changed", src.get_path ());
            build_files_have_changed = true;
            changed ();
        } else if (FileMonitorEvent.ATTRIBUTE_CHANGED in event_type) {
            Logger.debug ("compile", "watched file %s had an attribute changed", src.get_path ());
            build_files_have_changed = true;
            changed ();
        }
    }
}
