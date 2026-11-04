# Opt-in only: existing NAT instances retain their role and instance profile.
# The NAT image must already provide a running SSM agent and endpoint access.
variable "nat_ssm_enabled" {
  description = "Attach AmazonSSMManagedInstanceCore to the existing NAT role for SSM access."
  type        = bool
  default     = false
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  count = var.nat_ssm_enabled ? 1 : 0

  role       = aws_iam_role.nat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
