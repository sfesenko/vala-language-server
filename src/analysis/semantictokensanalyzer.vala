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
    class SemanticToken : Object {
        public uint line { get; set; }
        public uint character { get; set; }
        public uint length { get; set; }
        public uint token_type { get; set; }
        public uint modifiers { get; set; }
    }

    /**
     * LSP semantic token type indices.
     */
    enum SemanticTokenType {
        NAMESPACE = 0,
        CLASS = 1,
        ENUM = 2,
        INTERFACE = 3,
        STRUCT = 4,
        TYPE_PARAMETER = 5,
        TYPE = 6,
        PARAMETER = 7,
        VARIABLE = 8,
        PROPERTY = 9,
        ENUM_MEMBER = 10,
        EVENT = 11,
        FUNCTION = 12,
        METHOD = 13,
        KEYWORD = 14,
        STRING = 15,
        NUMBER = 16,
        COMMENT = 17,
        OPERATOR = 18
    }

    /**
     * LSP semantic token modifier bit indices.
     */
    enum SemanticTokenModifier {
        DECLARATION = 0,
        DEFINITION = 1,
        READONLY = 2,
        STATIC = 3,
        DEPRECATED = 4,
        ABSTRACT = 5,
        ASYNC = 6,
        MODIFICATION = 7,
        DOCUMENTATION = 8,
        DEFAULT_LIBRARY = 9
    }

    /**
     * Analyzer that walks the full AST of a file and produces semantic tokens
     * for syntax highlighting.
     */
    class SemanticTokensAnalyzer : Vala.CodeVisitor, CodeAnalyzer {
        private Vala.SourceFile file;
        private ArrayList<SemanticToken> tokens = new ArrayList<SemanticToken> ();
        private Vala.TypeSymbol? current_type_symbol = null;
        private HashSet<Vala.CodeNode> visited_nodes = new HashSet<Vala.CodeNode> ();
        private HashSet<string> emitted_tokens = new HashSet<string> ();

        public DateTime last_updated { get; set; }

        public SemanticTokensAnalyzer (Vala.SourceFile file) {
            this.file = file;
            debug ("[SEMTOK] analyzer created, file=%s, content_len=%lu",
                   file.filename, file.content != null ? file.content.length : 0);
            this.visit_source_file (file);
        }

        public ArrayList<SemanticToken> get_tokens () {
            return tokens;
        }

        private bool try_emit_token (uint line, uint character, uint length, uint token_type, uint modifiers) {
            string key = @"$line:$character:$length:$token_type:$modifiers";
            if (emitted_tokens.contains (key))
                return false;
            emitted_tokens.add (key);
            if (tokens.size < 10)
                debug ("[SEMTOK] emit: line=%u, char=%u, len=%u, type=%u, mod=%u",
                       line, character, length, token_type, modifiers);
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
            debug ("[SEMTOK] add_token: line=%u, char=%u, len=%u, type=%u, mod=%u",
                   line, character, length, token_type, modifiers);
            try_emit_token (line, character, length, token_type, modifiers);
        }

        private int find_name_in_text (string text, string name) {
            int search_start = 0;
            while (true) {
                int pos = text.index_of (name, search_start);
                if (pos < 0)
                    return -1;
                bool prev_ok = pos == 0 || (!text[pos - 1].isalnum () && text[pos - 1] != '_');
                int name_end = pos + name.length;
                bool next_ok = name_end >= text.length || (!text[name_end].isalnum () && text[name_end] != '_');
                if (prev_ok && next_ok)
                    return pos;
                search_start = pos + 1;
            }
        }

        private uint line_byte_length (string content, uint line) {
            long line_start = (long) Util.get_string_pos (content, line, 0);
            long pos = line_start;
            while (pos < content.length && content[pos] != '\n')
                pos++;
            return (uint) (pos - line_start);
        }

        private void add_name_token (Vala.CodeNode node, string name, uint token_type, uint modifiers = 0) {
            var sr = node.source_reference;
            if (sr == null || sr.file != file)
                return;
            var content = sr.file.content;
            if (sr.file is TextDocument) {
                var fresh = ((TextDocument) sr.file).last_fresh_content;
                if (content != fresh)
                    debug ("[SEMTOK] add_name_token: content differs from last_fresh_content (" +
                           "sr: line=%d,col=%d, name=%s, content_len=%lu, fresh_len=%lu)",
                           sr.begin.line, sr.begin.column, name,
                           content != null ? content.length : 0,
                           fresh != null ? fresh.length : 0);
            }
            long from = (long) Util.get_string_pos (content, (uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1));
            long to = (long) Util.get_string_pos (content, (uint) (sr.end.line - 1), (uint) (sr.end.column));
            string text = content[from:to];
            int name_start = find_name_in_text (text, name);
            if (name_start < 0) {
                add_token (sr, token_type, modifiers);
                return;
            }
            uint line = (uint) (sr.begin.line - 1);
            uint character = (uint) (sr.begin.column - 1) + (uint) name_start;
            uint length = (uint) name.length;
            uint max_len = line_byte_length (content, line);
            if (character + length > max_len) {
                debug ("[SEMTOK] add_name_token bounds fail: line=%u, char=%u, len=%u > max=%u, type=%u, node=%s",
                       line, character, length, max_len, token_type, node.type_name);
                add_token (sr, token_type, modifiers);
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
                var content = sr.file.content;
                long from = (long) Util.get_string_pos (content, (uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1));
                long to = (long) Util.get_string_pos (content, (uint) (sr.end.line - 1), (uint) (sr.end.column));
                string text = content[from:to];
                if (text.has_prefix ("owned")) {
                    try_emit_token ((uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1), 5, SemanticTokenType.KEYWORD, 0);
                    int type_offset = 5;
                    while (type_offset < text.length && text[type_offset] == ' ')
                        type_offset++;
                    if (type_offset < text.length)
                        try_emit_token ((uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1) + (uint) type_offset, (uint) (text.length - type_offset), SemanticTokenType.TYPE, 0);
                    return;
                }
            }
            add_token (sr, SemanticTokenType.TYPE);
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

        private bool is_in_file (Vala.CodeNode? node) {
            if (node == null)
                return false;
            var sr = node.source_reference;
            return sr != null && sr.file == file;
        }

        private bool is_decl_keyword (string word) {
            switch (word) {
                case "public":
                case "private":
                case "protected":
                case "internal":
                case "static":
                case "class":
                case "abstract":
                case "virtual":
                case "override":
                case "async":
                case "new":
                case "sealed":
                case "partial":
                case "extern":
                case "inline":
                case "volatile":
                case "const":
                case "namespace":
                case "struct":
                case "enum":
                case "interface":
                case "signal":
                case "delegate":
                case "var":
                case "yield":
                case "foreach":
                case "in":
                case "return":
                case "throw":
                case "delete":
                case "lock":
                case "if":
                case "else":
                case "switch":
                case "case":
                case "default":
                case "for":
                case "while":
                case "do":
                case "try":
                case "catch":
                case "finally":
                case "break":
                case "continue":
                case "using":
                case "get":
                case "set":
                case "owned":
                case "unowned":
                case "weak":
                case "void":
                    return true;
                default:
                    return false;
            }
        }

        private void emit_leading_keyword_tokens (Vala.SourceReference sr) {
            if (sr == null || sr.file != file)
                return;
            var content = sr.file.content;
            long from = (long) Util.get_string_pos (content, (uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1));
            long to = (long) Util.get_string_pos (content, (uint) (sr.end.line - 1), (uint) (sr.end.column));
            string text = content[from:to];
            uint base_line = (uint) (sr.begin.line - 1);
            uint base_col = (uint) (sr.begin.column - 1);
            uint pos = 0;
            while (pos < text.length) {
                while (pos < text.length && text[pos] == ' ')
                    pos++;
                if (pos >= text.length || !(text[pos].isalpha () || text[pos] == '_'))
                    break;
                uint word_start = pos;
                while (pos < text.length && (text[pos].isalpha () || text[pos] == '_'))
                    pos++;
                string word = text[word_start:pos];
                if (!is_decl_keyword (word))
                    break;
                try_emit_token (base_line, base_col + word_start, pos - word_start, SemanticTokenType.KEYWORD, 0);
            }
        }

        public override void visit_source_file (Vala.SourceFile source_file) {
            if (source_file != file)
                return;
            source_file.accept_children (this);
            tokens.sort ((a, b) => {
                if (a.line != b.line)
                    return (int) a.line - (int) b.line;
                return (int) a.character - (int) b.character;
            });
            debug ("[SEMTOK] visit_source_file: produced %u tokens", tokens.size);
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
            emit_leading_keyword_tokens (m.source_reference);
            add_type_token (m.return_type);
            uint tok_type = m.coroutine ? SemanticTokenType.FUNCTION : SemanticTokenType.METHOD;
            add_name_token (m, m.name, tok_type, compute_method_modifiers (m));
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
            if (!is_implicit)
                emit_leading_keyword_tokens (m.source_reference);
            add_name_token (m, m.class_name, SemanticTokenType.METHOD, compute_method_modifiers (m));
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

        private uint sym_token_type (Vala.Symbol? sym) {
            if (sym is Vala.Method || sym is Vala.CreationMethod || sym is Vala.Destructor)
                return SemanticTokenType.METHOD;
            if (sym is Vala.Property || sym is Vala.Field)
                return SemanticTokenType.PROPERTY;
            if (sym is Vala.Signal)
                return SemanticTokenType.EVENT;
            if (sym is Vala.EnumValue)
                return SemanticTokenType.ENUM_MEMBER;
            if (sym is Vala.Constant)
                return SemanticTokenType.VARIABLE;
            if (sym is Vala.TypeSymbol)
                return SemanticTokenType.TYPE;
            if (sym is Vala.Namespace)
                return SemanticTokenType.NAMESPACE;
            if (sym is Vala.Delegate)
                return SemanticTokenType.FUNCTION;
            if (sym is Vala.LocalVariable)
                return SemanticTokenType.VARIABLE;
            if (sym is Vala.Parameter)
                return SemanticTokenType.PARAMETER;
            return 255;
        }

        private void emit_sym_token (Vala.SourceReference? sr, Vala.Symbol? sym) {
            uint tok_type = sym_token_type (sym);
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
                var sym = expr.symbol_reference;
                uint tok_type = sym_token_type (sym);
                if (tok_type < 255) {
                    uint mods = 0;
                    if (sym is Vala.Constant)
                        mods = 1u << SemanticTokenModifier.READONLY;
                    add_name_token (expr, member_name, tok_type, mods);
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
            add_token (lit.source_reference, SemanticTokenType.STRING);
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
