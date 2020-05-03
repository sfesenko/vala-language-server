vls_src = files([
  'types.vala',
  'jsonrpc.vala',
  'list_symbols.vala',
  'codehelp/completionengine.vala',
  'codehelp/find_scope.vala',
  'codehelp/find_symbol.vala',
  'codehelp/signaturehelpengine.vala',
  'codehelp/symbolextractor.vala',
  'projects/projects.vala',
  'projects/buildtarget.vala',
  'projects/buildtask.vala',
  'projects/ccproject.vala',
  'projects/compilation.vala',
  'projects/defaultproject.vala',
  'projects/mesonproject.vala',
  'projects/abstract_project.vala',
  'projects/textdocument.vala',
  'projects/project_types.vala',
  'protocol.vala',
  'server_initialize.vala',
  'server.vala',
  'servertypes.vala',
  'reporter.vala'
])

if get_option('parse_system_girs')
  vls_src += 'girdocumentation.vala'
  add_project_arguments(['--define=PARSE_SYSTEM_GIRS'], language: 'vala')
endif

if get_option('active_parameter')
  add_project_arguments(['--define=VALA_FEATURE_INITIAL_ARGUMENT_COUNT'], language: 'vala')
endif

executable('vala-language-server',
  dependencies: deps,
  sources: [vls_src, conf_file, extra_vala_sources],
  c_args: ['-DG_LOG_DOMAIN="vls"'],
  install: true)
