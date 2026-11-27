output "images" {
  description = "Built images keyed by image name."
  value = {
    for key, image in var.images : key => {
      ami_id          = aws_ami.this[key].id
      installer_image = data.talos_image_factory_urls.this[key].urls.installer
      schematic_id    = talos_image_factory_schematic.this[key].id
      talos_version   = image.talos_version
      architecture    = image.architecture
      snapshot_id     = aws_ebs_snapshot_import.this[key].id
    }
  }
}
