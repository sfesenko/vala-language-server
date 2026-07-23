/* templatenodes.vala
 *
 * Copyright 2026 sfesenko
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Vala;
using Gee;

namespace Vls {
    /**
     * A single template-string literal (@"...") and the expressions that are
     * interpolated inside it via $(...).
     *
     * Captured *before* the semantic analyzer rewrites every Template node into
     * a to_string()/concat() chain, because afterwards the original template and
     * its literal segments no longer exist in the AST.
     */
    public class TemplateSpan {
        public Vala.SourceReference template;
        public Gee.List<Vala.SourceReference> expression_refs = new Gee.ArrayList<Vala.SourceReference> ();
    }

    /**
     * Collects all template literals of interest to the semantic-tokens
     * analyzer. Must run before code_context.check().
     */
    class TemplateNodes : Vala.CodeVisitor {
        private Gee.HashMap<Vala.SourceFile, Gee.List<TemplateSpan>> store;

        public TemplateNodes (Gee.HashMap<Vala.SourceFile, Gee.List<TemplateSpan>> store) {
            this.store = store;
        }

        public override void visit_source_file (Vala.SourceFile source_file) {
            source_file.accept_children (this);
        }

        // Statement / declaration containers must recurse so the traversal
        // reaches every expression in the file.
        public override void visit_namespace (Vala.Namespace ns) { ns.accept_children (this); }
        public override void visit_class (Vala.Class cl) { cl.accept_children (this); }
        public override void visit_interface (Vala.Interface iface) { iface.accept_children (this); }
        public override void visit_struct (Vala.Struct st) { st.accept_children (this); }
        public override void visit_enum (Vala.Enum en) { en.accept_children (this); }
        public override void visit_error_domain (Vala.ErrorDomain ed) { ed.accept_children (this); }
        public override void visit_method (Vala.Method m) { m.accept_children (this); }
        public override void visit_creation_method (Vala.CreationMethod m) { m.accept_children (this); }
        public override void visit_destructor (Vala.Destructor d) { d.accept_children (this); }
        public override void visit_constructor (Vala.Constructor c) { c.accept_children (this); }
        public override void visit_signal (Vala.Signal sig) { sig.accept_children (this); }
        public override void visit_property (Vala.Property prop) { prop.accept_children (this); }
        public override void visit_property_accessor (Vala.PropertyAccessor acc) { acc.accept_children (this); }
        public override void visit_block (Vala.Block b) { b.accept_children (this); }
        public override void visit_declaration_statement (Vala.DeclarationStatement stmt) { stmt.accept_children (this); }
        public override void visit_local_variable (Vala.LocalVariable local) { local.accept_children (this); }
        public override void visit_expression_statement (Vala.ExpressionStatement stmt) { stmt.accept_children (this); }
        public override void visit_if_statement (Vala.IfStatement stmt) { stmt.accept_children (this); }
        public override void visit_while_statement (Vala.WhileStatement stmt) { stmt.accept_children (this); }
        public override void visit_for_statement (Vala.ForStatement stmt) { stmt.accept_children (this); }
        public override void visit_foreach_statement (Vala.ForeachStatement stmt) { stmt.accept_children (this); }
        public override void visit_do_statement (Vala.DoStatement stmt) { stmt.accept_children (this); }
        public override void visit_try_statement (Vala.TryStatement stmt) { stmt.accept_children (this); }
        public override void visit_catch_clause (Vala.CatchClause clause) { clause.accept_children (this); }
        public override void visit_switch_statement (Vala.SwitchStatement stmt) { stmt.accept_children (this); }
        public override void visit_switch_section (Vala.SwitchSection section) { section.accept_children (this); }
        public override void visit_switch_label (Vala.SwitchLabel label) { label.accept_children (this); }
        public override void visit_lock_statement (Vala.LockStatement stmt) { stmt.accept_children (this); }
        public override void visit_unlock_statement (Vala.UnlockStatement stmt) { stmt.accept_children (this); }
        public override void visit_return_statement (Vala.ReturnStatement stmt) { stmt.accept_children (this); }
        public override void visit_throw_statement (Vala.ThrowStatement stmt) { stmt.accept_children (this); }
        public override void visit_yield_statement (Vala.YieldStatement stmt) { stmt.accept_children (this); }
        public override void visit_break_statement (Vala.BreakStatement stmt) { stmt.accept_children (this); }
        public override void visit_continue_statement (Vala.ContinueStatement stmt) { stmt.accept_children (this); }
        public override void visit_using_directive (Vala.UsingDirective ud) { ud.accept_children (this); }
        public override void visit_lambda_expression (Vala.LambdaExpression expr) { expr.accept_children (this); }
        public override void visit_formal_parameter (Vala.Parameter p) { p.accept_children (this); }
        public override void visit_constant (Vala.Constant c) { c.accept_children (this); }
        public override void visit_field (Vala.Field f) { f.accept_children (this); }
        public override void visit_delegate (Vala.Delegate d) { d.accept_children (this); }
        public override void visit_enum_value (Vala.EnumValue ev) { ev.accept_children (this); }
        public override void visit_error_code (Vala.ErrorCode ec) { ec.accept_children (this); }
        public override void visit_type_parameter (Vala.TypeParameter tp) { tp.accept_children (this); }
        public override void visit_with_statement (Vala.WithStatement stmt) { stmt.accept_children (this); }

        // Expression containers must recurse so templates nested inside them
        // (method-call arguments, assignments, binary expressions, casts, ...)
        // are discovered.
        public override void visit_method_call (Vala.MethodCall expr) { expr.accept_children (this); }
        public override void visit_object_creation_expression (Vala.ObjectCreationExpression expr) {
            expr.accept_children (this);
        }
        public override void visit_assignment (Vala.Assignment a) { a.accept_children (this); }
        public override void visit_binary_expression (Vala.BinaryExpression expr) { expr.accept_children (this); }
        public override void visit_unary_expression (Vala.UnaryExpression expr) { expr.accept_children (this); }
        public override void visit_conditional_expression (Vala.ConditionalExpression expr) { expr.accept_children (this); }
        public override void visit_cast_expression (Vala.CastExpression expr) { expr.accept_children (this); }
        public override void visit_type_check (Vala.TypeCheck expr) { expr.accept_children (this); }
        public override void visit_element_access (Vala.ElementAccess expr) { expr.accept_children (this); }
        public override void visit_initializer_list (Vala.InitializerList list) { list.accept_children (this); }
        public override void visit_array_creation_expression (Vala.ArrayCreationExpression expr) { expr.accept_children (this); }
        public override void visit_sizeof_expression (Vala.SizeofExpression expr) { expr.accept_children (this); }
        public override void visit_typeof_expression (Vala.TypeofExpression expr) { expr.accept_children (this); }
        public override void visit_addressof_expression (Vala.AddressofExpression expr) { expr.accept_children (this); }
        public override void visit_pointer_indirection (Vala.PointerIndirection expr) { expr.accept_children (this); }
        public override void visit_postfix_expression (Vala.PostfixExpression expr) { expr.accept_children (this); }
        public override void visit_reference_transfer_expression (Vala.ReferenceTransferExpression expr) {
            expr.accept_children (this);
        }
        public override void visit_slice_expression (Vala.SliceExpression expr) { expr.accept_children (this); }
        public override void visit_tuple (Vala.Tuple tuple) { tuple.accept_children (this); }
        public override void visit_named_argument (Vala.NamedArgument arg) { arg.accept_children (this); }
        public override void visit_regex_literal (Vala.RegexLiteral lit) { lit.accept_children (this); }

        public override void visit_template (Vala.Template tmpl) {
            var sr = tmpl.source_reference;
            if (sr != null) {
                var list = store.get (sr.file);
                if (list == null) {
                    list = new Gee.ArrayList<TemplateSpan> ();
                    store[sr.file] = list;
                }
                var span = new TemplateSpan ();
                span.template = sr;
                foreach (var expr in tmpl.get_expressions ())
                    if (expr.source_reference != null)
                        span.expression_refs.add (expr.source_reference);
                list.add (span);
            }
            // recurse for nested templates (e.g. @"a$( @"b$(x)" )c")
            tmpl.accept_children (this);
        }
    }
}
