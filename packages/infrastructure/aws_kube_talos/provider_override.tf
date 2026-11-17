# Cluster discovery tags belong to this module; the inherited provider ignores them.
provider "aws" {
  ignore_tags {
    key_prefixes = ["karpenter.sh"]
  }
}
