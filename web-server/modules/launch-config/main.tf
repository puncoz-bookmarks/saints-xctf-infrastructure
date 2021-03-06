/**
 * Infrastructure for the saintsxctf website launch configuration of EC2 instances
 * Author: Andrew Jarombek
 * Date: 12/10/2018
 */

locals {
  env = var.prod ? "prod" : "dev"
  env_tag = var.prod ? "production" : "development"
  domain_cert = var.prod ? "saintsxctf.com" : "*.saintsxctf.com"
}

#-----------------------
# Existing AWS Resources
#-----------------------

data "aws_vpc" "saints-xctf-vpc" {
  tags = {
    Name = "saints-xctf-com-vpc"
  }
}

data "aws_subnet" "saints-xctf-vpc-public-subnet-0" {
  tags = {
    Name = "saints-xctf-com-lisag-public-subnet"
  }
}

data "aws_subnet" "saints-xctf-vpc-public-subnet-1" {
  tags = {
    Name = "saints-xctf-com-megank-public-subnet"
  }
}

data "aws_ami" "saints-xctf-ami" {
  most_recent = true

  filter {
    name = "name"
    values = ["saints-xctf-web-server*"]
  }

  owners = ["739088120071"]
}

data "aws_iam_role" "s3-access-role" {
  name = "s3-access-role"
}

data "aws_acm_certificate" "saints-xctf-certificate" {
  domain = "${local.domain_cert}"
  statuses = ["ISSUED"]
}

data "aws_acm_certificate" "saints-xctf-wildcard-certificate" {
  domain = "*.${local.domain_cert}"
  statuses = ["ISSUED"]
}

data "template_file" "saints-xctf-startup" {
  template = file("${path.module}/saints-xctf-startup.sh")

  vars = {
    ENV = var.prod ? "prod" : "dev"
    DOMAIN = "saintsxctf.com."
    SUBDOMAIN = var.prod ? "saintsxctf.com." : "dev.saintsxctf.com."
    URL = var.prod ? "saintsxctf.com" : "dev.saintsxctf.com"

    # We still have to declare variables here that are assigned values in the script
    SaintsXCTFRecord = ""
    HostedZoneId = ""
  }
}

#--------------------------------------
# Executed Before Resources are Created
#--------------------------------------

/* Before creating any AWS resources, create an SSH key used to connect to the web server */
resource "null_resource" "saints-xctf-key-gen" {
  provisioner "local-exec" {
    command = "bash ../../modules/launch-config/saintsxctf-key-gen.sh ${var.prod ?
                  "saints-xctf-key" : "saints-xctf-dev-key"}"
  }
}

#----------------------------------------------------------
# New AWS Resources for the SaintsXCTF Launch Configuration
#----------------------------------------------------------

/* This instance profile gives the web server access to S3 fo secret files */
resource "aws_iam_instance_profile" "saints-xctf-instance-profile" {
  name = "saints-xctf-${local.env}-instance-profile"
  role = data.aws_iam_role.s3-access-role.name
}

resource "aws_launch_configuration" "saints-xctf-server-lc" {
  name = "saints-xctf-server-${local.env}-lc"
  image_id = data.aws_ami.saints-xctf-ami.id
  instance_type = "t2.micro"
  security_groups = [aws_security_group.saints-xctf-server-lc-security-group.id]
  associate_public_ip_address = true
  key_name = var.prod ? "saints-xctf-key" : "saints-xctf-dev-key"
  iam_instance_profile = aws_iam_instance_profile.saints-xctf-instance-profile.name

  user_data = data.template_file.saints-xctf-startup.rendered

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [null_resource.saints-xctf-key-gen]
}

