"""Static check: the controller release must depend on the CRD release."""
import pathlib
import re

src = pathlib.Path(__file__).parent.parent.joinpath('main.tf').read_text()
block = re.search(r'resource "helm_release" "karpenter" \{(.*?)\n\}\n', src, re.S).group(1)
assert re.search(r'depends_on\s*=\s*\[[^\]]*helm_release\.karpenter_crds', block), 'controller must depend on CRDs'
assert 'depends_on' not in re.search(r'resource "helm_release" "karpenter_crds" \{(.*?)\n\}\n', src, re.S).group(1)
