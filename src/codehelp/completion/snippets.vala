/* completion/snippets.vala
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

using Lsp;
using Gee;

namespace Vls.CompletionEngine {
    /**
     * Generate insert text for a class, struct, or interface
     */
    string? generate_insert_text_for_type_symbol (Vala.TypeSymbol type_symbol,
                                                  Vala.Scope? current_scope, uint method_spaces) {
        Vala.List<Vala.TypeParameter>? type_parameters = null;

        if (type_symbol is Vala.ObjectTypeSymbol)
            type_parameters = ((Vala.ObjectTypeSymbol)type_symbol).get_type_parameters ();
        else if (type_symbol is Vala.Struct)
            type_parameters = ((Vala.Struct)type_symbol).get_type_parameters ();
        else if (type_symbol is Vala.Delegate)
            type_parameters = ((Vala.Delegate)type_symbol).get_type_parameters ();

        if (type_parameters == null || type_parameters.is_empty)
            return null;

        var builder = new StringBuilder (type_symbol.name);
        builder.append_c ('<');
        uint p = 0;
        foreach (var type_parameter in type_parameters) {
            if (p > 0)
                builder.append (", ");
            builder.append_printf ("${%u:%s}", p + 1, type_parameter.name);
            p++;
        }
        builder.append_c ('>');
        builder.append ("$0");
        return builder.str;
    }

    string? generate_insert_text_for_callable (Vala.DataType? type, Vala.Callable callable_sym,
                                               Vala.Scope? current_scope, uint method_spaces,
                                               string? symbol_override = null) {
        var builder = new StringBuilder ();

        if (callable_sym.name == ".new") {
            if (callable_sym.parent_symbol == null) {
                warning ("parent is null for %s()", callable_sym.name);
                return null;
            }
            builder.append (symbol_override ?? callable_sym.parent_symbol.name);

            if (callable_sym.parent_symbol is Vala.ObjectTypeSymbol
                && ((Vala.ObjectTypeSymbol) callable_sym.parent_symbol).has_type_parameters ()) {
                uint num_parameters = callable_sym.get_parameters ().size;

                builder.append_c ('<');
                uint p = 0;
                foreach (var type_parameter
                         in ((Vala.ObjectTypeSymbol) callable_sym.parent_symbol).get_type_parameters ()) {
                    if (p > 0)
                        builder.append (", ");
                    builder.append_printf ("${%u:%s}", num_parameters + p + 1, type_parameter.name);
                    p++;
                }
                builder.append_c ('>');
            }
        } else {
            builder.append (symbol_override ?? callable_sym.name);

            var method_sym = callable_sym as Vala.Method;
            if (method_sym != null && method_sym.has_type_parameters ()) {
                uint num_parameters = callable_sym.get_parameters ().size;

                builder.append_c ('<');
                uint p = 0;
                foreach (var type_parameter in method_sym.get_type_parameters ()) {
                    if (p > 0)
                        builder.append (", ");
                    builder.append_printf ("${%u:%s}", num_parameters + p + 1, type_parameter.name);
                    p++;
                }
                builder.append_c ('>');
            }
        }

        builder.append (string.nfill (method_spaces, ' '));
        builder.append_c ('(');

        uint p = 0;
        Func<Vala.Parameter> serialize_parameter = (parameter) => {
            if (p > 0)
                builder.append (", ");
            if (parameter.direction == Vala.ParameterDirection.OUT)
                builder.append ("out ");
            else if (parameter.direction == Vala.ParameterDirection.REF)
                builder.append ("ref ");
            builder.append_printf ("${%u:%s}", p + 1,
                CodeHelp.get_symbol_representation (type, parameter, current_scope,
                    false, null, null, false, false, null, false));
            p++;
        };

        if (symbol_override == "begin" && callable_sym is Vala.Method && ((Vala.Method)callable_sym).coroutine) {
            foreach (var parameter in ((Vala.Method)callable_sym).get_async_begin_parameters ())
                serialize_parameter (parameter);
        } else {
            foreach (var parameter in callable_sym.get_parameters ())
                serialize_parameter (parameter);
        }
        builder.append_c (')');
        builder.append ("$0");

        return builder.str;
    }
}