resource "aws_autoscaling_group" "saints-xctf-asg" {
  name = "saints-xctf-server-${local.env}-asg"
  launch_configuration = aws_launch_configuration.saints-xctf-server-lc.id
  vpc_zone_identifier = [data.aws_subnet.saints-xctf-vpc-public-subnet-0.id]

  max_size = var.max_size
  min_size = var.min_size
  desired_capacity = var.desired_capacity

  target_group_arns = [
    aws_lb_target_group.saints-xctf-server-lb-target-group.arn,
    aws_lb_target_group.saints-xctf-server-lb-target-group-http.arn
  ]

  health_check_type = "ELB"
  health_check_grace_period = 600

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key = "Name"
    propagate_at_launch = true
    value = "saints-xctf-server-${local.env}-asg"
  }

  tag {
    key = "Application"
    propagate_at_launch = true
    value = "saints-xctf"
  }

  tag {
    key = "Environment"
    propagate_at_launch = true
    value = local.env_tag
  }
}

resource "aws_autoscaling_schedule" "saints-xctf-server-asg-schedule" {
  count = length(var.autoscaling_schedules)

  autoscaling_group_name = aws_autoscaling_group.saints-xctf-asg.name
  scheduled_action_name = lookup(var.autoscaling_schedules[count.index], "name", "default-schedule")

  max_size = lookup(var.autoscaling_schedules[count.index], "max_size", 0)
  min_size = lookup(var.autoscaling_schedules[count.index], "min_size", 0)
  desired_capacity = lookup(var.autoscaling_schedules[count.index], "desired_capacity", 0)

  recurrence = lookup(var.autoscaling_schedules[count.index], "recurrence", "0 5 * * *")
}

resource "aws_lb" "saints-xctf-server-application-lb" {
  name = "saints-xctf-${local.env}-server-lb"
  load_balancer_type = "application"

  subnets = [
    data.aws_subnet.saints-xctf-vpc-public-subnet-0.id,
    data.aws_subnet.saints-xctf-vpc-public-subnet-1.id
  ]

  security_groups = [aws_security_group.saints-xctf-server-lb-security-group.id]

  tags = {
    Name = "saints-xctf-server-${local.env}-application-lb"
    Application = "saints-xctf"
    Environment = local.env_tag
  }
}

resource "aws_lb_target_group" "saints-xctf-server-lb-target-group" {
  name = "saints-xctf-lb-target"

  health_check {
    interval = 10
    timeout = 5
    healthy_threshold = 3
    unhealthy_threshold = 2
    protocol = "HTTPS"
    path = "/"
    matcher = "200-299"
  }

  port = 443
  protocol = "HTTPS"
  vpc_id = data.aws_vpc.saints-xctf-vpc.id

  tags = {
    Name = "saints-xctf-${local.env}-lb-target-group"
    Application = "saints-xctf"
    Environment = local.env_tag
  }
}

resource "aws_lb_listener" "saints-xctf-server-lb-listener-https" {
  load_balancer_arn = aws_lb.saints-xctf-server-application-lb.arn
  port = 443
  protocol = "HTTPS"

  certificate_arn = data.aws_acm_certificate.saints-xctf-certificate.arn

  default_action {
    target_group_arn = aws_lb_target_group.saints-xctf-server-lb-target-group.arn
    type = "forward"
  }
}

resource "aws_lb_listener_certificate" "saints-xctf-server-lb-listener-wc-cert" {
  listener_arn    = aws_lb_listener.saints-xctf-server-lb-listener-https.arn
  certificate_arn = data.aws_acm_certificate.saints-xctf-wildcard-certificate.arn
}

resource "aws_lb_target_group" "saints-xctf-server-lb-target-group-http" {
  name = "saints-xctf-lb-target-http"

  health_check {
    interval = 10
    timeout = 5
    healthy_threshold = 3
    unhealthy_threshold = 2
    protocol = "HTTP"
    path = "/"
    matcher = "200-299"
  }

  port = 80
  protocol = "HTTP"
  vpc_id = data.aws_vpc.saints-xctf-vpc.id

  tags = {
    Name = "saints-xctf-${local.env}-lb-target-group-http"
    Application = "saints-xctf"
    Environment = local.env_tag
  }
}

