###############################################
# ALB Security Group
###############################################
resource "aws_security_group" "alb_sg" {
  name        = "${var.cluster_name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow HTTP from internet"
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

  tags = {
    Environment = var.environment
  }
}

###############################################
# Application Load Balancer
###############################################
resource "aws_lb" "app_alb" {
  name               = "${var.cluster_name}-alb"
  load_balancer_type = "application"
  internal           = false

  subnets         = module.vpc.public_subnets
  security_groups = [aws_security_group.alb_sg.id]

  tags = {
    Environment = var.environment
  }
}

###############################################
# Allow ALB -> NodePort (30080)
###############################################
resource "aws_security_group_rule" "alb_to_nodes" {
  description              = "Allow ALB to reach NodePort on worker nodes"
  type                     = "ingress"
  from_port                = 30080
  to_port                  = 30080
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = aws_security_group.alb_sg.id
}

###############################################
# Target Group
###############################################
resource "aws_lb_target_group" "app_tg" {
  name        = "${var.cluster_name}-tg"
  port        = 30080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"   # correct for NodePort

  health_check {
    path = "/"
  }

  tags = {
    Environment = var.environment
  }
}

###############################################
# HTTP Listener
###############################################
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

###############################################
# Discover ALL ASGs (EKS creates them)
###############################################
data "aws_autoscaling_groups" "all" {}

###############################################
# Filter ASGs for our nodegroup "app"
###############################################
data "aws_autoscaling_group" "app_asgs" {
  for_each = toset([
    for name in data.aws_autoscaling_groups.all.names : name
    if can(regex(".*app.*", name))   # matches nodegroup
  ])

  name = each.value
}

###############################################
# Attach ASGs to Target Group
###############################################
resource "aws_autoscaling_attachment" "asg_attachment" {
  for_each = data.aws_autoscaling_group.app_asgs

  autoscaling_group_name = each.value.name
  lb_target_group_arn   = aws_lb_target_group.app_tg.arn
}


