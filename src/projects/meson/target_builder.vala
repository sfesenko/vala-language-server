/* meson/target_builder.vala
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

class Vls.MesonTargetBuilder : Object {
    public ArrayList<BuildTarget> build_targets { get; private set; }
    private string build_dir;
    private string root_path;
    private FileCache file_cache;
    private AnalysisCache analysis_cache;
    private HashMap<BuildTarget, File> targets_executing_generated_programs;

    public signal void target_defined_in_file (string defined_in);

    public MesonTargetBuilder (string build_dir, string root_path, FileCache file_cache, AnalysisCache analysis_cache) {
        this.build_dir = build_dir;
        this.root_path = root_path;
        this.file_cache = file_cache;
        this.analysis_cache = analysis_cache;
        build_targets = new ArrayList<BuildTarget> ();
        targets_executing_generated_programs = new HashMap<BuildTarget, File> ();
    }

    public void build_targets_from_json (Json.Array targets_json,
                                         ArrayList<Meson.Dependency> raw_dependencies,
                                         Cancellable? cancellable = null) throws Error {
        var root_dir = File.new_for_path (root_path);
        int elem_idx = -1;
        // include paths for internal libraries
        var internal_lib_c_includes = new HashMap<File, Meson.TargetInfo> (Util.file_hash, Util.file_equal);

        foreach (Json.Node elem_node in targets_json.get_elements ()) {
            elem_idx++;
            var meson_target_info = Json.gobject_deserialize
                (typeof (Meson.TargetInfo), elem_node) as Meson.TargetInfo?;
            if (meson_target_info == null) {
                Logger.warn ("compile", "could not deserialize target/element #%d", elem_idx);
                continue;
            } else if (meson_target_info.target_sources.is_empty) {
                Logger.warn ("compile", "target #%d (%s) has no target sources", elem_idx, meson_target_info.id);
                continue;
            }

            Meson.TargetSourceInfo first_source = meson_target_info.target_sources[0];

            string target_private_output_dir;
            string? src_relative_path = root_dir.get_relative_path (File.new_for_path (meson_target_info.defined_in));

            if (src_relative_path != null) {
                src_relative_path = Path.get_dirname (src_relative_path);
                if (first_source.language != "vala")
                    target_private_output_dir = build_dir + Path.DIR_SEPARATOR_S + src_relative_path;
                else
                    target_private_output_dir = build_dir;
            } else {
                throw new ProjectError.INTROSPECTION (@"defined-in for $(meson_target_info.id) is not relative to source dir $(root_dir.get_path ())");
            }

            bool swap_with_previous_target = false;
            string? compiler_name = first_source.compiler.length > 0
                ? Path.get_basename (first_source.compiler[0]) : null;

            if (compiler_name != null) {
                var fixed_sources = new ArrayList<string> ();
                foreach (string source in first_source.sources) {
                    var input_file = File.new_for_commandline_arg_and_cwd (source, target_private_output_dir);
                    if (root_dir.get_relative_path (input_file) == input_file.get_basename () &&
                        !input_file.query_exists (cancellable)) {
                        input_file = File.new_build_filename (root_path, src_relative_path, input_file.get_basename ());
                        Logger.debug ("compile", "fixed %s source: from %s --> %s", compiler_name, source, input_file.get_path ());
                    }
                    fixed_sources.add (input_file.get_path ());
                }
                first_source.sources = fixed_sources.to_array ();
            }

            if (compiler_name == "glib-mkenums") {
                if (meson_target_info.name.has_suffix (".h")
                    && build_targets.size > 0
                    && build_targets[build_targets.size - 1].name.has_suffix (".c")
                    && meson_target_info.name.substring (0, meson_target_info.name.length - 2)
                        == build_targets[build_targets.size - 1].name.substring (0, build_targets[build_targets.size - 1].name.length - 2))
                    swap_with_previous_target = true;
            }

            first_source.parameters = MesonSubstitutions.substitute_target_args (meson_target_info,
                                                                first_source,
                                                                first_source.parameters,
                                                                src_relative_path,
                                                                build_dir, root_path, build_targets);
            first_source.compiler = MesonSubstitutions.substitute_target_args (meson_target_info,
                                                              first_source,
                                                              first_source.compiler,
                                                              src_relative_path,
                                                              build_dir, root_path, build_targets);

            if (first_source.language == "c") {
                var fixed_parameters = new ArrayList<string> ();
                fixed_parameters.add_all_array (first_source.parameters);

                var link_args = new ArrayList<string> ();

                foreach (string arg in first_source.parameters) {
                    MatchInfo match_info;
                    if (!/-I(.*)/.match (arg, 0, out match_info))
                        continue;
                    File include_dir = File.new_for_path ((!) match_info.fetch (1));

                    foreach (var entry in internal_lib_c_includes) {
                        if (Util.file_equal (entry.key, include_dir)) {
                            var libs = new ArrayList<string>.wrap (first_source.sources);
                            foreach (string lib in entry.value.filename) {
                                Logger.debug ("compile", "adding internal link arg `%s' to C target %s for include dir %s",
                                       lib, meson_target_info.id, entry.key.get_path ());
                                libs.add (lib);
                            }
                            first_source.sources = libs.to_array ();
                        }
                    }

                    if (meson_target_info.target_type == "shared library" && meson_target_info.filename != null) {
                        foreach (string filename in meson_target_info.filename) {
                            File file = File.new_for_commandline_arg_and_cwd (filename, target_private_output_dir);
                            if (Util.file_equal (include_dir, file) || include_dir.get_relative_path (file) != null) {
                                internal_lib_c_includes[include_dir] = meson_target_info;
                                Logger.debug ("compile", "associating include dir %s with meson target %s",
                                       include_dir.get_path (), meson_target_info.id);
                            }
                        }
                    }
                }

                foreach (Meson.Dependency raw_dep in raw_dependencies) {
                    bool is_subset_of_compile_args = true;
                    foreach (string compile_arg in raw_dep.compile_args) {
                        if (!(compile_arg in first_source.parameters)) {
                            is_subset_of_compile_args = false;
                            break;
                        }
                    }

                    if (is_subset_of_compile_args) {
                        foreach (string link_arg in raw_dep.link_args) {
                            if (!(link_arg in link_args)) {
                                link_args.add (link_arg);
                                Logger.debug ("compile", "adding link arg `%s' to C target %s", link_arg, meson_target_info.id);
                            }
                        }
                    }
                }
                fixed_parameters.add_all (link_args);

                if (meson_target_info.target_type == "shared library") {
                    if (!("-shared" in fixed_parameters))
                        fixed_parameters.add ("-shared");
                    if (!fixed_parameters.any_match (p => p.has_prefix ("-o"))) {
                        if (meson_target_info.filename.length > 0) {
                            fixed_parameters.add ("-o");
                            fixed_parameters.add (meson_target_info.filename[0]);
                        } else {
                            throw new ProjectError.INTROSPECTION (@" expected at least one filename for C shared-library target $(meson_target_info.id)");
                        }
                    }
                }

                first_source.parameters = fixed_parameters.to_array ();
            }

            if (first_source.language == "vala")
                build_targets.add (new Compilation (file_cache, analysis_cache,
                                                    target_private_output_dir,
                                                    meson_target_info.name,
                                                    meson_target_info.id,
                                                    elem_idx,
                                                    first_source.compiler,
                                                    first_source.parameters,
                                                    first_source.sources,
                                                    first_source.generated_sources,
                                                    meson_target_info.filename));
            else {
                BuildTarget? previous_target = null;
                if (swap_with_previous_target)
                    previous_target = build_targets.remove_at (build_targets.size - 1);

                bool executes_generated_program = false;
                File? compiler_exe = null;
                if (meson_target_info.target_type == "custom" &&
                    first_source.compiler.length > 0 && !Path.is_absolute (first_source.compiler[0])) {
                    compiler_exe = File.new_for_commandline_arg_and_cwd (first_source.compiler[0], build_dir);
                    foreach (var target in build_targets) {
                        foreach (var output in target.output) {
                            if (output.get_basename () == first_source.compiler[0]) {
                                compiler_exe = output;
                                break;
                            }
                        }
                    }
                    first_source.compiler[0] = compiler_exe.get_path ();
                    executes_generated_program = true;
                }

                var added_task = new BuildTask (file_cache,
                                                build_dir,
                                                target_private_output_dir,
                                                meson_target_info.name,
                                                meson_target_info.id,
                                                elem_idx + (swap_with_previous_target ? -1 : 0),
                                                first_source.compiler,
                                                first_source.parameters,
                                                first_source.sources,
                                                first_source.generated_sources,
                                                meson_target_info.filename,
                                                first_source.language);
                build_targets.add (added_task);
                if (previous_target != null) {
                    previous_target.no = elem_idx;
                    build_targets.add (previous_target);
                    Logger.debug ("compile", "swapping previous target %s after target %s", previous_target.id, meson_target_info.id);
                }

                if (executes_generated_program) {
                    targets_executing_generated_programs[added_task] = compiler_exe;
                    added_task.input.insert (0, compiler_exe);
                }
            }

            target_defined_in_file (meson_target_info.defined_in);
        }
    }

    public void augment_from_compile_commands (Cancellable? cancellable = null) throws Error {
        var ccs_parser = new Json.Parser.immutable_new ();
        var ccs_file = File.new_build_filename (build_dir, "compile_commands.json");
        Logger.debug ("compile", "loading file %s ...", ccs_file.get_path ());
        ccs_parser.load_from_stream (ccs_file.read (cancellable), cancellable);
        Json.Node? ccs_json_root = ccs_parser.get_root ();
        if (ccs_json_root == null)
            Logger.warn ("compile", "JSON root is null! Bailing out");
        else if (ccs_json_root.get_node_type () != Json.NodeType.ARRAY)
            Logger.warn ("compile", "JSON root is not an array! Bailing out");
        else {
            int nth_cc = -1;
            foreach (Json.Node elem_node in ccs_json_root.get_array ().get_elements ()) {
                nth_cc++;
                var cc = Json.gobject_deserialize (typeof (CompileCommand), elem_node) as CompileCommand;
                if (cc == null) {
                    Logger.warn ("compile", "could not deserialize compile command #%d", nth_cc);
                    continue;
                }
                var cc_file = File.new_for_path (Util.realpath (cc.file, cc.directory));
                Compilation? compilation = find_compilation_for_cc (cc, cc_file);
                if (compilation == null)
                    continue;
                // parse the compile command for additional arguments
                string? flag_name, arg_value;
                for (int arg_i = -1; (arg_i = Util.iterate_valac_args (cc.command, out flag_name, out arg_value, arg_i)) < cc.command.length;) {
                    if (flag_name != null || arg_value == null)
                        continue;
                    if (!arg_value.has_suffix (".vapi"))
                        continue;
                    var vapi_file = File.new_for_path (Util.realpath (arg_value, cc.directory));
                    if (!compilation.input.contains (vapi_file)) {
                        Logger.debug ("compile", "discovered VAPI file %s used by compilation %s",
                               vapi_file.get_path (), compilation.id);
                        compilation.input.add (vapi_file);
                    }
                }
            }
        }
    }

    public bool has_targets_executing_generated_programs () {
        return targets_executing_generated_programs.size > 0;
    }

    public void update_dependencies_for_targets_executing_generated_programs (HashMap<BuildTarget, File> dest) {
        foreach (var entry in targets_executing_generated_programs) {
            dest[entry.key] = entry.value;
        }
    }

    private Compilation? find_compilation_for_cc (CompileCommand cc, File cc_file) {
        // First try exact match by URI
        foreach (var target in build_targets) {
            if (target is Compilation) {
                var comp = (Compilation) target;
                foreach (var input_file in comp.input) {
                    if (input_file.get_uri () == cc_file.get_uri ())
                        return comp;
                }
            }
        }

        // Fallback: match by name/id/directory patterns
        MatchInfo match_info;
        string? id = null;
        string? name = null;
        BuildTarget? btarget_found = null;

        if (/.*?([^\\\/]+)\.p/.match (cc.output, 0, out match_info)) {
            var directory = File.new_for_commandline_arg_and_cwd (match_info.fetch (0), build_dir);
            string filename = match_info.fetch (1);
            name = filename;

            bool is_shlib = false;
            bool is_stlib = false;
            MatchInfo lib_match_info;
            if (/^lib(.*?)\.(a|lib|so|dll)/.match (filename, 0, out lib_match_info)) {
                name = lib_match_info.fetch (1);
                string lib_suffix = lib_match_info.fetch (2);
                if (lib_suffix == "a" || lib_suffix == "lib")
                    is_stlib = true;
                else if (lib_suffix == "so" || lib_suffix == "dll")
                    is_shlib = true;
            }

            btarget_found = build_targets
                .filter (t => t is Compilation)
                .map<Compilation> (t => t as Compilation)
                .first_match (t => t.name == name &&
                              (is_stlib ? t.id.has_suffix ("@sta") :
                               is_shlib ? t.id.has_suffix ("@sha") :
                               t.id.has_suffix ("@exe")) &&
                              directory.get_path () == t.directory);
        } else if (/[^\\\/]+(@@[^\\\/]+)?@\w+/.match (cc.output, 0, out match_info)) {
            id = match_info.fetch (0);
            btarget_found = build_targets.first_match (t => t.id == id);
        }

        if (btarget_found != null && (btarget_found is Compilation)) {
            return (Compilation) btarget_found;
        } else if (id != null) {
            Logger.debug ("compile", "could not associate CC with meson target-id: %s", id);
        } else if (name != null) {
            Logger.debug ("compile", "could not associate CC with meson target-name: %s", name);
        }
        return null;
    }
}
