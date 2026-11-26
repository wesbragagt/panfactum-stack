# NOTE: Retire active groups before upgrading so they do not keep launching unmanaged workers.
removed {
  from = aws_autoscaling_group.worker

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_autoscaling_group.worker_on_demand

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_launch_template.worker

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_launch_template.worker_on_demand

  lifecycle {
    destroy = false
  }
}