resource "aws_lb_listener" "saints-xctf-server-lb-listener-http" {
  load_balancer_arn = aws_lb.saints-xctf-server-application-lb.arn
  port = 80
  protocol = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.saints-xctf-server-lb-target-group-http.arn
    type = "forward"
  }
}

resource "aws_security_group" "saints-xctf-server-lc-security-group" {
  name = "saints-xctf-${local.env}-server-lc-security-group"
  vpc_id = data.aws_vpc.saints-xctf-vpc.id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "saints-xctf-${local.env}-server-lc-security-group"
    Application = "saints-xctf"
    Environment = local.env_tag
  }
}

# You can't have both cidr_blocks and source_security_group_id in a security group rule.  Because of this limitation,
# the security group rules are separated into two resources.  One uses CIDR blocks, the other uses
# Source Security Groups.
resource "aws_security_group_rule" "saints-xctf-server-lc-security-group-rule-cidr" {
  count = length(var.launch-config-sg-rules-cidr)

  security_group_id = aws_security_group.saints-xctf-server-lc-security-group.id
  type = lookup(var.launch-config-sg-rules-cidr[count.index], "type", "ingress")

  from_port = lookup(var.launch-config-sg-rules-cidr[count.index], "from_port", 0)
  to_port = lookup(var.launch-config-sg-rules-cidr[count.index], "to_port", 0)
  protocol = lookup(var.launch-config-sg-rules-cidr[count.index], "protocol", "-1")

  cidr_blocks = [lookup(var.launch-config-sg-rules-cidr[count.index], "cidr_blocks", "")]
}

resource "aws_security_group_rule" "saints-xctf-server-lc-security-group-rule-source" {
  count = length(var.launch-config-sg-rules-source)

  security_group_id = aws_security_group.saints-xctf-server-lc-security-group.id
  type = lookup(var.launch-config-sg-rules-source[count.index], "type", "ingress")

  from_port = lookup(var.launch-config-sg-rules-source[count.index], "from_port", 0)
  to_port = lookup(var.launch-config-sg-rules-source[count.index], "to_port", 0)
  protocol = lookup(var.launch-config-sg-rules-source[count.index], "protocol", "-1")

  source_security_group_id = lookup(var.launch-config-sg-rules-source[count.index], "source_sg", "")
}

resource "aws_security_group" "saints-xctf-server-lb-security-group" {
  name = "saints-xctf-${local.env}-server-elb-security-group"
  vpc_id = data.aws_vpc.saints-xctf-vpc.id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "saints-xctf-${local.env}-server-elb-security-group"
    Application = "saints-xctf"
    Environment = local.env_tag
  }
}

resource "aws_security_group_rule" "saints-xctf-server-lb-security-group-rule-cidr" {
  count = length(var.load-balancer-sg-rules-cidr)

  security_group_id = aws_security_group.saints-xctf-server-lb-security-group.id
  type = lookup(var.load-balancer-sg-rules-cidr[count.index], "type", "ingress")

  from_port = lookup(var.load-balancer-sg-rules-cidr[count.index], "from_port", 0)
  to_port = lookup(var.load-balancer-sg-rules-cidr[count.index], "to_port", 0)
  protocol = lookup(var.load-balancer-sg-rules-cidr[count.index], "protocol", "-1")

  cidr_blocks = [lookup(var.load-balancer-sg-rules-cidr[count.index], "cidr_blocks", "")]
}

resource "aws_security_group_rule" "saints-xctf-server-lb-security-group-rule-source" {
  count = length(var.load-balancer-sg-rules-source)

  security_group_id = aws_security_group.saints-xctf-server-lb-security-group.id
  type = lookup(var.load-balancer-sg-rules-source[count.index], "type", "ingress")

  from_port = lookup(var.load-balancer-sg-rules-source[count.index], "from_port", 0)
  to_port = lookup(var.load-balancer-sg-rules-source[count.index], "to_port", 0)
  protocol = lookup(var.load-balancer-sg-rules-source[count.index], "protocol", "-1")

  source_security_group_id = lookup(var.load-balancer-sg-rules-source[count.index], "source_sg", "")
}