data "aws_availability_zones" "available" {}

locals {
  name = var.project_name

  tags = {
    Project = var.project_name
  }
}

/* ───────────────────────────── VPC ───────────────────────────── */

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "${local.name}-vpc"
  })
}

/* ───────────────────────────── Subnets ───────────────────────────── */

locals {
  public_subnets = {
    for idx, cidr in var.public_subnets :
    "public-${idx + 1}" => {
      cidr = cidr
      az   = data.aws_availability_zones.available.names[idx]
    }
  }

  private_subnets = {
    for idx, cidr in var.private_subnets :
    "private-${idx + 1}" => {
      cidr = cidr
      az   = data.aws_availability_zones.available.names[idx]
    }
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${local.name}-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = merge(local.tags, {
    Name = "${local.name}-${each.key}"
    Tier = "private"
  })
}

/* ───────────────────────────── IGW + RT ───────────────────────────── */

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.name}-igw"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, {
    Name = "${local.name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

/* ───────────────────────────── NAT ───────────────────────────── */

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${local.name}-nat-eip"
  })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.public)[0].id

  tags = merge(local.tags, {
    Name = "${local.name}-nat"
  })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge(local.tags, {
    Name = "${local.name}-private-rt"
  })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

/* ───────────────────────────── Security Groups ───────────────────────────── */

# ALB SG
resource "aws_security_group" "alb" {
  name   = "${local.name}-alb-sg"
  vpc_id = aws_vpc.this.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.name}-alb-sg"
  })
}

# Private EC2 / ASG instances — allow ONLY ALB
resource "aws_security_group" "app" {
  name   = "${local.name}-app-sg"
  vpc_id = aws_vpc.this.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.name}-app-sg"
  })
}

/* ───────────────────────────── ALB + TG ───────────────────────────── */

resource "aws_lb_target_group" "app" {
  name     = "${local.name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 20
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.tags, {
    Name = "${local.name}-tg"
  })
}

resource "aws_lb" "app" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = values(aws_subnet.public)[*].id

  tags = merge(local.tags, {
    Name = "${local.name}-alb"
  })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

/* ───────────────────────────── Launch Template ───────────────────────────── */

resource "aws_launch_template" "app" {
  name_prefix   = "${local.name}-app-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = base64encode(<<EOF
#!/bin/bash
set -xe
yum update -y
yum install -y httpd
echo "OK - $(hostname)" > /var/www/html/index.html
systemctl enable httpd
systemctl start httpd
EOF
)

  lifecycle {
    create_before_destroy = true
  }
}

/* ───────────────────────────── Auto Scaling Group ───────────────────────────── */

resource "aws_autoscaling_group" "app" {
  name                      = "${local.name}-asg"
  desired_capacity          = 2
  min_size                  = 2
  max_size                  = 3
  health_check_type         = "ELB"
  health_check_grace_period = 60

  vpc_zone_identifier = values(aws_subnet.private)[*].id

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.app.arn]

  force_delete = true

  lifecycle {
    create_before_destroy = true
  }
}
