/**
 * Common Types, used across project 
 */
namespace Vls {

errordomain ProjectError {
    /**
     * Project backend has unsupported version.
     */
    VERSION_UNSUPPORTED,

    /**
     * Project build system is not supported
     */
    BUILD_SYSTEM_UNSUPPORTED,

    /**
     * Generic error during project introspection.
     */
    INTROSPECTION,

    /**
     * Failure during project configuration
     */
    CONFIGURATION,

    /**
     * If a build task failed. 
     */
    TASK_FAILED,

}

/**
 * Common Project interface
 */
interface Project : Object {

    /**
     * Emitted when build files change. This is mainly useful for tracking files that indirectly
     * affect Vala messages, such as C sources or build scripts.
     */
    public signal void changed ();

    /**
     * Build those elements of the project that need to be rebuilt.
     */
    public abstract void build_if_stale (Cancellable? cancellable = null) throws Error;

    /**
     * Get all unique packages used in this project
     */
    public abstract Gee.Collection<Vala.SourceFile> get_packages ();

    /**
     * Open the file
     */
    public abstract void open (string escaped_uri, Cancellable? cancellable = null) throws Error;

    /**
     * Close the file. Returns whether a context update is required.
     */   
    public abstract bool close (string escaped_uri) throws Error;

    public abstract Gee.ArrayList<Compilation> get_compilations ();

    /**
     * Reconfigure the project if there were changes to the build files that warrant doing so.
     * Returns true if the project was actually reconfigured, false otherwise.
     */
    public abstract bool reconfigure_if_stale (Cancellable? cancellable = null) throws Error;

     /**
     * Determine the Compilation that outputs `filename`
     * Return true if found, false otherwise.
     */
    public abstract bool lookup_compilation_for_output_file (string filename, out Compilation compilation);

    /**
     * Find all source files matching `escaped_uri`
     */
     public abstract Gee.ArrayList<Pair<Vala.SourceFile, Compilation>> lookup_compile_input_source_file (string escaped_uri);

    /**
     * Get all source files used in this project.
     */
    public abstract Gee.Collection<Vala.SourceFile> get_project_source_files ();

    /**
     * Contains documentation from found GIR files.
     */
    public abstract GirDocumentation? get_documentation ();
}

} // namespace