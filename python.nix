# The Python environment Strata's server and tools run in.
{ python3 }:
python3.withPackages (
  ps: with ps; [
    certifi
    charset-normalizer
    idna
    jinja2
    markupsafe
    numpy
    pillow
    psutil
    pyyaml
    regex
    requests
    tqdm
    truststore
    urllib3
  ]
)
