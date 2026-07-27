/* analysis_cache.vala
 *
 * Copyright 2024 Vala Language Server Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Gee;

/**
 * Project-level cache for per-file analyses (CodeStyleAnalyzer,
 * SymbolEnumerator, CodeLensAnalyzer, SemanticTokensAnalyzer).
 *
 * Keyed by (filename, Compilation identity) so that the same source file
 * used by multiple compilations (e.g. library + test target) gets isolated
 * caches.  Analyses survive individual compilation rebuilds (swap_compile_result)
 * because the Compilation object identity is stable across swaps.
 */
class Vls.AnalysisCache : Object {
    // _cache[filename][compilation][type] -> analyzer
    private HashMap<string, HashMap<Compilation, HashMap<Type, AbstractAnalyzer>>> _cache;

    public AnalysisCache () {
        _cache = new HashMap<string, HashMap<Compilation, HashMap<Type, AbstractAnalyzer>>> ();
    }

    public void invalidate_for_file (string filename) {
        _cache.unset (filename);
    }

    /**
     * Get or create the analysis of type T for the given source file.
     * Each (filename, Compilation) pair has its own isolated cache.
     */
    public T? get_analysis_for_file<T> (Compilation compilation, Vala.SourceFile source) {
        // Level 1: by filename
        var comp_cache = _cache[source.filename];
        if (comp_cache == null) {
            comp_cache = new HashMap<Compilation, HashMap<Type, AbstractAnalyzer>> ();
            _cache[source.filename] = comp_cache;
        }

        // Level 2: by compilation identity
        var type_cache = comp_cache[compilation];
        if (type_cache == null) {
            type_cache = new HashMap<Type, AbstractAnalyzer> ();
            comp_cache[compilation] = type_cache;
        }

        AbstractAnalyzer? analysis = null;
        bool has_cached = type_cache.has_key (typeof (T));

        if (!has_cached || type_cache[typeof (T)].last_updated < compilation.last_updated) {
            if (has_cached)
                Logger.debug ("compile", "get_analysis_for_file: stale %s for %s (comp_lu=%s)",
                       typeof (T).name (), source.filename,
                       Util.ts_to_string (compilation.last_updated));
            else
                Logger.debug ("compile", "get_analysis_for_file: no cached %s for %s, creating",
                       typeof (T).name (), source.filename);
            Vala.CodeContext.push (compilation.code_context);
            try {
                if (typeof (T) == typeof (CodeStyleAnalyzer)) {
                    analysis = new CodeStyleAnalyzer (source);
                } else if (typeof (T) == typeof (SymbolEnumerator)) {
                    analysis = new SymbolEnumerator (source);
                } else if (typeof (T) == typeof (CodeLensAnalyzer)) {
                    analysis = new CodeLensAnalyzer (source);
                } else if (typeof (T) == typeof (SemanticTokensAnalyzer)) {
                    analysis = new SemanticTokensAnalyzer (source, compilation.template_spans.get (source));
                }

                if (analysis != null) {
                    analysis.last_updated = GLib.get_real_time ();
                    type_cache[typeof (T)] = analysis;
                    Logger.debug ("compile", "get_analysis_for_file: created %s, analysis_lu=%s",
                           typeof (T).name (), Util.ts_to_string (analysis.last_updated));
                }
            } finally {
                Vala.CodeContext.pop ();
            }
        } else {
            analysis = type_cache[typeof (T)];
        }

        return (T) analysis;
    }
}
