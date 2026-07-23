/* compilation.vala
 *
 * Copyright 2020 Princeton Ferro <princetonferro@gmail.com>
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

class Vls.Compilation : BuildTarget {
    private HashSet<string> _packages = new HashSet<string> ();
    private HashSet<string> _defines = new HashSet<string> ();

    private HashSet<string> _vapi_dirs = new HashSet<string> ();
    private HashSet<string> _gir_dirs = new HashSet<string> ();
    private HashSet<string> _metadata_dirs = new HashSet<string> ();
    private HashSet<string> _gresources_dirs = new HashSet<string> ();

    /**
     * This helps us determine which files have remained the same after an
     * update.
     */
    private FileCache _file_cache;

    /**
     * These are files that are part of the project.
     */
    private HashMap<File, TextDocument> _project_sources = new HashMap<File, TextDocument> (Util.file_hash, Util.file_equal);

    /**
     * This is the list of initial content for project source files.
     * Used for files that do not exist ('untitled' files);
     */
    private HashMap<File, string> _sources_initial_content = new HashMap<File, string> (Util.file_hash, Util.file_equal);

    /**
     * These may not exist until right before we compile the code context.
     */
    private HashSet<File> _generated_sources = new HashSet<File> (Util.file_hash, Util.file_equal);

    /**
     * The analyses for each project source, cached at project level.
     */
    private AnalysisCache _analysis_cache;

    public Vala.CodeContext code_context { get; private set; default = new Vala.CodeContext (); }

    // CodeContext arguments:
    private bool _deprecated;
    private bool _experimental;
    private bool _experimental_non_null;
    private bool _abi_stability;
    private string? _target_glib;

    /**
     * The output directory.
     */
    public string directory { get; private set; }
    private Vala.Profile _profile;
    private string? _entry_point_name;
    private bool _fatal_warnings;

    /**
     * Absolute path to generated VAPI
     */
    private string? _output_vapi;

    /**
     * Absolute path to generated GIR
     */
    private string? _output_gir;

    /**
     * Absolute path to generated internal VAPI
     */
    private string? _output_internal_vapi;

    private bool _completed_first_compile;

    /**
     * Holds a strong reference to the previous CodeContext after a swap,
     * preventing it from being freed while in-flight handlers still
     * reference its AST nodes.  Cleared on idle after all pending
     * main-loop events have completed.
     */
    private Vala.CodeContext? _previous_code_context = null;

    /**
     * Whether packages have been loaded into the code context.
     * After the first successful compile, we reuse the same context
     * and skip re-adding packages on subsequent recompiles.
     */
    private bool _packages_loaded;

    /**
     * The reporter for the code context
     */
    public Reporter reporter {
        get {
            if (!(code_context.report is Reporter)) {
                error ("code_context.report is not a Reporter instance");
            }
            return (Reporter) code_context.report;
        }
    }

    /**
     * Maps a symbol's C name to the actual symbol. The documentation engine
     * uses this to replace references to C symbols with appropriate Vala references.
     */
    public HashMap<string, Vala.Symbol> cname_to_sym { get; private set; default = new HashMap<string, Vala.Symbol> (); }

    /**
     * Collects all local variables with inferred types that are not obvious in
     * the source code.
     */
    public HashSet<Vala.LocalVariable> var_decls { get; private set; default = new HashSet<Vala.LocalVariable> (); }

    /**
     * Collects all method calls and object creation expressions.
     */
    public HashMap<Vala.CodeNode, int> method_calls { get; private set; default = new HashMap<Vala.CodeNode, int> (); }

    /**
     * Collects every template-string literal (@"...") and its interpolation
     * expressions, captured before code_context.check() rewrites Template nodes
     * into to_string()/concat() chains. Keyed by the source file they belong to.
     */
    public HashMap<Vala.SourceFile, Gee.List<TemplateSpan>> template_spans { get; private set; default = new HashMap<Vala.SourceFile, Gee.List<TemplateSpan>> (); }

    /**
     * Set to true when the Vala library logs CRITICAL assertions during
     * code_context.check().  This indicates corrupted symbols (NULL parents,
     * type_symbols) from GIR package loading that will crash analyzers.
     */
    public bool has_corrupted_symbols { get; internal set; default = false; }

    public Compilation (FileCache file_cache, AnalysisCache analysis_cache, string output_dir, string name, string id, int no,
                        string[] compiler, string[] args, string[] sources, string[] generated_sources,
                        string?[] target_output_files,
                        string[]? sources_content = null) throws Error {
        base (output_dir, name, id, no);
        _file_cache = file_cache;
        _analysis_cache = analysis_cache;
        directory = output_dir;

        // parse arguments
        var output_dir_file = File.new_for_path (output_dir);
        bool set_directory = false;
        string? flag_name, arg_value;           // --<flag_name>[=<arg_value>]

        // because we rely on --directory for determining the location of output files
        // because we rely on --basedir (if defined) for determining the location of input files
        for (int arg_i = -1; (arg_i = Util.iterate_valac_args (args, out flag_name, out arg_value, arg_i)) < args.length;) {
            if (flag_name == "directory") {
                if (arg_value == null) {
                    warning ("Compilation(%s) null --directory", id);
                    continue;
                }
                directory = Util.realpath (arg_value, output_dir);
                set_directory = true;
            }
        }

        int ignored_args = 0;
        for (int arg_i = -1; (arg_i = Util.iterate_valac_args (args, out flag_name, out arg_value, arg_i)) < args.length;) {
            if (flag_name == "pkg") {
                _packages.add (arg_value);
            } else if (flag_name == "vapidir") {
                _vapi_dirs.add (arg_value);
            } else if (flag_name == "girdir") {
                _gir_dirs.add (arg_value);
            } else if (flag_name == "metadatadir") {
                _metadata_dirs.add (arg_value);
            } else if (flag_name == "gresourcesdir") {
                _gresources_dirs.add (arg_value);
            } else if (flag_name == "define") {
                _defines.add (arg_value);
            } else if (flag_name == "enable-experimental") {
                _experimental = true;
            } else if (flag_name == "enable-experimental-non-null") {
                _experimental_non_null = true;
            } else if (flag_name == "fatal-warnings") {
                _fatal_warnings = true;
            } else if (flag_name == "profile") {
                if (arg_value == "posix")
                    _profile = Vala.Profile.POSIX;
                else if (arg_value == "gobject")
                    _profile = Vala.Profile.GOBJECT;
                else
                    throw new ProjectError.INTROSPECTION (@"Compilation($id) unsupported Vala profile `$arg_value'");
            } else if (flag_name == "abi-stability") {
                _abi_stability = true;
            } else if (flag_name == "target-glib") {
                _target_glib = arg_value;
            } else if (flag_name == "vapi" || flag_name == "gir" || flag_name == "internal-vapi") {
                if (arg_value == null) {
                    warning ("Compilation(%s) --%s is null", id, flag_name);
                    continue;
                }

                string path = Util.realpath (arg_value, directory);
                if (!set_directory)
                    warning ("Compilation(%s) no --directory given, assuming %s", id, directory);
                if (flag_name == "vapi")
                    _output_vapi = path;
                else if (flag_name == "gir")
                    _output_gir = path;
                else
                    _output_internal_vapi = path;

                output.add (File.new_for_path (path));
            } else if (flag_name == null) {
                if (arg_value == null) {
                    warning ("Compilation(%s) failed to parse argument #%d (%s)", id, arg_i, args[arg_i]);
                } else if (Util.arg_is_vala_file (arg_value)) {
                    var file_from_arg = File.new_for_path (Util.realpath (arg_value, output_dir));
                    if (output_dir_file.get_relative_path (file_from_arg) != null)
                        _generated_sources.add (file_from_arg);
                    input.add (file_from_arg);
                }
            } else if (flag_name != "directory") {
                ignored_args++;
            }
        }

        if (ignored_args > 0)
            debug ("Compilation(%s): ignored %d arguments", id, ignored_args);

        // Bug #293: if no --vapidir was provided, add default system VAPI paths
        // so that the DefaultProject can find system packages like Posix.
        if (_vapi_dirs.size == 0) {
            _vapi_dirs.add ("/usr/share/vala/vapi");
            _vapi_dirs.add ("/usr/local/share/vala/vapi");
            // macOS Homebrew (Apple Silicon)
            _vapi_dirs.add ("/opt/homebrew/share/vala/vapi");
            var home_vapi = GLib.Environment.get_home_dir ();
            if (home_vapi != null)
                _vapi_dirs.add (Path.build_filename (home_vapi, ".local", "share", "vala", "vapi"));
        }

        for (int i = 0; i < sources.length; i++) {
            unowned string source = sources[i];
            unowned string? content = sources_content != null ? sources_content[i] : null;

            string? uri_scheme = Uri.parse_scheme (source);
            if (uri_scheme != null && uri_scheme.down () != "c") {
                var file = File.new_for_uri (source);
                input.add (file);
                if (content != null)
                    _sources_initial_content[file] = content;
            } else {
                input.add (File.new_for_path (Util.realpath (source, output_dir)));
            }
        }

        foreach (string generated_source in generated_sources) {
            var generated_source_file = File.new_for_path (Util.realpath (generated_source, output_dir));
            _generated_sources.add (generated_source_file);
            input.add (generated_source_file);
        }

        // add the rest of these target output files
        foreach (string? output_file in target_output_files) {
            if (output_file != null) {
                if (output.add (File.new_for_commandline_arg_and_cwd (output_file, output_dir)))
                    debug ("Compilation(%s): also outputs %s", id, output_file);
            }
        }

        // finally, add these very important packages
        if (_profile == Vala.Profile.POSIX) {
            _packages.add ("posix");
        } else {
            _packages.add ("glib-2.0");
            _packages.add ("gobject-2.0");
            if (_profile != Vala.Profile.GOBJECT)
                warning ("Compilation(%s) no --profile argument given, assuming GOBJECT", id);
        }
    }

    /**
     * Create and configure a fresh {@link Vala.CodeContext} with this
     * compilation's settings. Shared by the main-thread configure path
     * and the worker-thread compile path to avoid duplication.
     */
    private Vala.CodeContext create_code_context () {
        var ctx = new Vala.CodeContext () {
            deprecated = _deprecated,
            experimental = _experimental,
            experimental_non_null = _experimental_non_null,
            abi_stability = _abi_stability,
            directory = directory,
            vapi_directories = _vapi_dirs.to_array (),
            gir_directories = _gir_dirs.to_array (),
            metadata_directories = _metadata_dirs.to_array (),
            keep_going = true,
            entry_point_name = _entry_point_name,
            gresources_directories = _gresources_dirs.to_array ()
        };

#if VALA_0_50
        ctx.set_target_profile (_profile, false);
#else
        ctx.profile = _profile;
        switch (_profile) {
            case Vala.Profile.POSIX:
                ctx.add_define ("POSIX");
                break;
            case Vala.Profile.GOBJECT:
                ctx.add_define ("GOBJECT");
                break;
        }
#endif

        ctx.report = new Reporter (_fatal_warnings);
        if (_target_glib != null)
            ctx.set_target_glib_version (_target_glib);

        foreach (string define in _defines)
            ctx.add_define (define);

        return ctx;
    }

    /**
     * Add the profile-specific default using directive to a source file
     * and (if {@code also_to_root} is true) to the context root.
     */
    private void add_profile_using_directive (Vala.CodeContext ctx, Vala.SourceFile doc, bool also_to_root) {
        if (_profile == Vala.Profile.POSIX) {
            var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, "Posix", null));
            doc.add_using_directive (ns_ref);
            if (also_to_root)
                ctx.root.add_using_directive (ns_ref);
        } else if (_profile == Vala.Profile.GOBJECT) {
            var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, "GLib", null));
            doc.add_using_directive (ns_ref);
            if (also_to_root)
                ctx.root.add_using_directive (ns_ref);
        }
    }

    private void configure (Cancellable? cancellable = null, bool create_new_context = false) throws Error {
        // After the first compile, reuse the existing code_context
        // (which already has packages loaded) and just update source file
        // content. This avoids the 40-55% compile-time cost of re-adding
        // all packages via add_external_package.
        // Skip reuse when create_new_context is set (worker thread path).
        if (_packages_loaded && !create_new_context) {
            Vala.CodeContext.push (code_context);
            foreach (TextDocument doc in _project_sources.values) {
                doc.context = code_context;
                doc.get_comments ().clear ();
                doc.get_nodes ().clear ();
                doc.current_using_directives.clear ();
                // Root already has the using directive from the first compile;
                // only add to the document to avoid accumulation on root.
                add_profile_using_directive (code_context, doc, false);
                cancellable.set_error_if_cancelled ();
            }
            Vala.CodeContext.pop ();
            return;
        }

        // Recreate code context
        code_context = create_code_context ();
        Vala.CodeContext.push (code_context);

        if (_project_sources.is_empty) {
            debug ("Compilation(%s): will load input sources for the first time", id);
            if (input.is_empty)
                warning ("Compilation(%s): no input sources to load!", id);
            foreach (File file in input) {
                if (!dependencies.has_key (file)) {
                    try {
                        _project_sources[file] = new TextDocument (code_context, file, _sources_initial_content[file], true);
                    } catch (Error e) {
                        warning ("Compilation(%s): %s", id, e.message);
                        Vala.CodeContext.pop ();
                        throw e;    // rethrow
                    }
                } else
                    _generated_sources.add (file);

                cancellable.set_error_if_cancelled ();
            }
        }

        foreach (TextDocument doc in _project_sources.values) {
            doc.context = code_context;
            code_context.add_source_file (doc);
            doc.current_using_directives.clear ();
            add_profile_using_directive (code_context, doc, true);
            doc.get_comments ().clear ();
            doc.get_nodes ().clear ();
            cancellable.set_error_if_cancelled ();
        }

        // packages (should come after in case we've wrapped any package files in TextDocuments)
        foreach (string package in _packages)
            code_context.add_external_package (package);

        Vala.CodeContext.pop ();
    }

    private void compile () throws Error {
        debug ("compiling %s ...", id);
        Vala.CodeContext.push (code_context);
        var vala_parser = new Vala.Parser ();
        var genie_parser = new Vala.Genie.Parser ();
        var gir_parser = new Vala.GirParser ();

        // add all generated files before compiling
        foreach (File generated_file in _generated_sources) {
            // generated files are also part of the project, so we use TextDocument intead of Vala.SourceFile
            try {
                if (!generated_file.query_exists ())
                    throw new FileError.NOENT ("file does not exist");
                code_context.add_source_file (new TextDocument (code_context, generated_file));
            } catch (Error e) {
                warning ("could not add file for %s: %s - %s", id, generated_file.get_uri (), e.message);

                Vala.CodeContext.pop ();
                throw e;        // rethrow
            }
        }

        // compile everything
        vala_parser.parse (code_context);
        genie_parser.parse (code_context);
        gir_parser.parse (code_context);

        // update var decls, which must come before the AST is rewritten in check()
        var_decls.clear ();
        method_calls.clear ();
        foreach (var source_file in code_context.get_source_files ())
            source_file.accept (new InlayHintNodes (var_decls, method_calls));

        // capture template-string literals before check() rewrites them
        template_spans.clear ();
        foreach (var source_file in code_context.get_source_files ())
            source_file.accept (new TemplateNodes (template_spans));

        // continue compiling
        // Capture CRITICAL assertions from the Vala library to detect
        // corrupted symbols (e.g. from GIR package loading).  If any
        // are logged we mark the compilation so analyzers can skip it.
        var had_critical = false;
        uint vala_log_handler = Log.set_handler ("vala", LogLevelFlags.LEVEL_CRITICAL,
            (domain, levels, message) => { had_critical = true; });
        code_context.check ();
        Log.remove_handler ("vala", vala_log_handler);
        if (had_critical)
            has_corrupted_symbols = true;

        // generate output files
        // generate VAPI
        if (_output_vapi != null) {
            // create the directories if they don't exist
            DirUtils.create_with_parents (Path.get_dirname (_output_vapi), 0755);
            var interface_writer = new Vala.CodeWriter ();
            interface_writer.write_file (code_context, _output_vapi);
        }

        // write output GIR
        if (_output_gir != null) {
            // TODO: output GIR (Vala.GIRWriter is private)
        }

        // write out internal VAPI
        if (_output_internal_vapi != null) {
            // create the directories if they don't exist
            DirUtils.create_with_parents (Path.get_dirname (_output_internal_vapi), 0755);
            var interface_writer = new Vala.CodeWriter (Vala.CodeWriterType.INTERNAL);
            interface_writer.write_file (code_context, _output_internal_vapi);
        }

        // update C name map for package files
        cname_to_sym.clear ();
        foreach (Vala.SourceFile source_file in code_context.get_source_files ()) {
            if (source_file.file_type == Vala.SourceFileType.PACKAGE)
                source_file.accept (new CNameMapper (cname_to_sym));
        }

        // remove analyses for sources that are no longer a part of the code context
        var removed_sources = new Vala.HashSet<Vala.SourceFile> ();
        removed_sources.add_all (code_context.get_source_files ());
        foreach (var entry in _project_sources) {
            var text_document = entry.value;
            text_document.last_fresh_content = text_document.content;
            removed_sources.remove (entry.value);
        }
        foreach (var source in removed_sources)
            _analysis_cache.invalidate_for_file (source.filename);

        _completed_first_compile = true;
        _packages_loaded = true;
        Vala.CodeContext.pop ();
        debug ("finished compiling %s", id);
    }

    /**
     * Check whether this compilation needs to be recompiled.
     * Does NOT trigger any compilation — just checks staleness.
     */
    public bool is_stale () {
        if (!_completed_first_compile)
            return true;

        foreach (Map.Entry<File, BuildTarget> dep in dependencies) {
            if (_file_cache[dep.key].last_updated > last_updated)
                return true;
        }
        foreach (TextDocument doc in _project_sources.values) {
            if (doc.last_updated > last_updated) {
                debug ("[SEMTOK] is_stale: stale due to %s (lu=%s > comp_lu=%s)",
                       Util.project_path (doc.filename),
                       Util.ts_to_string (doc.last_updated), Util.ts_to_string (last_updated));
                return true;
            }
        }
        return false;
    }

    public override void build_if_stale (Cancellable? cancellable = null) throws Error {
        if (_project_sources.is_empty)
            // configure for first time
            configure (cancellable);

        bool updated_file = false;

        foreach (Map.Entry<File, BuildTarget> dep in dependencies) {
            if (_file_cache[dep.key].last_updated > last_updated) {
                // stale — will be caught below
                break;
            } else if (dep.value.last_updated > last_updated) {
                // dep was updated but file is the same
                updated_file = true;
            }
        }

        bool needs_rebuild = is_stale ();
        if (needs_rebuild) {
            debug ("[SEMTOK] build_if_stale: recompiling");
            var compile_start = GLib.get_monotonic_time ();
            configure (cancellable);
            cancellable.set_error_if_cancelled ();
            debug ("[SEMTOK] compile: starting");
            compile ();
            var compile_elapsed = GLib.get_monotonic_time () - compile_start;
            debug ("[SEMTOK] compile: done in %.3fs",
                   compile_elapsed / 1000000.0);
        }

        // update all output files
        foreach (var file in output)
            _file_cache.update (file, cancellable);

        // update last_updated AFTER file cache updates so is_stale()
        // doesn't think files are newer than the compilation
        if (needs_rebuild || updated_file)
            last_updated = GLib.get_real_time ();
    }

    /**
     * Result of an asynchronous compilation, ready to be swapped into
     * the main-thread Compilation via {@link swap_compile_result}.
     */
    public class CompileResult {
        public Vala.CodeContext code_context;
        public HashSet<Vala.LocalVariable> var_decls;
        public HashMap<Vala.CodeNode, int> method_calls;
        public HashMap<Vala.SourceFile, Gee.List<TemplateSpan>> template_spans;
        public HashMap<string, Vala.Symbol> cname_to_sym;
        public int64 last_updated;
        public bool has_corrupted_symbols;
    }

    /**
     * Run configure() + compile() on a worker thread with an isolated
     * CodeContext. Returns a {@link CompileResult} that can be swapped
     * into the main-thread Compilation on the main loop.
     *
     * The worker creates its own CodeContext and TextDocument objects;
     * the main thread's state is never touched.
     */
    public CompileResult compile_on_worker (Cancellable? cancellable = null) throws Error {
        var result = new CompileResult ();
        result.var_decls = new HashSet<Vala.LocalVariable> ();
        result.method_calls = new HashMap<Vala.CodeNode, int> ();
        result.template_spans = new HashMap<Vala.SourceFile, Gee.List<TemplateSpan>> ();
        result.cname_to_sym = new HashMap<string, Vala.Symbol> ();

        // Create isolated context using shared helper
        var worker_ctx = create_code_context ();
        result.code_context = worker_ctx;
        Vala.CodeContext.push (worker_ctx);

        // Create worker-local TextDocuments from the main thread's content
        var worker_sources = new HashMap<File, TextDocument> (Util.file_hash, Util.file_equal);
        foreach (var entry in _project_sources) {
            var doc = new TextDocument (worker_ctx, entry.key, entry.value.content, true);
            worker_sources[entry.key] = doc;
            worker_ctx.add_source_file (doc);
            doc.current_using_directives.clear ();
            add_profile_using_directive (worker_ctx, doc, true);
            doc.get_comments ().clear ();
            doc.get_nodes ().clear ();
        }

        foreach (string package in _packages)
            worker_ctx.add_external_package (package);

        // Bug #1: Add generated sources to worker context (same as compile()).
        foreach (File generated_file in _generated_sources) {
            try {
                if (!generated_file.query_exists ())
                    throw new FileError.NOENT ("file does not exist");
                worker_ctx.add_source_file (new TextDocument (worker_ctx, generated_file));
            } catch (Error e) {
                warning ("compile_on_worker: could not add generated file for %s: %s - %s",
                         id, generated_file.get_uri (), e.message);
                Vala.CodeContext.pop ();
                throw e;
            }
        }

        // Check cancellation before starting parse — a newer edit may
        // have arrived, making this compile stale.
        if (cancellable != null)
            cancellable.set_error_if_cancelled ();

        // Parse
        var vala_parser = new Vala.Parser ();
        var genie_parser = new Vala.Genie.Parser ();
        var gir_parser = new Vala.GirParser ();
        vala_parser.parse (worker_ctx);
        if (cancellable != null)
            cancellable.set_error_if_cancelled ();
        genie_parser.parse (worker_ctx);
        if (cancellable != null)
            cancellable.set_error_if_cancelled ();
        gir_parser.parse (worker_ctx);

        // Detect parse errors — @"$(" and similar produce structurally
        // corrupted ASTs that crash libvala later (vala_callable_get_parameters,
        // vala_scope_lookup, etc).  Parse errors are distinct from type errors:
        // type errors leave the AST structurally valid.
        if (worker_ctx.report.get_errors () > 0) {
            result.has_corrupted_symbols = true;
            debug ("compile_on_worker: %s has parse errors (%d), marking corrupted",
                   id, worker_ctx.report.get_errors ());
        }

        // AST walks (inlay hints + templates) on worker
        foreach (var source_file in worker_ctx.get_source_files ()) {
            source_file.accept (new InlayHintNodes (result.var_decls, result.method_calls));
            if (cancellable != null)
                cancellable.set_error_if_cancelled ();
        }
        foreach (var source_file in worker_ctx.get_source_files ()) {
            source_file.accept (new TemplateNodes (result.template_spans));
            if (cancellable != null)
                cancellable.set_error_if_cancelled ();
        }

        // Check cancellation before the expensive type-check —
        // this is the dominant cost and the best place to bail out.
        if (cancellable != null)
            cancellable.set_error_if_cancelled ();

        // Type check
        var worker_had_critical = false;
        uint worker_log_handler = Log.set_handler ("vala", LogLevelFlags.LEVEL_CRITICAL,
            (domain, levels, message) => { worker_had_critical = true; });
        worker_ctx.check ();
        Log.remove_handler ("vala", worker_log_handler);
        if (worker_had_critical)
            result.has_corrupted_symbols = true;
        if (cancellable != null)
            cancellable.set_error_if_cancelled ();

        // C name map
        foreach (Vala.SourceFile source_file in worker_ctx.get_source_files ()) {
            if (source_file.file_type == Vala.SourceFileType.PACKAGE)
                source_file.accept (new CNameMapper (result.cname_to_sym));
        }

        result.last_updated = GLib.get_real_time ();
        Vala.CodeContext.pop ();
        return result;
    }

    /**
     * Swap the result of {@link compile_async} into this Compilation's
     * state. Called on the main thread after the worker finishes.
     *
     * Returns true if the swap was accepted, false if rejected (corrupted AST).
     * When rejected, the old (valid, just stale) AST is preserved.
     */
    public bool swap_compile_result (CompileResult result) {
        if (result.has_corrupted_symbols) {
            debug ("swap_compile_result: %s has corrupted symbols, rejecting swap", id);
            has_corrupted_symbols = true;
            last_updated = result.last_updated;
            _completed_first_compile = true;
            return false;
        }
        // Keep the old CodeContext alive until all in-flight handlers finish.
        // Without this, handlers that captured references to old AST nodes
        // (SourceFile, TemplateSpan, etc.) get dangling pointers after free.
        // The field holds a strong reference; the idle handler clears it.
        _previous_code_context = code_context;
        code_context = result.code_context;
        // Schedule clear on idle — runs after ALL pending main-loop events
        // (i.e. all in-flight handlers) have completed.
        Idle.add (() => { _previous_code_context = null; return Source.REMOVE; });

        // Rebuild _project_sources from the swapped-in code_context so that
        // the next edit/compile cycle sees the same TextDocument objects.
        // Without this, _project_sources contains stale main-thread docs
        // while code_context has fresh worker docs — divergence causes
        // CRITICAL assertions in the Vala parser on subsequent compiles.
        // Save filename -> old File key mapping before clearing so the
        // new TextDocuments can reuse the original File keys (avoids
        // creating URI-based Files from paths, which breaks file_hash).
        var old_keys_by_filename = new HashMap<string, File> ();
        foreach (var entry in _project_sources)
            old_keys_by_filename[entry.value.filename] = entry.key;

        _project_sources.clear ();
        foreach (var source in code_context.get_source_files ()) {
            if (source is TextDocument) {
                File key = old_keys_by_filename[source.filename];
                _project_sources[key ?? File.new_for_path (source.filename)] = (TextDocument) source;
            }
        }

        // Remap template_spans keys from worker source files to _project_sources
        // TextDocuments (now rebuilt from the swapped context so identities match).
        var main_files_by_name = new HashMap<string, Vala.SourceFile> ();
        foreach (var entry in _project_sources)
            main_files_by_name[entry.value.filename] = entry.value;

        var remapped_spans = new HashMap<Vala.SourceFile, Gee.List<TemplateSpan>> ();
        foreach (var entry in result.template_spans) {
            var main_file = main_files_by_name[entry.key.filename];
            if (main_file != null)
                remapped_spans[main_file] = entry.value;
            else
                remapped_spans[entry.key] = entry.value;
        }
        template_spans = remapped_spans;

        var_decls = result.var_decls;
        method_calls = result.method_calls;
        template_spans = remapped_spans;
        cname_to_sym = result.cname_to_sym;
        last_updated = result.last_updated;
        _completed_first_compile = true;
        _packages_loaded = true;

        // Bug #2: Update last_fresh_content on all project sources
        // (matches compile() line 463 — needed by CodeStyleAnalyzer).
        foreach (var entry in _project_sources)
            entry.value.last_fresh_content = entry.value.content;

        // Bug #3: Write VAPI/GIR output on the main thread after swap.
        // The worker context has the fresh AST; write outputs now before
        // the old context is garbage-collected.
        if (_output_vapi != null) {
            DirUtils.create_with_parents (Path.get_dirname (_output_vapi), 0755);
            var interface_writer = new Vala.CodeWriter ();
            interface_writer.write_file (code_context, _output_vapi);
        }
        if (_output_internal_vapi != null) {
            DirUtils.create_with_parents (Path.get_dirname (_output_internal_vapi), 0755);
            var interface_writer = new Vala.CodeWriter (Vala.CodeWriterType.INTERNAL);
            interface_writer.write_file (code_context, _output_internal_vapi);
        }

        // Invalidate ALL cached analyses — the code_context was swapped to a
        // new instance, so any analyzer holding references to the old AST must
        // be recreated.  The stale check (analysis.last_updated < compilation.last_updated)
        // may not fire when the user's request arrives before an async swap completes,
        // so we aggressively wipe the cache for every project source.
        foreach (var entry in _project_sources)
            _analysis_cache.invalidate_for_file (entry.value.filename);

        // Update TextDocument contexts to point to the new code_context
        foreach (var entry in _project_sources)
            entry.value.context = code_context;
        return true;
    }

    /**
     * Get the analysis for the source file via the project-level AnalysisCache.
     */
    public T? get_analysis_for_file<T> (Vala.SourceFile source) {
        return _analysis_cache.get_analysis_for_file<T> (this, source);
    }

    public bool lookup_input_source_file (File file, out Vala.SourceFile input_source) {
        string? path = file.get_path ();
        string? filename = path != null ? Util.realpath (path) : null;
        string uri = file.get_uri ();
        foreach (var source_file in code_context.get_source_files ()) {
            if ((filename != null && Util.realpath (source_file.filename) == filename) || source_file.filename == uri) {
                input_source = source_file;
                return true;
            }
        }
        input_source = null;
        return false;
    }

    public Collection<Vala.SourceFile> get_project_files () {
        return _project_sources.values;
    }
}
