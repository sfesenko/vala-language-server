/* codehelp.vala
 *
 * Copyright 2020-2022 Princeton Ferro <princetonferro@gmail.com>
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

/**
 * Code help utilities that don't belong to any specific class
 */
namespace Vls.CodeHelp {
    /**
     * see `vala/valamemberaccess.vala`
     * This determines whether we can access a symbol in the current scope.
     */
    bool is_symbol_accessible (Vala.Symbol member, Vala.Scope current_scope) {
        if (member.access == Vala.SymbolAccessibility.PROTECTED && member.parent_symbol is Vala.TypeSymbol) {
            var target_type = (Vala.TypeSymbol) member.parent_symbol;
            bool in_subtype = false;

            for (Vala.Symbol? this_symbol = current_scope.owner;
                 this_symbol != null;
                 this_symbol = this_symbol.parent_symbol) {
                if (this_symbol == target_type) {
                    in_subtype = true;
                    break;
                }

                var cl = this_symbol as Vala.Class;
                if (cl != null && cl.is_subtype_of (target_type)) {
                    in_subtype = true;
                    break;
                }
            }

            return in_subtype;
        } else if (member.access == Vala.SymbolAccessibility.PRIVATE) {
            var target_type = member.parent_symbol;
            bool in_target_type = false;

            for (Vala.Symbol? this_symbol = current_scope.owner;
                 this_symbol != null;
                 this_symbol = this_symbol.parent_symbol) {
                if (this_symbol == target_type) {
                    in_target_type = true;
                    break;
                }
            }

            return in_target_type;
        }
        return true;
    }

    public string get_code_node_source (Vala.CodeNode node) {
        if (node is Vala.Literal)
            return node.to_string ();
        var sr = node.source_reference;
        if (sr == null)
            return @"(error - $(node.type_name) does not have source ref!)";
        // Slice against a single, consistent buffer (last-compiled contents for
        // a TextDocument, mapped contents otherwise) so offsets and the slice
        // never come from two different buffers.
        var slice = Vls.Foundation.slice_sourceref (sr);
        if (slice == null) {
            Logger.warn ("lsp", "expression %s has bad source reference %s",
                     node.to_string (), sr.to_string ());
            return node.to_string ();
        }
        return slice;
    }

    /**
     * Look for the symbol name in the current scope or try all ancestor scopes.
     */
    public Vala.Symbol? lookup_in_scope_and_ancestors (Vala.Scope scope, string name) {
        for (var current_scope = scope; current_scope != null; current_scope = current_scope.parent_scope) {
            var found_sym = current_scope.lookup (name);
            if (found_sym != null)
                return found_sym;
        }
        return null;
    }

    /**
     * Find a symbol that is imported.
     */
    public Vala.Symbol? find_imported_symbol_in_scope (Vala.Scope scope, string name) {
        if (scope.owner.source_reference != null) {
            foreach (Vala.UsingDirective ud in scope.owner.source_reference.file.current_using_directives) {
                var found_sym = ud.namespace_symbol.scope.lookup (name);
                if (found_sym != null)
                    return found_sym;
            }
        }
        return null;
    }

    public Vala.Symbol? lookup_symbol_full_name (string full_name, Vala.Scope scope,
                                                  out Gee.ArrayList<Vala.Symbol> components = null) {
        string[] symbol_names = full_name.split (".");
        Vala.Symbol? current_symbol = lookup_in_scope_and_ancestors (scope, symbol_names[0]);
        components = new Gee.ArrayList<Vala.Symbol> ();

        if (current_symbol != null)
            components.add (current_symbol);

        for (int i = 1; i < symbol_names.length && current_symbol != null; i++) {
            var found_symbol = current_symbol.scope.lookup (symbol_names[i]);
            if (found_symbol == null && symbol_names[i] == "new") {
                if (current_symbol is Vala.Class)
                    found_symbol = (((Vala.Class)current_symbol).default_construction_method
                                    as Vala.Symbol) ?? ((Vala.Class)current_symbol).constructor;
                else if (current_symbol is Vala.Struct)
                    found_symbol = ((Vala.Struct)current_symbol).default_construction_method;
            }
            if (found_symbol != null)
                components.add (current_symbol);
            current_symbol = found_symbol;
        }

        return current_symbol;
    }

