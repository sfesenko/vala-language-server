/* documentationengine.vala
 *
 * Documentation engine for VLS. Extracted from Server to break circular dependency.
 *
 * Copyright 2026 Sergii Fesenko
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

class Vls.DocumentationEngine : Object {
    private GirDocumentation _documentation;
    private Gee.HashMap<Vala.Symbol, DocComment?> _doc_cache = new Gee.HashMap<Vala.Symbol, DocComment?> ();

    public DocumentationEngine (GirDocumentation documentation) {
        _documentation = documentation;
    }

    public GirDocumentation gir {
        get { return _documentation; }
    }

    public void clear_cache () {
        _doc_cache.clear ();
    }

    public DocComment? get_symbol_documentation (Project project, Vala.Symbol sym) {
        if (_doc_cache.has_key (sym))
            return _doc_cache[sym];

        Compilation compilation = null;
        Vala.Symbol real_sym = SymbolReferences.find_real_symbol (project, sym);
        sym = real_sym;
        Vala.Symbol root = null;
        for (var node = sym; node != null; node = node.parent_symbol)
            root = node;
        if (root == null) {
            _doc_cache[sym] = null;
            return null;
        }
        foreach (var project_compilation in project.get_compilations ()) {
            if (project_compilation.code_context.root == root) {
                compilation = project_compilation;
                break;
            }
        }

        if (compilation == null) {
            _doc_cache[sym] = null;
            return null;
        }

        Vala.Comment? comment = null;
        DocComment? doc_comment = null;
        var gir_sym = _documentation.find_gir_symbol (sym);
        if (gir_sym != null && gir_sym.comment != null)
            comment = gir_sym.comment;
        else
            comment = sym.comment;

        if (comment != null) {
            try {
                if (comment is Vala.GirComment || gir_sym != null && gir_sym.comment == comment)
                    doc_comment = new DocComment.from_gir_comment (comment, _documentation, compilation);
                else
                    doc_comment = new DocComment.from_valadoc_comment (comment, sym, compilation);
            } catch (RegexError e) {
                warning ("failed to render comment - %s", e.message);
            }
        }

        if (doc_comment == null && sym is Vala.Parameter) {
            var parent_doc = get_symbol_documentation (project, sym.parent_symbol);
            if (parent_doc != null) {
                string? doc = parent_doc.parameters[sym.name];
                if (doc != null)
                    doc_comment = new DocComment (doc);
            }
        }

        _doc_cache[sym] = doc_comment;
        return doc_comment;
    }
}
