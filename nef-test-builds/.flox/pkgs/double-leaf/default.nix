{ runCommand, bash, coreutils }:
let
  pname = "double-leaf";
  version = "1";
in
runCommand "${pname}-${version}" {
  inherit pname version;
  meta.mainProgram = pname;
} ''
  mkdir -p "$out/share" "$out/bin"
  printf '%s\n' "${pname} v${version}" > "$out/share/value"
  cat > "$out/bin/${pname}" <<EOF
#!${bash}/bin/bash
exec ${coreutils}/bin/cat "$out/share/value"
EOF
  chmod +x "$out/bin/${pname}"
''
