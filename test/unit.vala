/* unit.vala
 *
 * Unit tests for VLS utility functions, using GLib.Test.
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

using Vls.Util;
using Json;

class TestSerializable : GLib.Object, Serializable {
    public string name { get; set; }
    public int value { get; set; }
}

void test_compare_versions () {
    assert (compare_versions ("1.2.3", "1.2.4") < 0);
    assert (compare_versions ("1.2.4", "1.2.3") > 0);
    assert (compare_versions ("1.2.3", "1.2.3") == 0);
    assert (compare_versions ("1.0", "1.0.0") < 0);
    assert (compare_versions ("2.0", "1.9.9") > 0);
}

void test_get_string_pos () {
    size_t pos = get_string_pos ("line0\nline1\nline2", 1, 2);
    assert (pos == 8);
    pos = get_string_pos ("abc", 0, 0);
    assert (pos == 0);
}

void test_count_chars_in_string () {
    int last = -1;
    assert (count_chars_in_string ("a.b.c", '.', out last) == 2);
    assert (last == 3);
    assert (count_chars_in_string ("no dots", '.', out last) == 0);
}

void test_get_arguments_from_command_str () {
    try {
        var args = get_arguments_from_command_str ("vala --pkg gtk4 'my file.vala'");
        assert (args.length == 4);
        assert (args[0] == "vala");
        assert (args[1] == "--pkg");
        assert (args[2] == "gtk4");
        assert (args[3] == "my file.vala");
    } catch (RegexError e) {
        assert_not_reached ();
    }
}

void test_is_newline () {
    assert (is_newline ('\n'));
    assert (is_newline ('\r'));
    assert (!is_newline ('a'));
}

void test_arg_is_vala_file () {
    assert (arg_is_vala_file ("foo.vala"));
    assert (arg_is_vala_file ("foo.vapi"));
    assert (arg_is_vala_file ("foo.gir"));
    assert (!arg_is_vala_file ("foo.c"));
    assert (!arg_is_vala_file ("foo.txt"));
}

void test_serialize_roundtrip () {
    var obj = new TestSerializable ();
    obj.name = "hello";
    obj.value = 42;
    try {
        Variant v = object_to_variant (obj);
        var back = parse_variant<TestSerializable> (v);
        assert (back.name == "hello");
        assert (back.value == 42);
    } catch (Error e) {
        assert_not_reached ();
    }
}

void test_find_name_in_text () {
    assert (find_name_in_text ("foo bar", "foo") == 0);
    assert (find_name_in_text ("call foo()", "foo") == 5);
    assert (find_name_in_text ("foobar", "foo") == -1);
    assert (find_name_in_text ("_foobar", "foo") == -1);
    assert (find_name_in_text ("foo_bar", "foo") == -1);
    assert (find_name_in_text ("foo_bar", "foo_bar") == 0);
    assert (find_name_in_text ("foo foo", "foo") == 0);
    assert (find_name_in_text ("bar baz", "foo") == -1);
}

void test_line_byte_length () {
    assert (line_byte_length ("hello\nworld", 0) == 5);
    assert (line_byte_length ("hello\nworld", 1) == 5);
    assert (line_byte_length ("single", 0) == 6);
    assert (line_byte_length ("\n\n", 0) == 0);
    assert (line_byte_length ("\n\n", 1) == 0);
    assert (line_byte_length ("abc\n\ndef", 1) == 0);
}

void test_is_decl_keyword () {
    assert (is_decl_keyword ("public"));
    assert (is_decl_keyword ("class"));
    assert (is_decl_keyword ("namespace"));
    assert (is_decl_keyword ("foreach"));
    assert (is_decl_keyword ("yield"));
    assert (is_decl_keyword ("owned"));
    assert (is_decl_keyword ("unowned"));
    assert (is_decl_keyword ("weak"));
    assert (is_decl_keyword ("get"));
    assert (is_decl_keyword ("set"));
    assert (!is_decl_keyword ("void"));
    assert (!is_decl_keyword ("var"));
    assert (!is_decl_keyword ("int"));
    assert (!is_decl_keyword ("string"));
    assert (!is_decl_keyword ("true"));
    assert (!is_decl_keyword ("false"));
    assert (!is_decl_keyword ("null"));
    assert (!is_decl_keyword ("this"));
    assert (!is_decl_keyword ("base"));
    assert (!is_decl_keyword ("as"));
    assert (!is_decl_keyword ("is"));
    assert (!is_decl_keyword ("sizeof"));
    assert (!is_decl_keyword ("typeof"));
    assert (!is_decl_keyword ("foo"));
    assert (!is_decl_keyword (""));
}

void test_delta_encode () {
    var tokens = new Gee.ArrayList<Vls.SemanticToken> ();
    var result = delta_encode (tokens);
    assert (result.size == 0);

    var t1 = new Vls.SemanticToken ();
    t1.line = 0; t1.character = 0; t1.length = 3; t1.token_type = 1; t1.modifiers = 0;
    tokens.add (t1);
    result = delta_encode (tokens);
    assert (result.size == 5);
    assert (result[0] == 0);
    assert (result[1] == 0);
    assert (result[2] == 3);
    assert (result[3] == 1);
    assert (result[4] == 0);

    var t2 = new Vls.SemanticToken ();
    t2.line = 0; t2.character = 5; t2.length = 4; t2.token_type = 2; t2.modifiers = 0;
    tokens.add (t2);
    result = delta_encode (tokens);
    assert (result.size == 10);
    assert (result[5] == 0);
    assert (result[6] == 5);
    assert (result[7] == 4);
    assert (result[8] == 2);
    assert (result[9] == 0);

    var t3 = new Vls.SemanticToken ();
    t3.line = 1; t3.character = 2; t3.length = 5; t3.token_type = 3; t3.modifiers = 1;
    tokens.add (t3);
    result = delta_encode (tokens);
    assert (result.size == 15);
    assert (result[10] == 1);
    assert (result[11] == 2);
    assert (result[12] == 5);
    assert (result[13] == 3);
    assert (result[14] == 1);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/vls/util/compare_versions", test_compare_versions);
    Test.add_func ("/vls/util/get_string_pos", test_get_string_pos);
    Test.add_func ("/vls/util/count_chars_in_string", test_count_chars_in_string);
    Test.add_func ("/vls/util/get_arguments_from_command_str", test_get_arguments_from_command_str);
    Test.add_func ("/vls/util/is_newline", test_is_newline);
    Test.add_func ("/vls/util/arg_is_vala_file", test_arg_is_vala_file);
    Test.add_func ("/vls/util/serialize_roundtrip", test_serialize_roundtrip);
    Test.add_func ("/vls/util/find_name_in_text", test_find_name_in_text);
    Test.add_func ("/vls/util/line_byte_length", test_line_byte_length);
    Test.add_func ("/vls/util/is_decl_keyword", test_is_decl_keyword);
    Test.add_func ("/vls/util/delta_encode", test_delta_encode);
    return Test.run ();
}