    /**
     * Represent a symbol's full name in a format that's contextualized in the current scope.
     *
     * @param symbol                            the data type to represent
     * @param scope                             the current scope
     * @param hide_imported_namespace_parent    whether to not print a parent symbol if it is an imported namespace
     */
    string get_symbol_name_representation (Vala.Symbol symbol, Vala.Scope? scope,
                                            bool hide_imported_namespace_parent = false) {
        var components = new GLib.Queue<string> ();
        for (var current_symbol = symbol; current_symbol != null && current_symbol.name != null;
             current_symbol = current_symbol.parent_symbol) {
            components.push_head (current_symbol.name);
            if (scope != null && lookup_in_scope_and_ancestors (scope, current_symbol.name) == current_symbol) {
                break;
            }
            if (hide_imported_namespace_parent && scope != null
                && find_imported_symbol_in_scope (scope, current_symbol.name) == current_symbol) {
                bool symbol_ambiguity = false;
                foreach (Vala.UsingDirective ud in scope.owner.source_reference.using_directives) {
                    if (ud.namespace_symbol != current_symbol.parent_symbol
                        && ud.namespace_symbol.scope.lookup (current_symbol.name) != null) {
                        symbol_ambiguity = true;
                        break;
                    }
                }
                // don't break if another imported namespace contains the same symbol
                if (!symbol_ambiguity)
                    break;
            }
        }

        var builder = new StringBuilder ();
        while (!components.is_empty ()) {
            builder.append (components.pop_head ());
            if (!components.is_empty ())
                builder.append_c ('.');
        }

        return builder.str;
    }

    /**
     * Represent a data type in a format that's contextualized in the current scope.
     *
     * @param data_type                         the data type to represent
     * @param scope                             the current scope
     * @param hide_imported_namespace_parent    whether to not print a parent symbol if it is an imported namespace
     */
    string get_data_type_representation (Vala.DataType data_type, Vala.Scope? scope,
                                          bool hide_imported_namespace_parent = false) {
        var builder = new StringBuilder ();

        if (data_type is Vala.ArrayType) {  // ArrayType is a ReferenceType
            // see ArrayType.to_qualified_string()
            var array_type = (Vala.ArrayType) data_type;
            var elem_str = get_data_type_representation
                (array_type.element_type, scope, hide_imported_namespace_parent);
            if (array_type.element_type.is_weak () && !(array_type.parent_node is Vala.Constant)) {
                elem_str = "(unowned %s)".printf (elem_str);
            }

            if (!array_type.fixed_length)
                return "%s[%s]%s".printf (elem_str,
                    string.nfill (array_type.rank - 1, ','), array_type.nullable ? "?" : "");
            return elem_str;
        } else if (data_type is Vala.ReferenceType && data_type.symbol != null) {
            var reference_type = (Vala.ReferenceType) data_type;
            builder.append (get_symbol_name_representation
                (reference_type.symbol, scope, hide_imported_namespace_parent));
            var type_arguments = reference_type.get_type_arguments ();
            if (!type_arguments.is_empty)
                builder.append_c ('<');
            int i = 1;
            foreach (var type_argument in type_arguments) {
                if (i > 1) {
                    builder.append (", ");
                }
                if (type_argument.is_weak ())
                    builder.append ("weak ");
                builder.append (get_data_type_representation (type_argument, scope, hide_imported_namespace_parent));
                i++;
            }
            if (!type_arguments.is_empty)
                builder.append_c ('>');
            if (data_type.nullable)
                builder.append_c ('?');
        } else {
            builder.append (data_type.to_qualified_string ());
        }

        return builder.str;
    }

    /**
     * Get the nearest scope containing this node.
     */
    public Vala.Scope? get_scope_containing_node (Vala.CodeNode code_node) {
        for (Vala.CodeNode? node = code_node; node != null; node = node.parent_node) {
            if (node is Vala.Symbol) {
                var sym = (Vala.Symbol) node;
                return sym.scope;
            }
        }
        return null;
    }

}
