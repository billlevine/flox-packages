{ runCommand, bash, coreutils, gnused, catalogs }:
let
  pname = "chain-mid";
  version = "1";
  dependencies = [
    catalogs.bill-levine.chain-leaf
  ];
in
runCommand "${pname}-${version}" {
  inherit pname version;
  meta.mainProgram = pname;
} ''
  mkdir -p "$out/share" "$out/bin"
  printf '%s\n' "${pname} v${version}" > "$out/share/deps-values"
  for dependency in ${builtins.concatStringsSep " " dependencies}; do
    if [ -f "$dependency/share/deps-values" ]; then
      ${gnused}/bin/sed 's/^/  /' "$dependency/share/deps-values"
    else
      ${gnused}/bin/sed 's/^/  /' "$dependency/share/value"
    fi
  done >> "$out/share/deps-values"
  cat > "$out/bin/${pname}" <<EOF
#!${bash}/bin/bash
exec ${coreutils}/bin/cat "$out/share/deps-values"
EOF
  chmod +x "$out/bin/${pname}"
''
