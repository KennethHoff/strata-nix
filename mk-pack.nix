# mkPack { name, gguf, packArgs ? [ ], meta ? { } }: a native GGUF and the
# pack strata-iq-pack builds from it, laid out as the engine's arguments take
# them: $out/model.gguf for --native, $out/pack for --pack, and
# $out/pack/tokenizer for services.strata.tokenizer.
{
  lib,
  runCommand,
  strata-iq-pack,
}:
{
  name,
  gguf,
  packArgs ? [ ],
  meta ? { },
}:
runCommand name
  {
    nativeBuildInputs = [ strata-iq-pack ];
    passthru = { inherit gguf; };
    inherit meta;
  }
  ''
    strata-iq-pack --gguf ${gguf} --out $out/pack ${lib.escapeShellArgs packArgs}
    ln -s ${gguf} $out/model.gguf
  ''
