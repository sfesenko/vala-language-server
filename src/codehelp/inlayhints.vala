/* inlayhints.vala
 *
 * Copyright 2017-2020 Princeton Ferro <princetonferro@gmail.com>
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2.1 of the
 * License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Vala;
using Lsp;

namespace Vls.InlayHints {
    class InlayHintHandler : Server.RequestHandler {
        private InlayHintParams p;

        // Pre-compiled regex to avoid Vala parser bug with /m flag on
        // regex literals (see cleanup branch review item #2).
        private static Regex? foreach_regex = null;

        public InlayHintHandler (Server.RequestContext ctx, InlayHintParams p) {
            base (ctx);
            this.p = p;
        }

        private static Regex get_foreach_regex () {
            if (foreach_regex == null) {
                try {
                    foreach_regex = new Regex ("""foreach\s*\(\s*var\s+(\w+)""", RegexCompileFlags.MULTILINE);
                } catch (RegexError e) {
                    Logger.warn ("lsp", "Failed to compile foreach regex: %s", e.message);
                    try {
                        foreach_regex = new Regex ("a^");  // matches nothing
                    } catch (RegexError e2) {
                        Logger.error ("lsp", "Cannot create fallback regex: %s", e2.message);
                    }
                }
            }
            return (!) foreach_regex;
        }

        /**
         * Scan forward from a position to find the separator after an argument.
         * Returns the number of characters to skip past last_arg_end to reach
         * just past the separator (e.g. comma + whitespace).
         * Falls back to 2 (comma + space) if scan fails.
         */
        private Position find_separator_end (string content, Position last_arg_end,
                                              Vls.Foundation.LineIndex? existing_line_index = null) {
            long idx = Vls.Foundation.byte_offset (content, last_arg_end.line, last_arg_end.character);
            if (idx < 0 || idx >= content.length)
                return new Position () { line = last_arg_end.line, character = last_arg_end.character + 2 };
            // Scan forward to find the comma, skipping commas inside strings.
            // Note: does not track nested parentheses — may find a comma inside
            // a nested call like foo(bar(1, 2), baz). Only reached on broken AST
            // (regex literal parser bug), so best-effort is acceptable.
            long scan = idx;
            bool in_string = false;
            while (scan < content.length && content[scan] != ',') {
                if (content[scan] == '"' && (scan == 0 || content[scan - 1] != '\\'))
                    in_string = !in_string;
                scan++;
            }
            if (scan >= content.length)
                return new Position () { line = last_arg_end.line, character = last_arg_end.character + 2 };
            // Found comma; skip it + any following whitespace (including newlines)
            scan++; // skip comma
            while (scan < content.length && (content[scan] == ' ' || content[scan] == '\t'
                                             || content[scan] == '\n' || content[scan] == '\r'))
                scan++;
            // Clamp to end of content
            if (scan > content.length)
                scan = content.length;
            // Convert byte offset back to line:character
            unowned Vls.Foundation.LineIndex line_index = existing_line_index ?? new Vls.Foundation.LineIndex (content);
            uint line = 0;
            long offset = 0;
            for (uint l = 0; l < line_index.line_count; l++) {
                long line_start = line_index.byte_offset (l);
                long line_end = (l + 1 < line_index.line_count) ? line_index.byte_offset (l + 1) : content.length;
                if (scan >= line_start && scan <= line_end) {
                    line = l;
                    offset = line_start;
                    break;
                }
            }
            uint character = (uint) (scan - offset);
            return new Position () { line = line, character = character };
        }

        public override void run () {
            var compilation = ctx.compilation;
            var query = new NodeSearch.within (ctx.file, p.range, false);
            if (query.result.is_empty) {
                Logger.debug ("lsp", "nothing found at %s", p.range.to_string ());
                reply_null ();
                return;
            }

            InlayHint[] hints = {};
            // Track positions to prevent overlapping hints from multiple
            // AST nodes at the same location.
            var hint_positions = new HashSet<string> ();

        foreach (var item in query.result) {
            Vala.LocalVariable? local = null;
            var representation = CodeHelp.get_code_node_source (item);
            MatchInfo foreach_match;
            if (item is Vala.DeclarationStatement)
                local = ((Vala.DeclarationStatement)item).declaration as Vala.LocalVariable;
            if (local != null && local.source_reference != null
                && local in compilation.var_decls) {
                var pos = new Position.from_libvala (local.source_reference.end);
                var key = @"$(pos.line):$(pos.character)";
                if (!hint_positions.contains (key)) {
                    hint_positions.add (key);
                    hints += new InlayHint () {
                        position = pos,
                        label = ":%s".printf (CodeHelp.get_data_type_representation (local.variable_type, null)),
                        kind = InlayHintKind.TYPE,
                        paddingLeft = true
                    };
                }
            } else if (get_foreach_regex ().match (representation, 0, out foreach_match)) {
                int start, end;
                if (foreach_match.fetch_pos (1, out start, out end)) {
                    Vala.DataType? element_type = null;
                    if (item is Vala.ForeachStatement && !(((Vala.ForeachStatement)item).type_reference is Vala.VarType) &&
                        ((Vala.ForeachStatement)item).element_variable != null) {
                        element_type = ((Vala.ForeachStatement)item).type_reference;
                    } else if (local != null) {
                        element_type = local.variable_type;
                        bool is_element_var = false;
                        for (Vala.CodeNode? current_node = local; current_node != null; current_node = current_node.parent_node) {
                            if (current_node is Vala.ForeachStatement) {
                                var stmt = (Vala.ForeachStatement)current_node;
                                is_element_var = stmt.variable_name == local.name;
                                break;
                            }
                        }
                        if (!is_element_var)
                            continue;
                    } else {
                        continue;
                    }

                    var range = SymbolReferences.get_narrowed_source_reference (item.source_reference, representation, start, end);
                    var fk = @"$(range.end.line):$(range.end.character)";
                    if (!hint_positions.contains (fk)) {
                        hint_positions.add (fk);
                        hints += new InlayHint () {
                            position = range.end,
                            label = ":%s".printf (CodeHelp.get_data_type_representation (element_type, null)),
                            kind = InlayHintKind.TYPE,
                            paddingLeft = true
                        };
                    }
                }
            } else if (item is Vala.LambdaExpression) {
                var lambda = (Vala.LambdaExpression)item;
                foreach (var param in lambda.get_parameters ()) {
                    var range = new Range.from_sourceref (param.source_reference);
                    if (param.variable_type != null) {
                        var pk = @"$(range.start.line):$(range.start.character)";
                        if (!hint_positions.contains (pk)) {
                            hint_positions.add (pk);
                            hints += new InlayHint () {
                                position = range.start,
                                label = CodeHelp.get_data_type_representation (param.variable_type, null),
                                kind = InlayHintKind.PARAMETER,
                                paddingRight = true
                            };
                        }
                    }
                }
            } else if ((item is Vala.MethodCall || item is Vala.ObjectCreationExpression) && compilation.method_calls.has_key (item)) {
                // Bug: Vala's parser creates incorrect AST source references
                // for method call arguments when the target is a regex literal
                // with flags (e.g. /pattern/m.replace(...)). The flags change
                // the literal's length, shifting all subsequent AST positions.
                // Skip parameter name hints for regex literal calls entirely
                // since their argument positions are unreliable.
                if (item is Vala.MethodCall) {
                    var mc = (Vala.MethodCall)item;
                    if (mc.call is Vala.MemberAccess && ((Vala.MemberAccess)mc.call).inner is Vala.RegexLiteral)
                        continue;
                }
                Vala.List<Vala.Parameter>? parameters = null;
                if (item is Vala.MethodCall) {
                    var mc = (Vala.MethodCall)item;
                    if (mc.call.value_type != null)
                        parameters = mc.call.value_type.get_parameters ();
                } else {
                    var oce = (Vala.ObjectCreationExpression)item;
                    if (oce.member_name != null && oce.member_name.symbol_reference is Vala.Callable)
                        parameters = ((Vala.Callable)oce.member_name.symbol_reference).get_parameters ();
                    else if (oce.type_reference != null)
                        parameters = oce.type_reference.get_parameters ();
                }
                if (parameters != null) {
                    int orig_param_count = compilation.method_calls[item];
                    var iter = parameters.iterator ();
                    var args_i = 0;
                    Vala.Parameter? last_ellipsis = null;
                    Vala.List<Vala.Expression> argument_list;
                    if (item is Vala.MethodCall)
                        argument_list = ((Vala.MethodCall)item).get_argument_list ();
                    else
                        argument_list = ((Vala.ObjectCreationExpression)item).get_argument_list ();
                    Position? last_arg_end = null;
                    foreach (var arg in argument_list) {
                        if (arg.source_reference == null) {
                            args_i++;
                            continue;
                        }
                        if (args_i >= orig_param_count)
                            break;
                        if (arg is Vala.NamedArgument) {
                            // Track position even for skipped named args so
                            // subsequent positional args don't overlap.
                            var named_range = new Range.from_sourceref (arg.source_reference);
                            if (last_arg_end == null || named_range.end.compare_to (last_arg_end) > 0)
                                last_arg_end = named_range.end;
                            args_i++;
                            continue;
                        }
                        if (!iter.next () && last_ellipsis == null)
                            break;
                        var formal_parameter = last_ellipsis ?? iter.get ();
                        if (formal_parameter.ellipsis)
                            last_ellipsis = formal_parameter;
                        var parameter_name = formal_parameter.name ?? @"arg$args_i";
                        var argument = arg;
                        if (argument is Vala.UnaryExpression &&
                            (((Vala.UnaryExpression)argument).operator == Vala.UnaryOperator.REF|| ((Vala.UnaryExpression)argument).operator == Vala.UnaryOperator.OUT))
                            argument = ((Vala.UnaryExpression)argument).inner;
                        if (CodeHelp.get_code_node_source (argument).casefold () == parameter_name.casefold ()) {
                            args_i++;
                            continue;
                        }
                        var range = new Range.from_sourceref (arg.source_reference);
                        // Guard: if this argument's start falls within the
                        // previous argument's text (incorrect AST source ref),
                        // shift the hint position just after the previous arg
                        // and the separator (comma + optional whitespace).
                        if (last_arg_end != null && range.start.compare_to (last_arg_end) < 0)
                            range.start = find_separator_end (ctx.file.content, last_arg_end);
                        var pk = @"$(range.start.line):$(range.start.character)";
                        if (!hint_positions.contains (pk)) {
                            hint_positions.add (pk);
                            hints += new InlayHint () {
                                position = range.start,
                                label = "%s:".printf (parameter_name),
                                kind = InlayHintKind.PARAMETER,
                                paddingRight = true
                            };
                        }
                        last_arg_end = range.end;
                        args_i++;
                    }
                }
            }
        }

        try {
            Variant[] array = {};
            foreach (var hint in hints)
                array += Util.object_to_variant (hint);
            reply_dict (new Variant.array (VariantType.VARDICT, array));
        } catch (Error e) {
            Logger.warn ("lsp", "failed to reply to client: %s", e.message);
        }
        }
    }
}
