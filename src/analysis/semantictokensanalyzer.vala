/* semantictokensanalyzer.vala
 *
 * Copyright 2026 sfesenko
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Lsp;
using Gee;

namespace Vls {
    /**
     * A single semantic token extracted from the AST.
     */
    /**
     * Analyzer that walks the full AST of a file and produces semantic tokens
     * for syntax highlighting.
     */
    class SemanticTokensAnalyzer : AbstractAnalyzer {
        private ArrayList<SemanticToken> tokens = new ArrayList<SemanticToken> ();
        private Vala.TypeSymbol? current_type_symbol = null;
        private HashSet<Vala.CodeNode> visited_nodes = new HashSet<Vala.CodeNode> ();
        private HashSet<ulong> emitted_tokens = new HashSet<ulong> ();

        private struct Span {
            public long start;
            public long end;
        }

        // Template literals captured before check() rewrote them, used to emit
        // STRING tokens for literal segments and to tokenize the original
        // interpolated expressions (the compiler rewrites them into
        // to_string()/concat() chains whose source refs overlap the
        // original interpolation byte spans).
        private Gee.List<TemplateSpan>? captured_templates;

        // Interpolation byte spans of this file, produced by the
        // context-independent TemplateScanner. Used for range-based
        // suppression: any rewritten member access whose source ref
        // overlaps an interpolation span is skipped. This is robust
        // against Vala's rewrite (no name coupling).
    private Gee.List<Vls.Foundation.InterpolationSpan?> interpolation_spans =
        new Gee.ArrayList<Vls.Foundation.InterpolationSpan?> ();

    // True during emit_captured_template_tokens(), false during the initial
    // AST walk. When true, overlap checks are bypassed so that interpolation
    // expressions produce tokens rather than being suppressed.
    private bool _in_template_pass = false;

    // Byte ranges of every @"..." template literal in the file, used to
    // suppress ALL rewritten nodes in the initial AST walk (not just
    // .concat/.to_string, but also any synthetic node whose source ref
    // falls inside a template).
    private Gee.ArrayList<long> _template_start_offsets = new Gee.ArrayList<long> ();
    private Gee.ArrayList<long> _template_end_offsets = new Gee.ArrayList<long> ();

        // Line-start offset index for file.content, built once per analyzer so
        // that repeated offset->position conversions (template segments,
        // interpolation spans) are O(log n) instead of rescanning the buffer.
        private Vls.Foundation.LineIndex? line_index;

    public SemanticTokensAnalyzer (Vala.SourceFile file, Gee.List<TemplateSpan>? template_spans = null) {
        this.file = file;
        this.captured_templates = template_spans;

        // Guard against corrupted code_context (e.g. GIR packages with NULL symbols)
        if (file.context == null || file.context.root == null || file.context.root.scope == null) {
            Vls.Log.warn ("lsp", "SemanticTokensAnalyzer: file %s has corrupted code context — skipping", file.filename);
            return;
        }

        var buf = file.content;
        if (buf != null) {
            line_index = new Vls.Foundation.LineIndex (buf);
            // Build interpolation spans from the raw buffer scan.
            foreach (var tmpl in Vls.Foundation.scan_templates (buf)) {
                if (tmpl.start < 0 || tmpl.end > buf.length)
                    continue;
                foreach (var interp in tmpl.interpolations)
                    if (interp.start >= 0 && interp.end <= buf.length)
                        interpolation_spans.add (interp);
            }
            // Build template literal byte ranges from captured_templates
            // for suppression of EVERY synthetic node inside @"...".
            if (captured_templates != null) {
                foreach (var ts in captured_templates) {
                    var sr = ts.template;
                    if (sr.file != file)
                        continue;
                    long t_start = line_index.byte_offset_for_char (
                        (uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1));
                    long t_end = line_index.byte_offset_for_char (
                        (uint) (sr.end.line - 1), (uint) sr.end.column);
                    if (t_end > t_start) {
                        _template_start_offsets.add (t_start);
                        _template_end_offsets.add (t_end);
                    }
                }
            }
        }

        Vls.Log.debug ("lsp", "analyzer created, file=%s, content_len=%d, interp_spans=%d",
               file.filename, buf != null ? buf.length : 0, interpolation_spans.size);
        this.visit_source_file (file);
    }

        /**
         * Slice [sr] using the pre-built {@link line_index} when available,
         * falling back to {@link Vls.Foundation.slice_sourceref}. Keeps the
         * semantic-tokens walk O(1)–O(log n) per source reference instead of the
         * O(buffer) {@link Vls.Util.get_string_pos} scans (see review.md
         * residual). The analyzer's {@link line_index} is built from
         * {@link Vala.SourceFile.content}, which is the same buffer the source
         * references are addressed against.
         */
        private string? slice_ref (Vala.SourceReference? sr) {
            if (sr == null || sr.file == null)
                return null;
            return line_index != null
                ? Vls.Foundation.slice_sourceref_with (sr, line_index)
                : Vls.Foundation.slice_sourceref (sr);
        }

        /**
         * Byte length of [line] in this file, using {@link line_index} when
         * available, else {@link Vls.Util.line_byte_length}.
         */
        private uint line_len (uint line) {
            if (line_index != null)
                return (uint) line_index.byte_length_of_line (line);
            var c = Vls.Foundation.buffer_for (file);
            return c != null ? (uint) Vls.Foundation.line_byte_length (c, line) : 0;
        }

        public ArrayList<SemanticToken> get_tokens () {
            return tokens;
        }

        // Composite key capturing the full token identity used both to skip
        // duplicates (overlapping tokens break LSP clients) and to make
        // try_emit_token O(1) instead of O(n) per call (n = tokens emitted).
        // Uses uint64 hash instead of string to avoid short-lived allocations.
        private uint64 token_key (uint line, uint character, uint length, uint token_type, uint modifiers) {
            uint64 h = (uint64) line;
            h = h * 31 + (uint64) character;
            h = h * 31 + (uint64) length;
            h = h * 31 + (uint64) token_type;
            h = h * 31 + (uint64) modifiers;
            return h;
        }

        private bool try_emit_token (uint line, uint character, uint length, uint token_type, uint modifiers) {
            ulong key = (ulong) token_key (line, character, length, token_type, modifiers);
            if (emitted_tokens.contains (key))
                return false;
            emitted_tokens.add (key);
            var token = new SemanticToken ();
            token.line = line;
            token.character = character;
            token.length = length;
            token.token_type = token_type;
            token.modifiers = modifiers;
            tokens.add (token);
            return true;
        }

        private void add_token (Vala.SourceReference? source_reference, uint token_type, uint modifiers = 0) {
            if (source_reference == null || source_reference.file != file)
                return;
            var begin = source_reference.begin;
            var end = source_reference.end;
            uint line = (uint) begin.line - 1;
            uint character = (uint) begin.column - 1;
            uint length = (uint) (end.column - begin.column + 1);
            if (length == 0)
                length = 1;
            // end.column is 1-based and inclusive of the last UTF-8 column, so
            // (end.column - begin.column + 1) counts UTF-8 code points, not
            // bytes. For multi-byte characters (e.g. "héllo") that over-counts.
            // Recompute from the buffer using byte offsets when available.
            string text = slice_ref (source_reference);
            if (text != null)
                length = (uint) text.length;
            try_emit_token (line, character, length, token_type, modifiers);
        }

        private void add_name_token (Vala.CodeNode node, string? name, uint token_type, uint modifiers = 0) {
            if (name == null)
                return;
            var sr = node.source_reference;
            if (sr == null || sr.file != file)
                return;
            // Slice against the consistent (last-compiled) buffer; null on inverted
            // or empty references (Vala's template rewrite can emit these).
            string text = slice_ref (sr);
            if (text == null)
                return;
            int name_start = Util.find_name_in_text (text, name);
            if (name_start < 0) {
                if (name[0] != '.' && name[0] != '_')
                    Vls.Log.debug ("lsp", "add_name_token: name '%s' not found in text for node=%s",
                           name, node.type_name);
                return;
            }
            uint line = (uint) (sr.begin.line - 1);
            uint character = (uint) (sr.begin.column - 1) + (uint) name_start;
            uint length = (uint) name.length;
            uint max_len = line_len (line);
            if (character + length > max_len) {
                Vls.Log.debug ("lsp", "add_name_token bounds fail: line=%u, char=%u, len=%u > max=%u, type=%u, node=%s",
                       line, character, length, max_len, token_type, node.type_name);
                return;
            }
            try_emit_token (line, character, length, token_type, modifiers);
        }

        private void add_type_token (Vala.DataType? type) {
            if (type == null || !is_in_file (type))
                return;
            var sr = type.source_reference;
            if (sr == null || sr.file != file)
                return;
            if (type.value_owned) {
                string text = slice_ref (sr);
                if (text == null)
                    return;
                if (text.has_prefix ("owned")) {
                    try_emit_token ((uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1), 5, SemanticTokenType.KEYWORD, 0);
                    int type_offset = 5;
                    while (type_offset < text.length && text[type_offset] == ' ')
                        type_offset++;
                    if (type_offset < text.length)
                        try_emit_token ((uint) (sr.begin.line - 1),
                                        (uint) (sr.begin.column - 1) + (uint) type_offset,
                                        (uint) (text.length - type_offset),
                                        SemanticTokenType.TYPE, 0);
                    return;
                }
            }
            add_token (sr, SemanticTokenType.TYPE);
            foreach (var arg in type.get_type_arguments ())
                add_type_token (arg);
        }

        private uint compute_method_modifiers (Vala.Method method) {
            uint modifiers = 1u << SemanticTokenModifier.DECLARATION;
            if (method.binding == Vala.MemberBinding.STATIC)
                modifiers |= 1u << SemanticTokenModifier.STATIC;
            if (method.is_abstract)
                modifiers |= 1u << SemanticTokenModifier.ABSTRACT;
            if (method.coroutine)
                modifiers |= 1u << SemanticTokenModifier.ASYNC;
            return modifiers;
        }

        private uint compute_property_modifiers (Vala.Property prop) {
            uint modifiers = 1u << SemanticTokenModifier.DECLARATION;
            if (prop.binding == Vala.MemberBinding.STATIC)
                modifiers |= 1u << SemanticTokenModifier.STATIC;
            if (prop.is_abstract)
                modifiers |= 1u << SemanticTokenModifier.ABSTRACT;
            return modifiers;
        }

        private uint compute_field_modifiers (Vala.Field field) {
            uint modifiers = 1u << SemanticTokenModifier.DECLARATION;
            if (field.binding == Vala.MemberBinding.STATIC)
                modifiers |= 1u << SemanticTokenModifier.STATIC;
            if (field.access == Vala.SymbolAccessibility.PRIVATE)
                modifiers |= 1u << SemanticTokenModifier.READONLY;
            return modifiers;
        }

        private uint compute_constant_modifiers (Vala.Constant c) {
            uint modifiers = 1u << SemanticTokenModifier.DECLARATION;
            modifiers |= 1u << SemanticTokenModifier.READONLY;
            return modifiers;
        }

        private void emit_leading_keyword_tokens (Vala.SourceReference sr) {
            if (sr == null || sr.file != file)
                return;
            // Slice against the consistent (last-compiled) buffer; null on
            // inverted or empty references.
            string text = slice_ref (sr);
            if (text == null)
                return;
            uint base_line = (uint) (sr.begin.line - 1);
            uint base_col = (uint) (sr.begin.column - 1);
            uint pos = 0;
            while (pos < text.length) {
                while (pos < text.length && (text[pos] == ' ' || text[pos] == '\t'))
                    pos++;
                if (pos >= text.length || !(text[pos].isalpha () || text[pos] == '_'))
                    break;
                uint word_start = pos;
                while (pos < text.length && (text[pos].isalpha () || text[pos] == '_'))
                    pos++;
                string word = text[word_start:pos];
                if (!Util.is_decl_keyword (word))
                    break;
                try_emit_token (base_line, base_col + word_start, pos - word_start, SemanticTokenType.KEYWORD, 0);
            }
        }

        // Returns `true` if @a sr's byte span overlaps any scanned
        // interpolation span of this file.  Used to suppress the
        // synthetic to_string()/concat() member accesses that Vala
        // inserts when rewriting template literals.
        private bool overlaps_interpolation (Vala.SourceReference sr) {
            if (_in_template_pass || line_index == null || sr.file != file)
                return false;
            long sb = line_index.byte_offset_for_char ((uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1));
            long se = line_index.byte_offset_for_char ((uint) (sr.end.line - 1), (uint) sr.end.column);
            foreach (var span in interpolation_spans) {
                if (sb < span.end && se > span.start)
                    return true;
            }
            // Also suppress any node whose source reference falls inside
            // a template literal (@"...") — the compiler may assign
            // synthetic .concat()/.to_string() source refs to the literal
            // segments, not just the $(...) parts.
            return overlaps_template (sb, se);
        }

        private bool overlaps_template (long sb, long se) {
            for (int i = 0; i < _template_start_offsets.size; i++) {
                if (sb < _template_end_offsets[i] && se > _template_start_offsets[i])
                    return true;
            }
            return false;
        }

        public override void visit_source_file (Vala.SourceFile source_file) {
            if (source_file != file)
                return;
            source_file.accept_children (this);
            emit_captured_template_tokens ();
            tokens.sort ((a, b) => {
                if (a.line != b.line)
                    return (int) a.line - (int) b.line;
                return (int) a.character - (int) b.character;
            });
            Vls.Log.debug ("lsp", "visit_source_file: produced %u tokens", tokens.size);
        }

        public override void visit_namespace (Vala.Namespace ns) {
            if (!is_in_file (ns))
                return;
            emit_leading_keyword_tokens (ns.source_reference);
            add_name_token (ns, ns.name, SemanticTokenType.NAMESPACE);
            ns.accept_children (this);
        }

        public override void visit_class (Vala.Class cl) {
            if (!is_in_file (cl))
                return;
            if (visited_nodes.contains (cl))
                return;
            visited_nodes.add (cl);
            var prev_type = current_type_symbol;
            current_type_symbol = cl;
            emit_leading_keyword_tokens (cl.source_reference);
            add_name_token (cl, cl.name, SemanticTokenType.CLASS);
            cl.accept_children (this);
            current_type_symbol = prev_type;
        }

        public override void visit_interface (Vala.Interface iface) {
            if (!is_in_file (iface))
                return;
            if (visited_nodes.contains (iface))
                return;
            visited_nodes.add (iface);
            var prev_type = current_type_symbol;
            current_type_symbol = iface;
            emit_leading_keyword_tokens (iface.source_reference);
            add_name_token (iface, iface.name, SemanticTokenType.INTERFACE);
            iface.accept_children (this);
            current_type_symbol = prev_type;
        }

        public override void visit_struct (Vala.Struct st) {
            if (!is_in_file (st))
                return;
            if (visited_nodes.contains (st))
                return;
            visited_nodes.add (st);
            var prev_type = current_type_symbol;
            current_type_symbol = st;
            emit_leading_keyword_tokens (st.source_reference);
            add_name_token (st, st.name, SemanticTokenType.STRUCT);
            st.accept_children (this);
            current_type_symbol = prev_type;
        }

        public override void visit_enum (Vala.Enum en) {
            if (!is_in_file (en))
                return;
            if (visited_nodes.contains (en))
                return;
            visited_nodes.add (en);
            emit_leading_keyword_tokens (en.source_reference);
            add_name_token (en, en.name, SemanticTokenType.ENUM);
            en.accept_children (this);
        }

        public override void visit_enum_value (Vala.EnumValue ev) {
            if (!is_in_file (ev))
                return;
            add_token (ev.source_reference, SemanticTokenType.ENUM_MEMBER,
                       1u << SemanticTokenModifier.DECLARATION);
        }

        public override void visit_error_domain (Vala.ErrorDomain edomain) {
            if (!is_in_file (edomain))
                return;
            if (visited_nodes.contains (edomain))
                return;
            visited_nodes.add (edomain);
            emit_leading_keyword_tokens (edomain.source_reference);
            add_name_token (edomain, edomain.name, SemanticTokenType.CLASS);
            edomain.accept_children (this);
        }

        public override void visit_error_code (Vala.ErrorCode ecode) {
            if (!is_in_file (ecode))
                return;
            add_token (ecode.source_reference, SemanticTokenType.ENUM_MEMBER,
                       1u << SemanticTokenModifier.DECLARATION);
        }

        public override void visit_method (Vala.Method m) {
            if (!is_in_file (m))
                return;
            // An implicit constructor (e.g. `Foo()` for `class Foo`) is
            // represented as a Method whose name equals the enclosing type and
            // whose source reference coincides with the type declaration. Its
            // name token would therefore duplicate the already-emitted class
            // name token at the exact same position, producing overlapping
            // tokens (a violation of the LSP semantic-tokens contract). Skip
            // the name/keyword emission for it; only tokenize its body.
            bool is_implicit_ctor = current_type_symbol != null
                && m.source_reference != null
                && current_type_symbol.source_reference != null
                && m.name == current_type_symbol.name
                && m.source_reference.begin.line == current_type_symbol.source_reference.begin.line
                && m.source_reference.begin.column == current_type_symbol.source_reference.begin.column;
            if (!is_implicit_ctor) {
                emit_leading_keyword_tokens (m.source_reference);
                add_type_token (m.return_type);
                uint tok_type = m.coroutine ? SemanticTokenType.FUNCTION : SemanticTokenType.METHOD;
                add_name_token (m, m.name, tok_type, compute_method_modifiers (m));
            }
            m.accept_children (this);
        }

        public override void visit_creation_method (Vala.CreationMethod m) {
            if (!is_in_file (m))
                return;
            bool is_implicit = current_type_symbol != null
                && m.source_reference != null
                && current_type_symbol.source_reference != null
                && m.source_reference.begin.line == current_type_symbol.source_reference.begin.line
                && m.source_reference.begin.column == current_type_symbol.source_reference.begin.column;
            if (!is_implicit) {
                emit_leading_keyword_tokens (m.source_reference);
                add_name_token (m, m.class_name, SemanticTokenType.METHOD, compute_method_modifiers (m));
            }
            m.accept_children (this);
        }

        public override void visit_destructor (Vala.Destructor d) {
            if (!is_in_file (d))
                return;
            emit_leading_keyword_tokens (d.source_reference);
            add_token (d.source_reference, SemanticTokenType.METHOD);
            d.accept_children (this);
        }

        public override void visit_property (Vala.Property prop) {
            if (!is_in_file (prop))
                return;
            emit_leading_keyword_tokens (prop.source_reference);
            add_type_token (prop.property_type);
            add_name_token (prop, prop.name, SemanticTokenType.PROPERTY, compute_property_modifiers (prop));
            prop.accept_children (this);
        }

        public override void visit_field (Vala.Field f) {
            if (!is_in_file (f))
                return;
            emit_leading_keyword_tokens (f.source_reference);
            add_type_token (f.variable_type);
            add_name_token (f, f.name, SemanticTokenType.PROPERTY, compute_field_modifiers (f));
            f.accept_children (this);
        }

        public override void visit_constant (Vala.Constant c) {
            if (!is_in_file (c))
                return;
            emit_leading_keyword_tokens (c.source_reference);
            add_type_token (c.type_reference);
            add_name_token (c, c.name, SemanticTokenType.VARIABLE, compute_constant_modifiers (c));
            c.accept_children (this);
        }

        public override void visit_signal (Vala.Signal sig) {
            if (!is_in_file (sig))
                return;
            emit_leading_keyword_tokens (sig.source_reference);
            add_type_token (sig.return_type);
            add_name_token (sig, sig.name, SemanticTokenType.EVENT, 1u << SemanticTokenModifier.DECLARATION);
            sig.accept_children (this);
        }

        public override void visit_delegate (Vala.Delegate d) {
            if (!is_in_file (d))
                return;
            emit_leading_keyword_tokens (d.source_reference);
            add_type_token (d.return_type);
            add_name_token (d, d.name, SemanticTokenType.FUNCTION, 1u << SemanticTokenModifier.DECLARATION);
            d.accept_children (this);
        }

        public override void visit_formal_parameter (Vala.Parameter p) {
            if (!is_in_file (p))
                return;
            add_type_token (p.variable_type);
            add_name_token (p, p.name, SemanticTokenType.PARAMETER, 1u << SemanticTokenModifier.DECLARATION);
            p.accept_children (this);
        }

        public override void visit_local_variable (Vala.LocalVariable local) {
            if (!is_in_file (local))
                return;
            emit_leading_keyword_tokens (local.source_reference);
            add_type_token (local.variable_type);
            add_name_token (local, local.name, SemanticTokenType.VARIABLE, 1u << SemanticTokenModifier.DECLARATION);
            local.accept_children (this);
        }

        public override void visit_type_parameter (Vala.TypeParameter tp) {
            if (!is_in_file (tp))
                return;
            add_token (tp.source_reference, SemanticTokenType.TYPE_PARAMETER,
                       1u << SemanticTokenModifier.DECLARATION);
        }

        private void emit_sym_token (Vala.SourceReference? sr, Vala.Symbol? sym) {
            uint tok_type = Util.sym_token_type (sym);
            if (tok_type >= 255)
                return;
            uint mods = 0;
            if (sym is Vala.Constant)
                mods = 1u << SemanticTokenModifier.READONLY;
            add_token (sr, tok_type, mods);
        }

        public override void visit_member_access (Vala.MemberAccess expr) {
            if (!is_in_file (expr))
                return;
            string? member_name = expr.member_name;
            if (member_name != null) {
                // Qualified access (obj.method): emit token for member name only
                // Use sr.end to find the member name position, since sr.begin may
                // point to a different line (multi-line chains like obj\n  .method).
                var sr = expr.source_reference;
                // Skip the synthetic to_string()/concat() member accesses
                // that the compiler inserts when rewriting template literals.
                // Suppression uses the rewrite method names combined with
                // range overlap (double-guarded), so user-written qualified
                // accesses such as $(obj.field) still survive while the
                // compiler-generated .to_string()/.concat() chains are dropped.
                bool synthetic = (member_name == "to_string" || member_name == "concat")
                                 && sr != null && sr.file == file && overlaps_interpolation (sr);
                if (!synthetic) {
                    var sym = expr.symbol_reference;
                    uint tok_type = Util.sym_token_type (sym);
                    // Captured template expressions have no symbol_reference
                    // (captured before semantic analysis resolves symbols).
                    // Default to VARIABLE so template interps get tokens.
                    if (tok_type >= 255 && _in_template_pass)
                        tok_type = SemanticTokenType.VARIABLE;
                    if (tok_type < 255) {
                        uint mods = 0;
                        if (sym is Vala.Constant)
                            mods = 1u << SemanticTokenModifier.READONLY;
                        uint line = (uint) sr.end.line - 1;
                        uint character = (uint) sr.end.column - (uint) member_name.length;
                        uint length = (uint) member_name.length;
                        uint max_len = line_len (line);
                        if (character + length <= max_len)
                            try_emit_token (line, character, length, tok_type, mods);
                    }
                }
            } else {
                // Standalone reference (no dot): emit token for full expression
                emit_sym_token (expr.source_reference, expr.symbol_reference);
            }
            expr.accept_children (this);
        }

        public override void visit_method_call (Vala.MethodCall expr) {
            if (!is_in_file (expr))
                return;
            // Let visit_member_access or visit_simple_name handle the call target
            // through accept_children to avoid duplicate tokens.
            expr.accept_children (this);
        }

        public override void visit_object_creation_expression (Vala.ObjectCreationExpression expr) {
            if (!is_in_file (expr))
                return;
            if (expr.member_name != null && expr.member_name.source_reference != null)
                add_token (expr.member_name.source_reference, SemanticTokenType.CLASS);
            expr.accept_children (this);
        }

        public override void visit_cast_expression (Vala.CastExpression expr) {
            if (!is_in_file (expr))
                return;
            if (expr.type_reference != null && expr.type_reference.source_reference != null)
                add_token (expr.type_reference.source_reference, SemanticTokenType.TYPE);
            expr.accept_children (this);
        }

        public override void visit_type_check (Vala.TypeCheck expr) {
            if (!is_in_file (expr))
                return;
            if (expr.type_reference != null && expr.type_reference.source_reference != null)
                add_token (expr.type_reference.source_reference, SemanticTokenType.TYPE);
            expr.accept_children (this);
        }

        public override void visit_block (Vala.Block b) {
            if (!is_in_file (b))
                return;
            b.accept_children (this);
        }

        public override void visit_declaration_statement (Vala.DeclarationStatement stmt) {
            if (!is_in_file (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_using_directive (Vala.UsingDirective ud) {
            if (!is_in_file (ud))
                return;
            emit_leading_keyword_tokens (ud.source_reference);
            ud.accept_children (this);
        }

        public override void visit_expression_statement (Vala.ExpressionStatement stmt) {
            if (!is_in_file (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_return_statement (Vala.ReturnStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_if_statement (Vala.IfStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_while_statement (Vala.WhileStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_for_statement (Vala.ForStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_foreach_statement (Vala.ForeachStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_try_statement (Vala.TryStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_throw_statement (Vala.ThrowStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_switch_statement (Vala.SwitchStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_do_statement (Vala.DoStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_lock_statement (Vala.LockStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_delete_statement (Vala.DeleteStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_yield_statement (Vala.YieldStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_break_statement (Vala.BreakStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_continue_statement (Vala.ContinueStatement stmt) {
            if (!is_in_file (stmt))
                return;
            emit_leading_keyword_tokens (stmt.source_reference);
            stmt.accept_children (this);
        }

        public override void visit_character_literal (Vala.CharacterLiteral lit) {
            if (!is_in_file (lit))
                return;
            add_token (lit.source_reference, SemanticTokenType.NUMBER);
        }

        public override void visit_null_literal (Vala.NullLiteral lit) {
            if (!is_in_file (lit))
                return;
            add_token (lit.source_reference, SemanticTokenType.KEYWORD);
        }

        public override void visit_assignment (Vala.Assignment a) {
            if (!is_in_file (a))
                return;
            a.accept_children (this);
        }

        public override void visit_binary_expression (Vala.BinaryExpression expr) {
            if (!is_in_file (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_unary_expression (Vala.UnaryExpression expr) {
            if (!is_in_file (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_element_access (Vala.ElementAccess expr) {
            if (!is_in_file (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_initializer_list (Vala.InitializerList list) {
            if (!is_in_file (list))
                return;
            list.accept_children (this);
        }

        public override void visit_array_creation_expression (Vala.ArrayCreationExpression expr) {
            if (!is_in_file (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_conditional_expression (Vala.ConditionalExpression expr) {
            if (!is_in_file (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_sizeof_expression (Vala.SizeofExpression expr) {
            if (!is_in_file (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_typeof_expression (Vala.TypeofExpression expr) {
            if (!is_in_file (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_lambda_expression (Vala.LambdaExpression expr) {
            if (!is_in_file (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_switch_section (Vala.SwitchSection section) {
            if (!is_in_file (section))
                return;
            section.accept_children (this);
        }

        public override void visit_switch_label (Vala.SwitchLabel label) {
            if (!is_in_file (label))
                return;
            emit_leading_keyword_tokens (label.source_reference);
            label.accept_children (this);
        }

        public override void visit_catch_clause (Vala.CatchClause clause) {
            if (!is_in_file (clause))
                return;
            emit_leading_keyword_tokens (clause.source_reference);
            clause.accept_children (this);
        }

        public override void visit_base_access (Vala.BaseAccess expr) {
            if (!is_in_file (expr))
                return;
            add_token (expr.source_reference, SemanticTokenType.KEYWORD);
        }

        public override void visit_string_literal (Vala.StringLiteral lit) {
            if (!is_in_file (lit))
                return;
            // Suppress the raw STRING token for template literals (@"...")
            // — the template emission code handles these with separate STRING
            // tokens for literal segments and proper tokens for interpolations.
            var sr = lit.source_reference;
            if (sr != null && overlaps_template_for_sr (sr))
                return;
            add_token (sr, SemanticTokenType.STRING);
        }

        private bool overlaps_template_for_sr (Vala.SourceReference sr) {
            if (line_index == null)
                return false;
            long sb = line_index.byte_offset_for_char ((uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1));
            long se = line_index.byte_offset_for_char ((uint) (sr.end.line - 1), (uint) sr.end.column);
            return overlaps_template (sb, se);
        }

        /**
         * Emits STRING tokens for the literal segments of a template, leaving
         * gaps (no overlap) where interpolated expressions are.
         *
         * @param spans sorted, non-overlapping [start, end) ranges of the
         *             interpolated expressions, in byte offsets.
         */
        private void emit_template_gaps (string content, long t_start, long t_end, Gee.List<Span?> spans) {
            if (spans.size == 0) {
                emit_string_segment (content, t_start, t_end);
                return;
            }
            long cursor = t_start;
            foreach (var span in spans) {
                if (span.start > cursor)
                    emit_string_segment (content, cursor, span.start);
                if (span.end > cursor)
                    cursor = span.end;
            }
            if (t_end > cursor)
                emit_string_segment (content, cursor, t_end);
        }

        /**
         * Re-emits STRING tokens for the literal parts of every template that
         * was captured before check() rewrote the AST, and tokenizes the
         * interpolated expressions. The captured expression nodes are accepted
         * directly so interpolation identifiers are colored correctly whether
         * or not the original Template node survived check().
         */
    private void emit_captured_template_tokens () {
        if (captured_templates == null)
            return;
        var content = file.content;
        if (content == null)
            return;
        _in_template_pass = true;
        foreach (var ts in captured_templates) {
            emit_template_tokens_for_template (content, ts);
        }
        _in_template_pass = false;
    }

        private void emit_template_tokens_for_template (string content, TemplateSpan ts) {
            if (ts.template.file != file || line_index == null)
                return;
            var sr = ts.template;
            long t_start = line_index.byte_offset_for_char ((uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1));
            long t_end = line_index.byte_offset_for_char ((uint) (sr.end.line - 1), (uint) sr.end.column);
            // Guard against stale source references (file edited since compile)
            if (t_start < 0 || t_end > content.length || t_end <= t_start)
                return;

            // Use scanner-based interpolation spans (from current content)
            // instead of expression-based spans that match the compiled
            // (possibly stale) content.  Only include spans that fall
            // within this template's byte range.
            var spans = new Gee.ArrayList<Span?> ();
            foreach (var ispan in interpolation_spans) {
                if (ispan.start >= t_start && ispan.end <= t_end)
                    spans.add (Span () { start = ispan.start, end = ispan.end });
            }
            // Fallback: if no scanner spans found, use expression spans
            if (spans.size == 0)
                spans = build_interpolation_spans (content, ts.expression_refs);
            if (spans == null || spans.size == 0) {
                emit_string_segment (content, t_start, t_end);
                return;
            }

            emit_template_gaps (content, t_start, t_end, spans);
        }

        private Gee.ArrayList<Span?>? build_interpolation_spans (string content, Gee.List<Vala.SourceReference> refs) {
            var spans = new Gee.ArrayList<Span?> ();
            foreach (var esr in refs) {
                if (esr == null || esr.file != file || line_index == null)
                    continue;
                long eb = line_index.byte_offset_for_char ((uint) (esr.begin.line - 1), (uint) (esr.begin.column - 1));
                long ee = line_index.byte_offset_for_char ((uint) (esr.end.line - 1), (uint) esr.end.column);
                if (ee > eb)
                    spans.add (Span () { start = eb, end = ee });
            }
            if (spans.size == 0)
                return null;
            spans.sort ((a, b) => {
                if (a.start < b.start) return -1;
                if (a.start > b.start) return 1;
                return 0;
            });
            return spans;
        }

        private void emit_string_segment (string content, long start, long end) {
            if (end <= start)
                return;
            // Resolve the starting (line, character) via the per-file line
            // index instead of rescanning from byte 0 (was O(n) per call).
            var start_pos = line_index != null
                ? Vls.Foundation.offset_to_position_with (line_index, start)
                : Vls.Foundation.offset_to_position (content, start);
            long line = start_pos.line;
            long col = start_pos.character;
            long pos = start;
            while (pos < end) {
                long line_end = pos;
                while (line_end < end && content[line_end] != '\n')
                    line_end++;
                long len = line_end - pos;
                if (len > 0)
                    try_emit_token ((uint) line, (uint) col, (uint) len, SemanticTokenType.STRING, 0);
                pos = line_end;
                if (pos < end) {
                    pos++;
                    line++;
                    col = 0;
                }
            }
        }

        public override void visit_integer_literal (Vala.IntegerLiteral lit) {
            if (!is_in_file (lit))
                return;
            add_token (lit.source_reference, SemanticTokenType.NUMBER);
        }

        public override void visit_real_literal (Vala.RealLiteral lit) {
            if (!is_in_file (lit))
                return;
            add_token (lit.source_reference, SemanticTokenType.NUMBER);
        }

        public override void visit_boolean_literal (Vala.BooleanLiteral lit) {
            if (!is_in_file (lit))
                return;
            add_token (lit.source_reference, SemanticTokenType.NUMBER);
        }
    }
}
