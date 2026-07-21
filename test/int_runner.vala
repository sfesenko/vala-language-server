/* int_runner.vala
 *
 * Integration test runner — registers all int_ tests and runs them.
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
 * along with this program.  If not see <http://www.gnu.org/licenses/>.
 */

using GLib;

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/int/publish_diagnostics", test_publish_diagnostics);
    Test.add_func ("/int/non_native_root_survives", test_non_native_root_survives);
    Test.add_func ("/int/initialize_capabilities", test_initialize_capabilities);
    Test.add_func ("/int/document_symbol", test_document_symbol);
    Test.add_func ("/int/hover", test_hover);
    Test.add_func ("/int/goto_definition", test_goto_definition);
    Test.add_func ("/int/range_formatting", test_range_formatting);
    Test.add_func ("/int/completion", test_completion);
    Test.add_func ("/int/semantic_tokens_full", test_semantic_tokens_full);
    Test.add_func ("/int/semantic_tokens_coverage", test_semantic_tokens_coverage);
    Test.add_func ("/int/semantic_tokens_range", test_semantic_tokens_range);
    Test.add_func ("/int/semantic_tokens_template_string", test_semantic_tokens_template_string);
    Test.add_func ("/int/semantic_tokens_delta", test_semantic_tokens_delta);
    Test.add_func ("/int/references", test_references);
    Test.add_func ("/int/document_highlight", test_document_highlight);
    Test.add_func ("/int/inlay_hint", test_inlay_hint);
    Test.add_func ("/int/workspace_symbol", test_workspace_symbol);
    Test.add_func ("/int/formatting", test_formatting);
    Test.add_func ("/int/implementation", test_implementation);
    Test.add_func ("/int/log_uses_project_path", test_log_uses_project_path);
    Test.add_func ("/int/golden/document_symbol", test_golden_document_symbol);
    Test.add_func ("/int/golden/goto_definition", test_golden_goto_definition);
    Test.add_func ("/int/golden/references", test_golden_references);
    Test.add_func ("/int/golden/document_highlight", test_golden_document_highlight);
    Test.add_func ("/int/golden/implementation", test_golden_implementation);
    Test.add_func ("/int/golden/hover", test_golden_hover);
    Test.add_func ("/int/golden/rename", test_golden_rename);
    Test.add_func ("/int/golden/prepare_rename", test_golden_prepare_rename);
    Test.add_func ("/int/golden/completion", test_golden_completion);
    Test.add_func ("/int/golden/semantic_tokens_full", test_golden_semantic_tokens_full);
    Test.add_func ("/int/golden/semantic_tokens_range", test_golden_semantic_tokens_range);
    Test.add_func ("/int/golden/semantic_tokens_full_delta", test_golden_semantic_tokens_full_delta);
    Test.add_func ("/int/golden/signature_help", test_golden_signature_help);
    Test.add_func ("/int/golden/formatting", test_golden_formatting);
    Test.add_func ("/int/golden/workspace_symbol", test_golden_workspace_symbol);
    Test.add_func ("/int/golden/inlay_hint", test_golden_inlay_hint);
    Test.add_func ("/int/golden/code_lens", test_golden_code_lens);
    Test.add_func ("/int/golden/code_action", test_golden_code_action);
    Test.add_func ("/int/golden/prepare_type_hierarchy", test_golden_prepare_type_hierarchy);
    Test.add_func ("/int/golden/prepare_call_hierarchy", test_golden_prepare_call_hierarchy);
    Test.add_func ("/int/golden/type_hierarchy_supertypes", test_golden_type_hierarchy_supertypes);
    Test.add_func ("/int/golden/type_hierarchy_subtypes", test_golden_type_hierarchy_subtypes);
    Test.add_func ("/int/golden/call_hierarchy_incoming", test_golden_call_hierarchy_incoming);
    Test.add_func ("/int/golden/call_hierarchy_outgoing", test_golden_call_hierarchy_outgoing);
    Test.add_func ("/int/golden/range_formatting", test_golden_range_formatting);
    Test.add_func ("/int/regression/adversarial_smoke_template_string", test_adversarial_smoke_template_string);
    Test.add_func ("/int/regression/adversarial_smoke_single_dollar", test_adversarial_smoke_single_dollar);
    Test.add_func ("/int/regression/adversarial_smoke_inverted_ref", test_adversarial_smoke_inverted_ref);
    Test.add_func ("/int/regression/adversarial_smoke_replace_eval", test_adversarial_smoke_replace_eval);
    Test.add_func ("/int/regression/enum_base_type_completion", test_enum_base_type_completion);
    Test.add_func ("/int/regression/struct_inheritance_completion", test_struct_inheritance_completion);
    Test.add_func ("/int/regression/override_completion_with_existing_methods", test_override_completion_with_existing_methods);
    Test.add_func ("/int/perf/compile_latency", test_perf_compile_latency);
    Test.add_func ("/int/perf/semantic_tokens_latency", test_perf_semantic_tokens_latency);
    Test.add_func ("/int/perf/recompilation_after_edit", test_perf_recompilation_after_edit);
    Test.add_func ("/int/perf/semantic_tokens_after_edit", test_perf_semantic_tokens_after_edit);
    Test.add_func ("/int/perf/using_directives_survive_recompile", test_perf_using_directives_survive_recompile);
    return Test.run ();
}
