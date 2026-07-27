/* textdocument.vala
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

using Vala;

class Vls.TextDocument : SourceFile {
    // Cached line-start index, rebuilt lazily when the content changes.
    // See {@link byte_offset} for the rationale (turns O(n) per-call
    // position conversion into O(log n) after the first build).
    private Vls.Foundation.LineIndex? _line_index = null;
    private unowned string? _line_index_buf = null;

    /**
     * Convert a zero-based (line, character) position in this document's
     * current {@link content} to a byte offset.
     *
     * Backed by a lazily-built, content-keyed {@link Vls.Foundation.LineIndex},
     * so repeated conversions against the same buffer (the common case during
     * editing and request handling) are O(log n) rather than O(n). The cache
     * is invalidated automatically whenever {@link content} is replaced.
     */
    public long byte_offset (uint line, uint character) {
        unowned string buf = this.content;
        if (_line_index == null || _line_index_buf != buf) {
            _line_index = new Vls.Foundation.LineIndex (buf);
            _line_index_buf = buf;
        }
        return _line_index.byte_offset_for_char (line, character);
    }

    /**
     * This must be manually updated by anything that changes the content
     * of this document.
     */
    public int64 last_updated { get; set; default = GLib.get_real_time (); }
    public int version { get; set; }

    public int last_saved_version { get; private set; }
    private string? _last_saved_content = null;
    public string last_saved_content {
        get {
            if (_last_saved_content == null)
                return this.content;
            return _last_saved_content;
        }
        set {
            _last_saved_content = value;
            last_saved_version = version;
        }
    }

    private string? _last_fresh_content = null;

    /**
     * The contents at the time of compilation.
     */
    public string last_fresh_content {
        get {
            if (_last_fresh_content == null)
                return this.content;
            return _last_fresh_content;
        }
        set {
            _last_fresh_content = value;
        }
    }

    public TextDocument (CodeContext context, File file, string? content = null, bool cmdline = false) throws FileError {
        string? cont = content;
        string uri = file.get_uri ();
        string? path = file.get_path ();
        path = path != null ? Util.realpath (path) : null;
        if (path != null && cont == null)
            FileUtils.get_contents (path, out cont);
        else if (path == null && cont == null)
            throw new FileError.NOENT (@"file $(uri) does not exist either on the system or in memory");
        SourceFileType ftype;
        if (uri.has_suffix (".vapi") || uri.has_suffix (".gir"))
            ftype = SourceFileType.PACKAGE;
        else if (uri.has_suffix (".vala") || uri.has_suffix (".gs"))
            ftype = SourceFileType.SOURCE;
        else {
            ftype = SourceFileType.NONE;
            Logger.warn ("compile", "file %s is neither a package nor a source file", uri);
        }
        // prefer paths to URIs, unless we don't have a path
        // (this happens when we have just opened a new file in some editors)
        base (context, ftype, path ?? uri, cont, cmdline);
    }
}
